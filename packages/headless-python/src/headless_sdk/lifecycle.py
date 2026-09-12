from __future__ import annotations

import asyncio
import atexit
import contextlib
import json
import os
import selectors
import shutil
import subprocess
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import TypeVar, cast

from ._protocol import decode_response
from ._transport import default_socket_path, validate_socket_location
from ._types import AsyncCancellation, SyncCancellation, is_finite_number
from .client import AsyncClient, Client, aconnect, connect
from .errors import CommandError, HeadlessError, HostLaunchError, ValidationError
from .generated import (
    LAUNCH_PRESENTATIONS,
    LIFECYCLE_ERROR_CODES,
    LOCAL_LIFECYCLE,
    MAXIMUM_MESSAGE_BYTES,
    HostStatus,
    LaunchPresentation,
    LifecycleErrorCode,
)

_STARTUP_DIAGNOSTIC_LIMIT = 64 * 1024
_DEFAULT_STARTUP_TIMEOUT = 10.0
_DEFAULT_SHUTDOWN_TIMEOUT = 5.0
T = TypeVar("T")


class _OwnershipRegistry:
    def __init__(self) -> None:
        self.hosts: set[HeadlessHost] = set()
        self.lock = threading.Lock()


_OWNERS = _OwnershipRegistry()


class _Diagnostics:
    def __init__(self) -> None:
        self._value = bytearray()
        self._lock = threading.Lock()

    def append(self, chunk: bytes) -> None:
        with self._lock:
            remaining = _STARTUP_DIAGNOSTIC_LIMIT - len(self._value)
            if remaining > 0:
                self._value.extend(chunk[:remaining])

    def text(self) -> str:
        with self._lock:
            return self._value.decode("utf-8", errors="replace").strip()


def _drain_stderr(process: subprocess.Popen[bytes], diagnostics: _Diagnostics) -> None:
    if process.stderr is None:
        return
    try:
        while chunk := process.stderr.read(64 * 1024):
            diagnostics.append(chunk)
    except (OSError, ValueError):
        return


def _cancelled(cancel: SyncCancellation | None) -> bool:
    return cancel is not None and cancel.is_set()


async def _complete_shielded(
    task: asyncio.Task[T],
) -> tuple[T, asyncio.CancelledError | None]:
    interrupted: asyncio.CancelledError | None = None
    while not task.done():
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError as error:
            if task.cancelled():
                raise
            if interrupted is None:
                interrupted = error
    return task.result(), interrupted


def _read_startup_frame(
    process: subprocess.Popen[bytes],
    diagnostics: _Diagnostics,
    deadline: float,
    cancel: SyncCancellation | None,
) -> bytes:
    if process.stdout is None:
        raise HostLaunchError("supervised launcher stdout is unavailable")
    output = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            if _cancelled(cancel):
                raise HostLaunchError("supervised launch was cancelled during startup")
            if process.poll() is not None and not selector.select(0):
                detail = diagnostics.text()
                suffix = f": {detail}" if detail else ""
                raise _process_exit_error(
                    f"supervised Headless launcher exited before readiness{suffix}",
                    process.returncode,
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HostLaunchError(
                    "supervised Headless launcher did not become ready before the deadline"
                )
            wait = min(remaining, 0.05) if cancel is not None else remaining
            if not selector.select(wait):
                continue
            chunk = os.read(process.stdout.fileno(), 64 * 1024)
            if not chunk:
                detail = diagnostics.text()
                suffix = f": {detail}" if detail else ""
                raise _process_exit_error(
                    f"supervised Headless launcher closed stdout before readiness{suffix}",
                    process.poll(),
                )
            diagnostics.append(chunk)
            output.extend(chunk)
            if len(output) > MAXIMUM_MESSAGE_BYTES:
                raise HostLaunchError(
                    "supervised launcher startup response exceeded the frame limit"
                )
            newline = output.find(b"\n")
            if newline < 0:
                continue
            if newline != len(output) - 1:
                raise HostLaunchError("supervised launcher emitted multiple startup frames")
            return bytes(output[:newline])


def _decode_startup(frame: bytes) -> HostStatus:
    try:
        envelope = json.loads(frame)
        if not isinstance(envelope, dict) or not isinstance(envelope.get("id"), str):
            raise ValueError("startup response has no request id")
        status = cast(HostStatus, decode_response(frame, envelope["id"], "ping"))
        if status["protocolVersion"] != envelope.get("version"):
            raise ValueError("startup result protocolVersion does not match its envelope")
        return status
    except CommandError as error:
        if error.code in LIFECYCLE_ERROR_CODES:
            raise HostLaunchError(
                str(error),
                code=cast(LifecycleErrorCode, error.code),
                suggestion=error.suggestion,
                details=error.details,
            ) from error
        raise HostLaunchError("supervised launcher returned an invalid startup response") from error
    except (HeadlessError, UnicodeDecodeError, ValueError) as error:
        raise HostLaunchError("supervised launcher returned an invalid startup response") from error


def _terminate_and_reap(process: subprocess.Popen[bytes], timeout: float) -> None:
    if process.stdin is not None and not process.stdin.closed:
        with contextlib.suppress(OSError):
            process.stdin.close()
    try:
        process.wait(timeout=timeout)
        return
    except subprocess.TimeoutExpired:
        process.terminate()
    try:
        process.wait(timeout=timeout)
        return
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _process_exit_error(message: str, returncode: int | None) -> HostLaunchError:
    return HostLaunchError(
        message,
        exit_code=returncode if returncode is not None and returncode >= 0 else None,
        signal=-returncode if returncode is not None and returncode < 0 else None,
    )


class HeadlessHost:
    def __init__(
        self,
        client: Client,
        process: subprocess.Popen[bytes],
        host_pid: int,
        shutdown_timeout: float,
    ) -> None:
        self.client = client
        self.pid = host_pid
        self.launcher_pid = process.pid
        self._process = process
        self._shutdown_timeout = shutdown_timeout
        self._close_lock = threading.Lock()
        self._cleaned = False
        self._detached_after_fork = False
        self._exited = threading.Event()
        self._exit_callbacks: list[Callable[[int], None]] = []
        self._fork_detachers: list[Callable[[], None]] = [client._after_fork_child]
        with _OWNERS.lock:
            _OWNERS.hosts.add(self)
        threading.Thread(target=self._watch_stdout, daemon=True).start()
        threading.Thread(target=self._watch_exit, daemon=True).start()

    @property
    def returncode(self) -> int | None:
        return self._process.poll()

    def _watch_stdout(self) -> None:
        if self._process.stdout is None:
            return
        try:
            if self._process.stdout.read(1):
                self.close()
        except (OSError, ValueError):
            return

    def _watch_exit(self) -> None:
        self._process.wait()
        with self._close_lock:
            callbacks = self._finish_cleanup()
        self._notify_exit(callbacks)

    def _finish_cleanup(self) -> tuple[Callable[[int], None], ...]:
        if self._cleaned:
            return ()
        self.client.close()
        for stream in (self._process.stdin, self._process.stdout, self._process.stderr):
            if stream is not None:
                with contextlib.suppress(OSError, ValueError):
                    stream.close()
        with _OWNERS.lock:
            _OWNERS.hosts.discard(self)
        self._cleaned = True
        callbacks = tuple(self._exit_callbacks)
        self._exit_callbacks.clear()
        self._fork_detachers.clear()
        self._exited.set()
        return callbacks

    def _notify_exit(self, callbacks: tuple[Callable[[int], None], ...]) -> None:
        returncode = cast(int, self._process.returncode)
        for callback in callbacks:
            with contextlib.suppress(BaseException):
                callback(returncode)

    def _register_exit_callback(self, callback: Callable[[int], None]) -> None:
        with self._close_lock:
            completed = self._cleaned
            if not completed:
                self._exit_callbacks.append(callback)
        if completed:
            callback(cast(int, self._process.returncode))

    def _register_fork_detacher(self, detacher: Callable[[], None]) -> None:
        with self._close_lock:
            if self._detached_after_fork:
                detacher()
                return
            self._fork_detachers.append(detacher)

    def _after_fork_child(self) -> None:
        self._detached_after_fork = True
        self._close_lock = threading.Lock()
        for detacher in self._fork_detachers:
            detacher()
        self._fork_detachers.clear()
        self._exit_callbacks.clear()
        for stream in (self._process.stdin, self._process.stdout, self._process.stderr):
            if stream is not None and not stream.closed:
                with contextlib.suppress(OSError, ValueError):
                    stream.close()

    def wait(self, timeout: float | None = None) -> int:
        if self._detached_after_fork:
            raise RuntimeError("an inherited Headless host cannot be awaited after fork")
        if not self._exited.wait(timeout):
            raise TimeoutError("owned Headless launcher did not exit before the deadline")
        return cast(int, self._process.returncode)

    def close(self) -> None:
        with self._close_lock:
            if self._detached_after_fork or self._cleaned:
                return
            try:
                _terminate_and_reap(self._process, self._shutdown_timeout)
            finally:
                callbacks = self._finish_cleanup()
        self._notify_exit(callbacks)

    def __enter__(self) -> HeadlessHost:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _close_owned_hosts() -> None:
    with _OWNERS.lock:
        hosts = tuple(_OWNERS.hosts)
    for host in hosts:
        with contextlib.suppress(BaseException):
            host.close()


def _after_fork_in_child() -> None:
    inherited_hosts = tuple(_OWNERS.hosts)
    for host in inherited_hosts:
        host._after_fork_child()
    _OWNERS.hosts.clear()
    _OWNERS.lock = threading.Lock()


atexit.register(_close_owned_hosts)
if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_after_fork_in_child)


def _selected_executable(executable: str | os.PathLike[str] | None) -> str:
    if executable is not None:
        selected = os.fspath(executable)
        if not isinstance(selected, str) or not os.path.isabs(selected):
            raise ValidationError("executable must be an absolute path")
        return selected
    discovered = shutil.which("headless")
    if discovered is None:
        raise HostLaunchError("headless executable was not found on PATH")
    return str(Path(discovered).resolve())


def _bounded_timeout(name: str, value: float, maximum: float) -> None:
    if not is_finite_number(value) or value <= 0 or value > maximum:
        raise ValidationError(f"{name} must be greater than zero and at most {maximum} seconds")


def launch(
    *,
    executable: str | os.PathLike[str] | None = None,
    socket_path: str | None = None,
    presentation: LaunchPresentation = "background",
    allow: Sequence[str] = (),
    environment: Mapping[str, str] | None = None,
    startup_timeout: float = _DEFAULT_STARTUP_TIMEOUT,
    shutdown_timeout: float = _DEFAULT_SHUTDOWN_TIMEOUT,
    cancel: SyncCancellation | None = None,
) -> HeadlessHost:
    _bounded_timeout("startup_timeout", startup_timeout, 120.0)
    _bounded_timeout("shutdown_timeout", shutdown_timeout, 30.0)
    deadline = time.monotonic() + startup_timeout
    if _cancelled(cancel):
        raise HostLaunchError("supervised launch was cancelled before spawn")
    selected_executable = _selected_executable(executable)
    selected_environment = dict(os.environ)
    if environment is not None:
        if not isinstance(environment, Mapping) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()
        ):
            raise ValidationError("environment must map string names to string values")
        selected_environment.update(environment)
    host_executable = selected_environment.get("HEADLESS_HOST_EXECUTABLE")
    if host_executable is not None and not os.path.isabs(host_executable):
        raise ValidationError("HEADLESS_HOST_EXECUTABLE must be an absolute path")
    selected_socket = (
        default_socket_path(selected_environment) if socket_path is None else socket_path
    )
    validate_socket_location(selected_socket)
    if not isinstance(presentation, str) or presentation not in LAUNCH_PRESENTATIONS:
        raise ValidationError(f"presentation must be one of {', '.join(LAUNCH_PRESENTATIONS)}")
    if isinstance(allow, (str, bytes)) or not isinstance(allow, Sequence):
        raise ValidationError("allow must be a sequence of host patterns")
    presentation_flags = {f"--{value}" for value in LAUNCH_PRESENTATIONS}
    argv = cast(list[str], list(LOCAL_LIFECYCLE["launch"]["argv"]))
    existing_flags = [argument for argument in argv if argument in presentation_flags]
    if len(existing_flags) != 1:
        raise ValidationError("generated launch argv has an invalid presentation flag")
    argv = [
        f"--{presentation}" if argument in presentation_flags else argument for argument in argv
    ]
    allow_definition = next(
        (option for option in LOCAL_LIFECYCLE["launch"]["options"] if option["name"] == "allow"),
        None,
    )
    if allow_definition is None or len(allow) > allow_definition["maximumItems"]:
        raise ValidationError("allowlist has too many patterns")
    for pattern in allow:
        if (
            not isinstance(pattern, str)
            or not pattern
            or len(pattern.encode("utf-8")) > allow_definition["itemMaximumBytes"]
        ):
            raise ValidationError("allowlist patterns are empty or exceed the schema limit")
        argv.extend(("--allow", pattern))
    selected_environment["HEADLESS_SOCKET"] = selected_socket
    try:
        process = subprocess.Popen(
            [selected_executable, *argv],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=selected_environment,
        )
    except OSError as error:
        raise HostLaunchError(f"could not start supervised Headless: {error}") from error
    diagnostics = _Diagnostics()
    threading.Thread(target=_drain_stderr, args=(process, diagnostics), daemon=True).start()
    client: Client | None = None
    try:
        startup = _decode_startup(_read_startup_frame(process, diagnostics, deadline, cancel))
        startup_pid = startup["pid"]
        if not isinstance(startup_pid, int) or isinstance(startup_pid, bool) or startup_pid <= 0:
            raise HostLaunchError("supervised launcher returned an invalid host pid")
        if startup["ready"] is not True:
            raise HostLaunchError("supervised launcher reported a host that is not ready")
        if process.poll() is not None:
            raise _process_exit_error(
                "supervised Headless launcher exited before ownership was established",
                process.returncode,
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise HostLaunchError(
                "supervised Headless launcher did not become ready before the deadline"
            )
        client = connect(selected_socket, timeout=remaining, cancel=cancel)
        connected_pid = client.host_status["pid"]
        if (
            not isinstance(connected_pid, int)
            or isinstance(connected_pid, bool)
            or connected_pid <= 0
        ):
            raise HostLaunchError("connected Headless host returned an invalid pid")
        if connected_pid != startup_pid:
            raise HostLaunchError(
                f"supervised launcher reported host pid {startup_pid}, "
                f"but the socket belongs to pid {connected_pid}"
            )
        if process.poll() is not None:
            raise _process_exit_error(
                "supervised Headless launcher exited before ownership was established",
                process.returncode,
            )
        return HeadlessHost(client, process, startup_pid, shutdown_timeout)
    except BaseException as error:
        if client is not None:
            client.close()
        with contextlib.suppress(BaseException):
            _terminate_and_reap(process, shutdown_timeout)
        if isinstance(error, HeadlessError):
            raise
        raise HostLaunchError("supervised Headless launch failed") from error


class AsyncHeadlessHost:
    def __init__(self, owner: HeadlessHost, client: AsyncClient) -> None:
        self._owner = owner
        self.client = client
        self.pid = owner.pid
        self._close_lock = asyncio.Lock()
        self._close_task: asyncio.Task[None] | None = None
        self._loop = asyncio.get_running_loop()
        self._exit_future: asyncio.Future[int] = self._loop.create_future()
        self._exit_cleanup_task: asyncio.Task[None] | None = None
        self._detached_after_fork = False
        owner._register_fork_detacher(client._after_fork_child)
        owner._register_fork_detacher(self._after_fork_child)
        owner._register_exit_callback(self._owner_exited)

    @property
    def returncode(self) -> int | None:
        return self._owner.returncode

    async def wait(self, timeout: float | None = None) -> int:
        if self._detached_after_fork:
            raise RuntimeError("an inherited Headless host cannot be awaited after fork")
        completion = asyncio.shield(self._exit_future)
        if timeout is None:
            return await completion
        try:
            return await asyncio.wait_for(completion, timeout)
        except TimeoutError as error:
            raise TimeoutError(
                "owned Headless launcher did not exit before the deadline"
            ) from error

    def _owner_exited(self, returncode: int) -> None:
        with contextlib.suppress(RuntimeError):
            self._loop.call_soon_threadsafe(self._start_exit_cleanup, returncode)

    def _start_exit_cleanup(self, returncode: int) -> None:
        if self._detached_after_fork or self._exit_cleanup_task is not None:
            return
        self._exit_cleanup_task = asyncio.create_task(self._complete_exit(returncode))

    async def _complete_exit(self, returncode: int) -> None:
        await self.client.close()
        if not self._exit_future.done():
            self._exit_future.set_result(returncode)

    def _after_fork_child(self) -> None:
        self._detached_after_fork = True

    async def close(self) -> None:
        if self._detached_after_fork:
            return
        async with self._close_lock:
            if self._close_task is None:
                self._close_task = asyncio.create_task(self._close())
            close_task = self._close_task
        _, interrupted = await _complete_shielded(close_task)
        if interrupted is not None:
            raise interrupted

    async def _close(self) -> None:
        await self.client.close()
        await asyncio.to_thread(self._owner.close)
        await self.wait()

    async def __aenter__(self) -> AsyncHeadlessHost:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()


async def alaunch(
    *,
    executable: str | os.PathLike[str] | None = None,
    socket_path: str | None = None,
    presentation: LaunchPresentation = "background",
    allow: Sequence[str] = (),
    environment: Mapping[str, str] | None = None,
    startup_timeout: float = _DEFAULT_STARTUP_TIMEOUT,
    shutdown_timeout: float = _DEFAULT_SHUTDOWN_TIMEOUT,
    cancel: AsyncCancellation | None = None,
) -> AsyncHeadlessHost:
    _bounded_timeout("startup_timeout", startup_timeout, 120.0)
    deadline = time.monotonic() + startup_timeout
    sync_cancel = threading.Event()

    async def forward_cancellation() -> None:
        if cancel is not None:
            await cancel.wait()
            sync_cancel.set()

    cancellation_task = asyncio.create_task(forward_cancellation())
    worker = asyncio.create_task(
        asyncio.to_thread(
            launch,
            executable=executable,
            socket_path=socket_path,
            presentation=presentation,
            allow=allow,
            environment=environment,
            startup_timeout=max(0.001, deadline - time.monotonic()),
            shutdown_timeout=shutdown_timeout,
            cancel=sync_cancel,
        )
    )
    owner: HeadlessHost | None = None
    try:
        owner = await asyncio.shield(worker)
        owner.client.close()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise HostLaunchError(
                "supervised Headless launcher did not become ready before the deadline"
            )
        async_client = await aconnect(
            owner.client.socket_path,
            timeout=remaining,
            cancel=cancel,
        )
        if async_client.host_status["pid"] != owner.pid:
            await async_client.close()
            raise HostLaunchError("async client connected to a different Headless host")
        return AsyncHeadlessHost(owner, async_client)
    except asyncio.CancelledError as cancellation:
        sync_cancel.set()
        try:
            owner, _ = await _complete_shielded(worker)
        except BaseException:
            owner = None
        if owner is not None:
            cleanup = asyncio.create_task(asyncio.to_thread(owner.close))
            with contextlib.suppress(BaseException):
                await _complete_shielded(cleanup)
        raise cancellation
    except BaseException as error:
        if owner is not None:
            cleanup = asyncio.create_task(asyncio.to_thread(owner.close))
            try:
                _, interrupted = await _complete_shielded(cleanup)
            except BaseException:
                interrupted = None
            if interrupted is not None:
                raise interrupted from error
        raise
    finally:
        cancellation_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await cancellation_task
