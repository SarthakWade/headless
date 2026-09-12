from __future__ import annotations

import json
import re
import uuid
from collections.abc import Mapping, Sequence
from typing import Any, cast

from ._types import Untrusted, is_finite_number
from .errors import (
    AuthenticationRequiredError,
    CommandError,
    MalformedResponseError,
    ProtocolMismatchError,
    ResponseIdMismatchError,
    UnsupportedCapabilityError,
    ValidationError,
)
from .generated import (
    COMMAND_METADATA,
    ERROR_DETAILS_METADATA,
    MAXIMUM_MESSAGE_BYTES,
    PROTOCOL_VERSION,
    RESPONSE_ADDITIONAL_PROPERTIES,
    AuthenticationRequired,
    CommandName,
    JsonValue,
)

_SESSION_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
_ENVELOPE_FIELDS = frozenset({"id", "version", "ok", "result", "error"})
_MAXIMUM_SESSION_BYTES = 64
_MAXIMUM_REQUEST_ID_BYTES = 128


def _utf8_length(value: str) -> int:
    return len(value.encode("utf-8"))


def _is_json_value(value: object) -> bool:
    pending = [value]
    inspected = 0
    while pending:
        if inspected >= MAXIMUM_MESSAGE_BYTES:
            return False
        inspected += 1
        candidate = pending.pop()
        if candidate is None or isinstance(candidate, (str, bool)):
            continue
        if is_finite_number(candidate):
            continue
        if isinstance(candidate, list):
            pending.extend(candidate)
            continue
        if isinstance(candidate, dict) and all(isinstance(key, str) for key in candidate):
            pending.extend(candidate.values())
            continue
        return False
    return True


def _record(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise MalformedResponseError(f"{label} must be an object")
    return value


def _reject_nonstandard_json_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant {value}")


def validate_session(session: str) -> None:
    if (
        not isinstance(session, str)
        or not session
        or _utf8_length(session) > _MAXIMUM_SESSION_BYTES
        or _SESSION_PATTERN.fullmatch(session) is None
    ):
        raise ValidationError(
            "session must contain 1 to 64 bytes using only letters, digits, dot, "
            "underscore, or hyphen"
        )


def _validate_parameter(command: str, definition: Mapping[str, Any], value: object) -> None:
    name = cast(str, definition["name"])
    label = f"{command}.{name}"
    value_type = definition["type"]
    if value_type == "string":
        if not isinstance(value, str):
            raise ValidationError(f"{label} must be a string")
        if definition.get("required") is True and not value:
            raise ValidationError(f"{label} must not be empty")
        minimum = definition.get("minimumBytes")
        maximum = definition.get("maximumBytes")
        if isinstance(minimum, int) and _utf8_length(value) < minimum:
            raise ValidationError(f"{label} must contain at least {minimum} UTF-8 bytes")
        if isinstance(maximum, int) and _utf8_length(value) > maximum:
            raise ValidationError(f"{label} exceeds {maximum} UTF-8 bytes")
        values = definition.get("values")
        if isinstance(values, list):
            candidate = value.lower() if definition.get("caseInsensitiveValues") is True else value
            if candidate not in values:
                raise ValidationError(f"{label} must be one of {', '.join(values)}")
        return
    if value_type == "boolean":
        if not isinstance(value, bool):
            raise ValidationError(f"{label} must be a boolean")
        return
    if value_type in {"integer", "number"}:
        if not is_finite_number(value) or (value_type == "integer" and not isinstance(value, int)):
            raise ValidationError(f"{label} must be a finite {value_type}")
        minimum = definition.get("minimum")
        maximum = definition.get("maximum")
        if isinstance(minimum, (int, float)) and value < minimum:
            raise ValidationError(f"{label} must be at least {minimum}")
        if isinstance(maximum, (int, float)) and value > maximum:
            raise ValidationError(f"{label} must be at most {maximum}")
        return
    if value_type == "string-array":
        if (
            not isinstance(value, Sequence)
            or isinstance(value, (str, bytes))
            or any(not isinstance(item, str) or not item for item in value)
        ):
            raise ValidationError(f"{label} must be an array of non-empty strings")
        maximum_items = definition.get("maximumItems")
        if isinstance(maximum_items, int) and len(value) > maximum_items:
            raise ValidationError(f"{label} exceeds {maximum_items} items")
        item_maximum = definition.get("itemMaximumBytes")
        if isinstance(item_maximum, int) and any(
            _utf8_length(item) > item_maximum for item in value
        ):
            raise ValidationError(f"{label} contains an item exceeding {item_maximum} UTF-8 bytes")
        return
    raise ValidationError(f"unsupported generated parameter type for {label}")


def validate_parameters(command: CommandName, parameters: Mapping[str, object]) -> None:
    metadata = COMMAND_METADATA.get(command)
    if metadata is None:
        raise ValidationError(f"unknown Headless command: {command}")
    if not isinstance(parameters, dict):
        raise ValidationError(f"{command} parameters must be a plain dictionary")
    definitions = cast(list[dict[str, Any]], metadata["parameters"])
    known = {cast(str, definition["name"]): definition for definition in definitions}
    unknown = next((key for key in parameters if key not in known), None)
    if unknown is not None:
        raise ValidationError(f"{command} received unknown parameter {unknown}")
    for name, definition in known.items():
        if name not in parameters:
            if definition["required"] is True:
                raise ValidationError(f"{command} requires {name}")
        else:
            _validate_parameter(command, definition, parameters[name])
    if command == "session.create":
        validate_session(cast(str, parameters["name"]))


def create_request(
    command: CommandName,
    parameters: dict[str, JsonValue],
    session: str | None = None,
    request_id: str | None = None,
) -> dict[str, JsonValue]:
    validate_parameters(command, parameters)
    identifier = str(uuid.uuid4()) if request_id is None else request_id
    if (
        not isinstance(identifier, str)
        or not identifier
        or _utf8_length(identifier) > _MAXIMUM_REQUEST_ID_BYTES
    ):
        raise ValidationError("request id is invalid")
    if session is not None:
        validate_session(session)
        if COMMAND_METADATA[command]["scope"] != "session":
            raise ValidationError(f"{command} is host-scoped and cannot target a session")
    request: dict[str, JsonValue] = {
        "id": identifier,
        "version": PROTOCOL_VERSION,
        "command": command,
        "parameters": parameters,
    }
    if session is not None:
        request["session"] = session
    return request


def encode_request(request: Mapping[str, JsonValue]) -> bytes:
    try:
        encoded = (
            json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        )
    except (TypeError, ValueError) as error:
        raise ValidationError("request could not be encoded as JSON") from error
    if len(encoded) > MAXIMUM_MESSAGE_BYTES:
        raise ValidationError(f"request exceeds the {MAXIMUM_MESSAGE_BYTES}-byte frame limit")
    if encoded.count(b"\n") != 1 or not encoded.endswith(b"\n"):
        raise ValidationError("request must contain exactly one terminal newline frame")
    return encoded


def _valid_field(field_type: str, value: object) -> bool:
    if field_type == "array":
        return isinstance(value, list) and _is_json_value(value)
    if field_type == "boolean":
        return isinstance(value, bool)
    if field_type == "json":
        return _is_json_value(value)
    if field_type == "number":
        return is_finite_number(value)
    if field_type == "object":
        return isinstance(value, dict) and _is_json_value(value)
    if field_type == "string":
        return isinstance(value, str)
    if field_type == "string-or-null":
        return value is None or isinstance(value, str)
    return False


def _validate_object_schema(label: str, schema: Mapping[str, Any], value: object) -> dict[str, Any]:
    record = _record(value, label)
    fields = cast(list[dict[str, Any]], schema["fields"])
    known = {cast(str, field["name"]) for field in fields}
    for field in fields:
        name = cast(str, field["name"])
        if name not in record:
            if field["required"] is True:
                raise MalformedResponseError(f"{label} is missing {name}")
        elif not _valid_field(cast(str, field["type"]), record[name]):
            raise MalformedResponseError(f"{label} has invalid {name}")
    if schema["additionalProperties"] is False:
        unknown = next((name for name in record if name not in known), None)
        if unknown is not None:
            raise MalformedResponseError(f"{label} has unknown field {unknown}")
    if not _is_json_value(record):
        raise MalformedResponseError(f"{label} is not valid JSON")
    return record


def decode_response(frame: bytes, expected_id: str, command: CommandName) -> object:
    try:
        value = json.loads(
            frame.decode("utf-8"),
            parse_constant=_reject_nonstandard_json_constant,
        )
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise MalformedResponseError("Headless returned malformed JSON") from error
    response = _record(value, "Headless response")
    if not RESPONSE_ADDITIONAL_PROPERTIES:
        unknown = next((name for name in response if name not in _ENVELOPE_FIELDS), None)
        if unknown is not None:
            raise MalformedResponseError(f"Headless response has unknown field {unknown}")
    version = response.get("version")
    if not isinstance(version, str):
        raise MalformedResponseError("Headless response is missing its protocol version")
    if version != PROTOCOL_VERSION:
        raise ProtocolMismatchError(PROTOCOL_VERSION, version)
    identifier = response.get("id")
    if not isinstance(identifier, str):
        raise MalformedResponseError("Headless response is missing its id")
    if identifier != expected_id:
        raise ResponseIdMismatchError(expected_id, identifier)
    if not isinstance(response.get("ok"), bool):
        raise MalformedResponseError("Headless response is missing ok")
    if response["ok"] is False:
        if response.get("result") is not None:
            raise MalformedResponseError("failed Headless response contains a result")
        error_record = _record(response.get("error"), "failed Headless response error")
        code = error_record.get("code")
        message = error_record.get("message")
        if not isinstance(code, str) or not isinstance(message, str):
            raise MalformedResponseError("failed Headless response has an invalid error")
        suggestion = error_record.get("suggestion")
        if suggestion is not None and not isinstance(suggestion, str):
            raise MalformedResponseError("response error suggestion must be a string")
        details = error_record.get("details")
        if details is not None and not _is_json_value(details):
            raise MalformedResponseError("response error details are not valid JSON")
        if code == "UNSUPPORTED_CAPABILITY":
            raise UnsupportedCapabilityError(command, message, suggestion, details)
        if code == "AUTH_REQUIRED":
            validated = _validate_object_schema(
                "AUTH_REQUIRED details",
                cast(dict[str, Any], ERROR_DETAILS_METADATA["AUTH_REQUIRED"]["schema"]),
                details,
            )
            raise AuthenticationRequiredError(
                message,
                suggestion,
                Untrusted(cast(AuthenticationRequired, validated)),
            )
        raise CommandError(code, message, suggestion, details)
    if response.get("error") is not None:
        raise MalformedResponseError("successful Headless response contains an error")
    metadata = cast(dict[str, Any], COMMAND_METADATA[command]["result"])
    result = _validate_object_schema(
        f"{command} result", cast(dict[str, Any], metadata["schema"]), response.get("result")
    )
    if metadata["mayContainUntrustedContent"] is True:
        return Untrusted(result)
    return result
