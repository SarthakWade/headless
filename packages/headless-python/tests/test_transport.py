from __future__ import annotations

import asyncio
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import pytest

from headless_sdk import (
    CancelledBeforeSend,
    ClientClosedError,
    CommandError,
    MalformedResponseError,
    OperationOutcomeUnknown,
    ProtocolMismatchError,
    ResponseIdMismatchError,
    ResponseTooLargeError,
    TimeoutBeforeSend,
    UnsupportedCapabilityError,
    Untrusted,
    ValidationError,
    aconnect,
    connect,
)
from headless_sdk._transport import AsyncUnixSocketTransport, SyncUnixSocketTransport
from headless_sdk.generated import MAXIMUM_MESSAGE_BYTES, PROTOCOL_VERSION

from .helpers import PrivateSocketServer, host_status, json_frame, unique_socket_path


def test_connect_negotiates_capabilities_and_preserves_untrusted_results() -> None:
    def response(request: dict[str, Any], _: object) -> bytes:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        assert request["command"] == "visit"
        return json_frame(
            {
                "id": request["id"],
                "version": PROTOCOL_VERSION,
                "ok": True,
                "result": {
                    "url": request["parameters"]["url"],
                    "title": "Untrusted",
                    "readyState": "complete",
                    "text": "page text",
                    "runningAnimations": 0,
                    "mutationQuietMs": 500,
                    "scrollY": 0,
                    "contentHeight": 900,
                },
            }
        )

    with PrivateSocketServer(response) as server, connect(server.socket_path) as client:
        result = client.session("work.one").visit(url="https://example.com")
        assert isinstance(result, Untrusted)
        assert result.value["title"] == "Untrusted"
        assert server.requests[1]["session"] == "work.one"
        assert "visit" in client.capabilities["commands"]
        with pytest.raises(ValidationError, match="timeout"):
            client.ping(timeout=10**1000)


def test_connect_close_never_stops_shared_host() -> None:
    with PrivateSocketServer(
        lambda request, _: json_frame(host_status(request["id"], 7101))
    ) as server:
        connect(server.socket_path).close()
        second = connect(server.socket_path)
        assert second.host_status["pid"] == 7101
        second.close()
        assert len(server.requests) == 2


def test_direct_session_close_updates_sync_and_async_wrapper_state() -> None:
    def response(request: dict[str, Any], _: object) -> bytes:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        assert request["command"] == "session.close"
        time.sleep(0.05)
        return json_frame(
            {
                "id": request["id"],
                "version": PROTOCOL_VERSION,
                "ok": True,
                "result": {"closed": request["session"]},
            }
        )

    async def async_scenario(socket_path: str) -> None:
        client = await aconnect(socket_path)
        session = client.session("async")
        first, second = await asyncio.gather(session.session_close(), session.session_close())
        assert first["closed"] == "async"
        assert second["closed"] == "async"
        with pytest.raises(ClientClosedError):
            await session.visit(url="https://example.com")
        await session.close()
        await client.close()

    with PrivateSocketServer(response) as server:
        client = connect(server.socket_path)
        session = client.session("sync")
        with ThreadPoolExecutor(max_workers=2) as executor:
            first, second = executor.map(lambda _: session.session_close(), range(2))
        assert first["closed"] == "sync"
        assert second["closed"] == "sync"
        with pytest.raises(ClientClosedError):
            session.visit(url="https://example.com")
        session.close()
        client.close()
        asyncio.run(async_scenario(server.socket_path))
        assert [request["command"] for request in server.requests] == [
            "ping",
            "session.close",
            "ping",
            "session.close",
        ]


def test_sync_session_close_retries_before_send_and_quarantines_unknown_outcomes() -> None:
    def response(request: dict[str, Any], _: object) -> bytes | None:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        if request["command"] == "session.close" and request["session"].endswith("unknown"):
            return None
        assert request["command"] == "session.close"
        return json_frame(
            {
                "id": request["id"],
                "version": PROTOCOL_VERSION,
                "ok": True,
                "result": {"closed": request["session"]},
            }
        )

    with PrivateSocketServer(response) as server:
        client = connect(server.socket_path)
        retry = client.session("sync-retry")
        cancel = threading.Event()
        cancel.set()
        with pytest.raises(CancelledBeforeSend):
            retry.session_close(cancel=cancel)
        cancel.clear()
        assert retry.session_close()["closed"] == "sync-retry"

        unknown = client.session("sync-unknown")
        with pytest.raises(OperationOutcomeUnknown):
            unknown.session_close()
        with pytest.raises(ClientClosedError):
            unknown.visit(url="https://example.com")
        with pytest.raises(OperationOutcomeUnknown):
            unknown.session_close()
        client.close()
        close_sessions = [
            request["session"]
            for request in server.requests
            if request["command"] == "session.close"
        ]
        assert close_sessions == [
            "sync-retry",
            "sync-unknown",
        ]


def test_async_session_close_preserves_cancellation_certainty() -> None:
    close_started = threading.Event()

    def response(request: dict[str, Any], _: object) -> bytes | None:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        if request["command"] == "session.close" and request["session"].endswith("unknown"):
            return None
        assert request["command"] == "session.close"
        if request["session"] == "async-caller-cancel":
            close_started.set()
            time.sleep(0.1)
        return json_frame(
            {
                "id": request["id"],
                "version": PROTOCOL_VERSION,
                "ok": True,
                "result": {"closed": request["session"]},
            }
        )

    async def scenario(socket_path: str) -> None:
        client = await aconnect(socket_path)
        retry = client.session("async-retry")
        cancel = asyncio.Event()
        cancel.set()
        with pytest.raises(CancelledBeforeSend):
            await retry.session_close(cancel=cancel)
        cancel.clear()
        assert (await retry.session_close())["closed"] == "async-retry"

        caller_cancel = client.session("async-caller-cancel")
        pending = asyncio.create_task(caller_cancel.session_close())
        assert await asyncio.to_thread(close_started.wait, 1)
        pending.cancel()
        with pytest.raises(OperationOutcomeUnknown):
            await pending
        with pytest.raises(ClientClosedError):
            await caller_cancel.visit(url="https://example.com")
        with pytest.raises(OperationOutcomeUnknown):
            await caller_cancel.session_close()

        unknown = client.session("async-unknown")
        with pytest.raises(OperationOutcomeUnknown):
            await unknown.session_close()
        with pytest.raises(ClientClosedError):
            await unknown.visit(url="https://example.com")
        with pytest.raises(OperationOutcomeUnknown):
            await unknown.session_close()
        await client.close()

    with PrivateSocketServer(response) as server:
        asyncio.run(scenario(server.socket_path))
        close_sessions = [
            request["session"]
            for request in server.requests
            if request["command"] == "session.close"
        ]
        assert close_sessions == [
            "async-retry",
            "async-caller-cancel",
            "async-unknown",
        ]


def test_async_session_close_honors_a_concurrent_followers_cancellation() -> None:
    close_started = threading.Event()

    def response(request: dict[str, Any], _: object) -> bytes:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        close_started.set()
        time.sleep(0.1)
        return json_frame(
            {
                "id": request["id"],
                "version": PROTOCOL_VERSION,
                "ok": True,
                "result": {"closed": request["session"]},
            }
        )

    async def scenario(socket_path: str) -> None:
        client = await aconnect(socket_path)
        session = client.session("async-follower-cancel")
        leader = asyncio.create_task(session.session_close())
        assert await asyncio.to_thread(close_started.wait, 1)
        cancel = asyncio.Event()
        follower = asyncio.create_task(session.session_close(cancel=cancel))
        await asyncio.sleep(0)
        cancel.set()
        with pytest.raises(CancelledBeforeSend):
            await follower
        assert (await leader)["closed"] == "async-follower-cancel"
        await client.close()

    with PrivateSocketServer(response) as server:
        asyncio.run(scenario(server.socket_path))
        assert [request["command"] for request in server.requests] == ["ping", "session.close"]


def test_commands_cannot_bypass_connection_or_capability_negotiation() -> None:
    path = unique_socket_path("unused")
    client = connect
    from headless_sdk import Client

    disconnected = Client(path)
    with pytest.raises(ValidationError, match=r"connect\(\) must complete"):
        disconnected.session_create(name="one")
    disconnected.close()
    del client

    with (
        PrivateSocketServer(
            lambda request, _: json_frame(host_status(request["id"], commands=["ping"]))
        ) as server,
        connect(server.socket_path) as limited,
    ):
        with pytest.raises(UnsupportedCapabilityError):
            limited.session("one").visit(url="https://example.com")
        assert len(server.requests) == 1


def test_socket_location_permissions_and_outbound_frame_validation(tmp_path: Path) -> None:
    with pytest.raises(ValidationError, match="must be absolute"):
        SyncUnixSocketTransport("")
    with pytest.raises(ValidationError, match="must be absolute"):
        connect("")
    with PrivateSocketServer(lambda request, _: json_frame(host_status(request["id"]))) as server:
        transport = SyncUnixSocketTransport(server.socket_path)
        with pytest.raises(ValidationError, match="timeout"):
            transport.send(b"{}\n", "huge-timeout", 10**1000)
        with pytest.raises(ValidationError, match="terminal newline"):
            transport.send(b"{}", "missing-newline", 1)
        with pytest.raises(ValidationError, match="exactly one"):
            transport.send(b"{}\n{}\n", "multiple", 1)
        os.chmod(server.socket_path, 0o666)
        with pytest.raises(Exception, match="socket is not private"):
            transport.send(b"{}\n", "public", 1)
        os.chmod(server.socket_path, 0o600)
        transport.close()

    with pytest.raises(ValidationError, match="direct child"):
        SyncUnixSocketTransport(str(tmp_path / "host.sock"))
    with pytest.raises(ValidationError, match="direct child"):
        connect(str(tmp_path / "connect.sock"))

    target = unique_socket_path("target")
    link = unique_socket_path("symlink")
    Path(target).touch(mode=0o600)
    Path(link).symlink_to(target)
    try:
        with pytest.raises(Exception, match="socket is not private"):
            SyncUnixSocketTransport(link).send(b"{}\n", "symlink", 1)
    finally:
        Path(link).unlink(missing_ok=True)
        Path(target).unlink(missing_ok=True)


def test_timeout_and_cancellation_before_write_are_retry_safe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with PrivateSocketServer(lambda request, _: json_frame(host_status(request["id"]))) as server:
        transport = SyncUnixSocketTransport(server.socket_path)
        cancel = threading.Event()
        cancel.set()
        with pytest.raises(CancelledBeforeSend) as cancelled:
            transport.send(b"{}\n", "cancelled", 1, cancel)
        assert cancelled.value.retry_safe

        clock = iter((0.0, 2.0))
        monkeypatch.setattr("headless_sdk._transport.time.monotonic", lambda: next(clock, 2.0))
        with pytest.raises(TimeoutBeforeSend) as timed_out:
            transport.send(b"{}\n", "timeout", 1)
        assert timed_out.value.retry_safe
        transport.close()


def test_post_write_timeout_cancellation_and_read_failure_are_unknown() -> None:
    received = threading.Event()

    def response(request: dict[str, Any], _: object) -> bytes | None:
        received.set()
        if request["id"] == "closed":
            return None
        time.sleep(0.5)
        return None

    with PrivateSocketServer(response) as server:
        transport = SyncUnixSocketTransport(server.socket_path)
        with pytest.raises(OperationOutcomeUnknown) as timed_out:
            transport.send(b'{"id":"timeout"}\n', "timeout", 0.02)
        assert timed_out.value.reason == "timed-out"
        assert not timed_out.value.retry_safe

        cancel = threading.Event()
        result: list[BaseException] = []

        def send() -> None:
            try:
                transport.send(b'{"id":"cancel"}\n', "cancel", 1, cancel)
            except BaseException as error:
                result.append(error)

        received.clear()
        thread = threading.Thread(target=send)
        thread.start()
        assert received.wait(1)
        cancel.set()
        thread.join(1)
        assert isinstance(result[0], OperationOutcomeUnknown)
        assert result[0].reason == "cancelled"  # type: ignore[union-attr]

        with pytest.raises(OperationOutcomeUnknown) as closed:
            transport.send(b'{"id":"closed"}\n', "closed", 1)
        assert isinstance(closed.value.__cause__, MalformedResponseError)
        transport.close()


def test_all_post_write_response_failures_preserve_specific_causes() -> None:
    mode = "valid"

    def response(request: dict[str, Any], connection: Any) -> bytes | None:
        nonlocal mode
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        valid = {
            "id": request["id"],
            "version": PROTOCOL_VERSION,
            "ok": True,
            "result": {"stopping": True},
        }
        if mode == "malformed":
            return b"not-json\n"
        if mode == "empty":
            return None
        if mode == "partial":
            return b'{"id":"partial"'
        if mode == "oversized":
            return b"a" * (MAXIMUM_MESSAGE_BYTES + 1)
        if mode == "multiple":
            return b"{}\n{}\n"
        if mode == "delayed-multiple":
            connection.sendall(json_frame(valid))
            time.sleep(0.02)
            return b"{}\n"
        if mode == "mismatch":
            return json_frame(valid | {"id": "other"})
        if mode == "version":
            return json_frame(valid | {"version": "9.9"})
        if mode == "result":
            return json_frame(valid | {"result": {}})
        if mode == "command-error":
            return json_frame(
                {
                    "id": request["id"],
                    "version": PROTOCOL_VERSION,
                    "ok": False,
                    "error": {"code": "TIMEOUT", "message": "host timed out"},
                }
            )
        raise AssertionError(mode)

    expected = {
        "malformed": MalformedResponseError,
        "empty": MalformedResponseError,
        "partial": MalformedResponseError,
        "oversized": ResponseTooLargeError,
        "multiple": MalformedResponseError,
        "delayed-multiple": MalformedResponseError,
        "mismatch": ResponseIdMismatchError,
        "version": ProtocolMismatchError,
        "result": MalformedResponseError,
    }
    with PrivateSocketServer(response) as server, connect(server.socket_path) as client:
        for mode, cause_type in expected.items():
            with pytest.raises(OperationOutcomeUnknown) as caught:
                client.shutdown()
            assert isinstance(caught.value.__cause__, cause_type), mode
        mode = "command-error"
        with pytest.raises(CommandError) as command_error:
            client.shutdown()
        assert command_error.value.code == "TIMEOUT"


def test_async_client_transport_and_task_cancellation() -> None:
    received = threading.Event()

    def response(request: dict[str, Any], _: object) -> bytes | None:
        if request["command"] == "ping":
            return json_frame(host_status(request["id"]))
        received.set()
        time.sleep(0.5)
        return None

    async def scenario(server: PrivateSocketServer) -> None:
        client = await aconnect(server.socket_path)
        try:
            pending = asyncio.create_task(client.shutdown(timeout=1))
            assert await asyncio.to_thread(received.wait, 1)
            pending.cancel()
            with pytest.raises(OperationOutcomeUnknown) as caught:
                await pending
            assert caught.value.reason == "cancelled"
            assert not caught.value.retry_safe
        finally:
            await client.close()

    with PrivateSocketServer(response) as server:
        asyncio.run(scenario(server))


def test_async_pre_cancel_is_retry_safe(monkeypatch: pytest.MonkeyPatch) -> None:
    async def scenario(server: PrivateSocketServer) -> None:
        transport = AsyncUnixSocketTransport(server.socket_path)
        cancel = asyncio.Event()
        cancel.set()
        with pytest.raises(CancelledBeforeSend):
            await transport.send(b"{}\n", "cancelled", 1, cancel)
        await transport.close()

        cancel_after_connect = asyncio.Event()
        cancelling_transport = AsyncUnixSocketTransport(server.socket_path)
        open_connection = asyncio.open_unix_connection

        async def cancelling_open(path: str) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
            connection = await open_connection(path)
            cancel_after_connect.set()
            return connection

        monkeypatch.setattr(asyncio, "open_unix_connection", cancelling_open)
        with pytest.raises(CancelledBeforeSend):
            await cancelling_transport.send(
                b"{}\n", "cancelled-after-connect", 1, cancel_after_connect
            )
        await cancelling_transport.close()

        closing_transport = AsyncUnixSocketTransport(server.socket_path)

        async def closing_open(path: str) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
            connection = await open_connection(path)
            await closing_transport.close()
            return connection

        monkeypatch.setattr(asyncio, "open_unix_connection", closing_open)
        with pytest.raises(ClientClosedError):
            await closing_transport.send(b"{}\n", "closed-after-connect", 1)

    with PrivateSocketServer(lambda request, _: json_frame(host_status(request["id"]))) as server:
        asyncio.run(scenario(server))
        assert server.requests == []
