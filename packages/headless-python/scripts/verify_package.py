from __future__ import annotations

import email
import sys
import tarfile
import tomllib
import zipfile
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
VERSION = tomllib.loads((PACKAGE_ROOT / "pyproject.toml").read_text())["project"]["version"]
DIST_INFO = f"lockintime_headless-{VERSION}.dist-info"
PACKAGE_FILES = {
    "headless_sdk/__init__.py",
    "headless_sdk/_protocol.py",
    "headless_sdk/_transport.py",
    "headless_sdk/_types.py",
    "headless_sdk/client.py",
    "headless_sdk/errors.py",
    "headless_sdk/generated.py",
    "headless_sdk/lifecycle.py",
    "headless_sdk/py.typed",
}
WHEEL_FILES = PACKAGE_FILES | {
    f"{DIST_INFO}/METADATA",
    f"{DIST_INFO}/RECORD",
    f"{DIST_INFO}/WHEEL",
    f"{DIST_INFO}/licenses/LICENSE",
}
SDIST_ROOT = f"lockintime_headless-{VERSION}"
SDIST_FILES = {
    f"{SDIST_ROOT}/.gitignore",
    f"{SDIST_ROOT}/LICENSE",
    f"{SDIST_ROOT}/PKG-INFO",
    f"{SDIST_ROOT}/README.md",
    f"{SDIST_ROOT}/pyproject.toml",
    *(f"{SDIST_ROOT}/src/{name}" for name in PACKAGE_FILES),
}


def require_single(pattern: str) -> Path:
    matches = list((PACKAGE_ROOT / "dist").glob(pattern))
    if len(matches) != 1:
        raise SystemExit(f"expected one {pattern} artifact, found {len(matches)}")
    return matches[0]


def assert_exact(label: str, actual: set[str], expected: set[str]) -> None:
    if actual == expected:
        return
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    raise SystemExit(f"{label} contents differ; missing={missing}, unexpected={unexpected}")


def verify_metadata(raw: bytes) -> None:
    metadata = email.message_from_bytes(raw)
    if metadata["Name"] != "lockintime-headless" or metadata["Version"] != VERSION:
        raise SystemExit("built package name or version does not match release metadata")
    if metadata["Requires-Python"] != "<3.15,>=3.11":
        raise SystemExit("built package lost its Python compatibility declaration")
    requirements = metadata.get_all("Requires-Dist", [])
    runtime = [requirement for requirement in requirements if "extra ==" not in requirement]
    if runtime:
        raise SystemExit(f"runtime dependencies are forbidden: {runtime}")
    classifiers = set(metadata.get_all("Classifier", []))
    for version in ("3.11", "3.12", "3.13", "3.14"):
        if f"Programming Language :: Python :: {version}" not in classifiers:
            raise SystemExit(f"missing CPython {version} compatibility classifier")


def main() -> None:
    wheel = require_single("*.whl")
    sdist = require_single("*.tar.gz")
    expected_wheel_name = f"lockintime_headless-{VERSION}-py3-none-any.whl"
    if wheel.name != expected_wheel_name:
        raise SystemExit(f"unexpected wheel filename: {wheel.name}")
    with zipfile.ZipFile(wheel) as archive:
        names = {name.rstrip("/") for name in archive.namelist() if not name.endswith("/")}
        assert_exact("wheel", names, WHEEL_FILES)
        verify_metadata(archive.read(f"{DIST_INFO}/METADATA"))
    with tarfile.open(sdist, "r:gz") as archive:
        names = {member.name for member in archive.getmembers() if member.isfile()}
        assert_exact("sdist", names, SDIST_FILES)
        verify_metadata(archive.extractfile(f"{SDIST_ROOT}/PKG-INFO").read())  # type: ignore[union-attr]
    print(f"verified exact wheel ({len(WHEEL_FILES)} files) and sdist ({len(SDIST_FILES)} files)")


if __name__ == "__main__":
    sys.exit(main())
