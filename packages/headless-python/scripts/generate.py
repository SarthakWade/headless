from __future__ import annotations

import argparse
import hashlib
import json
import keyword
import pprint
import re
from pathlib import Path
from typing import Any

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]
SCHEMA_PATH = REPOSITORY_ROOT / "sdk" / "protocol-schema.json"
FIXTURES_PATH = REPOSITORY_ROOT / "sdk" / "protocol-fixtures.json"
OUTPUT_PATH = PACKAGE_ROOT / "src" / "headless_sdk" / "generated.py"


def class_name(value: str) -> str:
    return "".join(
        part[:1].upper() + part[1:] for part in re.split(r"[^A-Za-z0-9]+", value) if part
    )


def snake_name(value: str) -> str:
    value = value.replace(".", "_")
    value = re.sub(r"(?<!^)(?=[A-Z])", "_", value).lower()
    return f"{value}_" if keyword.iskeyword(value) else value


def literal_union(values: list[str]) -> str:
    return f"Literal[{', '.join(repr(value) for value in values)}]"


def parameter_type(parameter: dict[str, Any]) -> str:
    values = parameter.get("values")
    if isinstance(values, list) and not parameter.get("caseInsensitiveValues", False):
        return literal_union(values)
    return {
        "boolean": "bool",
        "integer": "int",
        "number": "int | float",
        "string": "str",
        "string-array": "Sequence[str]",
    }[parameter["type"]]


def result_type(field_type: str) -> str:
    return {
        "array": "list[JsonValue]",
        "boolean": "bool",
        "json": "JsonValue",
        "number": "int | float",
        "object": "dict[str, JsonValue]",
        "string": "str",
        "string-or-null": "str | None",
    }[field_type]


def command_result_type(command: dict[str, Any]) -> str:
    name = command["result"]["schema"]["name"]
    if command["result"]["mayContainUntrustedContent"]:
        return f"Untrusted[{name}]"
    return name


def register_result_schema(
    result_schemas: dict[str, dict[str, Any]], result: object, source: str
) -> None:
    if not isinstance(result, dict) or not isinstance(result.get("fields"), list):
        raise ValueError(f"invalid result schema: {source}")
    name = result.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"invalid result schema name: {source}")
    previous = result_schemas.get(name)
    if previous is not None and previous != result:
        raise ValueError(f"conflicting result schema: {name}")
    result_schemas[name] = result


def emit_parameters(lines: list[str], command: dict[str, Any]) -> None:
    name = f"{class_name(command['name'])}Parameters"
    lines.append(f"class {name}(TypedDict):")
    if not command["parameters"]:
        lines.append("    pass")
    for parameter in command["parameters"]:
        annotation = parameter_type(parameter)
        if not parameter["required"]:
            annotation = f"NotRequired[{annotation}]"
        lines.append(f"    {parameter['name']}: {annotation}")
    lines.append("")


def emit_result(lines: list[str], schema: dict[str, Any]) -> None:
    lines.append(f"class {schema['name']}(TypedDict, total=False):")
    for field in schema["fields"]:
        wrapper = "Required" if field["required"] else "NotRequired"
        lines.append(f"    {field['name']}: {wrapper}[{result_type(field['type'])}]")
    if not schema["fields"]:
        lines.append("    pass")
    lines.append("")


def emit_method(lines: list[str], command: dict[str, Any], asynchronous: bool) -> None:
    prefix = "async def" if asynchronous else "def"
    method = snake_name(command["name"])
    result = command_result_type(command)
    lines.append(f"    {prefix} {method}(")
    lines.append("        self,")
    lines.append("        *,")
    for parameter in command["parameters"]:
        annotation = parameter_type(parameter)
        default = "" if parameter["required"] else " = None"
        if not parameter["required"]:
            annotation = f"{annotation} | None"
        lines.append(f"        {snake_name(parameter['name'])}: {annotation}{default},")
    lines.append("        timeout: float | None = None,")
    cancel_type = "AsyncCancellation" if asynchronous else "SyncCancellation"
    lines.append(f"        cancel: {cancel_type} | None = None,")
    lines.append(f"    ) -> {result}:")
    if command["parameters"]:
        lines.append("        parameters: dict[str, JsonValue] = {")
        lines.extend(
            f"            {parameter['name']!r}: cast(JsonValue, {snake_name(parameter['name'])}),"
            for parameter in command["parameters"]
            if parameter["required"]
        )
        lines.append("        }")
        for parameter in command["parameters"]:
            if not parameter["required"]:
                local = snake_name(parameter["name"])
                lines.append(f"        if {local} is not None:")
                lines.append(
                    f"            parameters[{parameter['name']!r}] = cast(JsonValue, {local})"
                )
    else:
        lines.append("        parameters: dict[str, JsonValue] = {}")
    invocation = "_invoke_async" if asynchronous else "_invoke_sync"
    awaited = "await " if asynchronous else ""
    invocation_line = (
        f"        return cast({result}, {awaited}self.{invocation}"
        f"({command['name']!r}, parameters, timeout, cancel))"
    )
    lines.append(invocation_line)
    lines.append("")


def emit_mixin(
    lines: list[str],
    name: str,
    commands: list[dict[str, Any]],
    asynchronous: bool,
) -> None:
    lines.append(f"class {name}:")
    invocation = "_invoke_async" if asynchronous else "_invoke_sync"
    if asynchronous:
        lines.extend(
            [
                f"    async def {invocation}(",
                "        self, command: CommandName, parameters: dict[str, JsonValue],",
                "        timeout: float | None, cancel: AsyncCancellation | None,",
                "    ) -> object:",
                "        raise NotImplementedError",
                "",
            ]
        )
    else:
        lines.extend(
            [
                f"    def {invocation}(",
                "        self, command: CommandName, parameters: dict[str, JsonValue],",
                "        timeout: float | None, cancel: SyncCancellation | None,",
                "    ) -> object:",
                "        raise NotImplementedError",
                "",
            ]
        )
    for command in commands:
        emit_method(lines, command, asynchronous)


def generate() -> str:
    schema_bytes = SCHEMA_PATH.read_bytes()
    fixture_bytes = FIXTURES_PATH.read_bytes()
    schema = json.loads(schema_bytes)
    fixtures = json.loads(fixture_bytes)
    if schema.get("format") != "headless-sdk-contract" or schema.get("schemaVersion") != 1:
        raise ValueError("unsupported Headless SDK schema")
    if fixtures.get("schemaVersion") != 1 or fixtures.get("protocolVersion") != schema.get(
        "protocolVersion"
    ):
        raise ValueError("protocol fixtures do not match the SDK schema")
    commands = schema.get("commands")
    if not isinstance(commands, list) or not commands:
        raise ValueError("schema has no commands")
    lifecycle = schema.get("localLifecycle", {}).get("launch", {})
    presentations = next(
        (
            option.get("values")
            for option in lifecycle.get("options", [])
            if option.get("name") == "presentation"
        ),
        None,
    )
    if not isinstance(presentations, list) or "background" not in presentations:
        raise ValueError("schema has no launch presentation contract")

    result_schemas: dict[str, dict[str, Any]] = {}
    for command in commands:
        if command.get("scope") not in {"host", "session"}:
            raise ValueError(f"invalid command scope: {command.get('name')}")
        result = command.get("result", {}).get("schema")
        register_result_schema(result_schemas, result, str(command.get("name")))
    for code, detail in schema.get("errorDetails", {}).items():
        result = detail.get("schema")
        register_result_schema(result_schemas, result, f"error detail {code}")

    metadata = {
        command["name"]: {
            "capabilityNegotiated": command["capabilityNegotiated"],
            "constraints": command["constraints"],
            "parameters": command["parameters"],
            "result": command["result"],
            "scope": command["scope"],
            "timeout": command["timeout"],
        }
        for command in commands
    }
    max_timeout = max(
        max(
            command["timeout"]["defaultMilliseconds"],
            command["timeout"].get("maximumMilliseconds", 0),
            *command["timeout"]["parameterPresentOverrides"].values(),
        )
        for command in commands
    )
    error_codes = schema["response"]["failure"]["error"]["codes"]
    lifecycle_codes = lifecycle["errors"]
    lines = [
        "# Generated by scripts/generate.py. Do not edit.",
        "from __future__ import annotations",
        "",
        "from collections.abc import Sequence",
        "from typing import Any, Literal, NotRequired, Required, TypeAlias, TypedDict, cast",
        "",
        "from ._types import AsyncCancellation, SyncCancellation, Untrusted",
        "",
        "JsonPrimitive: TypeAlias = bool | float | int | str | None",
        'JsonValue: TypeAlias = JsonPrimitive | list["JsonValue"] | dict[str, "JsonValue"]',
        "",
        f"PROTOCOL_VERSION = {schema['protocolVersion']!r}",
        f"PROTOCOL_SCHEMA_VERSION = {schema['schemaVersion']}",
        f"MAXIMUM_MESSAGE_BYTES = {schema['maximumMessageBytes']}",
        f"MAXIMUM_COMMAND_TIMEOUT_SECONDS = {max_timeout / 1000!r}",
        f"PROTOCOL_SCHEMA_SHA256 = {hashlib.sha256(schema_bytes).hexdigest()!r}",
        f"PROTOCOL_FIXTURES_SHA256 = {hashlib.sha256(fixture_bytes).hexdigest()!r}",
        f"RESPONSE_ADDITIONAL_PROPERTIES = {schema['response']['additionalProperties']!r}",
        f"COMMAND_ERROR_CODES = {tuple(error_codes)!r}",
        f"CommandErrorCode = {literal_union(error_codes)}",
        f"LIFECYCLE_ERROR_CODES = {tuple(lifecycle_codes)!r}",
        f"LifecycleErrorCode = {literal_union(lifecycle_codes)}",
        f"LAUNCH_PRESENTATIONS = {tuple(presentations)!r}",
        f"LaunchPresentation = {literal_union(presentations)}",
        f"CommandName = {literal_union([command['name'] for command in commands])}",
        "",
    ]
    for command in commands:
        emit_parameters(lines, command)
    for result in result_schemas.values():
        emit_result(lines, result)
    lines.extend(
        [
            "COMMAND_METADATA: dict[CommandName, dict[str, Any]] = "
            f"{pprint.pformat(metadata, sort_dicts=True, width=100)}",
            "ERROR_DETAILS_METADATA: dict[str, dict[str, Any]] = "
            f"{pprint.pformat(schema['errorDetails'], sort_dicts=True, width=100)}",
            "LOCAL_LIFECYCLE: dict[str, Any] = "
            f"{pprint.pformat(schema['localLifecycle'], sort_dicts=True, width=100)}",
            "",
            "def command_timeout_seconds(",
            "    command: CommandName, parameters: dict[str, JsonValue]",
            ") -> float:",
            '    policy = COMMAND_METADATA[command]["timeout"]',
            '    for parameter, milliseconds in policy["parameterPresentOverrides"].items():',
            "        if parameter in parameters:",
            "            return cast(float, milliseconds / 1000)",
            '    if "parameterName" in policy:',
            '        value = parameters.get(policy["parameterName"])',
            "        if isinstance(value, (int, float)) and not isinstance(value, bool):",
            "            milliseconds = max(",
            '                policy["minimumMilliseconds"],',
            '                min(policy["maximumMilliseconds"],',
            '                    value + policy["parameterGraceMilliseconds"]),',
            "            )",
            "            return cast(float, milliseconds / 1000)",
            '    return cast(float, policy["defaultMilliseconds"] / 1000)',
            "",
        ]
    )
    host_commands = [command for command in commands if command["scope"] == "host"]
    session_commands = [command for command in commands if command["scope"] == "session"]
    emit_mixin(lines, "SyncHostCommands", host_commands, False)
    emit_mixin(lines, "SyncSessionCommands", session_commands, False)
    emit_mixin(lines, "AsyncHostCommands", host_commands, True)
    emit_mixin(lines, "AsyncSessionCommands", session_commands, True)
    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    output = generate()
    if arguments.check:
        if not OUTPUT_PATH.exists() or OUTPUT_PATH.read_text(encoding="utf-8") != output:
            raise SystemExit("generated Python SDK is stale; run python scripts/generate.py")
    else:
        OUTPUT_PATH.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
