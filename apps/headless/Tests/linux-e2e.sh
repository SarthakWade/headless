#!/bin/sh
set -eu

export HEADLESS_ARTIFACT_DIR="/tmp/headless-artifacts-e2e-$$"
export XDG_DATA_HOME="/tmp/headless-data-e2e-$$"
export XDG_CONFIG_HOME="/tmp/headless-config-e2e-$$"
export HEADLESS_HOST_LOG="/tmp/headless-host-e2e-$$.log"
STEP="setup"
SUPERVISED_FIFO=""
SUPERVISED_OUTPUT=""
SUPERVISED_LAUNCHER_PID=""

FIXTURE_ROOT="$(mktemp -d /tmp/headless-fixture.XXXXXX)"
INSTALL_ROOT="$(mktemp -d /tmp/headless-install.XXXXXX)"
mkdir -p "$FIXTURE_ROOT/designers/dashboard" "$FIXTURE_ROOT/next" "$FIXTURE_ROOT/hostile" "$FIXTURE_ROOT/large-document" "$FIXTURE_ROOT/trusted-input" "$FIXTURE_ROOT/auth-state" "$FIXTURE_ROOT/auth-login" "$FIXTURE_ROOT/file-upload" "$FIXTURE_ROOT/api" "$FIXTURE_ROOT/allowlist-exits" "$FIXTURE_ROOT/allowlist-redirect"
cp /opt/headless/fixtures/dashboard.html "$FIXTURE_ROOT/designers/dashboard/index.html"
cp /opt/headless/fixtures/next.html "$FIXTURE_ROOT/next/index.html"
cp /opt/headless/fixtures/hostile.html "$FIXTURE_ROOT/hostile/index.html"
cp /opt/headless/fixtures/large-document.html "$FIXTURE_ROOT/large-document/index.html"
cp /opt/headless/fixtures/trusted-input.html "$FIXTURE_ROOT/trusted-input/index.html"
cp /opt/headless/fixtures/auth-state.html "$FIXTURE_ROOT/auth-state/index.html"
cp /opt/headless/fixtures/auth-login.html "$FIXTURE_ROOT/auth-login/index.html"
cp /opt/headless/fixtures/file-upload.html "$FIXTURE_ROOT/file-upload/index.html"
cp /opt/headless/fixtures/allowlist-exits.html "$FIXTURE_ROOT/allowlist-exits/index.html"
cp /opt/headless/fixtures/allowlist-redirect.html "$FIXTURE_ROOT/allowlist-redirect/index.html"
cp /opt/headless/fixtures/api-diagnostic.json "$FIXTURE_ROOT/api/diagnostic"
busybox httpd -f -p 127.0.0.1:41739 -h "$FIXTURE_ROOT" &
FIXTURE_PID=$!

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ]; then
    echo "Linux E2E failed during: $STEP" >&2
    if [ -s "$HEADLESS_HOST_LOG" ]; then
      echo "--- host log ---" >&2
      cat "$HEADLESS_HOST_LOG" >&2
    fi
  fi
  headless stop >/dev/null 2>&1 || true
  if [ -n "$SUPERVISED_LAUNCHER_PID" ]; then
    kill "$SUPERVISED_LAUNCHER_PID" >/dev/null 2>&1 || true
  fi
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_ROOT"
  rm -rf "$INSTALL_ROOT"
  rm -rf "$HEADLESS_ARTIFACT_DIR"
  rm -rf "$XDG_DATA_HOME"
  rm -rf "$XDG_CONFIG_HOME"
  rm -f "$HEADLESS_HOST_LOG"
  [ -z "$SUPERVISED_FIFO" ] || rm -f "$SUPERVISED_FIFO"
  [ -z "$SUPERVISED_OUTPUT" ] || rm -f "$SUPERVISED_OUTPUT"
  exit "$status"
}
trap cleanup EXIT INT TERM

/opt/headless/package/install-linux.sh --prefix "$INSTALL_ROOT" | grep -q 'Headless installed'
test -x "$INSTALL_ROOT/bin/headless"
test -x "$INSTALL_ROOT/bin/headless-host"
test -x "$INSTALL_ROOT/bin/headless-credential-broker"
test -r "$INSTALL_ROOT/bin/Headless_HeadlessProtocol.resources/AgentRuntime.js"
if /opt/headless/package/install-linux.sh --prefix relative/path >/dev/null 2>&1; then
  echo "relative install prefix was not rejected" >&2
  exit 1
fi
if SNAP_INSTALL="$(HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium \
    /opt/headless/package/install-linux.sh --prefix "$INSTALL_ROOT/snap" 2>&1)"; then
  echo "Snap Chromium was accepted by the installer" >&2
  exit 1
fi
echo "$SNAP_INSTALL" | grep -q 'UNSUPPORTED_BROWSER_RUNTIME'
echo "$SNAP_INSTALL" | grep -q 'Snap Chromium is not reliable'

if CREDENTIAL_LIST="$(headless credentials list 2>&1)"; then
  echo "credential vault did not fail closed without a Secret Service session" >&2
  exit 1
fi
echo "$CREDENTIAL_LIST" | grep -q 'VAULT_UNAVAILABLE'
test ! -e "$HOME/.local/share/headless/credential-vault/credentials-index.json"
/opt/headless/linux-credential-vault.sh

STEP="runtime-discovery"
headless runtime | grep -q '"executable":"/usr/lib/chromium/chromium"'
headless runtime | grep -q '"transport":"inherited-devtools-pipe"'
if SNAP_RUNTIME="$(HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium headless runtime 2>&1)"; then
  echo "Snap Chromium was accepted by runtime selection" >&2
  exit 1
fi
echo "$SNAP_RUNTIME" | grep -q 'UNSUPPORTED_BROWSER_RUNTIME'
echo "$SNAP_RUNTIME" | grep -q 'Snap Chromium is not reliable'
if RELATIVE_RUNTIME="$(HEADLESS_CHROMIUM_EXECUTABLE=relative/chromium headless runtime 2>&1)"; then
  echo "a relative Chromium override was accepted" >&2
  exit 1
fi
echo "$RELATIVE_RUNTIME" | grep -q 'must be absolute'

STEP="settings"
SETTINGS_LIST="$(headless config list)"
echo "$SETTINGS_LIST" | grep -q '"key":"startup-presentation"'
echo "$SETTINGS_LIST" | grep -q '"access":"agent-writable"'
echo "$SETTINGS_LIST" | grep -q '"supportedOnCurrentPlatform":false'
SETTINGS_DESCRIPTION="$(headless config describe startup-presentation)"
echo "$SETTINGS_DESCRIPTION" | grep -q '"allowedValues":\["background","foreground"\]'
echo "$SETTINGS_DESCRIPTION" | grep -q '"supportedOnCurrentPlatform":false'
test "$(stat -c %a "$XDG_CONFIG_HOME/headless")" = "700"
test "$(stat -c %a "$XDG_CONFIG_HOME/headless/settings.lock")" = "600"
for PRESENTATION_COMMAND in \
  "get startup-presentation" \
  "set startup-presentation foreground" \
  "reset startup-presentation"; do
  if PRESENTATION_CONFIG="$(headless config $PRESENTATION_COMMAND 2>&1)"; then
    echo "macOS startup presentation configuration was accepted on Linux: $PRESENTATION_COMMAND" >&2
    exit 1
  fi
  echo "$PRESENTATION_CONFIG" | grep -q 'UNSUPPORTED_CAPABILITY'
done
if PRESENTATION_START="$(headless start --foreground 2>&1)"; then
  echo "macOS startup presentation override was accepted on Linux" >&2
  exit 1
fi
echo "$PRESENTATION_START" | grep -q 'UNSUPPORTED_CAPABILITY'

STEP="supervised-host-owner-exit"
SUPERVISED_FIFO="$(mktemp /tmp/headless-supervised-fifo.XXXXXX)"
SUPERVISED_OUTPUT="$(mktemp /tmp/headless-supervised-output.XXXXXX)"
rm -f "$SUPERVISED_FIFO"
mkfifo "$SUPERVISED_FIFO"
headless start --supervised <"$SUPERVISED_FIFO" >"$SUPERVISED_OUTPUT" &
SUPERVISED_LAUNCHER_PID=$!
exec 9>"$SUPERVISED_FIFO"
for _ in $(seq 1 160); do
  [ -s "$SUPERVISED_OUTPUT" ] && headless status >/dev/null 2>&1 && break
  sleep 0.05
done
SUPERVISED_RESULT="$(cat "$SUPERVISED_OUTPUT")"
echo "$SUPERVISED_RESULT" | grep -q '"ready":true'
SUPERVISED_HOST_PID="$(echo "$SUPERVISED_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$SUPERVISED_HOST_PID"
test "$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')" = "$SUPERVISED_HOST_PID"
kill -9 "$SUPERVISED_LAUNCHER_PID"
wait "$SUPERVISED_LAUNCHER_PID" >/dev/null 2>&1 || true
SUPERVISED_LAUNCHER_PID=""
for _ in $(seq 1 100); do
  ! kill -0 "$SUPERVISED_HOST_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$SUPERVISED_HOST_PID" >/dev/null 2>&1; then
  echo "supervised host survived launcher termination" >&2
  exit 1
fi
exec 9>&-
rm -f "$SUPERVISED_FIFO" "$SUPERVISED_OUTPUT"
SUPERVISED_FIFO=""
SUPERVISED_OUTPUT=""

STEP="host-start"
headless start | grep -q '"ready":true'
test "$(stat -c %a "$XDG_DATA_HOME/headless")" = "700"
test "$(stat -c %a "$XDG_DATA_HOME/headless/chromium-profile")" = "700"
if RUNNING_PRESENTATION_START="$(headless start --foreground 2>&1)"; then
  echo "macOS startup presentation override was accepted by a running Linux host" >&2
  exit 1
fi
echo "$RUNNING_PRESENTATION_START" | grep -q 'UNSUPPORTED_CAPABILITY'

STEP="authentication-state-setup"
headless visit 'http://127.0.0.1:41739/auth-state/?action=login' | grep -q 'Authentication State'

STEP="authentication-challenge"
if AUTH_REQUIRED="$(headless visit 'http://127.0.0.1:41739/auth-login/' 2>&1)"; then
  echo "confirmed login form did not require authentication" >&2
  exit 1
fi
STEP="authentication-challenge-code"
echo "$AUTH_REQUIRED" | grep -q '"code":"AUTH_REQUIRED"'
STEP="authentication-challenge-origin"
echo "$AUTH_REQUIRED" | grep -q '"origin":"http://127.0.0.1:41739"'
STEP="authentication-challenge-accounts"
echo "$AUTH_REQUIRED" | grep -q '"accounts":\[\]'
STEP="authentication-challenge-presence"
echo "$AUTH_REQUIRED" | grep -q '"userPresenceRequired":true'
STEP="authentication-challenge-availability"
echo "$AUTH_REQUIRED" | grep -q '"credentialUseAvailable":false'
STEP="authentication-direct-account"
headless fill @e1 -- 'fixture@example.test' | grep -q '"valueLength":20'
STEP="authentication-direct-password"
headless fill @e2 -- 'synthetic-direct-password' | grep -q '"valueLength":25'
STEP="authentication-direct-submit"
headless click @e3 | grep -q '"clicked"'
STEP="authentication-direct-continuation"
headless wait --text 'Signed in' | grep -q 'Signed in'
STEP="authentication-no-implicit-save"
test ! -e "$HOME/.local/share/headless/credential-vault/credentials-index.json"
STEP="authentication-cookie-state"
headless cookies list | grep -q '"name":"headless_auth_state"'
STEP="authentication-storage-state"
headless storage list --scope local | grep -q 'headless_auth_state'
PROFILE_RESTART_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$PROFILE_RESTART_PID"
headless stop | grep -q '"stopping":true'
for _ in $(seq 1 100); do
  ! kill -0 "$PROFILE_RESTART_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$PROFILE_RESTART_PID" >/dev/null 2>&1; then
  echo "host did not release the durable profile during restart" >&2
  exit 1
fi
headless start | grep -q '"ready":true'
headless visit 'http://127.0.0.1:41739/auth-state/?action=check' | grep -q 'Authentication State'
headless inspect --text | grep -q 'Cookie state: signed-in'
headless inspect --text | grep -q 'Storage state: signed-in'
headless visit 'http://127.0.0.1:41739/auth-state/?action=logout' | grep -q 'Authentication State'
headless inspect --text | grep -q 'Cookie state: missing'
headless inspect --text | grep -q 'Storage state: missing'
LOGOUT_RESTART_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$LOGOUT_RESTART_PID"
headless stop >/dev/null
for _ in $(seq 1 100); do
  ! kill -0 "$LOGOUT_RESTART_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$LOGOUT_RESTART_PID" >/dev/null 2>&1; then
  echo "host did not exit while verifying durable logout" >&2
  exit 1
fi
headless start >/dev/null
headless visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless inspect --text | grep -q 'Cookie state: missing'
headless inspect --text | grep -q 'Storage state: missing'
headless visit 'http://127.0.0.1:41739/auth-state/?action=login' >/dev/null
headless profile clear | grep -q '"cleared":true'
headless visit 'http://127.0.0.1:41739/auth-state/?action=check' | grep -q 'Authentication State'
headless inspect --text | grep -q 'Cookie state: missing'
headless inspect --text | grep -q 'Storage state: missing'

# Isolated sessions neither inherit nor leak browser state, and closing the
# owning session destroys its context.
headless visit 'http://127.0.0.1:41739/auth-state/?action=login' >/dev/null
headless session create private-a --isolated | grep -q '"isolated":true'
headless --session private-a visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless --session private-a inspect --text | grep -q 'Cookie state: missing'
headless --session private-a inspect --text | grep -q 'Storage state: missing'
headless --session private-a visit 'http://127.0.0.1:41739/auth-state/?action=login' >/dev/null
headless session create private-b --isolated | grep -q '"isolated":true'
headless --session private-b visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless --session private-b inspect --text | grep -q 'Cookie state: missing'
headless --session private-b inspect --text | grep -q 'Storage state: missing'
headless session close private-a | grep -q '"closed":"private-a"'
headless session create private-a --isolated | grep -q '"isolated":true'
headless --session private-a visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless --session private-a inspect --text | grep -q 'Cookie state: missing'
headless --session private-a inspect --text | grep -q 'Storage state: missing'
headless visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless inspect --text | grep -q 'Cookie state: signed-in'
headless inspect --text | grep -q 'Storage state: signed-in'
headless session close private-a >/dev/null
headless session close private-b >/dev/null
headless visit 'http://127.0.0.1:41739/auth-state/?action=logout' >/dev/null
headless session create private-crash --isolated >/dev/null
headless --session private-crash visit 'http://127.0.0.1:41739/auth-state/?action=login' >/dev/null
CRASHED_HOST_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$CRASHED_HOST_PID"
kill -9 "$CRASHED_HOST_PID"
for _ in $(seq 1 100); do
  ! kill -0 "$CRASHED_HOST_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$CRASHED_HOST_PID" >/dev/null 2>&1; then
  echo "host did not terminate during isolated crash recovery" >&2
  exit 1
fi
headless start >/dev/null
headless session create private-crash --isolated >/dev/null
headless --session private-crash visit 'http://127.0.0.1:41739/auth-state/?action=check' >/dev/null
headless --session private-crash inspect --text | grep -q 'Cookie state: missing'
headless --session private-crash inspect --text | grep -q 'Storage state: missing'
headless session close private-crash >/dev/null

# The fixture server is the only TCP listener. Chromium control must stay on
# its inherited DevTools pipe rather than exposing a loopback debugging port.
UNEXPECTED_TCP="$(awk 'NR > 1 && $4 == "0A" && $2 !~ /:A30B$/ { print $2 }' /proc/net/tcp /proc/net/tcp6)"
test -z "$UNEXPECTED_TCP"

HEADLESS_CONFORMANCE_CLI="$(command -v headless)" \
HEADLESS_CONFORMANCE_ENGINE=chromium \
HEADLESS_CONFORMANCE_BASE_URL=http://127.0.0.1:41739 \
  /opt/headless/conformance.sh

headless session create qa | grep -q '"session":"qa"'
headless session list | grep -q '"qa"'
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
# Exercise the control-channel regression directly: the same session must
# survive a second document, reload that document, go back, and reload again.
headless --session qa visit http://127.0.0.1:41739/next/ | grep -q 'Designer Details'
headless --session qa reload | grep -q 'Designer Details'
headless --session qa back | grep -q 'Designers Dashboard'
headless --session qa reload | grep -q 'Designers Dashboard'
SNAPSHOT="$(headless --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
ACTION_SNAPSHOT="$(headless --session qa inspect --context actions --task 'click Continue')"
echo "$ACTION_SNAPSHOT" | grep -q '"contextMode":"actions"'
echo "$ACTION_SNAPSHOT" | grep -q '"task":"click Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"name":"Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"actions":\["click"\]'
echo "$ACTION_SNAPSHOT" | grep -q '"relevance"'
CONSOLE="$(headless --session qa console list --level error)"
echo "$CONSOLE" | grep -q 'Next.js runtime error'
NETWORK="$(headless --session qa network list)"
echo "$NETWORK" | grep -q '"requestId"'
NETWORK_ID="$(echo "$NETWORK" | sed -n 's/.*"requestId":"\([^"]*\)"[^}]*"url":"[^"]*\/api\/diagnostic".*/\1/p')"
test -n "$NETWORK_ID"
NETWORK_DETAIL="$(headless --session qa network get "$NETWORK_ID")"
echo "$NETWORK_DETAIL" | grep -q '"requestHeaders"'
echo "$NETWORK_DETAIL" | grep -q '\[redacted\]'
STYLES="$(headless --session qa styles get --role region --name 'Diagnostics probe' --property display)"
echo "$STYLES" | grep -q '"display":"flex"'
COOKIES="$(headless --session qa cookies list)"
echo "$COOKIES" | grep -q '"name":"qa_session"'
echo "$COOKIES" | grep -q '"valueBytes"'
STORAGE="$(headless --session qa storage list)"
echo "$STORAGE" | grep -q 'qa-diagnostic-key'
echo "$STORAGE" | grep -q 'qa-session-key'
if SENSITIVE_STORAGE="$(headless --session qa storage list --values)"; then
  echo "sensitive storage values were available without opt-in" >&2
  exit 1
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
QA_REPORT="$(headless --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
headless --session qa qa clear | grep -q '"cleared"'
headless --session qa qa report | grep -q '"events":0'
headless --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
headless --session qa press Escape | grep -q '"pressed":"Escape"'
headless --session qa visit http://127.0.0.1:41739/trusted-input/ | grep -q 'Trusted input fixture'
headless --session qa inspect --interactive | grep -q '"name":"Trusted input"'
headless --session qa fill @e1 'CDP value' | grep -q '"valueLength":9'
headless --session qa press Enter | grep -q '"pressed":"Enter"'
headless --session qa click --role button --name 'Trusted click' | grep -q '"clicked"'
TRUSTED_INPUT="$(headless --session qa inspect --text)"
echo "$TRUSTED_INPUT" | grep -q 'input:true'
echo "$TRUSTED_INPUT" | grep -q 'key:Enter:true'
echo "$TRUSTED_INPUT" | grep -q 'click:true'
STEP="file-upload"
printf 'resume-fixture\n' > "$HEADLESS_ARTIFACT_DIR/resume.txt"
chmod 600 "$HEADLESS_ARTIFACT_DIR/resume.txt"
test "$(cat "$HEADLESS_ARTIFACT_DIR/resume.txt")" = "resume-fixture"
test "$(stat -c %a "$HEADLESS_ARTIFACT_DIR/resume.txt")" = "600"
headless artifacts list | grep -q '"name":"resume.txt"'
if headless artifacts add /etc/passwd --name resume.txt >/dev/null 2>&1; then
  echo "agent-facing local-file ingest was not rejected" >&2
  exit 1
fi
headless --session qa visit http://127.0.0.1:41739/file-upload/ | grep -q 'File upload fixture'
UPLOAD_SNAPSHOT="$(headless --session qa inspect --interactive)"
echo "$UPLOAD_SNAPSHOT" | grep -q '"name":"Resume"'
echo "$UPLOAD_SNAPSHOT" | grep -q '"actions":\["upload"\]'
echo "$UPLOAD_SNAPSHOT" | grep -q '"inputType":"file"'
UPLOAD="$(headless --session qa upload --role textbox --name Resume --artifact resume.txt)"
echo "$UPLOAD" | grep -q '"artifact":"resume.txt"'
echo "$UPLOAD" | grep -q '"uploaded"'
! echo "$UPLOAD" | grep -q "$HEADLESS_ARTIFACT_DIR"
! echo "$UPLOAD" | grep -q "$FIXTURE_ROOT"
UPLOAD_PAGE="$(headless --session qa inspect --text)"
echo "$UPLOAD_PAGE" | grep -q 'resume.txt'
if MISSING_UPLOAD="$(headless --session qa upload --role textbox --name Resume --artifact missing.txt)"; then
  echo "missing artifact upload was not rejected" >&2
  exit 1
fi
echo "$MISSING_UPLOAD" | grep -q 'ARTIFACT_ERROR'
if BUTTON_UPLOAD="$(headless --session qa upload --role button --name 'Not a file' --artifact resume.txt)"; then
  echo "upload to a non-file control was not rejected" >&2
  exit 1
fi
echo "$BUTTON_UPLOAD" | grep -q 'ELEMENT_NOT_FOUND'
EPHEMERAL="$(headless --session qa upload --role textbox --name Ephemeral --artifact resume.txt)"
echo "$EPHEMERAL" | grep -q '"artifact":"resume.txt"'
echo "$EPHEMERAL" | grep -q '"uploaded"'
if DISABLED_UPLOAD="$(headless --session qa upload --role textbox --name 'Disabled resume' --artifact resume.txt)"; then
  echo "disabled file input upload was not rejected" >&2
  exit 1
fi
echo "$DISABLED_UPLOAD" | grep -E -q 'NOT_EDITABLE|ELEMENT_NOT_FOUND|OPERATION_FAILED'
if HIDDEN_NAME_UPLOAD="$(headless --session qa upload --role textbox --name 'Already hidden' --artifact resume.txt)"; then
  echo "hidden file input upload was not rejected" >&2
  exit 1
fi
echo "$HIDDEN_NAME_UPLOAD" | grep -E -q 'ELEMENT_NOT_FOUND|ELEMENT_NOT_VISIBLE|OPERATION_FAILED'
HIDE_SNAP="$(headless --session qa inspect --interactive --limit 50)"
HIDEABLE_REF="$(printf '%s' "$HIDE_SNAP" | grep -o '"name":"Hideable","ref":"@e[0-9]*"' | head -n1 | grep -o '@e[0-9]*')"
test -n "$HIDEABLE_REF"
headless --session qa click --role button --name 'Hide file input' | grep -q '"clicked"'
if HIDDEN_REF_UPLOAD="$(headless --session qa upload "$HIDEABLE_REF" --artifact resume.txt)"; then
  echo "previously issued ref to a hidden file input was accepted" >&2
  exit 1
fi
echo "$HIDDEN_REF_UPLOAD" | grep -E -q 'ELEMENT_NOT_VISIBLE|ELEMENT_NOT_FOUND|OPERATION_FAILED'
LEAVE="$(headless --session qa upload --role textbox --name Leave --artifact resume.txt)"
echo "$LEAVE" | grep -q '"artifact":"resume.txt"'
echo "$LEAVE" | grep -q '"uploaded"'
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
if EXTERNAL_RESULT="$(headless --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  exit 1
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if NON_WEB_RESULT="$(headless --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  exit 1
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if CREDENTIAL_RESULT="$(headless --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  exit 1
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
if SUSPICIOUS_RESULT="$(headless --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  exit 1
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
headless --session qa click --role button --name 'Scripted host-blocked navigation' | grep -q '"clicked"'
headless --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
BLOCKED_NAVIGATION_REPORT="$(headless --session qa qa report)"
echo "$BLOCKED_NAVIGATION_REPORT" | grep -q '"kind":"navigation-blocked"'
echo "$BLOCKED_NAVIGATION_REPORT" | grep -q 'about:blank'
headless --session qa qa clear | grep -q '"cleared"'
headless --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
headless --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
headless --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
headless --session qa screenshot --format jpeg --output viewport.jpeg | grep -q '"name":"viewport.jpeg"'
headless --session qa screenshot --format pdf --full-page --output full-page.pdf | grep -q '"name":"full-page.pdf"'
if headless --session qa screenshot --format pdf --role button --name Continue --output continue.pdf >/dev/null 2>&1; then
  echo "element PDF capture was not rejected" >&2
  exit 1
fi
VIEWPORT_SERIES="$(headless --session qa screenshot --every-viewport --format jpg --output scroll-capture)"
echo "$VIEWPORT_SERIES" | grep -q '"series":"viewport"'
echo "$VIEWPORT_SERIES" | grep -q '"name":"scroll-capture-001.jpg"'
test -s "$HEADLESS_ARTIFACT_DIR/scroll-capture-001.jpg"
SCROLL_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'scroll-capture-*.jpg' | wc -l | tr -d ' ')"
test "$SCROLL_CAPTURE_COUNT" -ge 2
SECTION_SERIES="$(headless --session qa screenshot --by-section --output section-capture)"
echo "$SECTION_SERIES" | grep -q '"series":"section"'
SECTION_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'section-capture-*.png' | wc -l | tr -d ' ')"
test "$SECTION_CAPTURE_COUNT" -ge 3
headless --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$HEADLESS_ARTIFACT_DIR/visual-diff.png"
headless --session qa performance get | grep -q '"webVitals"'
ANIMATIONS="$(headless --session qa animations list)"
echo "$ANIMATIONS" | grep -q '"animations"'
echo "$ANIMATIONS" | grep -q '"playState":"running"'
headless --session qa network emulate --latency 25 --download-kbps 1000 --upload-kbps 500 | grep -q '"latencyMs":25'
headless --session qa network emulate | grep -q '"offline":false'
headless --session qa network mock set http://127.0.0.1:41739/api/diagnostic --body '{"mocked":true}' --status 201 | grep -q '"activeMocks":1'
# An active mock must not pause unrelated document and asset requests. This
# reload exercises the mocked API while the dashboard itself remains live.
headless --session qa reload | grep -q 'Designers Dashboard'
headless --session qa network mock clear | grep -q '"cleared":1'
headless --session qa flow start | grep -q '"recording":true'
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
headless --session qa click --role button --name Continue | grep -q '"clicked"'
headless --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
if ! FLOW_RUN="$(headless --session qa flow run dashboard-flow.json)"; then
  echo "$FLOW_RUN" >&2
  exit 1
fi
echo "$FLOW_RUN" | grep -q '"completed":2'
if ! REPORT_CREATE="$(headless --session qa report create --output pr-report.json)"; then
  echo "$REPORT_CREATE" >&2
  exit 1
fi
echo "$REPORT_CREATE" | grep -q '"name":"pr-report.json"'
grep -q 'headless-qa-report-v1' "$HEADLESS_ARTIFACT_DIR/pr-report.json"
headless --session qa visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
test -s "$HEADLESS_ARTIFACT_DIR/viewport.png"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.png"
test -s "$HEADLESS_ARTIFACT_DIR/continue.png"
test -s "$HEADLESS_ARTIFACT_DIR/viewport.jpeg"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.pdf"
test "$(od -An -tx1 -N8 "$HEADLESS_ARTIFACT_DIR/viewport.png" | tr -d ' \n')" = "89504e470d0a1a0a"
test "$(od -An -tx1 -N8 "$HEADLESS_ARTIFACT_DIR/full-page.png" | tr -d ' \n')" = "89504e470d0a1a0a"
test "$(od -An -tx1 -N8 "$HEADLESS_ARTIFACT_DIR/continue.png" | tr -d ' \n')" = "89504e470d0a1a0a"
test "$(od -An -tx1 -N3 "$HEADLESS_ARTIFACT_DIR/viewport.jpeg" | tr -d ' \n')" = "ffd8ff"
head -c 5 "$HEADLESS_ARTIFACT_DIR/full-page.pdf" | grep -q '%PDF-'
set -- $(od -An -tu1 -j 20 -N 4 "$HEADLESS_ARTIFACT_DIR/viewport.png")
VIEWPORT_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
set -- $(od -An -tu1 -j 20 -N 4 "$HEADLESS_ARTIFACT_DIR/full-page.png")
FULL_HEIGHT=$(($1 * 16777216 + $2 * 65536 + $3 * 256 + $4))
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if headless --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  exit 1
fi
if headless screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  exit 1
fi
if ! RECORD_START="$(headless --session qa record start --fps 5)"; then
  echo "$RECORD_START" >&2
  exit 1
fi
echo "$RECORD_START"
echo "$RECORD_START" | grep -q '"active":true'
RECORDING_STATUS="$(headless --session qa record status)"
echo "$RECORDING_STATUS" | grep -q '"active":true'
echo "$RECORDING_STATUS" | grep -Eq '"frames":[1-9][0-9]*'
if headless --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  exit 1
fi
headless --session qa tour --full-page --pace 500 | grep -q '"durationMs"'
headless --session qa click --role button --name Continue | grep -q '"clicked"'
if ! NEXT_PAGE="$(headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000)"; then
  echo "$NEXT_PAGE" >&2
  exit 1
fi
echo "$NEXT_PAGE" | grep -q 'Designer Details'
headless --session qa tour --full-page --pace 500 | grep -q '"durationMs"'
headless --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
headless --session qa record status | grep -q '"active":false'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4"
head -c 64 "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -q 'ftyp'
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -Eq '^[^,]+,[1-9][0-9]*,[1-9][0-9]*$'
RECORDING_DURATION_MS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 \
  "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | awk '{printf "%d", $1 * 1000}')"
test "$RECORDING_DURATION_MS" -ge 2000
UNIQUE_RECORDING_FRAMES="$(ffmpeg -hide_banner -loglevel error \
  -i "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" -f framemd5 - \
  | awk -F ', ' '!/^#/ {print $6}' | sort -u | wc -l)"
test "$UNIQUE_RECORDING_FRAMES" -ge 8
test "$(stat -c %a "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
headless --session qa record start --fps 3 --format webm --quality fast | grep -q '"format":"webm"'
headless --session qa scroll top | grep -q '"direction":"top"'
headless --session qa tour --full-page --pace 500 | grep -q '"durationMs"'
headless --session qa record stop --output dashboard-flow.webm | grep -q '"name":"dashboard-flow.webm"'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.webm"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  "$HEADLESS_ARTIFACT_DIR/dashboard-flow.webm" | grep -Eq '^vp[89],[1-9][0-9]*,[1-9][0-9]*$'
headless --session qa record start --fps 2 --format gif --quality fast | grep -q '"format":"gif"'
headless --session qa scroll top | grep -q '"direction":"top"'
headless --session qa tour --full-page --pace 500 | grep -q '"durationMs"'
headless --session qa record stop --output dashboard-flow.gif | grep -q '"name":"dashboard-flow.gif"'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.gif"
head -c 6 "$HEADLESS_ARTIFACT_DIR/dashboard-flow.gif" | grep -Eq 'GIF8[79]a'
headless artifacts list | grep -q '"name":"dashboard-flow.mp4"'
headless artifacts list | grep -q '"name":"dashboard-flow.webm"'
headless artifacts list | grep -q '"name":"dashboard-flow.gif"'
headless --session qa back | grep -q 'Designers Dashboard'
headless --session qa reload | grep -q 'Designers Dashboard'
headless --session qa capture-info | grep -q '"engine":"chromium"'
headless --session qa capture-info | grep -q '"browserExecutable":"/usr/lib/chromium/chromium"'
headless --session qa visit http://127.0.0.1:41739/large-document/ | grep -q 'Large Operations Handbook'
SUMMARY="$(headless --session qa inspect --context summary --task 'Linux service-account authentication' --limit 8 --budget 700)"
echo "$SUMMARY" | grep -q '"contextMode":"summary"'
echo "$SUMMARY" | grep -q 'Linux service-account authentication'
echo "$SUMMARY" | grep -q '"budget":700'
test "$(printf %s "$SUMMARY" | wc -c)" -lt 3200
OUTLINE="$(headless --session qa inspect --context outline --task 'Linux service-account authentication' --limit 8 --budget 900)"
TARGET_REGION="$(printf %s "$OUTLINE" | sed -n 's/.*"name":"Linux service-account authentication"[^}]*"ref":"\(@r[0-9]*\)".*/\1/p')"
test -n "$TARGET_REGION"
SCOPED_TEXT="$(headless --session qa inspect --context text --within "$TARGET_REGION" --task 'Ubuntu service account' --limit 4 --budget 700)"
echo "$SCOPED_TEXT" | grep -q 'short-lived service account'
echo "$SCOPED_TEXT" | grep -q '"within":"'"$TARGET_REGION"'"'
SCOPED_ACTIONS="$(headless --session qa inspect --context actions --within "$TARGET_REGION" --task 'copy authentication command' --limit 5 --budget 700)"
echo "$SCOPED_ACTIONS" | grep -q '"name":"Copy authentication command"'
headless --session qa visit http://127.0.0.1:41739/hostile/ | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$(headless --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
headless session close qa | grep -q '"closed":"qa"'

# Shutdown deliberately bypasses the transport's request queue so an operator
# can stop a stalled browser action. Teardown therefore runs while a command is
# still in flight, and before the host state lock both threads mutated the same
# session and recording dictionaries. Reproduce that with an active recording
# and a long tour in flight, then require a clean exit and a clean restart.
headless session create race | grep -q '"session":"race"'
headless --session race visit http://127.0.0.1:41739/designers/dashboard/ >/dev/null
headless --session race record start --fps 5 --output race-shutdown.mp4 >/dev/null
RACE_HOST_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$RACE_HOST_PID"
headless --session race tour --full-page --pace 1000 >/dev/null 2>&1 &
RACE_TOUR_PID=$!
sleep 1
headless stop | grep -q '"stopping":true'
wait "$RACE_TOUR_PID" 2>/dev/null || true
RACE_WAITED=0
while [ "$RACE_WAITED" -lt 30 ]; do
  kill -0 "$RACE_HOST_PID" 2>/dev/null || break
  RACE_WAITED=$((RACE_WAITED + 1))
  sleep 1
done
if kill -0 "$RACE_HOST_PID" 2>/dev/null; then
  echo "host did not exit after shutdown during an in-flight command" >&2
  exit 1
fi
headless start >/dev/null
headless status | grep -q '"ready":true'
headless session list | grep -q '"sessions":\["default"\]'

# Navigation allowlist: stop the unrestricted host, start with --allow,
# deny off-list visit/click/form/script/window/redirect, then restore an
# unrestricted host for cleanup.
wait_for_host_exit() {
  pid="$1"
  waited=0
  while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    waited=$((waited + 1))
    sleep 0.1
  done
}
assert_page_stays_on_loopback() {
  reason="$1"
  waited=0
  snapshot=""
  while [ "$waited" -lt 20 ]; do
    snapshot="$(headless inspect --context summary 2>/dev/null || true)"
    if echo "$snapshot" | grep -q 'HOST_UNAVAILABLE'; then
      echo "$reason (host stopped responding)" >&2
      echo "$snapshot" >&2
      exit 1
    fi
    if echo "$snapshot" | grep -q '"url":"http://127.0.0.1' \
      && ! echo "$snapshot" | grep -q '"url":"https://example.com'; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 0.1
  done
  echo "$reason" >&2
  echo "$snapshot" >&2
  exit 1
}
STEP="navigation-allowlist"
ALLOWLIST_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
headless stop >/dev/null 2>&1 || true
wait_for_host_exit "$ALLOWLIST_PID"
headless start --allow 127.0.0.1 | grep -q '"navigationAllowlist":\["127.0.0.1"\]'
headless visit http://127.0.0.1:41739/designers/dashboard/ | grep -q 'Designers Dashboard'
if ALLOWLIST_VISIT="$(headless visit https://example.com/)"; then
  echo "off-allowlist visit was not blocked" >&2
  exit 1
fi
echo "$ALLOWLIST_VISIT" | grep -q 'UNSAFE_NAVIGATION'
if ALLOWLIST_CLICK="$(headless click --role link --name 'Off-allowlist site')"; then
  echo "off-allowlist click was not blocked" >&2
  exit 1
fi
echo "$ALLOWLIST_CLICK" | grep -q 'UNSAFE_NAVIGATION'
headless visit http://127.0.0.1:41739/allowlist-exits/ | grep -q 'Allowlist exits'
if ALLOWLIST_FORM="$(headless click --role button --name 'Leave via form')"; then
  echo "off-allowlist form submit was not blocked" >&2
  exit 1
fi
echo "$ALLOWLIST_FORM" | grep -q 'UNSAFE_NAVIGATION'
assert_page_stays_on_loopback "form submit left the allowlist"
headless click --role button --name 'Leave via script' >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "script navigation left the allowlist"
ALLOWLIST_SESSIONS_BEFORE="$(headless session list)"
echo "$ALLOWLIST_SESSIONS_BEFORE" | grep -q '"sessions":\["default"\]'
headless click --role button --name 'Leave via window' >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "window.open left the allowlist"
ALLOWLIST_SESSIONS_AFTER="$(headless session list)"
echo "$ALLOWLIST_SESSIONS_AFTER" | grep -q '"sessions":\["default"\]'
headless visit http://127.0.0.1:41739/allowlist-redirect/ >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "redirect left the allowlist"
headless start --allow 127.0.0.1 | grep -q '"ready":true'
ALLOWLIST_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
headless stop >/dev/null
wait_for_host_exit "$ALLOWLIST_PID"
headless start --allow 127.0.0.1 --allow localhost | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
headless start --allow localhost --allow 127.0.0.1 | grep -q '"ready":true'
headless start --allow localhost --allow 127.0.0.1 | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
if ALLOWLIST_MISMATCH="$(headless start --allow example.com)"; then
  echo "a conflicting --allow list was accepted on a running host" >&2
  exit 1
fi
echo "$ALLOWLIST_MISMATCH" | grep -q 'NAVIGATION_ALLOWLIST_CONFLICT'
echo "$ALLOWLIST_MISMATCH" | grep -q 'headless stop'
headless start | grep -q '"ready":true'
headless status | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
ALLOWLIST_PID="$(headless status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
headless stop >/dev/null
wait_for_host_exit "$ALLOWLIST_PID"
headless start | grep -q '"navigationAllowlist":\[\]'

if [ -n "${HEADLESS_EVIDENCE_DIR:-}" ]; then
  umask 077
  mkdir -p "$HEADLESS_EVIDENCE_DIR"
  cp "$HEADLESS_ARTIFACT_DIR"/*.png "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.jpg "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.jpeg "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.pdf "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.mp4 "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.webm "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.gif "$HEADLESS_EVIDENCE_DIR/"
  cp "$HEADLESS_ARTIFACT_DIR"/*.json "$HEADLESS_EVIDENCE_DIR/"
  (
    cd "$HEADLESS_EVIDENCE_DIR"
    sha256sum ./*.png ./*.jpg ./*.jpeg ./*.pdf ./*.mp4 ./*.webm ./*.gif ./*.json > SHA256SUMS
  )
fi

echo "Linux P2 end-to-end flow passed"
