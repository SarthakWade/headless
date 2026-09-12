"""Typed Python client for the local Headless browser host."""

from importlib.metadata import PackageNotFoundError, version

from ._types import AsyncCancellation, SyncCancellation, Untrusted
from .client import AsyncClient, AsyncSession, Client, Session, aconnect, connect
from .errors import (
    AuthenticationRequiredError,
    CancelledBeforeSend,
    ClientClosedError,
    CommandError,
    ConnectionError,
    HeadlessError,
    HostLaunchError,
    MalformedResponseError,
    OperationOutcomeUnknown,
    ProtocolMismatchError,
    ResponseIdMismatchError,
    ResponseTooLargeError,
    TimeoutBeforeSend,
    TransportError,
    UnsupportedCapabilityError,
    ValidationError,
)
from .generated import (
    MAXIMUM_MESSAGE_BYTES,
    PROTOCOL_FIXTURES_SHA256,
    PROTOCOL_SCHEMA_SHA256,
    PROTOCOL_SCHEMA_VERSION,
    PROTOCOL_VERSION,
    AuthenticationRequired,
    CommandName,
    HostStatus,
    LaunchPresentation,
)
from .lifecycle import AsyncHeadlessHost, HeadlessHost, alaunch, launch

try:
    __version__ = version("lockintime-headless")
except PackageNotFoundError:
    # Source checkouts used by integration tests do not have installed metadata.
    __version__ = "0+source"

__all__ = [
    "MAXIMUM_MESSAGE_BYTES",
    "PROTOCOL_FIXTURES_SHA256",
    "PROTOCOL_SCHEMA_SHA256",
    "PROTOCOL_SCHEMA_VERSION",
    "PROTOCOL_VERSION",
    "AsyncCancellation",
    "AsyncClient",
    "AsyncHeadlessHost",
    "AsyncSession",
    "AuthenticationRequired",
    "AuthenticationRequiredError",
    "CancelledBeforeSend",
    "Client",
    "ClientClosedError",
    "CommandError",
    "CommandName",
    "ConnectionError",
    "HeadlessError",
    "HeadlessHost",
    "HostLaunchError",
    "HostStatus",
    "LaunchPresentation",
    "MalformedResponseError",
    "OperationOutcomeUnknown",
    "ProtocolMismatchError",
    "ResponseIdMismatchError",
    "ResponseTooLargeError",
    "Session",
    "SyncCancellation",
    "TimeoutBeforeSend",
    "TransportError",
    "UnsupportedCapabilityError",
    "Untrusted",
    "ValidationError",
    "__version__",
    "aconnect",
    "alaunch",
    "connect",
    "launch",
]
