#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

./Tests/release-checksums.sh
./Tests/linux-installer.sh

for tool in swift swiftc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "headless tests: missing $tool. Install Xcode Command Line Tools with: xcode-select --install" >&2
    else
      echo "headless tests: missing $tool. Install the Swift toolchain or run Tests/linux-docker.sh." >&2
    fi
    exit 69
  fi
done

SDK_ARGS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Some Command Line Tools releases briefly ship a compiler newer than the
  # default SDK symlink. Choose the newest SDK the compiler can actually read.
  while IFS= read -r sdk; do
    [[ -d "$sdk" ]] || continue
    if swiftc -module-cache-path build/module-cache -sdk "$sdk" \
        -target "$(uname -m)-apple-macos13.0" -typecheck \
        Sources/HeadlessProtocol/Protocol.swift \
        Sources/HeadlessProtocol/ProtocolSchema.swift \
        Sources/HeadlessProtocol/SupervisedHost.swift \
        Sources/HeadlessProtocol/CredentialCommands.swift \
        Sources/HeadlessProtocol/HostError.swift \
        Sources/HeadlessProtocol/CaptureFormats.swift \
        Sources/HeadlessProtocol/NavigationAllowlist.swift >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      SDK_ARGS=(--sdk "$sdk")
      break
    fi
  done < <(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name 'MacOSX*.sdk' -print 2>/dev/null | sort -r)
  if [[ -z "${SDKROOT:-}" ]]; then
    echo "headless tests: no compatible macOS SDK was found. Update Xcode Command Line Tools." >&2
    exit 69
  fi
  export CLANG_MODULE_CACHE_PATH="${PWD}/build/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/build/swiftpm-module-cache"
fi

TEST_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/headless-tests.XXXXXX")"
trap 'rm -rf "$TEST_SCRATCH"' EXIT
EXPECTED_VERSION="${HEADLESS_VERSION:-$(tr -d '[:space:]' < VERSION)}"
for INVALID_VERSION in 01.2.3 1.02.3 1.2.03 1.2.3-01 1.2.3-.beta 1.2.3-beta. 1.2.3+build..1; do
  if HEADLESS_VERSION="$INVALID_VERSION" swift package dump-package >/dev/null 2>&1; then
    echo "headless tests: invalid product version was accepted: $INVALID_VERSION" >&2
    exit 1
  fi
done
for manifest in package.json ../web/package.json ../../package.json; do
  MANIFEST_VERSION="$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)",*$/\1/p' "$manifest")"
  [[ "$MANIFEST_VERSION" == "$(tr -d '[:space:]' < VERSION)" ]] || {
    echo "headless tests: $manifest version does not match VERSION" >&2
    exit 1
  }
done
BIN_PATH="$(swift build "${SDK_ARGS[@]}" --scratch-path "$TEST_SCRATCH" --show-bin-path)"
swift build "${SDK_ARGS[@]}" --product headless-protocol-tests --scratch-path "$TEST_SCRATCH"
swift build "${SDK_ARGS[@]}" --product headless --scratch-path "$TEST_SCRATCH"
swift build "${SDK_ARGS[@]}" --product headless-credential-broker --scratch-path "$TEST_SCRATCH"
swift build "${SDK_ARGS[@]}" --product headless-mcp --scratch-path "$TEST_SCRATCH"
swift build "${SDK_ARGS[@]}" --product headless-mcp-tests --scratch-path "$TEST_SCRATCH"
HEADLESS_REQUIRE_SDK_CONTRACT=1 "$BIN_PATH/headless-protocol-tests"
if [[ "$(uname -s)" == "Darwin" ]]; then
  cc -D_GNU_SOURCE -std=c11 -Wall -Wextra -Werror \
    -I SecurePrompt/include SecurePrompt/SecurePrompt.c Tests/secure-prompt.c \
    -o "$TEST_SCRATCH/secure-prompt-tests"
else
  cc -D_GNU_SOURCE -std=c11 -Wall -Wextra -Werror \
    -I SecurePrompt/include SecurePrompt/SecurePrompt.c Tests/secure-prompt.c \
    -lutil -o "$TEST_SCRATCH/secure-prompt-tests"
fi
"$TEST_SCRATCH/secure-prompt-tests"
[[ "$("$BIN_PATH/headless" --version)" == "headless $EXPECTED_VERSION" ]] || {
  echo "headless tests: CLI product version does not match $EXPECTED_VERSION" >&2
  exit 1
}
"$BIN_PATH/headless" schema > "$TEST_SCRATCH/protocol-schema.json"
cmp "$TEST_SCRATCH/protocol-schema.json" ../../sdk/protocol-schema.json || {
  echo "headless tests: sdk/protocol-schema.json is stale; regenerate it with headless schema" >&2
  exit 1
}
PATH_INVOCATION_ROOT="$TEST_SCRATCH/path-invocation"
mkdir -p "$PATH_INVOCATION_ROOT"
ln -s "$BIN_PATH/headless" "$PATH_INVOCATION_ROOT/headless"
for invocation in path symlink; do
  set +e
  if [[ "$invocation" == "path" ]]; then
    BROKER_OUTPUT="$(PATH="$PATH_INVOCATION_ROOT:/usr/bin:/bin" headless credentials list 2>&1)"
  else
    BROKER_OUTPUT="$("$PATH_INVOCATION_ROOT/headless" credentials list 2>&1)"
  fi
  set -e
  if [[ "$BROKER_OUTPUT" == *"trusted headless-credential-broker executable is missing"* ]]; then
    echo "headless tests: broker discovery failed for $invocation invocation" >&2
    exit 1
  fi
done
"$BIN_PATH/headless-mcp-tests" "$BIN_PATH/headless-mcp" "$EXPECTED_VERSION" \
  "../../sdk/protocol-fixtures.json"
