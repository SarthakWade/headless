from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import pytest

from headless_sdk import (
    AuthenticationRequiredError,
    CommandError,
    ProtocolMismatchError,
    ResponseIdMismatchError,
    UnsupportedCapabilityError,
    Untrusted,
    ValidationError,
)
from headless_sdk._protocol import create_request, decode_response, encode_request
from headless_sdk.errors import MalformedResponseError
from headless_sdk.generated import (
    COMMAND_METADATA,
    PROTOCOL_FIXTURES_SHA256,
    PROTOCOL_SCHEMA_SHA256,
    PROTOCOL_VERSION,
    command_timeout_seconds,
)

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def response_frame(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


def test_generated_contract_matches_canonical_schema_and_fixtures() -> None:
    schema_bytes = (REPOSITORY_ROOT / "sdk/protocol-schema.json").read_bytes()
    fixture_bytes = (REPOSITORY_ROOT / "sdk/protocol-fixtures.json").read_bytes()
    schema = json.loads(schema_bytes)
    fixtures = json.loads(fixture_bytes)
    assert hashlib.sha256(schema_bytes).hexdigest() == PROTOCOL_SCHEMA_SHA256
    assert hashlib.sha256(fixture_bytes).hexdigest() == PROTOCOL_FIXTURES_SHA256
    assert fixtures["protocolVersion"] == PROTOCOL_VERSION
    assert len(COMMAND_METADATA) == len(schema["commands"])


def test_canonical_fixtures_have_identical_wire_shapes() -> None:
    fixtures = load_json(REPOSITORY_ROOT / "sdk/protocol-fixtures.json")
    for fixture in fixtures["cases"]:
        request = create_request(
            fixture["request"]["command"],
            fixture["request"]["parameters"],
            fixture["request"].get("session"),
            fixture["request"]["id"],
        )
        assert request == fixture["request"], fixture["name"]
        result = decode_response(
            response_frame(fixture["response"]),
            fixture["request"]["id"],
            fixture["request"]["command"],
        )
        if COMMAND_METADATA[fixture["request"]["command"]]["result"]["mayContainUntrustedContent"]:
            assert result == Untrusted(fixture["response"]["result"])
        else:
            assert result == fixture["response"]["result"]
    for request in fixtures["directRequests"]:
        create_request(request["command"], request["parameters"], request_id=request["id"])
    for request in fixtures["invalidRequests"]:
        with pytest.raises(ValidationError):
            create_request(request["command"], request["parameters"], request_id=request["id"])


def test_schema_driven_validation_matches_swift_bounds() -> None:
    with pytest.raises(ValidationError, match="unknown Headless command"):
        create_request("unknown.command", {})  # type: ignore[arg-type]
    with pytest.raises(ValidationError, match="must not be empty"):
        create_request("visit", {"url": ""})
    with pytest.raises(ValidationError, match="non-empty strings"):
        create_request("styles.get", {"target": "@1", "properties": [""]})
    create_request("screenshot", {"format": "PnG"})
    create_request("visit", {"url": "https://example.com"}, "session.one_2-test")
    with pytest.raises(ValidationError, match="letters, digits"):
        create_request("visit", {"url": "https://example.com"}, "unsafe session")
    with pytest.raises(ValidationError, match="letters, digits"):
        create_request("session.create", {"name": "unsafe session"})
    with pytest.raises(ValidationError, match="host-scoped"):
        create_request("ping", {}, "session")
    with pytest.raises(ValidationError, match="unknown parameter password"):
        create_request(
            "auth.login",
            {"challenge": "id", "account": "work", "password": "secret"},
        )
    with pytest.raises(ValidationError, match="finite number"):
        create_request("wait", {"timeoutMs": 10**1000})
    with pytest.raises(ValidationError, match="request id is invalid"):
        create_request("ping", {}, request_id="")
    with pytest.raises(ValidationError, match="request id is invalid"):
        create_request("ping", {}, request_id=1)  # type: ignore[arg-type]
    with pytest.raises(ValidationError, match="session must contain"):
        create_request("visit", {"url": "https://example.com"}, 1)  # type: ignore[arg-type]


def test_generated_timeout_policies_are_used() -> None:
    assert COMMAND_METADATA["ping"]["scope"] == "host"
    assert COMMAND_METADATA["visit"]["scope"] == "session"
    assert command_timeout_seconds("ping", {}) == 15
    assert command_timeout_seconds("wait", {"timeoutMs": 100}) == 10
    assert command_timeout_seconds("wait", {"timeoutMs": 120_000}) == 125
    assert command_timeout_seconds("tour", {}) == 125
    assert command_timeout_seconds("screenshot", {"series": "viewport"}) == 125
    assert command_timeout_seconds("record.stop", {}) == 30


def test_request_has_exactly_one_terminal_newline() -> None:
    frame = encode_request(
        create_request("fill", {"target": "@1", "value": "line one\nline two"}, request_id="one")
    )
    assert frame.endswith(b"\n")
    assert b"\n" not in frame[:-1]
    assert json.loads(frame[:-1])["parameters"]["value"] == "line one\nline two"


def test_response_validation_accepts_schema_allowed_additive_fields() -> None:
    valid = {
        "id": "one",
        "version": PROTOCOL_VERSION,
        "ok": True,
        "result": {"stopping": True, "futureResultField": "accepted"},
        "futureEnvelopeField": {"accepted": True},
    }
    assert decode_response(response_frame(valid), "one", "shutdown") == valid["result"]
    with pytest.raises(MalformedResponseError):
        decode_response(b"not-json", "one", "shutdown")
    with pytest.raises(MalformedResponseError):
        decode_response(
            b'{"id":"one","version":"0.5","ok":true,"result":{"stopping":true},"x":NaN}',
            "one",
            "shutdown",
        )
    with pytest.raises(ResponseIdMismatchError):
        decode_response(response_frame(valid | {"id": "two"}), "one", "shutdown")
    with pytest.raises(ProtocolMismatchError):
        decode_response(response_frame(valid | {"version": "9.9"}), "one", "shutdown")
    with pytest.raises(MalformedResponseError, match="missing stopping"):
        decode_response(response_frame(valid | {"result": {}}), "one", "shutdown")
    with pytest.raises(MalformedResponseError, match="valid JSON"):
        decode_response(
            response_frame(valid | {"result": {"stopping": True, "future": 10**1000}}),
            "one",
            "shutdown",
        )


def test_command_and_authentication_errors_are_typed() -> None:
    def failure(code: str, details: object | None = None) -> bytes:
        return response_frame(
            {
                "id": "failed",
                "version": PROTOCOL_VERSION,
                "ok": False,
                "error": {"code": code, "message": "failed safely", "details": details},
            }
        )

    with pytest.raises(CommandError):
        decode_response(failure("TIMEOUT"), "failed", "wait")
    with pytest.raises(UnsupportedCapabilityError):
        decode_response(failure("UNSUPPORTED_CAPABILITY"), "failed", "upload")

    auth = load_json(PACKAGE_ROOT / "tests/fixtures/auth-required.json")
    with pytest.raises(AuthenticationRequiredError) as caught:
        decode_response(failure("AUTH_REQUIRED", auth["valid"]), "failed", "click")
    assert caught.value.details.untrusted_content is True
    assert caught.value.details.value["challenge"] == auth["valid"]["challenge"]
    for fixture in auth["invalid"]:
        with pytest.raises(MalformedResponseError):
            decode_response(failure("AUTH_REQUIRED", fixture["details"]), "failed", "click")
    with pytest.raises(MalformedResponseError):
        decode_response(failure("AUTH_REQUIRED"), "failed", "click")
