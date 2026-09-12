from __future__ import annotations

import asyncio
import os
import uuid
from pathlib import Path

from headless_sdk import PROTOCOL_VERSION, alaunch, launch
from headless_sdk._transport import runtime_directory


def required_absolute_environment(name: str) -> str:
    value = os.environ.get(name)
    if value is None or not os.path.isabs(value):
        raise RuntimeError(f"{name} must be an absolute path")
    return value


def socket_path(label: str) -> str:
    return os.path.join(runtime_directory(), f"python-swift-{label}-{uuid.uuid4().hex}.sock")


def run_sync(executable: str, host_executable: str) -> None:
    path = socket_path("sync")
    host = None
    try:
        host = launch(
            executable=executable,
            socket_path=path,
            environment={"HEADLESS_HOST_EXECUTABLE": host_executable},
        )
        assert host.client.host_status["ready"] is True
        assert host.client.host_status["protocolVersion"] == PROTOCOL_VERSION
        assert host.client.ping()["pid"] == host.pid
        assert isinstance(host.client.session_list()["sessions"], list)
    finally:
        if host is not None:
            host.close()
        Path(path).unlink(missing_ok=True)


async def run_async(executable: str, host_executable: str) -> None:
    path = socket_path("async")
    host = None
    try:
        host = await alaunch(
            executable=executable,
            socket_path=path,
            environment={"HEADLESS_HOST_EXECUTABLE": host_executable},
        )
        assert host.client.host_status["ready"] is True
        assert host.client.host_status["protocolVersion"] == PROTOCOL_VERSION
        assert (await host.client.ping())["pid"] == host.pid
        assert isinstance((await host.client.session_list())["sessions"], list)
    finally:
        if host is not None:
            await host.close()
        await asyncio.to_thread(Path(path).unlink, missing_ok=True)


def main() -> None:
    if os.uname().sysname not in {"Darwin", "Linux"}:
        raise RuntimeError("Swift SDK integration requires macOS or Linux")
    executable = required_absolute_environment("HEADLESS_TEST_CLI")
    host_executable = required_absolute_environment("HEADLESS_TEST_HOST")
    run_sync(executable, host_executable)
    asyncio.run(run_async(executable, host_executable))


if __name__ == "__main__":
    main()
