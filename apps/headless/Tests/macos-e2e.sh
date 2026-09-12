#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."

for tool in node curl defaults lsof osascript perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "macOS E2E tests require $tool" >&2; exit 69; }
done

CLI="$PWD/Headless.app/Contents/Resources/bin/headless"
HOST="$PWD/Headless.app/Contents/MacOS/Headless"
[[ -x "$CLI" && -x "$HOST" ]] || { echo "Build Headless.app before macOS E2E tests" >&2; exit 1; }

PORT=$((43000 + RANDOM % 1000))
RUNTIME="/tmp/headless-$(id -u)"
mkdir -p "$RUNTIME"
chmod 700 "$RUNTIME"
export HEADLESS_SOCKET="$RUNTIME/macos-e2e-$$.sock"
export HEADLESS_ARTIFACT_DIR="$RUNTIME/artifacts-macos-e2e-$$"
export HEADLESS_HOST_EXECUTABLE="$HOST"
export HEADLESS_FIXTURE_PORT="$PORT"
export HEADLESS_E2E_DATA_STORE_ID="$(uuidgen)"
LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-e2e.XXXXXX")"
HOST_LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-host.XXXXXX")"
RESTORE_LOG="$(mktemp "${TMPDIR:-/tmp}/headless-macos-restore.XXXXXX")"
MENU_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headless-macos-snapshot.XXXXXX")"
MENU_SNAPSHOT_PATH="$MENU_SNAPSHOT_DIR/menu-snapshot.png"
CLIPBOARD_BACKUP="$(mktemp "${TMPDIR:-/tmp}/headless-macos-clipboard.XXXXXX")"
CLIPBOARD_SAVED=0
export HEADLESS_E2E_MENU_SNAPSHOT_PATH="$MENU_SNAPSHOT_PATH"
export HEADLESS_HOST_LOG="$HOST_LOG"
STEP="boot"
RESTORE_PID=""
HOST_PID=""
SUPERVISED_LAUNCHER_PID=""
SUPERVISED_FIFO=""
SUPERVISED_OUTPUT=""
DEFAULTS_DOMAIN="com.headless.app"
PRESENTATION_KEY="AgentStartupPresentation"
DEFAULTS_HAD_LAST_URL=0
DEFAULTS_LAST_URL=""
DEFAULTS_HAD_PRESENTATION=0
DEFAULTS_PRESENTATION=""
if DEFAULTS_LAST_URL="$(defaults read "$DEFAULTS_DOMAIN" LastURL 2>/dev/null)"; then
  DEFAULTS_HAD_LAST_URL=1
fi
if DEFAULTS_PRESENTATION="$(defaults read "$DEFAULTS_DOMAIN" "$PRESENTATION_KEY" 2>/dev/null)"; then
  DEFAULTS_HAD_PRESENTATION=1
fi

restore_last_url() {
  if [[ "$DEFAULTS_HAD_LAST_URL" == 1 ]]; then
    defaults write "$DEFAULTS_DOMAIN" LastURL -string "$DEFAULTS_LAST_URL"
  else
    defaults delete "$DEFAULTS_DOMAIN" LastURL >/dev/null 2>&1 || true
  fi
}

restore_startup_presentation() {
  if [[ "$DEFAULTS_HAD_PRESENTATION" == 1 ]]; then
    defaults write "$DEFAULTS_DOMAIN" "$PRESENTATION_KEY" -string "$DEFAULTS_PRESENTATION"
  else
    defaults delete "$DEFAULTS_DOMAIN" "$PRESENTATION_KEY" >/dev/null 2>&1 || true
  fi
}

fail() {
  trap - ERR
  print -r -u2 -- "macOS E2E failed during: $STEP"
  print -r -u2 -- "---- fixture log ----"
  cat "$LOG" >&2 || true
  print -r -u2 -- "---- host log ----"
  cat "$HOST_LOG" >&2 || true
  print -r -u2 -- "---- restore log ----"
  cat "$RESTORE_LOG" >&2 || true
  cleanup
  trap - EXIT INT TERM
  exit 1
}
trap 'fail' ERR

frontmost_pid() {
  osascript -l JavaScript \
    -e 'ObjC.import("AppKit"); Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)'
}

activate_pid() {
  local pid="$1"
  osascript_with_timeout - "$pid" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Previous frontmost process was not found"
    tell item 1 of targetProcesses to set frontmost to true
  end tell
end run
APPLESCRIPT
}

osascript_with_timeout() {
  perl -e '
    my $seconds = shift @ARGV;
    my $pid = fork();
    die "could not start osascript: $!\n" unless defined $pid;
    if ($pid == 0) {
      exec @ARGV;
      die "could not execute osascript: $!\n";
    }
    $SIG{ALRM} = sub {
      kill "TERM", $pid;
      select undef, undef, undef, 0.2;
      kill "KILL", $pid;
      waitpid $pid, 0;
      print STDERR "osascript timed out; grant Accessibility access to the test runner\n";
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    alarm 0;
    my $status = $?;
    exit 127 if $status == -1;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  ' 10 /usr/bin/osascript "$@"
}

ax_menu_attribute() {
  local pid="$1" menu_title="$2" item_title="$3" attribute_name="$4"
  osascript_with_timeout - "$pid" "$menu_title" "$item_title" "$attribute_name" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set menuTitle to item 2 of argv
  set itemTitle to item 3 of argv
  set attributeName to item 4 of argv
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses
      set targetItem to menu item itemTitle of menu 1 of menu bar item menuTitle of menu bar 1
      set attributeValue to value of attribute attributeName of targetItem
    end tell
  end tell
  if attributeValue is missing value then return "__MISSING__"
  return attributeValue as text
end run
APPLESCRIPT
}

ax_menu_exists() {
  local pid="$1" menu_title="$2" item_title="$3"
  osascript_with_timeout - "$pid" "$menu_title" "$item_title" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set menuTitle to item 2 of argv
  set itemTitle to item 3 of argv
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses
      return exists menu item itemTitle of menu 1 of menu bar item menuTitle of menu bar 1
    end tell
  end tell
end run
APPLESCRIPT
}

ax_press_menu_item() {
  local pid="$1" menu_title="$2" item_title="$3"
  osascript_with_timeout - "$pid" "$menu_title" "$item_title" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set menuTitle to item 2 of argv
  set itemTitle to item 3 of argv
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses
      set frontmost to true
      perform action "AXPress" of menu item itemTitle of menu 1 of menu bar item menuTitle of menu bar 1
    end tell
  end tell
end run
APPLESCRIPT
}

ax_window_count() {
  local pid="$1"
  osascript_with_timeout - "$pid" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses to return count of windows
  end tell
end run
APPLESCRIPT
}

ax_focused_element() {
  local pid="$1"
  osascript_with_timeout - "$pid" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses
      set focusedElement to value of attribute "AXFocusedUIElement"
      set focusedRole to value of attribute "AXRole" of focusedElement
      set focusedValue to value of attribute "AXValue" of focusedElement
    end tell
  end tell
  if focusedValue is missing value then set focusedValue to ""
  return focusedRole & tab & focusedValue
end run
APPLESCRIPT
}

ax_escape() {
  local pid="$1"
  osascript_with_timeout - "$pid" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses to set frontmost to true
    key code 53
  end tell
end run
APPLESCRIPT
}

ax_keystroke() {
  local pid="$1" key_text="$2" modifiers="$3"
  osascript_with_timeout - "$pid" "$key_text" "$modifiers" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set keyText to item 2 of argv
  set modifierNames to item 3 of argv
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses to set frontmost to true
    if modifierNames is "none" then
      keystroke keyText
    else if modifierNames is "command" then
      keystroke keyText using {command down}
    else if modifierNames is "command-shift" then
      keystroke keyText using {command down, shift down}
    else
      error "Unsupported test modifier set"
    end if
  end tell
end run
APPLESCRIPT
}

ax_front_window_attribute() {
  local pid="$1" attribute_name="$2"
  osascript_with_timeout - "$pid" "$attribute_name" <<'APPLESCRIPT'
on run argv
  set targetPID to item 1 of argv as integer
  set attributeName to item 2 of argv
  tell application "System Events"
    set targetProcesses to every application process whose unix id is targetPID
    if (count of targetProcesses) is not 1 then error "Headless accessibility process was not found"
    tell item 1 of targetProcesses
      if (count of windows) is 0 then error "Headless has no accessible windows"
      return value of attribute attributeName of front window
    end tell
  end tell
end run
APPLESCRIPT
}

wait_for_focused_value() {
  local pid="$1" expected="$2" focused_element
  for _ in {1..100}; do
    if focused_element="$(ax_focused_element "$pid" 2>/dev/null)" &&
       [[ "$focused_element" == AXTextField$'\t'"$expected" ]]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

save_clipboard() {
  osascript -l JavaScript - "$CLIPBOARD_BACKUP" <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');
const path = ObjC.unwrap($.NSProcessInfo.processInfo.arguments.objectAtIndex(4));
const items = $.NSPasteboard.generalPasteboard.pasteboardItems.js.map(item =>
  item.types.js.map(type => [
    ObjC.unwrap(type),
    ObjC.unwrap(item.dataForType(type).base64EncodedStringWithOptions(0)),
  ])
);
if (!$(JSON.stringify(items)).writeToFileAtomicallyEncodingError(
  path, true, $.NSUTF8StringEncoding, null
)) throw new Error('Could not save the pasteboard');
JXA
  CLIPBOARD_SAVED=1
}

restore_clipboard() {
  [[ "$CLIPBOARD_SAVED" == 1 ]] || return 0
  osascript -l JavaScript - "$CLIPBOARD_BACKUP" <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');
const path = ObjC.unwrap($.NSProcessInfo.processInfo.arguments.objectAtIndex(4));
const source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
  path, $.NSUTF8StringEncoding, null
));
const restored = $.NSMutableArray.array;
for (const representations of JSON.parse(source)) {
  const item = $.NSPasteboardItem.alloc.init;
  for (const [type, base64] of representations) {
    const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64), 0);
    if (!item.setDataForType(data, $(type))) throw new Error(`Could not restore ${type}`);
  }
  restored.addObject(item);
}
const pasteboard = $.NSPasteboard.generalPasteboard;
pasteboard.clearContents;
if (restored.count > 0 && !pasteboard.writeObjects(restored)) {
  throw new Error('Could not restore the pasteboard');
}
JXA
  CLIPBOARD_SAVED=0
}

fixture_request_count() {
  local request_path="$1" count
  count="$(curl -fsS --get --data-urlencode "path=$request_path" \
    "http://127.0.0.1:$PORT/request-count")"
  [[ "$count" == <-> ]] || return 1
  print -r -- "$count"
}

assert_menu_shortcut() {
  local pid="$1" menu_title="$2" item_title="$3" expected_key="$4" expected_modifiers="$5"
  local actual_key actual_modifiers
  if ! actual_key="$(ax_menu_attribute "$pid" "$menu_title" "$item_title" AXMenuItemCmdChar)"; then
    echo "Could not inspect $menu_title > $item_title through Accessibility" >&2
    return 1
  fi
  if ! actual_modifiers="$(ax_menu_attribute "$pid" "$menu_title" "$item_title" AXMenuItemCmdModifiers)"; then
    echo "Could not inspect $menu_title > $item_title modifiers through Accessibility" >&2
    return 1
  fi
  if [[ "$actual_key" == "__MISSING__" || "${actual_key:l}" != "${expected_key:l}" ]]; then
    echo "$menu_title > $item_title key was $actual_key, expected $expected_key" >&2
    return 1
  fi
  if [[ "$actual_modifiers" == "__MISSING__" || "$actual_modifiers" != "$expected_modifiers" ]]; then
    echo "$menu_title > $item_title modifiers were $actual_modifiers, expected $expected_modifiers" >&2
    return 1
  fi
}

assert_system_full_screen_shortcut() {
  local pid="$1" actual_key actual_modifiers
  actual_key="$(ax_menu_attribute "$pid" View "Enter Full Screen" AXMenuItemCmdChar)"
  actual_modifiers="$(ax_menu_attribute "$pid" View "Enter Full Screen" AXMenuItemCmdModifiers)"
  if [[ "${actual_key:l}" != f ]]; then
    echo "View > Enter Full Screen key was $actual_key, expected F" >&2
    return 1
  fi
  # AppKit exposes Control-Command-F as 4 on older releases and the
  # system-managed Function-F equivalent as 24 on newer releases.
  if [[ "$actual_modifiers" != 4 && "$actual_modifiers" != 24 ]]; then
    echo "View > Enter Full Screen modifiers were $actual_modifiers, expected 4 or 24" >&2
    return 1
  fi
}

wait_for_menu_enabled() {
  local pid="$1" menu_title="$2" item_title="$3" enabled
  for _ in {1..100}; do
    if enabled="$(ax_menu_attribute "$pid" "$menu_title" "$item_title" AXEnabled 2>/dev/null)" &&
       [[ "$enabled" == true ]]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

node Tests/fixture-server.mjs >"$LOG" 2>&1 &
FIXTURE_PID=$!

cleanup() {
  trap - ERR
  local host_pid_output
  local -a host_pids
  host_pid_output="$({
    lsof -t "$HEADLESS_SOCKET" 2>/dev/null || true
    if [[ -n "$HOST_PID" ]]; then print -r -- "$HOST_PID"; fi
    if [[ -n "$RESTORE_PID" ]]; then print -r -- "$RESTORE_PID"; fi
    true
  } | sort -u)"
  host_pids=("${(@f)host_pid_output}")
  if "$CLI" status >/dev/null 2>&1; then
    "$CLI" profile clear >/dev/null 2>&1 || true
  fi
  "$CLI" stop >/dev/null 2>&1 || true
  for _ in {1..100}; do
    local hosts_stopped=1
    for host_pid in "${host_pids[@]}"; do
      if [[ -n "$host_pid" ]] && kill -0 "$host_pid" >/dev/null 2>&1; then
        hosts_stopped=0
        break
      fi
    done
    [[ "$hosts_stopped" == 1 ]] && break
    sleep 0.05
  done
  for host_pid in "${host_pids[@]}"; do
    if [[ -n "$host_pid" ]] && kill -0 "$host_pid" >/dev/null 2>&1; then
      kill "$host_pid" >/dev/null 2>&1 || true
    fi
  done
  for _ in {1..40}; do
    local hosts_stopped=1
    for host_pid in "${host_pids[@]}"; do
      if [[ -n "$host_pid" ]] && kill -0 "$host_pid" >/dev/null 2>&1; then
        hosts_stopped=0
        break
      fi
    done
    [[ "$hosts_stopped" == 1 ]] && break
    sleep 0.05
  done
  for host_pid in "${host_pids[@]}"; do
    if [[ -n "$host_pid" ]] && kill -0 "$host_pid" >/dev/null 2>&1; then
      kill -9 "$host_pid" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$RESTORE_PID" ]]; then
    kill "$RESTORE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SUPERVISED_LAUNCHER_PID" ]]; then
    kill "$SUPERVISED_LAUNCHER_PID" >/dev/null 2>&1 || true
  fi
  kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  restore_last_url
  restore_startup_presentation
  if ! restore_clipboard; then
    print -r -u2 -- "Could not restore the pasteboard; backup retained at $CLIPBOARD_BACKUP"
  fi
  rm -rf "$HEADLESS_ARTIFACT_DIR"
  rm -rf "$MENU_SNAPSHOT_DIR"
  rm -f "$HEADLESS_SOCKET" "$LOG" "$HOST_LOG" "$RESTORE_LOG"
  [[ -z "$SUPERVISED_FIFO" ]] || rm -f "$SUPERVISED_FIFO"
  [[ -z "$SUPERVISED_OUTPUT" ]] || rm -f "$SUPERVISED_OUTPUT"
  if [[ "$CLIPBOARD_SAVED" == 0 ]]; then
    rm -f "$CLIPBOARD_BACKUP"
  fi
}
trap cleanup EXIT INT TERM

STEP="fixture-server"
for _ in {1..100}; do
  curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "http://127.0.0.1:$PORT/designers/dashboard" >/dev/null

STEP="restored-url-fallback"
UNAVAILABLE_PORT=$((PORT + 2000))
if lsof -nP -iTCP:"$UNAVAILABLE_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "macOS E2E restore port is unexpectedly in use: $UNAVAILABLE_PORT" >&2
  fail
fi
RESTORED_URL="http://127.0.0.1:$UNAVAILABLE_PORT/restored"
defaults write "$DEFAULTS_DOMAIN" LastURL -string "$RESTORED_URL"
HEADLESS_AGENT_HOST=0 "$HOST" >"$RESTORE_LOG" 2>&1 &
RESTORE_PID=$!
for _ in {1..100}; do
  "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
"$CLI" status | grep -q '"ready":true'
RESTORED_URL_CLEARED=0
for _ in {1..300}; do
  if ! defaults read "$DEFAULTS_DOMAIN" LastURL >/dev/null 2>&1; then
    RESTORED_URL_CLEARED=1
    break
  fi
  sleep 0.05
done
if [[ "$RESTORED_URL_CLEARED" != 1 ]]; then
  echo "failed restored URL was not cleared" >&2
  "$CLI" qa report >&2 || true
  fail
fi
sleep 1
RESTORED_SNAPSHOT="$("$CLI" inspect --text)"
echo "$RESTORED_SNAPSHOT" | grep -q 'search or enter a url'
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! kill -0 "$RESTORE_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$RESTORE_PID" >/dev/null 2>&1; then
  echo "manual restore-test host did not stop" >&2
  fail
fi
wait "$RESTORE_PID" || true
RESTORE_PID=""
restore_last_url
echo "▸ unavailable restored URL fell back to the start page"

STEP="start-host"
SETTINGS_LIST="$("$CLI" config list)"
echo "$SETTINGS_LIST" | grep -q '"key":"startup-presentation"'
echo "$SETTINGS_LIST" | grep -q '"access":"agent-writable"'
echo "$SETTINGS_LIST" | grep -q '"supportedOnCurrentPlatform":true'
SETTINGS_DESCRIPTION="$("$CLI" config describe startup-presentation)"
echo "$SETTINGS_DESCRIPTION" | grep -q '"allowedValues":\["background","foreground"\]'
echo "$SETTINGS_DESCRIPTION" | grep -q '"restartBehavior":"next-host-start"'
echo "$SETTINGS_DESCRIPTION" | grep -q '"summary":"Choose whether an agent-started macOS host activates in front of the current app."'
RESET_PRESENTATION="$("$CLI" config reset startup-presentation)"
echo "$RESET_PRESENTATION" | grep -q '"configured":false'
echo "$RESET_PRESENTATION" | grep -q '"startupPresentation":"background"'
DEFAULT_PRESENTATION="$("$CLI" config get startup-presentation)"
echo "$DEFAULT_PRESENTATION" | grep -q '"builtInDefault":"background"'
echo "$DEFAULT_PRESENTATION" | grep -q '"configured":null'
echo "$DEFAULT_PRESENTATION" | grep -q '"startupPresentation":"background"'
SET_PRESENTATION="$("$CLI" config set startup-presentation background)"
echo "$SET_PRESENTATION" | grep -q '"configured":true'
echo "$SET_PRESENTATION" | grep -q '"takesEffect":"next-host-start"'
echo "$SET_PRESENTATION" | grep -q '"startupPresentation":"background"'
test "$(defaults read "$DEFAULTS_DOMAIN" "$PRESENTATION_KEY")" = "background"
CONFIGURED_PRESENTATION="$("$CLI" config get startup-presentation)"
echo "$CONFIGURED_PRESENTATION" | grep -q '"configured":"background"'
echo "$CONFIGURED_PRESENTATION" | grep -q '"startupPresentation":"background"'

STEP="supervised-host-owner-exit"
SUPERVISED_FIFO="$(mktemp "${TMPDIR:-/tmp}/headless-supervised-fifo.XXXXXX")"
SUPERVISED_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/headless-supervised-output.XXXXXX")"
rm -f "$SUPERVISED_FIFO"
mkfifo "$SUPERVISED_FIFO"
"$CLI" start --background --supervised <"$SUPERVISED_FIFO" >"$SUPERVISED_OUTPUT" &
SUPERVISED_LAUNCHER_PID=$!
exec 9>"$SUPERVISED_FIFO"
for _ in {1..160}; do
  [[ -s "$SUPERVISED_OUTPUT" ]] && "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
SUPERVISED_RESULT="$(cat "$SUPERVISED_OUTPUT")"
echo "$SUPERVISED_RESULT" | grep -q '"ready":true'
SUPERVISED_HOST_PID="$(echo "$SUPERVISED_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$SUPERVISED_HOST_PID"
test "$("$CLI" status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')" = "$SUPERVISED_HOST_PID"
kill -9 "$SUPERVISED_LAUNCHER_PID"
wait "$SUPERVISED_LAUNCHER_PID" >/dev/null 2>&1 || true
SUPERVISED_LAUNCHER_PID=""
for _ in {1..100}; do
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

STEP="start-host"
START_RESULT="$("$CLI" start)" || {
  print -r -u2 -- "headless start failed:"
  print -r -u2 -- "$START_RESULT"
  fail
}
echo "$START_RESULT" | grep -q '"ready":true' || {
  print -r -u2 -- "host did not become ready: $START_RESULT"
  fail
}
echo "▸ host ready"

if AUTH_REQUIRED="$("$CLI" visit "http://127.0.0.1:$PORT/auth-login" 2>&1)"; then
  print -r -u2 -- "confirmed login form did not require authentication"
  exit 1
fi
echo "$AUTH_REQUIRED" | grep -q '"code":"AUTH_REQUIRED"'
echo "$AUTH_REQUIRED" | grep -q "\"origin\":\"http://127.0.0.1:$PORT\""
echo "$AUTH_REQUIRED" | grep -q '"accounts":\[\]'
echo "$AUTH_REQUIRED" | grep -q '"userPresenceRequired":true'
echo "$AUTH_REQUIRED" | grep -q '"credentialUseAvailable":true'
"$CLI" fill @e1 -- 'fixture@example.test' | grep -q '"valueLength":20'
"$CLI" fill @e2 -- 'synthetic-direct-password' | grep -q '"valueLength":25'
"$CLI" click @e3 | grep -q '"clicked"'
"$CLI" wait --text 'Signed in' | grep -q 'Signed in'
STEP="tcp-check"
HOST_PID="$(echo "$START_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$HOST_PID"
if [[ "$(frontmost_pid)" == "$HOST_PID" ]]; then
  echo "default agent startup stole focus" >&2
  fail
fi
RUNNING_START_RESULT="$("$CLI" start --foreground)"
echo "$RUNNING_START_RESULT" | grep -q "\"pid\":$HOST_PID"
if [[ "$(frontmost_pid)" == "$HOST_PID" ]]; then
  echo "a launch-time foreground flag reordered an existing host" >&2
  fail
fi
if lsof -nP -a -p "$HOST_PID" -iTCP -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "Headless host opened an unexpected TCP listener" >&2
  fail
fi
BACKGROUND_FRONTMOST_PID="$(frontmost_pid)"
STEP="menu-shortcut-inventory"
# AX encodes Shift, Option, and Control as bits 1, 2, and 4. Command is
# implicit unless the NoCommand bit (8) is present.
while IFS=$'\t' read -r menu_title item_title expected_key expected_modifiers; do
  assert_menu_shortcut "$HOST_PID" "$menu_title" "$item_title" "$expected_key" "$expected_modifiers"
done <<'SHORTCUTS'
Headless	Hide Headless	h	0
Headless	Hide Others	h	2
Headless	Quit Headless	q	0
File	New Window	n	0
File	Open Location…	l	0
File	Save Snapshot to Desktop	s	1
File	Close Window	w	0
Edit	Undo	z	0
Edit	Redo	z	1
Edit	Cut	x	0
Edit	Copy	c	0
Edit	Paste	v	0
Edit	Select All	a	0
Edit	Copy Current URL	c	1
View	Reload Page	r	0
View	Reload Ignoring Cache	r	1
View	Zoom In	=	0
View	Zoom Out	-	0
View	Actual Size	0	0
History	Back	[	0
History	Forward	]	0
Window	Minimize	m	0
Window	Pin on Top	p	2
Help	Headless Help	/	1
SHORTCUTS
assert_system_full_screen_shortcut "$HOST_PID"
for settings_title in "Settings" "Settings…" "Preferences" "Preferences…"; do
  if [[ "$(ax_menu_exists "$HOST_PID" Headless "$settings_title")" == true ]]; then
    echo "$settings_title is shipped but has no Cmd-, coverage" >&2
    fail
  fi
done

STEP="menu-new-window-close"
WINDOWS_BEFORE="$(ax_window_count "$HOST_PID")"
ax_press_menu_item "$HOST_PID" File "New Window"
NEW_WINDOW_OPENED=0
for _ in {1..100}; do
  if [[ "$(ax_window_count "$HOST_PID")" == $((WINDOWS_BEFORE + 1)) ]]; then
    NEW_WINDOW_OPENED=1
    break
  fi
  sleep 0.05
done
if [[ "$NEW_WINDOW_OPENED" != 1 ]]; then
  echo "New Window menu action did not create a window" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" File "Close Window"
NEW_WINDOW_CLOSED=0
for _ in {1..100}; do
  if [[ "$(ax_window_count "$HOST_PID")" == "$WINDOWS_BEFORE" ]]; then
    NEW_WINDOW_CLOSED=1
    break
  fi
  sleep 0.05
done
if [[ "$NEW_WINDOW_CLOSED" != 1 ]]; then
  echo "Close Window menu action did not close the active window" >&2
  fail
fi

STEP="menu-open-location"
ax_press_menu_item "$HOST_PID" File "Open Location…"
LOCATION_VALUE=""
for _ in {1..100}; do
  if FOCUSED_ELEMENT="$(ax_focused_element "$HOST_PID" 2>/dev/null)" &&
     [[ "$FOCUSED_ELEMENT" == AXTextField$'\t'http://* ]]; then
    LOCATION_VALUE="${FOCUSED_ELEMENT#*$'\t'}"
    break
  fi
  sleep 0.05
done
if [[ -z "$LOCATION_VALUE" ]]; then
  echo "Open Location did not focus the address field with the current URL" >&2
  fail
fi

STEP="menu-text-responder"
save_clipboard
TEXT_SENTINEL="headlessmenualpha"
ax_keystroke "$HOST_PID" a command
ax_keystroke "$HOST_PID" "$TEXT_SENTINEL" none
wait_for_focused_value "$HOST_PID" "$TEXT_SENTINEL"
ax_keystroke "$HOST_PID" a command
ax_keystroke "$HOST_PID" c command
ax_keystroke "$HOST_PID" temporary none
wait_for_focused_value "$HOST_PID" temporary
ax_keystroke "$HOST_PID" a command
ax_keystroke "$HOST_PID" v command
wait_for_focused_value "$HOST_PID" "$TEXT_SENTINEL"
ax_keystroke "$HOST_PID" a command
ax_keystroke "$HOST_PID" x command
wait_for_focused_value "$HOST_PID" ""
ax_keystroke "$HOST_PID" v command
wait_for_focused_value "$HOST_PID" "$TEXT_SENTINEL"
ax_keystroke "$HOST_PID" z command
wait_for_focused_value "$HOST_PID" ""
ax_keystroke "$HOST_PID" z command-shift
wait_for_focused_value "$HOST_PID" "$TEXT_SENTINEL"
ax_escape "$HOST_PID"

STEP="menu-reload"
"$CLI" visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
RELOAD_COUNT_BEFORE="$(fixture_request_count /designers/dashboard)"
ax_press_menu_item "$HOST_PID" View "Reload Page"
RELOAD_OBSERVED=0
for _ in {1..200}; do
  if RELOAD_COUNT_AFTER="$(fixture_request_count /designers/dashboard 2>/dev/null)" &&
     [[ "$RELOAD_COUNT_AFTER" -gt "$RELOAD_COUNT_BEFORE" ]]; then
    RELOAD_OBSERVED=1
    break
  fi
  sleep 0.05
done
if [[ "$RELOAD_OBSERVED" != 1 ]]; then
  echo "Reload Page did not produce a new page request" >&2
  fail
fi
"$CLI" wait --text 'Designers dashboard' --settled --timeout 10000 | grep -q 'Designers Dashboard'

STEP="menu-snapshot"
ax_press_menu_item "$HOST_PID" File "Save Snapshot to Desktop"
for _ in {1..200}; do
  [[ -s "$MENU_SNAPSHOT_PATH" ]] && break
  sleep 0.05
done
if [[ -z "$MENU_SNAPSHOT_PATH" || ! -s "$MENU_SNAPSHOT_PATH" ]]; then
  echo "Save Snapshot to Desktop did not create a non-empty PNG" >&2
  fail
fi
file "$MENU_SNAPSHOT_PATH" | grep -q 'PNG image data'

STEP="menu-zoom"
"$CLI" screenshot --output menu-zoom-baseline.png >/dev/null
ax_press_menu_item "$HOST_PID" View "Zoom In"
"$CLI" screenshot --output menu-zoom-in.png >/dev/null
if cmp -s "$HEADLESS_ARTIFACT_DIR/menu-zoom-baseline.png" "$HEADLESS_ARTIFACT_DIR/menu-zoom-in.png"; then
  echo "Zoom In did not change rendered page output" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" View "Actual Size"
"$CLI" screenshot --output menu-zoom-reset.png >/dev/null
cmp -s "$HEADLESS_ARTIFACT_DIR/menu-zoom-baseline.png" "$HEADLESS_ARTIFACT_DIR/menu-zoom-reset.png"
ax_press_menu_item "$HOST_PID" View "Zoom Out"
"$CLI" screenshot --output menu-zoom-out.png >/dev/null
if cmp -s "$HEADLESS_ARTIFACT_DIR/menu-zoom-baseline.png" "$HEADLESS_ARTIFACT_DIR/menu-zoom-out.png"; then
  echo "Zoom Out did not change rendered page output" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" View "Actual Size"

STEP="menu-full-screen"
ax_press_menu_item "$HOST_PID" View "Enter Full Screen"
FULL_SCREEN_ENTERED=0
for _ in {1..400}; do
  if FULL_SCREEN_STATE="$(ax_front_window_attribute "$HOST_PID" AXFullScreen 2>/dev/null)" &&
     [[ "$FULL_SCREEN_STATE" == true ]]; then
    FULL_SCREEN_ENTERED=1
    break
  fi
  sleep 0.05
done
if [[ "$FULL_SCREEN_ENTERED" != 1 ]]; then
  echo "Enter Full Screen did not put the front window into full-screen mode" >&2
  fail
fi
EXIT_FULL_SCREEN_AVAILABLE=0
for _ in {1..100}; do
  if [[ "$(ax_menu_exists "$HOST_PID" View "Exit Full Screen" 2>/dev/null || true)" == true ]]; then
    EXIT_FULL_SCREEN_AVAILABLE=1
    break
  fi
  sleep 0.05
done
if [[ "$EXIT_FULL_SCREEN_AVAILABLE" != 1 ]]; then
  echo "Enter Full Screen did not expose the standard Exit Full Screen action" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" View "Exit Full Screen"
FULL_SCREEN_EXITED=0
for _ in {1..400}; do
  if FULL_SCREEN_STATE="$(ax_front_window_attribute "$HOST_PID" AXFullScreen 2>/dev/null)" &&
     [[ "$FULL_SCREEN_STATE" == false ]]; then
    FULL_SCREEN_EXITED=1
    break
  fi
  sleep 0.05
done
if [[ "$FULL_SCREEN_EXITED" != 1 ]]; then
  echo "Exit Full Screen did not restore the front window" >&2
  fail
fi

STEP="menu-history"
"$CLI" visit "http://127.0.0.1:$PORT/next" | grep -q 'Designer Details'
if ! wait_for_menu_enabled "$HOST_PID" History Back; then
  echo "History > Back did not become enabled after visiting the next page" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" History Back
"$CLI" wait --url /designers/dashboard --text 'Designers dashboard' --settled --timeout 10000 | grep -q 'Designers Dashboard'
if ! wait_for_menu_enabled "$HOST_PID" History Forward; then
  echo "History > Forward did not become enabled after navigating back" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" History Forward
if ! HISTORY_FORWARD_RESULT="$("$CLI" wait --url /next --text 'Designer details' --settled --timeout 10000)" ||
   ! grep -q 'Designer Details' <<<"$HISTORY_FORWARD_RESULT"; then
  echo "History > Forward did not return to the next page" >&2
  print -r -u2 -- "$HISTORY_FORWARD_RESULT"
  fail
fi

STEP="menu-pin"
ax_press_menu_item "$HOST_PID" Window "Pin on Top"
PINNED_MARK="$(ax_menu_attribute "$HOST_PID" Window "Pin on Top" AXMenuItemMarkChar)"
if [[ "$PINNED_MARK" == "__MISSING__" || -z "$PINNED_MARK" ]]; then
  echo "Pin on Top did not enter its checked state" >&2
  fail
fi
ax_press_menu_item "$HOST_PID" Window "Pin on Top"
UNPINNED_MARK="$(ax_menu_attribute "$HOST_PID" Window "Pin on Top" AXMenuItemMarkChar)"
if [[ "$UNPINNED_MARK" != "__MISSING__" && -n "$UNPINNED_MARK" ]]; then
  echo "Pin on Top did not return to its unchecked state" >&2
  fail
fi
activate_pid "$BACKGROUND_FRONTMOST_PID"
BACKGROUND_FOCUS_RESTORED=0
for _ in {1..100}; do
  if [[ "$(frontmost_pid)" == "$BACKGROUND_FRONTMOST_PID" ]]; then
    BACKGROUND_FOCUS_RESTORED=1
    break
  fi
  sleep 0.05
done
if [[ "$BACKGROUND_FOCUS_RESTORED" != 1 ]]; then
  echo "menu checks did not restore the previously frontmost process" >&2
  fail
fi
echo "▸ menu shortcut inventory and actions passed"

STEP="cross-engine-conformance"
HEADLESS_CONFORMANCE_CLI="$CLI" \
HEADLESS_CONFORMANCE_ENGINE=webkit \
HEADLESS_CONFORMANCE_BASE_URL="http://127.0.0.1:$PORT" \
  Tests/conformance.sh
STEP="session-visit"
"$CLI" session create qa | grep -q '"session":"qa"'
if [[ "$(frontmost_pid)" == "$HOST_PID" ]]; then
  echo "agent session creation stole focus" >&2
  fail
fi
"$CLI" session list | grep -q '"qa"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
STEP="inspect-diagnostics"
SNAPSHOT="$("$CLI" --session qa inspect --interactive --text)"
echo "$SNAPSHOT" | grep -q '"name":"Continue"'
echo "$SNAPSHOT" | grep -q '"name":"Reviewer"'
! echo "$SNAPSHOT" | grep -q '"pwned":true'
ACTION_SNAPSHOT="$("$CLI" --session qa inspect --context actions --task 'click Continue')"
echo "$ACTION_SNAPSHOT" | grep -q '"contextMode":"actions"'
echo "$ACTION_SNAPSHOT" | grep -q '"task":"click Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"name":"Continue"'
echo "$ACTION_SNAPSHOT" | grep -q '"actions":\["click"\]'
echo "$ACTION_SNAPSHOT" | grep -q '"relevance"'
CONSOLE="$("$CLI" --session qa console list --level error)"
echo "$CONSOLE" | grep -q 'Next.js runtime error'
NETWORK="$("$CLI" --session qa network list)"
echo "$NETWORK" | grep -q '"requestId"'
NETWORK_ID="$(echo "$NETWORK" | sed -n 's/.*"requestId":"\([^"]*\)"[^}]*"url":"[^"]*\/api\/diagnostic".*/\1/p')"
test -n "$NETWORK_ID"
NETWORK_DETAIL="$("$CLI" --session qa network get "$NETWORK_ID")"
echo "$NETWORK_DETAIL" | grep -q '"requestHeaders"'
echo "$NETWORK_DETAIL" | grep -q '\[redacted\]'
STYLES="$("$CLI" --session qa styles get --role region --name 'Diagnostics probe' --property display)"
echo "$STYLES" | grep -q '"display":"flex"'
COOKIES="$("$CLI" --session qa cookies list)"
echo "$COOKIES" | grep -q '"name":"qa_session"'
echo "$COOKIES" | grep -q '"valueBytes"'
STORAGE="$("$CLI" --session qa storage list)"
echo "$STORAGE" | grep -q 'qa-diagnostic-key'
echo "$STORAGE" | grep -q 'qa-session-key'
if SENSITIVE_STORAGE="$("$CLI" --session qa storage list --values)"; then
  echo "sensitive storage values were available without opt-in" >&2
  fail
fi
echo "$SENSITIVE_STORAGE" | grep -q 'SENSITIVE_DIAGNOSTICS_DISABLED'
STEP="qa-report"
QA_REPORT="$("$CLI" --session qa qa report)"
echo "$QA_REPORT" | grep -q '"kind":"console"'
echo "$QA_REPORT" | grep -q '"status":404'
echo "$QA_REPORT" | grep -q '"kind":"framework-error"'
echo "$QA_REPORT" | grep -q '"kind":"local-not-found"'
"$CLI" --session qa qa clear | grep -q '"cleared"'
"$CLI" --session qa qa report | grep -q '"events":0'
STEP="safe-input-navigation"
"$CLI" --session qa fill @e1 'Ada Lovelace' | grep -q '"valueLength":12'
"$CLI" --session qa press Escape | grep -q '"pressed":"Escape"'
STEP="safe-input-external-link"
if EXTERNAL_RESULT="$("$CLI" --session qa click --role link --name 'External application')"; then
  echo "external application link was not blocked" >&2
  fail
fi
echo "$EXTERNAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-non-web-link"
if NON_WEB_RESULT="$("$CLI" --session qa click --role link --name 'Non-web browser URL')"; then
  echo "non-HTTP browser URL was not blocked" >&2
  fail
fi
echo "$NON_WEB_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-credential-link"
if CREDENTIAL_RESULT="$("$CLI" --session qa click --role link --name 'Credential-bearing URL')"; then
  echo "credential-bearing browser URL was not blocked" >&2
  fail
fi
echo "$CREDENTIAL_RESULT" | grep -q 'UNSAFE_NAVIGATION'
STEP="safe-input-suspicious-link"
if SUSPICIOUS_RESULT="$("$CLI" --session qa click --role link --name 'Suspicious installer')"; then
  echo "suspicious installer link was not blocked" >&2
  fail
fi
echo "$SUSPICIOUS_RESULT" | grep -q 'UNSAFE_RESOURCE_TYPE'
STEP="safe-input-scripted-navigation"
"$CLI" --session qa click --role button --name 'Scripted non-web navigation' | grep -q '"clicked"'
"$CLI" --session qa wait --url /designers/dashboard --settled --timeout 10000 | grep -q 'Designers Dashboard'
STEP="safe-input-download"
"$CLI" --session qa click --role link --name 'Download fixture' | grep -q '"clicked"'
sleep 1
BLOCKED_DOWNLOAD_REPORT="$("$CLI" --session qa qa report)"
STEP="safe-input-download-report"
echo "$BLOCKED_DOWNLOAD_REPORT" | grep -q '"kind":"download-blocked"'
echo "$BLOCKED_DOWNLOAD_REPORT" | grep -q '/download.txt'
"$CLI" --session qa qa clear | grep -q '"cleared"'
STEP="artifacts-visual"
"$CLI" --session qa screenshot --output viewport.png | grep -q '"name":"viewport.png"'
"$CLI" --session qa screenshot --full-page --output full-page.png | grep -q '"name":"full-page.png"'
"$CLI" --session qa screenshot --role button --name Continue --output continue.png | grep -q '"name":"continue.png"'
"$CLI" --session qa screenshot --format jpg --output viewport.jpg --clipboard | grep -q '"clipboard":true'
"$CLI" --session qa screenshot --format pdf --full-page --output full-page.pdf | grep -q '"name":"full-page.pdf"'
VIEWPORT_SERIES="$("$CLI" --session qa screenshot --every-viewport --format jpg --output scroll-capture)"
echo "$VIEWPORT_SERIES" | grep -q '"series":"viewport"'
echo "$VIEWPORT_SERIES" | grep -q '"name":"scroll-capture-001.jpg"'
test -s "$HEADLESS_ARTIFACT_DIR/scroll-capture-001.jpg"
SCROLL_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'scroll-capture-*.jpg' | wc -l | tr -d ' ')"
test "$SCROLL_CAPTURE_COUNT" -ge 2
SECTION_SERIES="$("$CLI" --session qa screenshot --by-section --output section-capture)"
echo "$SECTION_SERIES" | grep -q '"series":"section"'
SECTION_CAPTURE_COUNT="$(find "$HEADLESS_ARTIFACT_DIR" -maxdepth 1 -name 'section-capture-*.png' | wc -l | tr -d ' ')"
test "$SECTION_CAPTURE_COUNT" -ge 3
"$CLI" --session qa visual compare viewport.png viewport.png --output visual-diff.png | grep -q '"name":"visual-diff.png"'
test -s "$HEADLESS_ARTIFACT_DIR/visual-diff.png"
"$CLI" --session qa performance get | grep -q '"webVitals"'
ANIMATIONS="$("$CLI" --session qa animations list)"
echo "$ANIMATIONS" | grep -q '"animations"'
echo "$ANIMATIONS" | grep -q '"iterations":null'
STEP="network-emulate-unsupported"
if NETWORK_SIMULATION="$("$CLI" --session qa network emulate --latency 25)"; then
  echo "WebKit network emulation was unexpectedly exposed" >&2
  fail
fi
echo "$NETWORK_SIMULATION" | grep -q 'UNSUPPORTED_CAPABILITY'
STEP="file-upload-unsupported"
printf 'resume-fixture\n' > "$HEADLESS_ARTIFACT_DIR/resume.txt"
chmod 600 "$HEADLESS_ARTIFACT_DIR/resume.txt"
if "$CLI" artifacts add /etc/passwd --name resume.txt >/dev/null 2>&1; then
  echo "agent-facing local-file ingest was not rejected" >&2
  fail
fi
"$CLI" --session qa visit "http://127.0.0.1:$PORT/file-upload" | grep -q 'File upload fixture'
UPLOAD_SNAPSHOT="$("$CLI" --session qa inspect --interactive)"
echo "$UPLOAD_SNAPSHOT" | grep -q '"name":"Resume"'
if echo "$UPLOAD_SNAPSHOT" | grep -q '"actions":\["upload"\]'; then
  echo "WebKit inspect advertised upload despite missing fileUpload support" >&2
  fail
fi
if UPLOAD="$("$CLI" --session qa upload --role textbox --name Resume --artifact resume.txt)"; then
  echo "WebKit file upload was unexpectedly exposed" >&2
  fail
fi
echo "$UPLOAD" | grep -q 'UNSUPPORTED_CAPABILITY'
STEP="flows-reports"
"$CLI" --session qa flow start | grep -q '"recording":true'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa flow stop --output dashboard-flow.json | grep -q '"name":"dashboard-flow.json"'
"$CLI" --session qa flow run dashboard-flow.json | grep -q '"completed":2'
"$CLI" --session qa report create --output pr-report.json | grep -q '"name":"pr-report.json"'
grep -q 'headless-qa-report-v1' "$HEADLESS_ARTIFACT_DIR/pr-report.json"
"$CLI" --session qa visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
test -s "$HEADLESS_ARTIFACT_DIR/viewport.png"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.png"
test -s "$HEADLESS_ARTIFACT_DIR/continue.png"
test -s "$HEADLESS_ARTIFACT_DIR/viewport.jpg"
test -s "$HEADLESS_ARTIFACT_DIR/full-page.pdf"
test "$(xxd -p -l 3 "$HEADLESS_ARTIFACT_DIR/viewport.jpg")" = "ffd8ff"
head -c 5 "$HEADLESS_ARTIFACT_DIR/full-page.pdf" | grep -q '%PDF-'
VIEWPORT_HEIGHT="$(sips -g pixelHeight "$HEADLESS_ARTIFACT_DIR/viewport.png" | awk '/pixelHeight/ {print $2}')"
FULL_HEIGHT="$(sips -g pixelHeight "$HEADLESS_ARTIFACT_DIR/full-page.png" | awk '/pixelHeight/ {print $2}')"
test "$FULL_HEIGHT" -gt "$VIEWPORT_HEIGHT"
if "$CLI" --session qa screenshot --output viewport.png >/dev/null 2>&1; then
  echo "artifact overwrite was not rejected" >&2
  fail
fi
if "$CLI" screenshot --output ../escape.png >/dev/null 2>&1; then
  echo "artifact path traversal was not rejected" >&2
  fail
fi
STEP="recording"
"$CLI" --session qa record start --fps 5 | grep -q '"active":true'
"$CLI" --session qa record status | grep -q '"active":true'
if "$CLI" --session qa record start >/dev/null 2>&1; then
  echo "a second recording was not rejected" >&2
  fail
fi
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa click --role button --name Continue | grep -q '"clicked"'
"$CLI" --session qa wait --url /next --text 'Designer details' --settled --timeout 10000 | grep -q 'Designer Details'
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa record stop --output dashboard-flow.mp4 | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" --session qa record status | grep -q '"active":false'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4"
file "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4" | grep -Eq 'ISO Media|MP4'
test "$(stat -f %Lp "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mp4")" = "600"
"$CLI" --session qa record start --fps 3 --format mov --quality fast | grep -q '"format":"mov"'
"$CLI" --session qa scroll top | grep -q '"direction":"top"'
"$CLI" --session qa tour --full-page --pace 5000 | grep -q '"durationMs"'
"$CLI" --session qa record stop --output dashboard-flow.mov | grep -q '"name":"dashboard-flow.mov"'
test -s "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mov"
file "$HEADLESS_ARTIFACT_DIR/dashboard-flow.mov" | grep -Eq 'ISO Media|QuickTime'
"$CLI" artifacts list | grep -q '"name":"dashboard-flow.mp4"'
"$CLI" artifacts list | grep -q '"name":"dashboard-flow.mov"'
"$CLI" --session qa back | grep -q 'Designers Dashboard'
"$CLI" --session qa reload | grep -q 'Designers Dashboard'
STEP="capture-hostile"
CAPTURE="$("$CLI" --session qa capture-info)"
echo "$CAPTURE" | grep -q '"engine":"webkit"'
echo "$CAPTURE" | grep -q '"windowId"'
echo "$CAPTURE" | grep -q '"trace"'
STEP="progressive-context-pruning"
"$CLI" --session qa visit "http://127.0.0.1:$PORT/large-document" | grep -q 'Large Operations Handbook'
SUMMARY="$("$CLI" --session qa inspect --context summary --task 'Linux service-account authentication' --limit 8 --budget 700)"
echo "$SUMMARY" | grep -q '"contextMode":"summary"'
echo "$SUMMARY" | grep -q 'Linux service-account authentication'
echo "$SUMMARY" | grep -q '"budget":700'
test "$(printf %s "$SUMMARY" | wc -c)" -lt 3200
OUTLINE="$("$CLI" --session qa inspect --context outline --task 'Linux service-account authentication' --limit 8 --budget 900)"
TARGET_REGION="$(printf %s "$OUTLINE" | sed -n 's/.*"name":"Linux service-account authentication"[^}]*"ref":"\(@r[0-9]*\)".*/\1/p')"
test -n "$TARGET_REGION"
SCOPED_TEXT="$("$CLI" --session qa inspect --context text --within "$TARGET_REGION" --task 'Ubuntu service account' --limit 4 --budget 700)"
echo "$SCOPED_TEXT" | grep -q 'short-lived service account'
SCOPED_ACTIONS="$("$CLI" --session qa inspect --context actions --within "$TARGET_REGION" --task 'copy authentication command' --limit 5 --budget 700)"
echo "$SCOPED_ACTIONS" | grep -q '"name":"Copy authentication command"'
"$CLI" --session qa visit "http://127.0.0.1:$PORT/hostile" | grep -q 'Hostile output fixture'
BOUNDED_SNAPSHOT="$("$CLI" --session qa inspect)"
echo "$BOUNDED_SNAPSHOT" | grep -q '"truncated":true'
test "$(printf %s "$BOUNDED_SNAPSHOT" | wc -c)" -lt 1048576
HOSTILE_DIAGNOSTICS="$("$CLI" --session qa qa report)"
echo "$HOSTILE_DIAGNOSTICS" | grep -q 'hostile forged diagnostic'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"source":"webkit-page-bridge"'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"untrustedContent":true'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"events":500'
echo "$HOSTILE_DIAGNOSTICS" | grep -q '"truncated":true'
if echo "$HOSTILE_DIAGNOSTICS" | grep -q 'hostile-claims-trusted'; then
  echo "hostile page controlled diagnostic provenance" >&2
  fail
fi
"$CLI" session close qa | grep -q '"closed":"qa"'

STEP="configured-foreground-start"
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
"$CLI" config set startup-presentation foreground | grep -q '"startupPresentation":"foreground"'
"$CLI" config get startup-presentation | grep -q '"startupPresentation":"foreground"'
test "$(defaults read "$DEFAULTS_DOMAIN" "$PRESENTATION_KEY")" = "foreground"
FOREGROUND_RESULT="$("$CLI" start)"
FOREGROUND_PID="$(echo "$FOREGROUND_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$FOREGROUND_PID"
FOREGROUND_ACTIVE=0
for _ in {1..100}; do
  if [[ "$(frontmost_pid)" == "$FOREGROUND_PID" ]]; then
    FOREGROUND_ACTIVE=1
    break
  fi
  sleep 0.05
done
if [[ "$FOREGROUND_ACTIVE" != 1 ]]; then
  echo "configured foreground startup did not activate Headless" >&2
  fail
fi
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done

STEP="background-override"
BACKGROUND_RESULT="$("$CLI" start --background)"
BACKGROUND_PID="$(echo "$BACKGROUND_RESULT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$BACKGROUND_PID"
if [[ "$(frontmost_pid)" == "$BACKGROUND_PID" ]]; then
  echo "background launch override did not override the configured foreground default" >&2
  fail
fi
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! kill -0 "$BACKGROUND_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$BACKGROUND_PID" >/dev/null 2>&1; then
  echo "background override host did not stop" >&2
  fail
fi

STEP="durable-authentication-profile"
"$CLI" start --background | grep -q '"ready":true'
STEP="durable-authentication-login"
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=login" | grep -q 'Authentication State'
"$CLI" inspect --text | grep -q 'Cookie state: signed-in'
"$CLI" inspect --text | grep -q 'Storage state: signed-in'
STEP="durable-authentication-first-stop"
PROFILE_RESTART_PID="$("$CLI" status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$PROFILE_RESTART_PID"
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! kill -0 "$PROFILE_RESTART_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$PROFILE_RESTART_PID" >/dev/null 2>&1; then
  echo "host did not exit during durable profile restart" >&2
  fail
fi
STEP="durable-authentication-persisted-state"
"$CLI" start --background | grep -q '"ready":true'
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=check" | grep -q 'Authentication State'
"$CLI" inspect --text | grep -q 'Cookie state: signed-in'
"$CLI" inspect --text | grep -q 'Storage state: signed-in'
STEP="durable-authentication-logout"
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=logout" >/dev/null
"$CLI" inspect --text | grep -q 'Cookie state: missing'
"$CLI" inspect --text | grep -q 'Storage state: missing'
STEP="durable-authentication-second-stop"
LOGOUT_RESTART_PID="$("$CLI" status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$LOGOUT_RESTART_PID"
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! kill -0 "$LOGOUT_RESTART_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$LOGOUT_RESTART_PID" >/dev/null 2>&1; then
  echo "host did not exit while verifying durable logout" >&2
  fail
fi
STEP="durable-authentication-persisted-logout"
"$CLI" start --background >/dev/null
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" inspect --text | grep -q 'Cookie state: missing'
"$CLI" inspect --text | grep -q 'Storage state: missing'
STEP="durable-authentication-profile-clear"
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=login" >/dev/null
"$CLI" profile clear | grep -q '"cleared":true'
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=check" | grep -q 'Authentication State'
"$CLI" inspect --text | grep -q 'Cookie state: missing'
"$CLI" inspect --text | grep -q 'Storage state: missing'

STEP="isolated-session-lifecycle"
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=login" >/dev/null
"$CLI" session create private-a --isolated | grep -q '"isolated":true'
"$CLI" --session private-a visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" --session private-a inspect --text | grep -q 'Cookie state: missing'
"$CLI" --session private-a inspect --text | grep -q 'Storage state: missing'
"$CLI" --session private-a visit "http://127.0.0.1:$PORT/auth-state?action=login" >/dev/null
"$CLI" session create private-b --isolated | grep -q '"isolated":true'
"$CLI" --session private-b visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" --session private-b inspect --text | grep -q 'Cookie state: missing'
"$CLI" --session private-b inspect --text | grep -q 'Storage state: missing'
"$CLI" session close private-a | grep -q '"closed":"private-a"'
"$CLI" session create private-a --isolated | grep -q '"isolated":true'
"$CLI" --session private-a visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" --session private-a inspect --text | grep -q 'Cookie state: missing'
"$CLI" --session private-a inspect --text | grep -q 'Storage state: missing'
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" inspect --text | grep -q 'Cookie state: signed-in'
"$CLI" inspect --text | grep -q 'Storage state: signed-in'
"$CLI" session close private-a >/dev/null
"$CLI" session close private-b >/dev/null
"$CLI" visit "http://127.0.0.1:$PORT/auth-state?action=logout" >/dev/null
"$CLI" session create private-crash --isolated >/dev/null
"$CLI" --session private-crash visit "http://127.0.0.1:$PORT/auth-state?action=login" >/dev/null
CRASHED_HOST_PID="$("$CLI" status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
test -n "$CRASHED_HOST_PID"
kill -9 "$CRASHED_HOST_PID"
for _ in {1..100}; do
  ! kill -0 "$CRASHED_HOST_PID" >/dev/null 2>&1 && break
  sleep 0.05
done
if kill -0 "$CRASHED_HOST_PID" >/dev/null 2>&1; then
  echo "host did not terminate during isolated crash recovery" >&2
  fail
fi
"$CLI" start --background >/dev/null
"$CLI" session create private-crash --isolated >/dev/null
"$CLI" --session private-crash visit "http://127.0.0.1:$PORT/auth-state?action=check" >/dev/null
"$CLI" --session private-crash inspect --text | grep -q 'Cookie state: missing'
"$CLI" --session private-crash inspect --text | grep -q 'Storage state: missing'
"$CLI" session close private-crash >/dev/null
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done

STEP="navigation-allowlist"
assert_page_stays_on_loopback() {
  local reason="$1"
  local waited=0
  local snapshot=""
  while (( waited < 20 )); do
    snapshot="$("$CLI" inspect --context summary 2>/dev/null || true)"
    if print -r -- "$snapshot" | grep -q 'HOST_UNAVAILABLE'; then
      print -r -u2 -- "$reason (host stopped responding)"
      print -r -u2 -- "$snapshot"
      fail
    fi
    if print -r -- "$snapshot" | grep -q '"url":"http://127.0.0.1' \
      && ! print -r -- "$snapshot" | grep -q '"url":"https://example.com'; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 0.1
  done
  print -r -u2 -- "$reason"
  print -r -u2 -- "$snapshot"
  fail
}
ALLOWLIST_START="$("$CLI" start --allow 127.0.0.1)"
echo "$ALLOWLIST_START" | grep -q '"ready":true'
echo "$ALLOWLIST_START" | grep -q '"navigationAllowlist":\["127.0.0.1"\]'
"$CLI" visit "http://127.0.0.1:$PORT/designers/dashboard" | grep -q 'Designers Dashboard'
if ALLOWLIST_VISIT="$("$CLI" visit https://example.com/)"; then
  echo "off-allowlist visit was not blocked" >&2
  fail
fi
echo "$ALLOWLIST_VISIT" | grep -q 'UNSAFE_NAVIGATION'
if ALLOWLIST_CLICK="$("$CLI" click --role link --name 'Off-allowlist site')"; then
  echo "off-allowlist click was not blocked" >&2
  fail
fi
echo "$ALLOWLIST_CLICK" | grep -q 'UNSAFE_NAVIGATION'
"$CLI" visit "http://127.0.0.1:$PORT/allowlist-exits" | grep -q 'Allowlist exits'
if ALLOWLIST_FORM="$("$CLI" click --role button --name 'Leave via form')"; then
  echo "off-allowlist form submit was not blocked" >&2
  fail
fi
echo "$ALLOWLIST_FORM" | grep -q 'UNSAFE_NAVIGATION'
assert_page_stays_on_loopback "form submit left the allowlist"
"$CLI" click --role button --name 'Leave via script' >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "script navigation left the allowlist"
ALLOWLIST_SESSIONS_BEFORE="$("$CLI" session list)"
print -r -- "$ALLOWLIST_SESSIONS_BEFORE" | grep -q '"sessions":\["default"\]'
"$CLI" click --role button --name 'Leave via window' >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "window.open left the allowlist"
ALLOWLIST_SESSIONS_AFTER="$("$CLI" session list)"
print -r -- "$ALLOWLIST_SESSIONS_AFTER" | grep -q '"sessions":\["default"\]'
"$CLI" visit "http://127.0.0.1:$PORT/allowlist-redirect" >/dev/null 2>&1 || true
sleep 0.5
assert_page_stays_on_loopback "redirect left the allowlist"
"$CLI" start --allow 127.0.0.1 | grep -q '"ready":true'
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
"$CLI" start --allow 127.0.0.1 --allow localhost | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
"$CLI" start --allow localhost --allow 127.0.0.1 | grep -q '"ready":true'
"$CLI" start --allow localhost --allow 127.0.0.1 | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
if ALLOWLIST_MISMATCH="$("$CLI" start --allow example.com)"; then
  echo "a conflicting --allow list was accepted on a running host" >&2
  fail
fi
echo "$ALLOWLIST_MISMATCH" | grep -q 'NAVIGATION_ALLOWLIST_CONFLICT'
echo "$ALLOWLIST_MISMATCH" | grep -q 'headless stop'
"$CLI" start | grep -q '"ready":true'
"$CLI" status | grep -q '"navigationAllowlist":\["127.0.0.1","localhost"\]'
"$CLI" stop >/dev/null
for _ in {1..100}; do
  ! "$CLI" status >/dev/null 2>&1 && break
  sleep 0.05
done
"$CLI" start | grep -q '"navigationAllowlist":\[\]'
"$CLI" stop >/dev/null

echo "macOS P2 end-to-end flow passed"
