from __future__ import annotations

import atexit
import json
import os
import socket
import stat
import threading
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from headless_sdk.generated import COMMAND_METADATA, PROTOCOL_VERSION

ResponseFactory = Callable[[dict[str, Any], socket.socket], bytes | None]
_TEST_SOCKET_PATHS: set[Path] = set()


def _cleanup_test_sockets() -> None:
    for path in _TEST_SOCKET_PATHS:
        path.unlink(missing_ok=True)


atexit.register(_cleanup_test_sockets)


def unique_socket_path(prefix: str) -> str:
    directory = Path(f"/tmp/headless-{os.getuid()}")
    directory.mkdir(mode=0o700, exist_ok=True)
    mode = directory.lstat().st_mode
    if directory.is_symlink() or stat.S_IMODE(mode) & 0o077:
        raise RuntimeError("Headless runtime directory is not private")
    path = directory / f"python-{os.getpid()}-{prefix}-{uuid.uuid4().hex}.sock"
    _TEST_SOCKET_PATHS.add(path)
    return str(path)


def json_frame(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode() + b"\n"


def host_status(
    request_id: str,
    pid: int = 7001,
    commands: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "id": request_id,
        "version": PROTOCOL_VERSION,
        "ok": True,
        "result": {
            "ready": True,
            "pid": pid,
            "engine": "chromium",
            "platform": "linux",
            "productVersion": "1.1.0-test",
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {
                "commands": list(COMMAND_METADATA) if commands is None else commands,
            },
            "recordingAvailable": False,
            "artifactDirectory": "/private/test-artifacts",
            "navigationAllowlist": [],
        },
    }


class PrivateSocketServer:
    def __init__(self, response: ResponseFactory, prefix: str = "server") -> None:
        self.socket_path = unique_socket_path(prefix)
        self.requests: list[dict[str, Any]] = []
        self._response = response
        self._closed = threading.Event()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        self._server.listen()
        self._server.settimeout(0.05)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._closed.is_set():
            try:
                connection, _ = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            threading.Thread(
                target=self._handle,
                args=(connection,),
                daemon=True,
            ).start()

    def _handle(self, connection: socket.socket) -> None:
        with connection:
            data = bytearray()
            while b"\n" not in data and len(data) <= 1024 * 1024:
                chunk = connection.recv(64 * 1024)
                if not chunk:
                    return
                data.extend(chunk)
            request = json.loads(bytes(data).split(b"\n", 1)[0])
            self.requests.append(request)
            response = self._response(request, connection)
            if response is not None:
                try:
                    connection.sendall(response)
                except (BrokenPipeError, ConnectionResetError):
                    return

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        self._server.close()
        self._thread.join(timeout=1)
        Path(self.socket_path).unlink(missing_ok=True)

    def __enter__(self) -> PrivateSocketServer:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def write_mock_launcher(directory: Path) -> Path:
    executable = directory / "headless-test.py"
    executable.write_text(
        f"""#!/usr/bin/env python3
import json
import os
import socket
import sys
import threading
import time

PROTOCOL_VERSION = {PROTOCOL_VERSION!r}
mode = os.environ.get("HEADLESS_TEST_MODE", "owned")
expected_presentation = os.environ.get("HEADLESS_TEST_PRESENTATION", "background")
expected = ["start", "--" + expected_presentation, "--supervised"]
if sys.argv[1:4] != expected:
    sys.exit(64)
socket_path = os.environ["HEADLESS_SOCKET"]
commands = json.loads(os.environ["HEADLESS_TEST_COMMANDS"])
pid_file = os.environ.get("HEADLESS_TEST_PID_FILE")
if pid_file:
    open(pid_file, "w", encoding="utf-8").write(str(os.getpid()))
if mode == "failure":
    sys.exit(7)

def status(request_id, pid):
    return {{
        "id": request_id,
        "version": PROTOCOL_VERSION,
        "ok": True,
        "result": {{
            "ready": True,
            "pid": pid,
            "engine": "chromium",
            "platform": "linux",
            "productVersion": "1.1.0-test",
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {{"commands": commands}},
            "recordingAvailable": False,
            "artifactDirectory": "/private/test-artifacts",
            "navigationAllowlist": [],
        }},
    }}

if mode == "failure-envelope":
    print(json.dumps({{
        "id": "startup-failure",
        "version": PROTOCOL_VERSION,
        "ok": False,
        "error": {{
            "code": "NAVIGATION_ALLOWLIST_CONFLICT",
            "message": "an incompatible host is already running",
            "suggestion": "stop the existing host",
            "details": {{"requested": ["two.example"]}},
        }},
    }}), flush=True)
    sys.stdin.buffer.read()
    sys.exit(0)

server = None
if mode not in {{"existing", "no-frame", "malformed", "multiple"}}:
    os.makedirs(os.path.dirname(socket_path), mode=0o700, exist_ok=True)
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen()
    server.settimeout(0.05)

if mode == "malformed":
    print("not-json", flush=True)
elif mode == "multiple":
    line = json.dumps(status("startup", os.getpid()))
    sys.stdout.write(line + "\\n" + line + "\\n")
    sys.stdout.flush()
elif mode != "no-frame":
    startup_delay = os.environ.get("HEADLESS_TEST_STARTUP_DELAY")
    if startup_delay:
        time.sleep(float(startup_delay))
    startup_pid = int(os.environ.get("HEADLESS_TEST_STARTUP_PID", os.getpid()))
    print(json.dumps(status("startup", startup_pid)), flush=True)
    if mode == "delayed-multiple":
        def extra():
            print(json.dumps(status("late", os.getpid())), flush=True)
        threading.Timer(0.1, extra).start()

stopping = False
def owner_closed():
    global stopping
    while os.read(sys.stdin.fileno(), 65536):
        pass
    stopping = True
    if server is not None:
        server.close()
threading.Thread(target=owner_closed, daemon=True).start()

exit_after = os.environ.get("HEADLESS_TEST_EXIT_AFTER")
deadline = time.monotonic() + float(exit_after) if exit_after else None
request_count = 0
while not stopping:
    if deadline is not None and time.monotonic() >= deadline:
        break
    if server is None:
        time.sleep(0.02)
        continue
    try:
        connection, _ = server.accept()
    except TimeoutError:
        continue
    except OSError:
        break
    with connection:
        data = bytearray()
        while b"\\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                break
            data.extend(chunk)
        if data:
            request = json.loads(bytes(data).split(b"\\n", 1)[0])
            request_count += 1
            if request_count == 2 and os.environ.get("HEADLESS_TEST_SECOND_RESPONSE_DELAY"):
                time.sleep(float(os.environ["HEADLESS_TEST_SECOND_RESPONSE_DELAY"]))
            connection.sendall((json.dumps(status(request["id"], os.getpid())) + "\\n").encode())
if server is not None:
    server.close()
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
""",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable
