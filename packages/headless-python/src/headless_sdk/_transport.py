from __future__ import annotations

import asyncio
import contextlib
import errno
import os
import selectors
import socket
import stat
import threading
import time
from collections.abc import Awaitable, Mapping
from typing import Any, TypeVar

from ._types import AsyncCancellation, SyncCancellation, is_finite_number
from .errors import (
    CancelledBeforeSend,
    ClientClosedError,
    ConnectionError,
    MalformedResponseError,
    OperationOutcomeUnknown,
    ResponseTooLargeError,
    TimeoutBeforeSend,
    ValidationError,
)
from .generated import MAXIMUM_COMMAND_TIMEOUT_SECONDS, MAXIMUM_MESSAGE_BYTES

T = TypeVar("T")
_CONNECTING = {errno.EINPROGRESS, errno.EALREADY, errno.EWOULDBLOCK}


def runtime_directory() -> str:
    if not hasattr(os, "getuid"):
        raise ConnectionError("Headless local transport requires a Unix-like operating system")
    return f"/tmp/headless-{os.getuid()}"


def validate_socket_location(socket_path: str, label: str = "socket_path") -> None:
    if not isinstance(socket_path, str) or not os.path.isabs(socket_path):
        raise ValidationError(f"{label} must be absolute")
    normalized = os.path.abspath(socket_path)
    if normalized != socket_path or os.path.dirname(normalized) != runtime_directory():
        raise ValidationError(
            f"{label} must be a direct child of the Headless runtime directory "
            f"{runtime_directory()}"
        )


def default_socket_path(environment: Mapping[str, str] | None = None) -> str:
    selected = os.environ if environment is None else environment
    override = selected.get("HEADLESS_SOCKET")
    if override is not None:
        validate_socket_location(override, "HEADLESS_SOCKET")
        return override
    return os.path.join(runtime_directory(), "host.sock")


def validate_private_socket(socket_path: str) -> None:
    validate_socket_location(socket_path)
    user_id = os.getuid()
    try:
        parent = os.lstat(os.path.dirname(socket_path))
    except OSError as error:
        raise ConnectionError("Headless runtime directory is unavailable") from error
    if (
        not stat.S_ISDIR(parent.st_mode)
        or stat.S_ISLNK(parent.st_mode)
        or parent.st_uid != user_id
        or stat.S_IMODE(parent.st_mode) & 0o077
    ):
        raise ConnectionError("Headless runtime directory is not private to the current user")
    try:
        endpoint = os.lstat(socket_path)
    except OSError as error:
        raise ConnectionError("Headless host is not running") from error
    if (
        not stat.S_ISSOCK(endpoint.st_mode)
        or stat.S_ISLNK(endpoint.st_mode)
        or endpoint.st_uid != user_id
        or stat.S_IMODE(endpoint.st_mode) & 0o077
    ):
        raise ConnectionError("Headless socket is not private to the current user")


def _validate_request(frame: bytes, timeout: float) -> None:
    if not is_finite_number(timeout) or timeout <= 0 or timeout > MAXIMUM_COMMAND_TIMEOUT_SECONDS:
        raise ValidationError(
            "timeout must be greater than zero and at most "
            f"{MAXIMUM_COMMAND_TIMEOUT_SECONDS} seconds"
        )
    if len(frame) > MAXIMUM_MESSAGE_BYTES:
        raise ValidationError(f"request exceeds the {MAXIMUM_MESSAGE_BYTES}-byte frame limit")
    if not frame.endswith(b"\n") or frame.count(b"\n") != 1:
        raise ValidationError("request must contain exactly one terminal newline frame")


def _certainty_error(
    request_id: str,
    sent: bool,
    reason: str,
    cause: BaseException | None = None,
) -> BaseException:
    if sent:
        return OperationOutcomeUnknown(request_id, reason, cause)
    if reason == "cancelled":
        return CancelledBeforeSend()
    if reason == "timed-out":
        return TimeoutBeforeSend()
    if isinstance(cause, BaseException):
        return ConnectionError("could not connect to the Headless host")
    return ConnectionError("Headless connection failed before the request was sent")


class SyncUnixSocketTransport:
    def __init__(self, socket_path: str | None = None) -> None:
        self.socket_path = default_socket_path() if socket_path is None else socket_path
        validate_socket_location(self.socket_path)
        self._closed = False
        self._active: set[socket.socket] = set()
        self._lock = threading.Lock()

    def _ensure_open(self) -> None:
        if self._closed:
            raise ClientClosedError()

    def _wait_ready(
        self,
        endpoint: socket.socket,
        event: int,
        deadline: float,
        cancel: SyncCancellation | None,
        request_id: str,
        sent: bool,
    ) -> None:
        with selectors.DefaultSelector() as selector:
            selector.register(endpoint, event)
            while True:
                if cancel is not None and cancel.is_set():
                    raise _certainty_error(request_id, sent, "cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise _certainty_error(request_id, sent, "timed-out")
                wait = min(remaining, 0.05) if cancel is not None else remaining
                if selector.select(wait):
                    return

    def send(
        self,
        frame: bytes,
        request_id: str,
        timeout: float,
        cancel: SyncCancellation | None = None,
    ) -> bytes:
        self._ensure_open()
        _validate_request(frame, timeout)
        if cancel is not None and cancel.is_set():
            raise CancelledBeforeSend()
        validate_private_socket(self.socket_path)
        self._ensure_open()
        deadline = time.monotonic() + timeout
        endpoint = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        endpoint.setblocking(False)
        with self._lock:
            if self._closed:
                endpoint.close()
                raise ClientClosedError()
            self._active.add(endpoint)
        sent = False
        try:
            result = endpoint.connect_ex(self.socket_path)
            if result not in {0, errno.EISCONN}:
                if result not in _CONNECTING:
                    raise OSError(result, os.strerror(result))
                self._wait_ready(
                    endpoint, selectors.EVENT_WRITE, deadline, cancel, request_id, sent
                )
                result = endpoint.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if result:
                    raise OSError(result, os.strerror(result))
            offset = 0
            while offset < len(frame):
                if cancel is not None and cancel.is_set():
                    raise _certainty_error(request_id, sent, "cancelled")
                if time.monotonic() >= deadline:
                    raise _certainty_error(request_id, sent, "timed-out")
                try:
                    written = endpoint.send(frame[offset:])
                except BlockingIOError:
                    self._wait_ready(
                        endpoint, selectors.EVENT_WRITE, deadline, cancel, request_id, sent
                    )
                    continue
                if written <= 0:
                    raise OSError("socket write made no progress")
                sent = True
                offset += written

            response = bytearray()
            while True:
                self._wait_ready(endpoint, selectors.EVENT_READ, deadline, cancel, request_id, sent)
                chunk = endpoint.recv(64 * 1024)
                if not chunk:
                    break
                response.extend(chunk)
                newline = response.find(b"\n")
                if len(response) > MAXIMUM_MESSAGE_BYTES or (
                    len(response) == MAXIMUM_MESSAGE_BYTES and newline < 0
                ):
                    raise OperationOutcomeUnknown(
                        request_id,
                        "read-failed",
                        ResponseTooLargeError(MAXIMUM_MESSAGE_BYTES),
                    )
                if newline >= 0 and newline != len(response) - 1:
                    raise OperationOutcomeUnknown(
                        request_id,
                        "read-failed",
                        MalformedResponseError("Headless returned more than one response frame"),
                    )
            newline = response.find(b"\n")
            if newline < 0:
                message = (
                    "Headless response was empty"
                    if not response
                    else "Headless response did not end with a newline"
                )
                raise OperationOutcomeUnknown(
                    request_id, "read-failed", MalformedResponseError(message)
                )
            return bytes(response[:newline])
        except (CancelledBeforeSend, TimeoutBeforeSend, OperationOutcomeUnknown):
            raise
        except OSError as error:
            raise _certainty_error(request_id, sent, "read-failed", error) from error
        finally:
            with self._lock:
                self._active.discard(endpoint)
            endpoint.close()

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            active = tuple(self._active)
        for endpoint in active:
            endpoint.close()

    def _after_fork_child(self) -> None:
        active = tuple(self._active)
        self._active.clear()
        self._closed = True
        self._lock = threading.Lock()
        for endpoint in active:
            endpoint.close()


class AsyncUnixSocketTransport:
    def __init__(self, socket_path: str | None = None) -> None:
        self.socket_path = default_socket_path() if socket_path is None else socket_path
        validate_socket_location(self.socket_path)
        self._closed = False
        self._active: set[asyncio.StreamWriter] = set()

    async def _await_step(
        self,
        awaitable: Awaitable[T],
        deadline: float,
        cancel: AsyncCancellation | None,
        request_id: str,
        sent: bool,
    ) -> T:
        operation = asyncio.ensure_future(awaitable)
        cancellation = asyncio.create_task(cancel.wait()) if cancel is not None else None
        tasks: set[asyncio.Future[Any]] = {operation}
        if cancellation is not None:
            tasks.add(cancellation)
        try:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise _certainty_error(request_id, sent, "timed-out")
            done, _ = await asyncio.wait(
                tasks, timeout=remaining, return_when=asyncio.FIRST_COMPLETED
            )
            if cancellation is not None and cancellation in done:
                operation.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await operation
                raise _certainty_error(request_id, sent, "cancelled")
            if operation in done:
                return operation.result()
            operation.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await operation
            raise _certainty_error(request_id, sent, "timed-out")
        except asyncio.CancelledError as error:
            operation.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await operation
            raise _certainty_error(request_id, sent, "cancelled", error) from error
        finally:
            if cancellation is not None:
                cancellation.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await cancellation

    async def send(
        self,
        frame: bytes,
        request_id: str,
        timeout: float,
        cancel: AsyncCancellation | None = None,
    ) -> bytes:
        if self._closed:
            raise ClientClosedError()
        _validate_request(frame, timeout)
        if cancel is not None and cancel.is_set():
            raise CancelledBeforeSend()
        validate_private_socket(self.socket_path)
        if self._closed:
            raise ClientClosedError()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        sent = False
        writer: asyncio.StreamWriter | None = None
        try:
            reader, connected_writer = await self._await_step(
                asyncio.open_unix_connection(self.socket_path),
                deadline,
                cancel,
                request_id,
                sent,
            )
            writer = connected_writer
            if self._closed:
                raise ClientClosedError()
            if cancel is not None and cancel.is_set():
                raise CancelledBeforeSend()
            self._active.add(writer)
            writer.write(frame)
            sent = True
            await self._await_step(writer.drain(), deadline, cancel, request_id, sent)
            response = bytearray()
            while True:
                chunk = await self._await_step(
                    reader.read(64 * 1024), deadline, cancel, request_id, sent
                )
                if not chunk:
                    break
                response.extend(chunk)
                newline = response.find(b"\n")
                if len(response) > MAXIMUM_MESSAGE_BYTES or (
                    len(response) == MAXIMUM_MESSAGE_BYTES and newline < 0
                ):
                    raise OperationOutcomeUnknown(
                        request_id,
                        "read-failed",
                        ResponseTooLargeError(MAXIMUM_MESSAGE_BYTES),
                    )
                if newline >= 0 and newline != len(response) - 1:
                    raise OperationOutcomeUnknown(
                        request_id,
                        "read-failed",
                        MalformedResponseError("Headless returned more than one response frame"),
                    )
            newline = response.find(b"\n")
            if newline < 0:
                message = (
                    "Headless response was empty"
                    if not response
                    else "Headless response did not end with a newline"
                )
                raise OperationOutcomeUnknown(
                    request_id, "read-failed", MalformedResponseError(message)
                )
            return bytes(response[:newline])
        except (CancelledBeforeSend, TimeoutBeforeSend, OperationOutcomeUnknown):
            raise
        except OSError as error:
            raise _certainty_error(request_id, sent, "read-failed", error) from error
        finally:
            if writer is not None:
                self._active.discard(writer)
                writer.close()
                with contextlib.suppress(Exception):
                    await writer.wait_closed()

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        active = tuple(self._active)
        for writer in active:
            writer.close()
        for writer in active:
            with contextlib.suppress(Exception):
                await writer.wait_closed()
        self._active.clear()

    def _after_fork_child(self) -> None:
        self._closed = True
        active = tuple(self._active)
        self._active.clear()
        for writer in active:
            writer.close()
