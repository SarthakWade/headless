from __future__ import annotations

import asyncio
import contextlib
import threading
import time
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeoutError
from typing import Any, cast

from ._protocol import create_request, decode_response, encode_request, validate_session
from ._transport import AsyncUnixSocketTransport, SyncUnixSocketTransport, default_socket_path
from ._types import AsyncCancellation, SyncCancellation, is_finite_number
from .errors import (
    CancelledBeforeSend,
    ClientClosedError,
    CommandError,
    MalformedResponseError,
    OperationOutcomeUnknown,
    TimeoutBeforeSend,
    UnsupportedCapabilityError,
    ValidationError,
)
from .generated import (
    COMMAND_METADATA,
    MAXIMUM_COMMAND_TIMEOUT_SECONDS,
    PROTOCOL_VERSION,
    AsyncHostCommands,
    AsyncSessionCommands,
    CommandName,
    HostStatus,
    JsonValue,
    SessionClose,
    SyncHostCommands,
    SyncSessionCommands,
    command_timeout_seconds,
)


def _request_timeout(
    command: CommandName, parameters: dict[str, JsonValue], requested: float | None
) -> float:
    if requested is None:
        return command_timeout_seconds(command, parameters)
    if (
        not is_finite_number(requested)
        or requested <= 0
        or requested > MAXIMUM_COMMAND_TIMEOUT_SECONDS
    ):
        raise ValidationError(
            "timeout must be greater than zero and at most "
            f"{MAXIMUM_COMMAND_TIMEOUT_SECONDS} seconds"
        )
    return requested


def _supported_commands(status: HostStatus) -> frozenset[CommandName]:
    capabilities = status["capabilities"]
    commands = capabilities.get("commands")
    if not isinstance(commands, list) or any(not isinstance(command, str) for command in commands):
        raise MalformedResponseError("host capabilities do not declare supported commands")
    known = frozenset(COMMAND_METADATA)
    return frozenset(command for command in commands if command in known)


def _validate_status(status: HostStatus) -> frozenset[CommandName]:
    if status["protocolVersion"] != PROTOCOL_VERSION:
        raise MalformedResponseError(
            "ping result protocolVersion does not match the response envelope"
        )
    return _supported_commands(status)


class Client(SyncHostCommands):
    def __init__(self, socket_path: str | None = None) -> None:
        self.socket_path = default_socket_path() if socket_path is None else socket_path
        self._transport = SyncUnixSocketTransport(self.socket_path)
        self._host_status: HostStatus | None = None
        self._supported: frozenset[CommandName] | None = None
        self._closed = False

    @property
    def host_status(self) -> HostStatus:
        if self._host_status is None:
            raise ValidationError("connect() must complete before reading host status")
        return self._host_status

    @property
    def capabilities(self) -> dict[str, JsonValue]:
        return self.host_status["capabilities"]

    def connect(
        self,
        *,
        timeout: float | None = None,
        cancel: SyncCancellation | None = None,
    ) -> Client:
        status = self.ping(timeout=timeout, cancel=cancel)
        supported = _validate_status(status)
        self._host_status = status
        self._supported = supported
        return self

    def request(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        *,
        session: str | None = None,
        timeout: float | None = None,
        cancel: SyncCancellation | None = None,
    ) -> object:
        if self._closed:
            raise ClientClosedError()
        if session is not None:
            validate_session(session)
        if command != "ping" and self._supported is None:
            raise ValidationError("connect() must complete before browser commands are sent")
        if command != "ping" and self._supported is not None and command not in self._supported:
            raise UnsupportedCapabilityError(command)
        request = create_request(command, parameters, session)
        request_id = cast(str, request["id"])
        frame = self._transport.send(
            encode_request(request),
            request_id,
            _request_timeout(command, parameters, timeout),
            cancel,
        )
        try:
            result = decode_response(frame, request_id, command)
            if command == "ping":
                _validate_status(cast(HostStatus, result))
            return result
        except CommandError:
            raise
        except MalformedResponseError as error:
            raise OperationOutcomeUnknown(request_id, "read-failed", error) from error

    def session(self, name: str) -> Session:
        validate_session(name)
        return Session(self, name)

    def open_session(
        self,
        name: str,
        *,
        isolated: bool | None = None,
        timeout: float | None = None,
        cancel: SyncCancellation | None = None,
    ) -> Session:
        self.session_create(name=name, isolated=isolated, timeout=timeout, cancel=cancel)
        return self.session(name)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._transport.close()

    def _after_fork_child(self) -> None:
        self._closed = True
        self._transport._after_fork_child()

    def __enter__(self) -> Client:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _invoke_sync(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        timeout: float | None,
        cancel: SyncCancellation | None,
    ) -> object:
        return self.request(command, parameters, timeout=timeout, cancel=cancel)


class Session(SyncSessionCommands):
    def __init__(self, client: Client, name: str) -> None:
        validate_session(name)
        self._client = client
        self.name = name
        self._closed = False
        self._close_lock = threading.Lock()
        self._close_future: Future[SessionClose] | None = None

    def session_close(
        self,
        *,
        timeout: float | None = None,
        cancel: SyncCancellation | None = None,
    ) -> SessionClose:
        with self._close_lock:
            leader = self._close_future is None
            if leader:
                self._close_future = Future()
            close_future = self._close_future
        assert close_future is not None
        if not leader:
            if close_future.done():
                return close_future.result()
            deadline = time.monotonic() + _request_timeout("session.close", {}, timeout)
            while True:
                if cancel is not None and cancel.is_set():
                    raise CancelledBeforeSend()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutBeforeSend()
                wait = min(remaining, 0.05) if cancel is not None else remaining
                try:
                    return close_future.result(timeout=wait)
                except FutureTimeoutError:
                    continue
        try:
            result = cast(
                SessionClose,
                self._client.request(
                    "session.close", {}, session=self.name, timeout=timeout, cancel=cancel
                ),
            )
            self._closed = True
            close_future.set_result(result)
            return result
        except BaseException as error:
            if isinstance(error, OperationOutcomeUnknown):
                self._closed = True
            close_future.set_exception(error)
            if not isinstance(error, OperationOutcomeUnknown):
                with self._close_lock:
                    if self._close_future is close_future:
                        self._close_future = None
            raise

    def close(
        self,
        *,
        timeout: float | None = None,
        cancel: SyncCancellation | None = None,
    ) -> None:
        if self._closed:
            return
        self.session_close(timeout=timeout, cancel=cancel)

    def __enter__(self) -> Session:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _invoke_sync(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        timeout: float | None,
        cancel: SyncCancellation | None,
    ) -> object:
        with self._close_lock:
            closing = self._close_future is not None
        if self._closed or closing:
            raise ClientClosedError()
        return self._client.request(
            command, parameters, session=self.name, timeout=timeout, cancel=cancel
        )


class AsyncClient(AsyncHostCommands):
    def __init__(self, socket_path: str | None = None) -> None:
        self.socket_path = default_socket_path() if socket_path is None else socket_path
        self._transport = AsyncUnixSocketTransport(self.socket_path)
        self._host_status: HostStatus | None = None
        self._supported: frozenset[CommandName] | None = None
        self._closed = False

    @property
    def host_status(self) -> HostStatus:
        if self._host_status is None:
            raise ValidationError("aconnect() must complete before reading host status")
        return self._host_status

    @property
    def capabilities(self) -> dict[str, JsonValue]:
        return self.host_status["capabilities"]

    async def connect(
        self,
        *,
        timeout: float | None = None,
        cancel: AsyncCancellation | None = None,
    ) -> AsyncClient:
        status = await self.ping(timeout=timeout, cancel=cancel)
        supported = _validate_status(status)
        self._host_status = status
        self._supported = supported
        return self

    async def request(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        *,
        session: str | None = None,
        timeout: float | None = None,
        cancel: AsyncCancellation | None = None,
    ) -> object:
        if self._closed:
            raise ClientClosedError()
        if session is not None:
            validate_session(session)
        if command != "ping" and self._supported is None:
            raise ValidationError("aconnect() must complete before browser commands are sent")
        if command != "ping" and self._supported is not None and command not in self._supported:
            raise UnsupportedCapabilityError(command)
        request = create_request(command, parameters, session)
        request_id = cast(str, request["id"])
        frame = await self._transport.send(
            encode_request(request),
            request_id,
            _request_timeout(command, parameters, timeout),
            cancel,
        )
        try:
            result = decode_response(frame, request_id, command)
            if command == "ping":
                _validate_status(cast(HostStatus, result))
            return result
        except CommandError:
            raise
        except MalformedResponseError as error:
            raise OperationOutcomeUnknown(request_id, "read-failed", error) from error

    def session(self, name: str) -> AsyncSession:
        validate_session(name)
        return AsyncSession(self, name)

    async def open_session(
        self,
        name: str,
        *,
        isolated: bool | None = None,
        timeout: float | None = None,
        cancel: AsyncCancellation | None = None,
    ) -> AsyncSession:
        await self.session_create(name=name, isolated=isolated, timeout=timeout, cancel=cancel)
        return self.session(name)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self._transport.close()

    def _after_fork_child(self) -> None:
        self._closed = True
        self._transport._after_fork_child()

    async def __aenter__(self) -> AsyncClient:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def _invoke_async(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        timeout: float | None,
        cancel: AsyncCancellation | None,
    ) -> object:
        return await self.request(command, parameters, timeout=timeout, cancel=cancel)


class AsyncSession(AsyncSessionCommands):
    def __init__(self, client: AsyncClient, name: str) -> None:
        validate_session(name)
        self._client = client
        self.name = name
        self._closed = False
        self._closing = False
        self._close_lock = asyncio.Lock()
        self._close_result: SessionClose | None = None
        self._close_error: OperationOutcomeUnknown | None = None

    async def session_close(
        self,
        *,
        timeout: float | None = None,
        cancel: AsyncCancellation | None = None,
    ) -> SessionClose:
        cached = self._cached_close_result()
        if cached is not None:
            return cached
        remaining = await self._acquire_close_lock(timeout, cancel)
        try:
            cached = self._cached_close_result()
            if cached is not None:
                return cached
            self._closing = True
            try:
                result = cast(
                    SessionClose,
                    await self._client.request(
                        "session.close", {}, session=self.name, timeout=remaining, cancel=cancel
                    ),
                )
            except OperationOutcomeUnknown as error:
                self._closed = True
                self._close_error = error
                raise
            finally:
                self._closing = False
            self._closed = True
            self._close_result = result
            return result
        finally:
            self._close_lock.release()

    def _cached_close_result(self) -> SessionClose | None:
        if self._close_error is not None:
            raise self._close_error
        return self._close_result

    async def _acquire_close_lock(
        self,
        timeout: float | None,
        cancel: AsyncCancellation | None,
    ) -> float:
        if cancel is not None and cancel.is_set():
            raise CancelledBeforeSend()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + _request_timeout("session.close", {}, timeout)
        acquisition = asyncio.create_task(self._close_lock.acquire())
        cancellation = asyncio.create_task(cancel.wait()) if cancel is not None else None
        pending: set[asyncio.Future[Any]] = {acquisition}
        if cancellation is not None:
            pending.add(cancellation)
        acquired = False
        keep_lock = False
        try:
            done, _ = await asyncio.wait(
                pending,
                timeout=max(0, deadline - loop.time()),
                return_when=asyncio.FIRST_COMPLETED,
            )
            if cancellation is not None and cancellation in done:
                raise CancelledBeforeSend()
            if acquisition not in done:
                raise TimeoutBeforeSend()
            acquired = acquisition.result()
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise TimeoutBeforeSend()
            keep_lock = True
            return remaining
        except asyncio.CancelledError as error:
            raise CancelledBeforeSend() from error
        finally:
            if not acquisition.done():
                acquisition.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await acquisition
            elif not acquired and not acquisition.cancelled():
                acquired = acquisition.result()
            if acquired and not keep_lock:
                self._close_lock.release()
            if cancellation is not None:
                cancellation.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await cancellation

    async def close(
        self,
        *,
        timeout: float | None = None,
        cancel: AsyncCancellation | None = None,
    ) -> None:
        if self._closed:
            return
        await self.session_close(timeout=timeout, cancel=cancel)

    async def __aenter__(self) -> AsyncSession:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def _invoke_async(
        self,
        command: CommandName,
        parameters: dict[str, JsonValue],
        timeout: float | None,
        cancel: AsyncCancellation | None,
    ) -> object:
        if self._closed or self._closing:
            raise ClientClosedError()
        return await self._client.request(
            command, parameters, session=self.name, timeout=timeout, cancel=cancel
        )


def connect(
    socket_path: str | None = None,
    *,
    timeout: float | None = None,
    cancel: SyncCancellation | None = None,
) -> Client:
    client = Client(socket_path)
    try:
        return client.connect(timeout=timeout, cancel=cancel)
    except BaseException:
        client.close()
        raise


async def aconnect(
    socket_path: str | None = None,
    *,
    timeout: float | None = None,
    cancel: AsyncCancellation | None = None,
) -> AsyncClient:
    client = AsyncClient(socket_path)
    try:
        return await client.connect(timeout=timeout, cancel=cancel)
    except BaseException:
        await client.close()
        raise
