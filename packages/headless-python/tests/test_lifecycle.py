from __future__ import annotations

import asyncio
import gc
import json
import os
import signal
import subprocess
import sys
import threading
import time
import traceback
import warnings
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import pytest

from headless_sdk import (
    ClientClosedError,
    HostLaunchError,
    OperationOutcomeUnknown,
    ValidationError,
    aconnect,
    alaunch,
    connect,
    launch,
)
from headless_sdk.generated import COMMAND_METADATA, LOCAL_LIFECYCLE

from .helpers import (
    PrivateSocketServer,
    host_status,
    json_frame,
    unique_socket_path,
    write_mock_launcher,
)


def environment(**extra: str) -> dict[str, str]:
    return {"HEADLESS_TEST_COMMANDS": json.dumps(list(COMMAND_METADATA)), **extra}


def process_is_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def wait_until(predicate: Any, timeout: float = 2) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("condition was not met before deadline")
        time.sleep(0.01)


def test_supervised_launch_owns_only_exact_matching_host(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    socket_path = unique_socket_path("owned")
    signal_handlers = {
        signal.SIGINT: signal.getsignal(signal.SIGINT),
        signal.SIGTERM: signal.getsignal(signal.SIGTERM),
    }
    host = launch(executable=executable, socket_path=socket_path, environment=environment())
    try:
        assert LOCAL_LIFECYCLE["launch"]["argv"] == ["start", "--background", "--supervised"]
        assert host.pid == host.client.host_status["pid"]
        assert host.launcher_pid > 0
        assert signal.getsignal(signal.SIGINT) == signal_handlers[signal.SIGINT]
        assert signal.getsignal(signal.SIGTERM) == signal_handlers[signal.SIGTERM]
        host.client.close()
        time.sleep(0.05)
        assert host.returncode is None
    finally:
        host.close()
    assert host.wait(1) == 0
    assert process_is_gone(host.launcher_pid)


def test_foreground_presentation_allowlist_and_absolute_paths(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    host = launch(
        executable=executable,
        socket_path=unique_socket_path("foreground"),
        presentation="foreground",
        allow=["example.com"],
        environment=environment(HEADLESS_TEST_PRESENTATION="foreground"),
    )
    host.close()
    with pytest.raises(ValidationError, match="presentation"):
        launch(
            executable=executable,
            socket_path=unique_socket_path("presentation"),
            presentation="sideways",  # type: ignore[arg-type]
            environment=environment(),
        )
    with pytest.raises(ValidationError, match="presentation"):
        launch(
            executable=executable,
            socket_path=unique_socket_path("presentation-type"),
            presentation=1,  # type: ignore[arg-type]
            environment=environment(),
        )
    for invalid_allow in ("example.com", b"example.com", [""], [1]):
        with pytest.raises(ValidationError, match="allow"):
            launch(
                executable=executable,
                socket_path=unique_socket_path("allow"),
                allow=invalid_allow,  # type: ignore[arg-type]
                environment=environment(),
            )
    with pytest.raises(ValidationError, match="absolute"):
        launch(executable="relative/headless")
    with pytest.raises(ValidationError, match="HEADLESS_HOST_EXECUTABLE"):
        launch(
            executable=executable,
            socket_path=unique_socket_path("host-executable"),
            environment=environment(HEADLESS_HOST_EXECUTABLE="relative/host"),
        )
    with pytest.raises(ValidationError, match="environment"):
        launch(
            executable=executable,
            socket_path=unique_socket_path("environment"),
            environment={"BAD": 1},  # type: ignore[dict-item]
        )
    with pytest.raises(ValidationError, match="direct child"):
        launch(executable=executable, socket_path=str(tmp_path / "host.sock"))
    with pytest.raises(ValidationError, match="must be absolute"):
        launch(executable=executable, socket_path="", environment=environment())
    with pytest.raises(ValidationError, match="startup_timeout"):
        launch(executable=executable, startup_timeout=10**1000)


def test_concurrent_shared_host_is_not_claimed_or_stopped(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    with PrivateSocketServer(
        lambda request, _: json_frame(host_status(request["id"], 7201)),
        "race",
    ) as shared:
        pid_file = tmp_path / "race.pid"
        with pytest.raises(HostLaunchError, match=r"pid 7202.*pid 7201"):
            launch(
                executable=executable,
                socket_path=shared.socket_path,
                environment=environment(
                    HEADLESS_TEST_MODE="existing",
                    HEADLESS_TEST_STARTUP_PID="7202",
                    HEADLESS_TEST_PID_FILE=str(pid_file),
                ),
            )
        launcher_pid = int(pid_file.read_text())
        assert process_is_gone(launcher_pid)
        client = connect(shared.socket_path)
        assert client.host_status["pid"] == 7201
        client.close()
        assert len(shared.requests) == 2


def test_missing_binary_and_structured_startup_failures(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    with pytest.raises(HostLaunchError) as missing:
        launch(executable=tmp_path / "missing", socket_path=unique_socket_path("missing"))
    assert missing.value.code == "HOST_START_FAILED"

    pid_file = tmp_path / "failure.pid"
    with pytest.raises(HostLaunchError) as failed:
        launch(
            executable=executable,
            socket_path=unique_socket_path("failure"),
            environment=environment(
                HEADLESS_TEST_MODE="failure",
                HEADLESS_TEST_PID_FILE=str(pid_file),
            ),
        )
    assert failed.value.exit_code == 7
    assert process_is_gone(int(pid_file.read_text()))

    with pytest.raises(HostLaunchError) as envelope:
        launch(
            executable=executable,
            socket_path=unique_socket_path("failure-envelope"),
            environment=environment(HEADLESS_TEST_MODE="failure-envelope"),
        )
    assert envelope.value.code == "NAVIGATION_ALLOWLIST_CONFLICT"
    assert envelope.value.suggestion == "stop the existing host"
    assert envelope.value.details["requested"] == ["two.example"]


def test_timeout_cancellation_and_invalid_startup_frames_reap_launcher(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    for mode in ("no-frame", "malformed", "multiple"):
        pid_file = tmp_path / f"{mode}.pid"
        with pytest.raises(HostLaunchError):
            launch(
                executable=executable,
                socket_path=unique_socket_path(mode),
                startup_timeout=2,
                shutdown_timeout=0.1,
                environment=environment(
                    HEADLESS_TEST_MODE=mode,
                    HEADLESS_TEST_PID_FILE=str(pid_file),
                ),
            )
        assert process_is_gone(int(pid_file.read_text()))

    cancel = threading.Event()
    cancel.set()
    with pytest.raises(HostLaunchError, match="cancelled before spawn"):
        launch(executable=executable, cancel=cancel)


def test_host_exit_and_delayed_startup_violation_close_client(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    host = launch(
        executable=executable,
        socket_path=unique_socket_path("exit"),
        environment=environment(HEADLESS_TEST_EXIT_AFTER="0.15"),
    )
    wait_until(lambda: host.returncode is not None)
    host.wait(1)
    with pytest.raises(ClientClosedError):
        host.client.ping()
    assert all(
        stream is None or stream.closed
        for stream in (host._process.stdin, host._process.stdout, host._process.stderr)
    )
    host.close()

    delayed = launch(
        executable=executable,
        socket_path=unique_socket_path("delayed"),
        environment=environment(HEADLESS_TEST_MODE="delayed-multiple"),
    )
    wait_until(lambda: delayed.returncode is not None)
    delayed.wait(1)
    with pytest.raises(ClientClosedError):
        delayed.client.ping()
    assert process_is_gone(delayed.launcher_pid)


@pytest.mark.skipif(
    not hasattr(os, "fork") or not hasattr(os, "register_at_fork"),
    reason="fork safety is POSIX-only",
)
def test_forked_child_detaches_owner_without_stopping_parent(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    host = launch(
        executable=executable,
        socket_path=unique_socket_path("fork"),
        environment=environment(),
    )
    streams = tuple(
        stream
        for stream in (host._process.stdin, host._process.stdout, host._process.stderr)
        if stream is not None
    )
    inherited_fds = {stream.fileno() for stream in streams}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        child_pid = os.fork()
    if child_pid == 0:
        status = 0
        try:
            assert host._detached_after_fork
            assert all(stream.closed for stream in streams)
            with pytest.raises(ClientClosedError):
                host.client.ping()
            host.close()
            replacement_fds = [os.open(os.devnull, os.O_RDONLY) for _ in streams]
            assert inherited_fds.intersection(replacement_fds)
            host._process.stdin = None
            host._process.stdout = None
            host._process.stderr = None
            del streams
            gc.collect()
            for descriptor in replacement_fds:
                os.fstat(descriptor)
                os.close(descriptor)
        except BaseException:
            status = 1
        os._exit(status)
    _, child_status = os.waitpid(child_pid, 0)
    try:
        assert os.waitstatus_to_exitcode(child_status) == 0
        assert host.returncode is None
        assert host.client.ping()["pid"] == host.pid
    finally:
        host.close()


def test_async_launch_uses_async_client_and_preserves_ownership(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executable = write_mock_launcher(tmp_path)

    async def scenario() -> None:
        host = await alaunch(
            executable=executable,
            socket_path=unique_socket_path("async"),
            environment=environment(),
        )
        assert host.pid == host.client.host_status["pid"]
        assert (await host.client.ping())["pid"] == host.pid
        original_close = host._owner.close
        cleanup_started = threading.Event()

        def delayed_close() -> None:
            cleanup_started.set()
            time.sleep(0.05)
            original_close()

        monkeypatch.setattr(host._owner, "close", delayed_close)
        closing = asyncio.create_task(host.close())
        assert await asyncio.to_thread(cleanup_started.wait, 1)
        closing.cancel()
        await asyncio.sleep(0.01)
        closing.cancel()
        with pytest.raises(asyncio.CancelledError):
            await closing
        assert process_is_gone(host._owner.launcher_pid)
        await host.close()
        assert await host.wait(1) == 0

    asyncio.run(scenario())


def test_repeated_async_launch_cancellation_cannot_orphan_owner(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executable = write_mock_launcher(tmp_path)
    owner_ready = threading.Event()
    owner_holder: list[Any] = []
    real_launch = launch

    def delayed_launch(**options: Any) -> Any:
        options["cancel"] = None
        owner = real_launch(**options)
        owner_holder.append(owner)
        owner_ready.set()
        time.sleep(0.1)
        return owner

    monkeypatch.setattr("headless_sdk.lifecycle.launch", delayed_launch)

    async def scenario() -> None:
        launching = asyncio.create_task(
            alaunch(
                executable=executable,
                socket_path=unique_socket_path("repeated-launch-cancel"),
                environment=environment(),
            )
        )
        assert await asyncio.to_thread(owner_ready.wait, 1)
        launching.cancel()
        await asyncio.sleep(0.01)
        launching.cancel()
        with pytest.raises(asyncio.CancelledError):
            await launching

    asyncio.run(scenario())
    assert len(owner_holder) == 1
    assert process_is_gone(owner_holder[0].launcher_pid)


def test_async_host_does_not_occupy_the_default_executor(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)

    async def scenario() -> None:
        loop = asyncio.get_running_loop()
        executor = ThreadPoolExecutor(max_workers=1)
        loop.set_default_executor(executor)
        host = await alaunch(
            executable=executable,
            socket_path=unique_socket_path("single-worker"),
            environment=environment(),
        )
        try:
            assert await asyncio.wait_for(asyncio.to_thread(lambda: 42), 1) == 42
            await asyncio.wait_for(host.close(), 2)
            assert process_is_gone(host._owner.launcher_pid)
        finally:
            await host.close()
            executor.shutdown(wait=True)

    asyncio.run(scenario())


@pytest.mark.skipif(
    not hasattr(os, "fork") or not hasattr(os, "register_at_fork"),
    reason="fork safety is POSIX-only",
)
def test_async_fork_detaches_replacement_client(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    child_error = tmp_path / "async-fork-child.txt"

    async def scenario() -> None:
        host = await alaunch(
            executable=executable,
            socket_path=unique_socket_path("async-fork"),
            environment=environment(),
        )
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            child_pid = os.fork()
        if child_pid == 0:
            status = 0
            try:
                assert host._owner._detached_after_fork
                assert host.client._closed
                assert all(
                    stream is None or stream.closed
                    for stream in (
                        host._owner._process.stdin,
                        host._owner._process.stdout,
                        host._owner._process.stderr,
                    )
                )
                asyncio.run(host.close())
            except BaseException:
                child_error.write_text(traceback.format_exc())
                status = 1
            os._exit(status)
        _, child_status = await asyncio.to_thread(os.waitpid, child_pid, 0)
        try:
            assert os.waitstatus_to_exitcode(child_status) == 0, (
                child_error.read_text() if child_error.exists() else "child returned no traceback"
            )
            assert (await host.client.ping())["pid"] == host.pid
        finally:
            await host.close()

    asyncio.run(scenario())


def test_async_client_closes_after_natural_launcher_exit(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)

    async def scenario() -> None:
        host = await alaunch(
            executable=executable,
            socket_path=unique_socket_path("async-exit"),
            environment=environment(HEADLESS_TEST_EXIT_AFTER="0.15"),
        )
        await asyncio.wait_for(host.wait(), 1)
        with pytest.raises(ClientClosedError):
            await host.client.ping()
        assert all(
            stream is None or stream.closed
            for stream in (
                host._owner._process.stdin,
                host._owner._process.stdout,
                host._owner._process.stderr,
            )
        )
        await host.close()

    asyncio.run(scenario())


def test_async_launch_uses_one_total_startup_deadline(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    pid_file = tmp_path / "deadline.pid"

    async def scenario() -> None:
        started = time.monotonic()
        with pytest.raises((HostLaunchError, OperationOutcomeUnknown)):
            await alaunch(
                executable=executable,
                socket_path=unique_socket_path("async-deadline"),
                startup_timeout=0.3,
                shutdown_timeout=0.1,
                environment=environment(
                    HEADLESS_TEST_STARTUP_DELAY="0.16",
                    HEADLESS_TEST_SECOND_RESPONSE_DELAY="0.18",
                    HEADLESS_TEST_PID_FILE=str(pid_file),
                ),
            )
        # Cleanup has its own 100 ms budget after the single 300 ms startup budget.
        assert time.monotonic() - started < 0.5

    asyncio.run(scenario())
    assert process_is_gone(int(pid_file.read_text()))


def test_interpreter_exit_closes_owner_pipe_and_reaps_launcher(tmp_path: Path) -> None:
    executable = write_mock_launcher(tmp_path)
    socket_path = unique_socket_path("interpreter-exit")
    pid_file = tmp_path / "interpreter-exit.pid"
    source_root = Path(__file__).resolve().parents[1] / "src"
    script = f"""
from headless_sdk import launch
launch(
    executable={str(executable)!r},
    socket_path={socket_path!r},
    environment={{
        "HEADLESS_TEST_COMMANDS": {json.dumps(list(COMMAND_METADATA))!r},
        "HEADLESS_TEST_PID_FILE": {str(pid_file)!r},
    }},
)
"""
    child_environment = dict(os.environ)
    child_environment["PYTHONPATH"] = str(source_root)
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=child_environment,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert process_is_gone(int(pid_file.read_text()))


def test_async_connect_remains_shared(tmp_path: Path) -> None:
    del tmp_path

    async def scenario(server: PrivateSocketServer) -> None:
        client = await aconnect(server.socket_path)
        assert client.host_status["pid"] == 7301
        await client.close()
        second = await aconnect(server.socket_path)
        await second.close()

    with PrivateSocketServer(
        lambda request, _: json_frame(host_status(request["id"], 7301))
    ) as server:
        asyncio.run(scenario(server))
        assert len(server.requests) == 2
