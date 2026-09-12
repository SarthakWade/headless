# Command reference

Every command the `headless` CLI accepts. Usage lines below are kept verbatim
from `agentHelp` in `Sources/HeadlessProtocol/CLI.swift`, and a protocol-suite
test (`docsCommandReferenceMatchesHelp`) fails when they drift apart.

All commands talk to one persistent host over a private per-user Unix socket.
There is no TCP listener and no way to execute arbitrary JavaScript.
Page-derived strings are always marked as untrusted content, and every
response that can be large reports what it left out (`truncated`, `omitted`,
`contextStats`).

Global options:

```sh
headless --session NAME <command>   # target a named session
headless <command> -- --value       # stop option parsing; literal values
```

## Host lifecycle

```sh
version | --version
start [--background|--foreground] [--allow PATTERN]... [--supervised] | status | stop | runtime
profile clear
config list | config describe KEY | config get KEY
config set KEY VALUE | config reset KEY
session create [NAME] [--isolated] | session list | session close NAME
capabilities
schema
```

- `start` launches the host if it is not already running. Repeatable
  `--allow PATTERN` (comma-separated values also accepted) restricts agent
  navigation to matching hosts; omit it to keep unrestricted HTTP(S). `status`
  reports the active `navigationAllowlist` (empty means unrestricted). Changing
  the list on a running host is rejected (`headless stop` first); a later
  `start --allow` with the same hosts in any order is a no-op. `stop`
  controls the host afterwards. `runtime` reports which engine is active and
  where it came from.
- `start --supervised` is for SDK-owned lifecycle management. It refuses to
  attach to an existing host, verifies the launched host PID, and shuts the host
  down when the launcher input closes or the launcher exits. Normal starts
  remain shared and detached.
- `schema` prints the versioned SDK contract generated from the Swift request
  definitions. It is local-only and includes request and response envelopes,
  command parameters and bounds, errors, compatibility, cancellation, and
  security metadata. The checked-in golden copy is `sdk/protocol-schema.json`.
- `config list` discovers agent-visible settings. `config describe KEY` reports
  its type, default, platform scope, access class, effect timing, current value,
  and whether the current platform supports it. `config get`, `set`, and
  `reset` read, change, or restore a built-in default.
- `startup-presentation` is an `agent-writable` macOS enum with `background`
  and `foreground` values. It takes effect on the next host start. Linux lists
  and describes it as unsupported, then rejects `get`, `set`, and `reset` with
  `UNSUPPORTED_CAPABILITY`.
- Normal sessions are windows (macOS) or tabs (Linux) sharing **one browser
  profile**. Cookies and local storage are shared across normal sessions and
  survive host and machine restarts. `session create NAME --isolated` instead
  creates a fresh engine-native ephemeral context that shares no cookies,
  storage, cache, permissions, or authentication state with the normal profile
  or another isolated session. Closing it destroys that context. Isolated
  sessions cannot list or use normal-vault credentials. They can enroll aliases
  through `auth login --interactive`; those credentials
  stay only in that isolated session's memory and are erased on close or host
  termination. `profile clear` closes every session, including isolated
  sessions, and permanently
  removes normal-profile cookies, storage, caches, and permissions.

## Settings

Settings are local CLI operations and never enter the browser protocol or MCP.
Each registry definition has a typed value, validated default, platform scope,
effect timing, and one access class:

- `agent-readable` is visible to agent callers but cannot be changed by them.
- `agent-writable` is visible and mutable by agent callers.
- `user-only` is omitted from `list` and rejected as unknown by `describe`,
  `get`, `set`, and `reset` through the agent CLI. A future trusted native or
  OS-authenticated surface is required to access it.

On macOS, the registry uses the `com.headless.app` preferences domain and keeps
the existing `AgentStartupPresentation` storage key, avoiding migration or
resurrection of a stale value. Linux uses
`$XDG_CONFIG_HOME/headless/settings.json`, falling back to
`~/.config/headless/settings.json`. The Linux backend is bounded and versioned,
requires current-user ownership with `0700` directory and `0600` regular files,
rejects links and malformed state, serializes writers, and atomically replaces
and synchronizes the file.

Security invariants are not settings. The registry cannot enable arbitrary
JavaScript, a TCP listener, unsafe schemes, downloads, sandbox bypasses,
sensitive-diagnostic bypasses, or credential authorization. Those boundaries
remain fixed and fail closed.

## Credential vault

```sh
credentials list [--origin URL]
credentials add --origin URL --alias NAME --interactive
credentials rename --origin URL --alias OLD --to NEW
credentials remove --origin URL --alias NAME
auth login --challenge ID --account ALIAS | auth login --interactive
```

Credential commands are local-only and never enter the browser protocol or MCP.
`credentials add` reads the username and password from `/dev/tty`, hides and
confirms the password, rejects redirected standard input, and restores terminal
echo after success, failure, or a handled signal. Passwords are never accepted
in arguments or environment variables and never appear in command output.

Origins are exact HTTPS origins with lowercase hosts and normalized default
ports. Paths, queries, fragments, embedded credentials, and public HTTP origins
are rejected. HTTP is accepted only for `localhost`, `127.0.0.1`, and `::1`
development origins. Aliases are 1-64 ASCII letters, numbers, periods,
underscores, or hyphens and are case-insensitively unique per origin.

macOS stores passwords in the encrypted default user Keychain with an empty
trusted-app list and passphrase protection on the decryption ACL. A fresh
broker-owned native user-presence gate applies to every retrieval. The vault
uses no shared access group. Local/ad-hoc builds are reported as
`local-unnotarized`; rebuilds may make macOS ask again. This deliberately uses
the file-based default Keychain because Apple's biometric data-protection Keychain requires a
provisioning-profile-authorized app identity. The file-based API is deprecated,
so a future Developer ID release must migrate the same record semantics rather
than silently changing them. Linux uses the system
Secret Service through `/usr/bin/secret-tool` and the current user's validated
`/run/user/UID/bus` socket. Caller-supplied D-Bus addresses are ignored. Vault
commands are time-bounded; missing, locked, denied, timed-out, or unknown
backend failures fail closed without creating a plaintext store. Listing
reads only a private `0600` nonsecret alias index inside a `0700` directory.
Corrupt, oversized, symlinked, foreign-owned, or permissive metadata fails
closed instead of being replaced.

Secrets are not exported or backed up by Headless; the OS vault owns its own
backup and recovery behavior. Index writes are atomic. A durable transaction
journal rolls back interrupted additions and completes interrupted deletions
on the next vault command. Renames atomically update only the nonsecret index.
Unknown future index schemas require an explicit migration. Normal-vault
aliases are unavailable to private contexts. When Headless confirms a
top-level, same-origin POST login form, the blocked command returns
`AUTH_REQUIRED` with a 60-second, single-use challenge and only the aliases for
that exact origin. The challenge is also bound to a per-document identity, so
a same-origin reload invalidates it.
`auth login` asks the operating-system vault to authorize the selected alias,
fills inside the trusted host, submits once, and reports whether the flow
redirected, needs additional verification or a passkey, rejected the
credentials, or requires fresh inspection because verification is ambiguous.
It never retries the original blocked action.

`auth login --interactive` instead opens trusted input owned by Headless. On
macOS this is a native secure dialog; on Linux it reads the username and hidden
password from the foreground `/dev/tty`. It can create a challenge from the
current confirmed form, so a challenge ID is optional. After Headless verifies
that the form disappeared or redirected, it separately asks whether to save,
with No as the default. Saving requires a user-entered alias and sends the
candidate secret only through a bounded pipe to the trusted broker. Failed,
unverified, additional-verification, and passkey continuations never offer to
save. Raw `fill` remains available and never saves implicitly.

Heuristic login hints do not create challenges. Cross-origin frames are not
inspected or filled and are reported as an explicit continuation. Public HTTP
origins cannot use saved credentials. Authentication metadata is marked as
untrusted page-derived content. A denied
or unavailable vault fails closed without filling; denial leaves the challenge
available for a deliberate retry. Existing raw `fill` commands remain
available for test credentials and never save values implicitly. Headless can
redact those values from its own output and artifacts, but cannot remove a
password that a user already supplied from a model provider's transcript.
Saved entry does not put the password in an input-event payload. Page
diagnostics are suppressed during credential submission, discarded afterward,
and restored only after the password field is cleared or a new document commits.

Linux can enroll and manage Secret Service records, but saved use currently returns `USER_PRESENCE_UNAVAILABLE`:
an unlocked Secret Service does not guarantee a fresh prompt, and Headless does
not silently weaken the per-use authorization policy.

## Navigation and interaction

```sh
visit URL
inspect [--context summary|outline|text|actions|full] [--task TEXT]
        [--within @rN] [--limit N] [--budget TOKENS] [--depth N] [--text]
click REF | click --role ROLE [--name NAME]
fill REF TEXT | fill REF -- TEXT_WITH_LITERAL_FLAGS | press KEY
upload REF --artifact FILE | upload --role ROLE [--name NAME] --artifact FILE
scroll [up|down|top|bottom] [--amount PX]
back | reload
wait [--settled] [--url PATTERN] [--text TEXT] [--timeout MS]
tour [--full-page] [--pace PX_PER_SECOND]
```

```sh
visit URL
back | reload
```

- `visit` accepts HTTP/HTTPS only. Bare hostnames normalize to HTTP
  (`localhost:3000` → `http://localhost:3000`). URLs carrying credentials are
  rejected. Downloads and unsafe schemes never navigate.
- `inspect` is how an agent sees the page. Element references (`@eN`) belong to
  the most recent inspection and are reissued on every inspect; region
  references (`@rN`) stay resolvable so you can outline first and scope later.
  See "Reference lifetime" in P1.md for the full contract.
- `click`, `fill`, `upload`, and `press` accept either a reference or a semantic
  target (`--role`/`--name`). On Linux these dispatch trusted CDP input events;
  WebKit uses synthetic input, and capabilities declare the difference.
- `fill REF -- value` keeps leading dashes in the value. Flow recordings never
  record fill values.
- `upload` attaches a file that already lives in the private artifact store.
  `--artifact` is a validated basename only, never a filesystem path. File
  bytes never travel on the socket. Linux Chromium attaches through
  `DOM.setFileInputFiles`; macOS WebKit returns `UNSUPPORTED_CAPABILITY`.
  Downloads stay denied. Agent-facing surfaces cannot import local files;
  operator-file import remains deferred until Headless has a trusted native
  picker or broker that can prove explicit user approval.
- `wait --timeout` and the tour duration are bounded; unbounded waits are
  rejected at parse time.

## Capture and evidence

```sh
capture-info
screenshot [REF | --role ROLE --name NAME | --full-page] [--format png|jpg|jpeg] [--output FILE] [--clipboard]
screenshot --full-page --format pdf [--output FILE.pdf]
screenshot --every-viewport|--by-section [--format png|jpg|jpeg] [--output PREFIX]
artifacts list
record start [--fps N] [--format mp4|mov|webm|gif] [--quality fast|balanced|high] [--output FILE]
record status | record stop [--output FILE]
qa report | qa clear
report create [--output REPORT.json]
```

- Screenshots and recordings become private artifacts in the per-user store,
  created `O_EXCL` with `0600`. They never overwrite and never leave it unless
  you copy them.
- `artifacts list` reports the bounded contents of the private store. `upload`
  can attach an allowed existing basename from that list; it is not a local
  file reader or a download manager.
- `--clipboard` capture is macOS only. Linux rejects clipboard capture because
  VM clipboards are not a reliable boundary.
- PDF screenshots and element-scoped capture follow the engine matrix reported
  by `capabilities`.
- The recorder captures browser pixels through ffmpeg only: no OS chrome, no
  microphone, no system audio.

## Diagnostics

```sh
console list [--level LEVEL] [--limit N]
network list [--failed] [--status CODE] [--limit N]
network get REQUEST_ID
network emulate [--offline] [--latency MS] [--download-kbps N] [--upload-kbps N]
network mock set URL --body BODY [--status CODE] [--content-type MIME]
network mock clear
styles get REF | styles get --role ROLE [--name NAME] [--property CSS_PROPERTY]
cookies list [--values]
storage list [--scope local|session|all] [--values]
visual compare BEFORE.png AFTER.png [--output DIFF.png]
performance get | animations list
flow start | flow stop [--output FLOW.json] | flow run FLOW.json
```

- `network emulate` and `network mock` are Chromium-engine features. WebKit
  returns `UNSUPPORTED_CAPABILITY` instead of approximating them.
- `cookies list --values` and `storage list --values` are double-gated: the
  flag plus `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1` on the host. Without both
  you get names and metadata, never values.
- `visual compare` accepts only existing private PNG artifacts, not filesystem
  paths, and writes its difference image back into the artifact store.
- Flows replay recorded commands but skip every `fill` value by design; rerun
  fills explicitly when you replay. `upload` may be recorded with the artifact
  basename only; replay needs that same store name.

## Where to go next

- Phase contracts: [P0.md](P0.md), [P1.md](P1.md), [P2.md](P2.md)
- Engine differences matrix: `headless capabilities`
- Benchmark method: [BENCHMARK.md](BENCHMARK.md)
