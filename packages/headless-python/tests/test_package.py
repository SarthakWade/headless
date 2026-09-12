from __future__ import annotations

import inspect
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

from headless_sdk import AsyncSession, Session
from scripts import generate as generator

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]


def test_metadata_support_provenance_and_zero_runtime_dependencies() -> None:
    metadata = tomllib.loads((PACKAGE_ROOT / "pyproject.toml").read_text())
    project = metadata["project"]
    assert project["requires-python"] == ">=3.11,<3.15"
    assert project["license"] == "MIT"
    assert project["dependencies"] == []
    assert project["urls"]["Repository"] == "https://github.com/LockInTime/headless.git"
    assert "Programming Language :: Python :: 3.14" in project["classifiers"]
    assert metadata["build-system"]["build-backend"] == "hatchling.build"


def test_generated_file_has_a_clean_diff() -> None:
    result = subprocess.run(
        [sys.executable, "scripts/generate.py", "--check"],
        cwd=PACKAGE_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_authentication_surface_cannot_accept_a_password() -> None:
    for method in (Session.auth_login, AsyncSession.auth_login):
        parameters = inspect.signature(method).parameters
        assert set(parameters) == {
            "self",
            "challenge",
            "account",
            "interactive",
            "timeout",
            "cancel",
        }
        assert "password" not in parameters


def test_source_checkout_import_does_not_require_distribution_metadata() -> None:
    environment = dict(os.environ)
    environment["PYTHONPATH"] = str(PACKAGE_ROOT / "src")
    result = subprocess.run(
        [sys.executable, "-S", "-c", "import headless_sdk; print(headless_sdk.__version__)"],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "0+source"


def test_python_release_actions_are_immutable() -> None:
    workflow = (REPOSITORY_ROOT / ".github/workflows/python-release.yml").read_text()
    references = re.findall(r"^\s*- uses: [^@\s]+@([^\s]+)$", workflow, re.MULTILINE)
    assert references
    assert all(re.fullmatch(r"[0-9a-f]{40}", reference) for reference in references)


def test_published_license_matches_repository() -> None:
    assert (PACKAGE_ROOT / "LICENSE").read_bytes() == (REPOSITORY_ROOT / "LICENSE").read_bytes()


def test_generator_rejects_conflicting_error_detail_types(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    schema = json.loads((REPOSITORY_ROOT / "sdk/protocol-schema.json").read_text())
    schema["errorDetails"]["FUTURE_ERROR"] = {
        "mayContainUntrustedContent": False,
        "schema": {
            "additionalProperties": True,
            "fields": [{"name": "different", "required": True, "type": "string"}],
            "name": "Shutdown",
            "type": "object",
        },
    }
    schema_path = tmp_path / "schema.json"
    schema_path.write_text(json.dumps(schema))
    monkeypatch.setattr(generator, "SCHEMA_PATH", schema_path)
    with pytest.raises(ValueError, match="conflicting result schema: Shutdown"):
        generator.generate()
