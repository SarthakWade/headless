from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ._types import Untrusted

if TYPE_CHECKING:
    from .generated import AuthenticationRequired, LifecycleErrorCode


class HeadlessError(Exception):
    """Base class for SDK failures."""


class ValidationError(HeadlessError):
    pass


class ClientClosedError(HeadlessError):
    def __init__(self) -> None:
        super().__init__("the Headless client is closed")


class TransportError(HeadlessError):
    def __init__(self, message: str, *, retry_safe: bool) -> None:
        super().__init__(message)
        self.retry_safe = retry_safe


class ConnectionError(TransportError):
    def __init__(self, message: str) -> None:
        super().__init__(message, retry_safe=True)


class TimeoutBeforeSend(TransportError):
    def __init__(self) -> None:
        super().__init__("the request timed out before any bytes were sent", retry_safe=True)


class CancelledBeforeSend(TransportError):
    def __init__(self) -> None:
        super().__init__("the request was cancelled before any bytes were sent", retry_safe=True)


class OperationOutcomeUnknown(TransportError):
    def __init__(self, request_id: str, reason: str, cause: BaseException | None = None) -> None:
        super().__init__(
            f"request {request_id} was sent but its outcome is unknown ({reason}); "
            "inspect host state before continuing",
            retry_safe=False,
        )
        self.request_id = request_id
        self.reason = reason
        self.__cause__ = cause


class MalformedResponseError(TransportError):
    def __init__(self, message: str) -> None:
        super().__init__(message, retry_safe=False)


class ResponseTooLargeError(MalformedResponseError):
    def __init__(self, maximum_bytes: int) -> None:
        super().__init__(f"Headless response exceeded the {maximum_bytes}-byte frame limit")


class ProtocolMismatchError(MalformedResponseError):
    def __init__(self, expected_version: str, actual_version: str) -> None:
        super().__init__(
            f"Headless protocol mismatch: expected {expected_version}, received {actual_version}"
        )
        self.expected_version = expected_version
        self.actual_version = actual_version


class ResponseIdMismatchError(MalformedResponseError):
    def __init__(self, expected_id: str, actual_id: str) -> None:
        super().__init__(
            f"Headless response id mismatch: expected {expected_id}, received {actual_id}"
        )
        self.expected_id = expected_id
        self.actual_id = actual_id


class CommandError(HeadlessError):
    def __init__(
        self,
        code: str,
        message: str,
        suggestion: str | None = None,
        details: Any = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.suggestion = suggestion
        self.details = details


class AuthenticationRequiredError(CommandError):
    details: Untrusted[AuthenticationRequired]

    def __init__(
        self,
        message: str,
        suggestion: str | None,
        details: Untrusted[AuthenticationRequired],
    ) -> None:
        super().__init__("AUTH_REQUIRED", message, suggestion, details)


class UnsupportedCapabilityError(CommandError):
    def __init__(
        self,
        command: str,
        message: str | None = None,
        suggestion: str | None = None,
        details: Any = None,
    ) -> None:
        super().__init__(
            "UNSUPPORTED_CAPABILITY",
            message or f"the connected Headless host does not support {command}",
            suggestion,
            details,
        )
        self.command = command


class HostLaunchError(HeadlessError):
    def __init__(
        self,
        message: str,
        *,
        code: LifecycleErrorCode = "HOST_START_FAILED",
        suggestion: str | None = None,
        details: Any = None,
        exit_code: int | None = None,
        signal: int | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.suggestion = suggestion
        self.details = details
        self.exit_code = exit_code
        self.signal = signal
