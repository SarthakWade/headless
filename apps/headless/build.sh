#!/bin/zsh
# Builds Headless.app and its agent CLI. No Xcode project or third-party packages.
set -euo pipefail
cd "${0:a:h}"

for tool in swift swiftc iconutil codesign lipo security; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "headless build: missing $tool. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 69
  fi
done

APP="Headless.app"
NATIVE_ARCH="$(uname -m)"
ARCH_LIST="${HEADLESS_ARCHS:-$NATIVE_ARCH}"
ARCHS=(${=ARCH_LIST})
ICON="build/Headless.icns"
VERSION="${HEADLESS_VERSION:-$(tr -d '[:space:]' < VERSION)}"
RELEASE_BUILD="${HEADLESS_RELEASE_BUILD:-0}"
mkdir -p build/module-cache build/swiftpm-module-cache build/bin

if [[ "$RELEASE_BUILD" != "0" && "$RELEASE_BUILD" != "1" ]]; then
  echo "headless build: HEADLESS_RELEASE_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$RELEASE_BUILD" == "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "headless build: release builds require CODESIGN_IDENTITY" >&2
    exit 64
  fi
  if [[ "$CODESIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "headless build: release builds require a Developer ID Application identity" >&2
    exit 64
  fi
fi

if (( ${#ARCHS[@]} == 0 )); then
  echo "headless build: HEADLESS_ARCHS must include arm64, x86_64, or both" >&2
  exit 64
fi
typeset -A SEEN_ARCHS
for arch in "${ARCHS[@]}"; do
  if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    echo "headless build: unsupported architecture: $arch" >&2
    exit 64
  fi
  if [[ -n "${SEEN_ARCHS[$arch]:-}" ]]; then
    echo "headless build: duplicate architecture: $arch" >&2
    exit 64
  fi
  SEEN_ARCHS[$arch]=1
done

# Select an SDK the installed Swift compiler can read. Apple occasionally ships
# a Command Line Tools compiler update before changing the default SDK symlink.
SDK_ARGS=()
if [[ -z "${SDKROOT:-}" ]]; then
  COMPATIBLE_SDK=""
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(NOn); do
    if swiftc -module-cache-path build/module-cache -sdk "$sdk" \
        -target "$NATIVE_ARCH-apple-macos13.0" -typecheck \
      Sources/HeadlessProtocol/Protocol.swift \
      Sources/HeadlessProtocol/ProtocolSchema.swift \
      Sources/HeadlessProtocol/SupervisedHost.swift \
      Sources/HeadlessProtocol/CredentialCommands.swift \
        Sources/HeadlessProtocol/HostError.swift \
        Sources/HeadlessProtocol/CaptureFormats.swift \
        Sources/HeadlessProtocol/NavigationAllowlist.swift >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      SDK_ARGS=(--sdk "$sdk")
      COMPATIBLE_SDK="$sdk"
      break
    fi
  done
  if [[ -z "$COMPATIBLE_SDK" ]]; then
    echo "headless build: no macOS SDK compatible with the installed Swift compiler was found." >&2
    echo "Update Xcode Command Line Tools, then retry." >&2
    exit 69
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swiftpm-module-cache"

if [[ ! -f "$ICON" ]]; then
  echo "▸ rendering icon"
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$ICON"
fi

echo "▸ compiling (${(j:,:)ARCHS})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SWIFT_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/headless-build.XXXXXX")"
trap 'rm -rf "$SWIFT_SCRATCH"' EXIT
HOST_BINARIES=()
CLI_BINARIES=()
MCP_BINARIES=()
BROKER_BINARIES=()
RESOURCE_BUNDLE=""
for arch in "${ARCHS[@]}"; do
  ARCH_SCRATCH="$SWIFT_SCRATCH/$arch"
  TARGET_ARGS=(--triple "$arch-apple-macos13.0")
  BIN_PATH="$(swift build "${SDK_ARGS[@]}" "${TARGET_ARGS[@]}" -c release --scratch-path "$ARCH_SCRATCH" --show-bin-path)"
  swift build "${SDK_ARGS[@]}" "${TARGET_ARGS[@]}" -c release --product headless-host --scratch-path "$ARCH_SCRATCH"
  swift build "${SDK_ARGS[@]}" "${TARGET_ARGS[@]}" -c release --product headless --scratch-path "$ARCH_SCRATCH"
  swift build "${SDK_ARGS[@]}" "${TARGET_ARGS[@]}" -c release --product headless-mcp --scratch-path "$ARCH_SCRATCH"
  swift build "${SDK_ARGS[@]}" "${TARGET_ARGS[@]}" -c release --product headless-credential-broker --scratch-path "$ARCH_SCRATCH"
  HOST_BINARIES+=("$BIN_PATH/headless-host")
  CLI_BINARIES+=("$BIN_PATH/headless")
  MCP_BINARIES+=("$BIN_PATH/headless-mcp")
  BROKER_BINARIES+=("$BIN_PATH/headless-credential-broker")
  if [[ -z "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$BIN_PATH/Headless_HeadlessProtocol.bundle"
  fi
done
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "headless build: compiled HeadlessProtocol resource bundle was not found" >&2
  exit 70
fi

copy_or_merge() {
  local destination="$1"
  shift
  if (( $# == 1 )); then
    cp "$1" "$destination"
  else
    lipo -create "$@" -output "$destination"
  fi
}

copy_or_merge "$APP/Contents/MacOS/Headless" "${HOST_BINARIES[@]}"
mkdir -p "$APP/Contents/Resources/bin"
copy_or_merge "$APP/Contents/Resources/bin/headless" "${CLI_BINARIES[@]}"
copy_or_merge "$APP/Contents/Resources/bin/headless-mcp" "${MCP_BINARIES[@]}"
copy_or_merge "$APP/Contents/Resources/bin/headless-credential-broker" "${BROKER_BINARIES[@]}"
cp "$APP/Contents/Resources/bin/headless" build/bin/headless
cp "$APP/Contents/Resources/bin/headless-mcp" build/bin/headless-mcp
cp "$APP/Contents/Resources/bin/headless-credential-broker" build/bin/headless-credential-broker
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/Headless_HeadlessProtocol.bundle"

cp "$ICON" "$APP/Contents/Resources/Headless.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headless</string>
  <key>CFBundleDisplayName</key><string>Headless</string>
  <key>CFBundleExecutable</key><string>Headless</string>
  <key>CFBundleIdentifier</key><string>com.headless.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>Headless</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  </dict>
  <key>NSHumanReadableCopyright</key><string>headless — the browser that isn’t there</string>
</dict>
</plist>
PLIST
Tests/macos-bundle-security.sh "$APP/Contents/Info.plist"

# Passkeys require Apple's restricted web-browser.public-key-credential
# entitlement backed by an Apple-approved provisioning profile. Direct
# Developer ID distribution does not receive that capability by default, so
# release builds omit it and the app exposes its existing fallback sign-in
# behavior. If Apple approves com.headless.app, provide both files explicitly.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
  if [[ "$RELEASE_BUILD" == "1" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
  fi
  APP_ENTITLEMENT_ARGS=()
  if [[ -n "${PROVISIONING_PROFILE:-}" || -n "${PASSKEY_ENTITLEMENTS:-}" ]]; then
    if [[ -z "${PROVISIONING_PROFILE:-}" || -z "${PASSKEY_ENTITLEMENTS:-}" ]]; then
      echo "headless build: passkeys require both PROVISIONING_PROFILE and PASSKEY_ENTITLEMENTS" >&2
      exit 64
    fi
    if [[ ! -f "$PROVISIONING_PROFILE" || ! -f "$PASSKEY_ENTITLEMENTS" ]]; then
      echo "headless build: passkey provisioning inputs must be regular files" >&2
      exit 66
    fi
    PROFILE_PLIST="$SWIFT_SCRATCH/provisioning-profile.plist"
    security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" || {
      echo "headless build: provisioning profile could not be decoded" >&2
      exit 65
    }
    PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    case "$PROFILE_APP_ID" in
      *.com.headless.app) ;;
      *)
        echo "headless build: provisioning profile is not approved for com.headless.app" >&2
        exit 64
        ;;
    esac
    PROFILE_PASSKEY="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.web-browser.public-key-credential' "$PROFILE_PLIST" 2>/dev/null || true)"
    REQUESTED_PASSKEY="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.web-browser.public-key-credential' "$PASSKEY_ENTITLEMENTS" 2>/dev/null || true)"
    if [[ "$PROFILE_PASSKEY" != true || "$REQUESTED_PASSKEY" != true ]]; then
      echo "headless build: Apple-approved passkey entitlement is missing from the provisioning inputs" >&2
      exit 64
    fi
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    APP_ENTITLEMENT_ARGS=(--entitlements "$PASSKEY_ENTITLEMENTS")
  fi
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/bin/headless"
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/bin/headless-mcp"
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/bin/headless-credential-broker"
  codesign "${SIGN_ARGS[@]}" "${APP_ENTITLEMENT_ARGS[@]}" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "▸ signed as $CODESIGN_IDENTITY"
else
  if [[ -n "${PROVISIONING_PROFILE:-}" || -n "${PASSKEY_ENTITLEMENTS:-}" ]]; then
    echo "headless build: passkey provisioning requires CODESIGN_IDENTITY" >&2
    exit 64
  fi
  codesign --force --sign - "$APP/Contents/Resources/bin/headless" 2>/dev/null
  codesign --force --sign - "$APP/Contents/Resources/bin/headless-mcp" 2>/dev/null
  codesign --force --sign - "$APP/Contents/Resources/bin/headless-credential-broker" 2>/dev/null
  codesign --force --sign - "$APP" 2>/dev/null
fi
SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ built $APP ($SIZE)"
echo "  try:  open $APP"
echo "  agent CLI:  ./$APP/Contents/Resources/bin/headless help"
