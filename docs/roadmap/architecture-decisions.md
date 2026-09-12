# Architecture decisions

Companion to [ROADMAP.md](../ROADMAP.md). This document records the keep/change
decisions for the codebase as it stands in August 2026, with reasons, so the
next months of work don't re-litigate them. Format per decision: **Decision →
Status → Rationale → Consequences / revisit trigger.**

---

## 1. Core language: keep Swift (decided, with a revisit trigger)

**Decision:** the core stays Swift — the shared `HeadlessProtocol` library,
the CLI, the MCP server, and both hosts. No Rust/Go rewrite.

**Status:** decided 2026-08-04 (owner delegated the recommendation; this is
it).

**Rationale:**

- The investment is already amortized: ~7.5k lines of working, tested Swift
  spanning both platforms, with zero third-party dependencies and a QA
  evidence trail proving behavior. A rewrite resets all of that for a benefit
  that is mostly hypothetical.
- The macOS host is irreducibly Swift (Cocoa/WebKit). A Rust/Go core would
  _add_ a language boundary (FFI or IPC between the Swift app and the new
  core) rather than remove one.
- Swift on Linux is genuinely fine here and proven in this repo: static
  stdlib builds in Docker (`Dockerfile.linux`), stripped binaries, no runtime
  to install.
- The real pain attributed to "Swift" is actually **duplication** (two hand-
  written hosts) and **stringly-typed errors** — fixable in place (decision
  §3), far cheaper than a rewrite.
- Contributor-pool concerns are mitigated by the agent-first reality: this
  repo is built to be worked on by coding agents, and the rule files +
  contract docs matter more than language familiarity.

**Costs accepted:**

- Windows: Swift-on-Windows exists (the Browser Company ships it) but the
  toolchain is rougher than Rust/Go. Accepted because Windows is a stretch
  goal (roadmap Phase W), and Phase 2's engine split confines the port to
  transport + process-spawn + artifact backends.
- Binary distribution stays per-platform build scripts rather than
  `cargo`/`goreleaser` conveniences. Phase 3 does this work once.

**Revisit trigger:** if Windows-native is ever promoted to must-have _and_ a
spike shows Swift-on-Windows cannot pass the Linux E2E scenario within ~2
weeks of effort, revisit with a concrete proposal: keep the WKWebView app in
Swift, move `HeadlessProtocol` + Chromium host to Rust, talk over the existing
JSON protocol (which is language-neutral by design and makes this migration
tractable later). Do not drift into a rewrite without hitting this trigger.

## 2. Monorepo layout: keep, with one addition

**Decision:** keep the pnpm monorepo (`apps/headless` Swift package,
`apps/web` Next.js, empty `packages/`). Node is only the workflow driver and
the web app; the product has no runtime Node dependency — keep it that way.

**Addition:** when benchmark/docs generation lands (roadmap Phase 5),
generated machine-readable outputs (benchmark JSON, command tables) live in
`packages/` or `apps/headless/build/` with explicit provenance, so the web app
imports data instead of transcribing it.

## 3. Two hosts → one `HostCore` + `BrowserEngine` interface (change, Phase 2)

**Status:** implemented 2026-08-10.

**Decision:** extract everything currently duplicated between
`apps/headless/main.swift` (macOS, ~340-line dispatch) and
`apps/headless/LinuxHost/main.swift` (~280-line dispatch) into a shared
`HostCore` in `HeadlessProtocol` (or a sibling target):

- one command dispatcher, one flow replay loop, one screenshot-series loop,
  one trace ring buffer, one report bundler, one error→code mapping;
- a small `BrowserEngine` protocol implemented twice: `WebKitEngine` (wraps
  `AgentBridge`) and `ChromiumEngine` (wraps `BrowserProcess`), later
  `ChromiumEngine` on Windows;
- **typed errors** (`HostError` enum carrying the protocol error code)
  replacing the `message.contains("ELEMENT_NOT_FOUND")` string matching on
  both hosts and in `AgentBridge.swift:416-418`;
- single definitions for the constants currently written 2–4×: blocked/caution
  extension sets (Swift _and_ the JS copy get a cross-check test), screenshot
  bounds, artifact charset, local-address list, inspect/console/storage/scroll
  enums, numeric bounds (CLI and validator currently disagree — e.g. scroll
  amount `>0` vs `>=0.1`).

**Rationale:** every new verb is currently written twice and the compiler only
checks enum exhaustiveness, not behavioral equivalence; silent divergence has
already happened (report `page` shape, capture-info shape, tour timeout, JPEG
quality path, PDF raster-vs-vector). This refactor is the precondition for
Windows and for keeping principle "one contract" true.

**Non-goal:** merging the engines' _capabilities_. Divergent capability stays
explicit (`UNSUPPORTED_CAPABILITY`); the point is that the _common_ path is
single-sourced and the divergent one is declared, generated into
`capabilities`, and asserted by tests.

**Capability-matrix consequence (implemented 2026-08-10):** each engine owns
one exhaustive profile used by both `headless capabilities` and the active
host's additive `ping.capabilities` field. Profiles partition every protocol
command into supported and unsupported sets and declare behavioral differences
that cannot be made identical without weakening an engine. This compatible
response addition does not bump protocol 0.5.

## 4. Wire protocol: keep as-is, version bump only when necessary

**Decision:** keep newline-delimited JSON over the private Unix socket,
version `"0.5"`, strict decoding, per-command parameter allow-lists, 1 MiB
frames. The protocol is deliberately language- and transport-neutral — that
neutrality is what keeps both the Windows port and the (rejected-for-now)
Rust option cheap.

**Amendments planned (backlog §A5, §G3):**

- Response-side bounding: `qa report` and `artifact.list` can exceed the 1 MiB
  frame today and surface a misleading `INVALID_REQUEST`. Add pagination
  (`--limit/--cursor`) or server-side truncation with `truncated: true`,
  consistent with the pruning philosophy. This is a compatible addition.
- Response `id` must echo the request `id` and clients should verify it
  (today failure paths return `id:"unknown"` and the client never checks).

**Rejected:** gRPC/protobuf, TCP+TLS, HTTP. They add dependencies, listeners,
or both, against principle 6 (local-first security).

## 5. Transport & isolation: keep Unix socket + peer-UID; abstract for Phase W

**Decision:** keep `/tmp/headless-<uid>` `0700`/`0600` + `getpeereid` /
`SO_PEERCRED` as the Unix mechanism. For Windows (Phase W), define a
`ControlTransport` seam in Phase 2 so a named-pipe + SID-ACL backend can slot
in without touching `HostCore`.

Known hardening items stay on the backlog (§A): accept-loop error spin,
hard-coded `SO_PEERCRED = 17`, `HEADLESS_SOCKET` asymmetry, no peer-UID test.

**Decision (unchanged from P0):** remote control remains deferred until it has
authentication, authorization, and transport security. SSH + stdio MCP remains
the only remote story. A hosted service is out of scope for this roadmap
(owner decision 2026-08-04: package-manager distribution, no cloud offering).

## 6. Windows strategy: Chromium-host port behind the Phase 2 seam (deferred)

**Decision:** Windows is a stretch goal (owner decision 2026-08-04:
"later / best-effort", not required for done). When attempted:

- **Engine:** the Chromium engine only. The WKWebView host is never ported.
- **Port surface (known and bounded):** `Transport.swift` (named pipes +
  SID peer check), `Artifacts.swift` (ACLs instead of POSIX modes; `O_EXCL`
  equivalent via `CREATE_NEW`), the spawn half of `BrowserProcess.swift`
  (`CreateProcess` + inheritable HANDLEs for `--remote-debugging-pipe` —
  Chromium on Windows takes handles via `STARTUPINFO`, not fd 3/4), the I/O
  half of `CDP.swift` (overlapped I/O instead of `poll`), signal handling
  (console control handler), `ChromiumRuntime.swift` (registry + Program
  Files + Edge discovery, `;` PATH splitting), ffmpeg `.exe` discovery, and
  re-authoring the shell scripts (the E2E suite is POSIX sh).
- **Portable already:** `Protocol.swift`, `CLI.swift`, `AgentRuntime.swift`
  (the JS is engine-agnostic), `Diagnostics.swift`, `Flows.swift`,
  `CaptureFormats.swift`, `ScreenshotSeries.swift`, `Recording.swift` (modulo
  discovery), `MCP/main.swift`.
- **Interim answer (Phase 3):** published Docker image + WSL2 documented as
  the supported Windows path.

**Update — 2026-08-22, Swift-for-Windows spike failed.** Per PLAN.md step 1,
we attempted to build the shared core with Swift 6.3.3 for
x86_64-unknown-windows-msvc on a real `windows-latest` runner
(workflow: `.github/workflows/windows-spike.yml`, branch
`spike/windows-core`; run logs preserved there). Findings:

1. Cross-compilation from Linux is not possible; Swift SDK bundles target
   Linux and WebAssembly only.
2. The winget toolchain is broken out of the box: runtime DLLs are split
   across two install trees (`Toolchains\6.3.3+Asserts\usr` and
   `Runtimes\6.3.3\usr`). `swift.exe` exits `STATUS_DLL_NOT_FOUND` until the
   trees are merged by hand.
3. After repair, no Swift code compiles: even `swiftc hello.swift` fails with
   "unable to load standard library for target x86_64-unknown-windows-msvc",
   both via SPM and direct `swiftc`. Suspected cause is the `+Asserts`
   toolchain packaged against a non-asserts runtime, or missing stdlib
   modules in the package.

Consequence: the "portable already" claim above does not hold on today's
toolchain, so a Windows engine adapter written in Swift is not viable.
WSL2/Docker remains the only supported Windows path. A native Windows host
requires either a materially better Swift-for-Windows toolchain or a scoped
Rust port of the shared core; revisit only when native Windows becomes an
actual product requirement, and record a new decision entry first.

## 7. macOS engine: keep WKWebView as the visible-browser experience

**Decision:** keep the WKWebView host as macOS's default engine. It is the
differentiated experience (a real visible browser window a human can watch the
agent drive, passkey story, clipboard) and it exercises the "same contract,
two engines" discipline that keeps the protocol honest.

**Acknowledged limits (stay documented, not "fixed"):** diagnostics are
best-effort (no full network event stream), no network emulation/mocking,
raster PDF. If agent demand ever requires full-fidelity diagnostics on macOS,
the answer is offering the Chromium engine on macOS as an _additional_
runtime behind the same CLI (the Linux host already builds on macOS-adjacent
Foundation APIs) — not hacking WKWebView. That would be a new decision entry.

**Resolved (backlog §B8, decision §18):** the page-world QA diagnostics bridge
is documented as detectable and forgeable; the host fixes its provenance,
bounds it per document, and marks its evidence untrusted. Agent actions and
inspection remain in `WKContentWorld`.

## 8. In-page action model: trusted CDP input on Linux

**Decision:** `click`/`fill`/`press` keep one portable command contract. On
Linux, the isolated agent world resolves the semantic target, applies the
existing link-safety policy, focuses it, and returns a bounded visible point;
the host then acts through CDP `Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`, and `Input.insertText`. Page handlers consequently
receive trusted browser input. Fill values travel directly in the validated
CDP command and are never returned or added to flows.

WKWebView retains the synthetic isolated-world implementation because it has
no equivalent safe host input API. `capabilities` declares `trusted-cdp` for
Chromium and `synthetic-dom` for WebKit. This is an engine fidelity difference,
not a second set of verbs.

**Rationale:** synthetic events fail on real-world widgets (rich editors,
canvas apps, key-repeat handlers); Chromium can do better cheaply; the
contract machinery from Phase 2 makes the divergence declarable.

## 9. Recording: keep the ffmpeg pipe design; revisit codec

**Decision:** keep `BrowserRecording`'s design (host-captured PNG frames piped
to an allow-listed ffmpeg; browser-frames-only recording scope). Revisit the
**mpeg4 (Part 2) codec choice** in Phase 3: it exists to avoid x264
licensing, but produces large, poorly-compatible files. Evaluate defaulting
MP4 to H.264 where a system encoder is available (VideoToolbox on macOS) or
making WebM/VP9 the recommended default in docs, keeping mpeg4 as fallback.
Add palettegen to the GIF path (quality, cheap).

## 10. Agent runtime: one embedded JS source is correct; injection cost is not

**Decision:** keep the single shared `agentRuntimeJavaScript` string as the
one implementation of page-side semantics for every engine (it is what makes
"same contract" real). Fix the delivery mechanics (backlog §B7):

- Linux re-creates the isolated world and re-sends ~30 KB of JS on **every**
  evaluate — 3 CDP round trips per command, polled at 20 Hz by `wait`
  (`BrowserProcess.swift:777-834`). Cache the world/context per navigation and
  use `Page.addScriptToEvaluateOnNewDocument`.
- macOS re-sends the same source per call through `callAsyncJavaScript`;
  install once per navigation via `WKUserScript` in the agent content world.
- Extract the JS to a `.js` resource compiled into the binary (SwiftPM
  resources) so tooling/tests stop regex-extracting it from a Swift string
  literal (`Tests/agent-runtime.test.mjs`'s `/#"""…"""#/` coupling).

**Status:** implemented 2026-08-10. The source is now the compiled
`Resources/AgentRuntime.js`; WebKit installs it in `HeadlessAgent` at document
start, while Chromium installs it with
`Page.addScriptToEvaluateOnNewDocument`, caches the isolated context for the
document, and invalidates or retries it across navigation races. Distribution
scripts install the generated resource bundle alongside each host executable.

## 11. Session model: document shared-profile reality; isolation is a future opt-in

**Decision:** sessions are windows (macOS) / tabs (Linux) sharing one
profile — cookies and storage are shared across sessions on both engines. This
matches the "persistent logged-in browser" product idea, so keep it as the
default, but **document it loudly** (it reads like an isolation boundary and
is not). If per-session isolation is wanted later, the Chromium engine gets
`Target.createBrowserContext` behind a `session create --isolated` flag; the
WKWebView engine would declare `UNSUPPORTED_CAPABILITY` or use non-persistent
`WKWebsiteDataStore`. New decision entry required when scheduled.

## 12. Versioning: unify on the git tag (change, Phase 3)

**Status:** implemented 2026-08-12.

**Decision:** the git tag becomes the single version source: injected at build
time (already works via `HEADLESS_VERSION`), reported by a new `headless
--version`/`version` command and in `ping`, matched by `package.json`, MCP
`serverInfo` (today it reports protocol version "0.5" as the server version),
and the website. Protocol version stays independent (wire compatibility ≠
product version). CHANGELOG generated per tag.

## 13. Web app: keep Next.js; move content to generated sources (Phase 5)

**Status:** implemented 2026-08-27.

**Decision:** keep `apps/web` on Next.js/Tailwind — no framework change. The
architectural change is **content provenance**: benchmark numbers, command
tables, and docs prose must be imported from repo artifacts (benchmark JSON
emitted by `benchmark.sh`, command reference generated from `CLI.swift`'s
parser/help, shared markdown) instead of hand-copied into TSX/TS in three
places. Also: delete dead visual code (`side-rays.tsx`/`ogl`, unused assets),
reconsider shipping two WebGL bundles for decoration, add deploy pipeline +
CI, metadata/sitemap/404. Details: backlog §F.

The website now validates and derives its benchmark presentation from the
generated benchmark JSON. Its rendered and copyable documentation share the
README and generated command reference as build-time sources, with a web lint
gate that fails on missing or malformed provenance instead of preserving a
stale hand-written fallback.

## 14. Testing architecture: promote the conformance suite (Phase 1–2)

**Status:** implemented 2026-08-10.

**Decision:** keep the three-layer shape (protocol unit suite, jsdom runtime
suite, per-platform E2E), and add the missing keystone: a **cross-engine
conformance runner** — one scenario file executed against both engines
asserting identical JSON shapes (or declared capability errors), replacing
today’s hand-mirrored `macos-e2e.sh`/`linux-e2e.sh` assertions that have
already drifted. The hand-rolled no-XCTest runner is fine (it keeps Linux
docker runs trivial); don't churn it to a framework.

The portable `Tests/conformance.sh` scenario is invoked by both platform E2E
suites. It asserts the same response fields for shared behavior and consults
the generated engine profile only for declared differences, so adding an
engine or changing a shared response requires updating one executable contract.

## 15. Distribution architecture (Phase 3, owner-decided)

**Decision (owner, 2026-08-04):** package managers, no hosted service.
Concretely: Homebrew tap (notarized), Linux curl installer + GHCR-published
Docker image, npm binary-wrapper for JS-stack reach, winget only with Phase W.
Checksums on everything; keep release CI's script-reuse design (the workflow
calls the same `build.sh`/`test.sh` a developer runs — preserve that
property when adding PR CI).

## 16. CLI values preserve shell argument boundaries (decided)

**Decision:** global `--json` and `--session` options are recognized only
before the first `--` sentinel. The sentinel is removed before command
parsing. `fill` accepts its text as exactly one shell argument rather than
joining multiple arguments with inserted spaces.

**Status:** decided 2026-08-10 while resolving backlog §A6.

**Rationale:** typed values are data and must reach the browser byte-for-byte
as represented by the Swift string. Searching the whole argv for global flags
could silently remove literal text, while joining tokens normalized tabs and
repeated spaces. Standard shell quoting plus an end-of-options sentinel makes
the boundary explicit and testable.

**Consequences:** callers quote multi-word fill text and place `--` before a
value containing a literal `--json` or `--session`. This changes only CLI
parsing; the wire protocol and protocol version remain unchanged.

## 17. MCP exposes the full remote-command surface with pessimistic annotations

**Decision:** keep `stop` and `session close` callable through the single
argv-based MCP tool. Describe the tool as state-mutating and explicitly set
the MCP annotations `readOnlyHint: false`, `destructiveHint: true`,
`idempotentHint: false`, and `openWorldHint: true`.

**Status:** decided 2026-08-10 while resolving backlog §C2.

**Rationale:** the MCP adapter deliberately mirrors the remote CLI surface.
Special-casing two valid remote commands in the adapter would create policy
drift and prevent an MCP operator from recovering a wedged host or cleaning up
a session. The same tool already navigates, clicks, fills, and changes browser
state, so describing it as universally "safe" was inaccurate. Because MCP
annotations apply to the whole tool rather than individual argv variants, the
tool must advertise the risk of its most destructive valid invocation.

**Consequences:** trusted MCP clients can require confirmation for the tool,
and callers can still invoke the complete browser-command surface. Annotations
are risk metadata, not authorization; the private socket, peer-UID check,
protocol validation, and host-enforced safety rules remain the security
boundary. Local-only commands such as `start` remain rejected by the adapter.
This changes MCP discovery metadata only and does not bump the wire protocol.

## 18. WebKit page diagnostics are explicitly untrusted evidence

**Decision:** keep the macOS console/fetch/XHR observer in the page content
world, while keeping every agent action and inspection helper in the named
`HeadlessAgent` isolated world. Treat all diagnostic output on both engines as
untrusted page evidence. The macOS host assigns the fixed source
`webkit-page-bridge`, ignores a page's claimed source, accepts at most 500
bridge messages per document, and reports rejected messages as truncation.

**Status:** decided 2026-08-10 while resolving backlog §B8.

**Rationale:** WKWebView exposes neither page console messages nor a complete
subresource network stream to an isolated content world. Patching the page's
console, fetch, and XHR APIs is therefore best-effort observation, not a
security boundary: the page can detect, replace, invoke, or spam that bridge.
Removing it would discard useful QA evidence; presenting its messages without
trust metadata would let a hostile page counterfeit host facts. Fixed native
provenance, a native acceptance cap, and pervasive untrusted markers preserve
the evidence without overstating its authority.

**Consequences:** protocol 0.5 adds `untrustedContent: true` to diagnostic
reports, events, derived issues, console listings, and network listings/details.
Consumers must not interpret diagnostic text or URLs as instructions. Native
navigation and download events use the same conservative marker because they
can contain page-selected URLs. A hostile-page macOS E2E test locks source
override, the 500-event bound, and truncation reporting.

## 19. macOS agent startup does not steal focus by default

**Decision:** windows created by CLI-launched macOS agent hosts are visible but
ordered behind the user's current application. `headless start --foreground`
and `--background` override presentation for a newly launched host. Users can
change the persistent default with the validated `headless config set
startup-presentation foreground|background` command and inspect it with
`headless config get startup-presentation`. Presentation choices never reorder
a host that is already running. Direct GUI launches retain normal foreground
behavior.

**Status:** implemented 2026-08-12.

**Rationale:** persistent agent automation should not interrupt the user's
keyboard and visual focus merely because a host or session starts. Keeping the
window visible preserves observability, screenshots, recording, and WebKit
rendering without making background automation disruptive. Making foreground
activation explicit still supports interactive demonstrations and debugging.

**Consequences:** automatic startup and `headless start` use the configured
presentation on macOS, falling back to background. Session windows created by
that host follow the same policy. Launch flags take precedence over the saved
setting. Linux behavior and the wire protocol are unchanged; presentation
configuration fails there with `UNSUPPORTED_CAPABILITY`. macOS E2E coverage
asserts the real frontmost process for configured background and foreground
startup, session creation, running-host no-op behavior, and launch overrides.

## 20. Developer ID releases omit unprovisioned passkey entitlement

**Decision:** direct macOS releases are universal Developer ID Application
builds with hardened runtime, secure timestamps, notarization, and stapling.
They omit `com.apple.developer.web-browser.public-key-credential` by default.
The build accepts that restricted entitlement only when an Apple-approved
provisioning profile and entitlement file are both supplied explicitly for
`com.headless.app`.

**Status:** implemented 2026-08-12 for Phase 3 distribution.

**Rationale:** Apple's Developer ID capability set does not generally include
the restricted web-browser passkey entitlement. Claiming it without matching
provisioning approval can make macOS terminate the app and can fail
notarization. Shipping a signed app that launches reliably is stronger than
advertising a passkey path the distribution identity cannot support. The host
already detects its own entitlement and hides WebAuthn when absent so sites can
offer password, phone, or other fallback sign-in.

**Consequences:** normal Homebrew and ZIP installs do not expose WKWebView
passkeys. Apple approval can enable them later without changing the protocol:
the release operator supplies both provisioning inputs and the existing runtime
check detects the granted entitlement. Tagged builds fail rather than falling
back to ad-hoc signing or skipping notarization. Pull-request dry runs still
exercise the universal package path with an ad-hoc signature and no Apple
credentials.

---

## 21. Rust port of the shared core, scoped to the protocol layer first

**Status:** decided 2026-08-22 (owner approved after the Windows spike).

**Decision:** the Swift-for-Windows spike (§6 update) failed, so a native
Windows host needs the shared core in a language whose toolchain actually
works on Windows. We port the shared core to Rust, incrementally and without
disturbing the shipping Swift product:

- **Scope:** `Sources/HeadlessProtocol/` semantics — protocol types,
  validation, navigation boundaries, artifact-name rules, bounds. Later
  increments: transport, CLI parser, then a Chromium engine host that ports
  the Linux CDP logic (`BrowserProcess.swift`, `CDP.swift`) so macOS, Linux,
  and Windows all run the same Chromium engine.
- **Not in scope:** the agent runtime JS (stays as-is), the WKWebView macOS
  host (stays Swift), the protocol version or wire format (unchanged; both
  implementations speak protocol 0.5).
- **Verification:** the Rust crate carries its own tests mirroring the Swift
  protocol suite's security-critical cases (unsafe URL rejection, credential
  embedding, frame caps, strict field validation), and CI builds it natively
  on Linux **and Windows** from day one.
- **Dependencies:** `serde`/`serde_json` only. The zero-third-party rule was
  a Swift-host decision; for Rust these two are the ecosystem baseline and
  are pinned.

**Progress, 2026-08-27:** #140 adds the platform-neutral connection/listener
seam, bounded newline framing, response correlation, and the secure Unix
backend. The Unix implementation preserves the private `0700` runtime,
`0600` socket, effective-UID peer authorization, stale-socket safety, and
live-endpoint protection. This does not implement or claim Windows transport;
the named-pipe, ACL, and SID-authentication backend remains a separate step.

The Swift product remains the reference implementation until the Rust core
passes an equivalent conformance suite; only then can it start replacing
hosts. Nothing in this decision changes the hard rules: no arbitrary-JS verb,
no TCP listener, fail closed, bounded everything.

## 22. Optional host origin allowlist on `headless start`

**Decision:** `headless start --allow PATTERN` installs a process-wide host
origin allowlist for agent navigation. Repeatable `--allow` flags and
comma-separated values in one flag are both accepted. Omitting `--allow`
keeps today's behavior: any otherwise-legal HTTP(S) URL. Presentation flags
stay macOS-only.

The matcher is a small `NavigationAllowlist` type in `HeadlessProtocol`, used
as an extra conjunct in `agentMayNavigate`. It cannot add `file:`,
`javascript:`, credentials, or blocked extensions; `normalizedWebURL` is
unchanged. When the list is set, visit, top-frame navigation, and in-page
clicks to a non-matching host fail with `UNSAFE_NAVIGATION`. `status` / ping
report `navigationAllowlist` (empty array means unrestricted). Changing the
list on an already-running host is rejected; matching list (set equality,
order-independent) or `start` without `--allow` against a running host
remains a no-op success. Every successful `start` ping is revalidated against
the requested list, including the post-spawn ready loop.

**Status:** implemented 2026-09-10.

**Rationale:** a prompt-injected or confused agent can otherwise leave the app
under test and open an arbitrary site. Scheme/credential/extension checks are
not an origin policy. The allowlist is a host-enforced boundary, not a prompt
rule, so it must live in the same function already consulted by CLI visit,
WKWebView `decidePolicyFor`, Linux Fetch Document pause / extra-target close,
and the isolated click guard. Linux does not treat
`Page.frameRequestedNavigation` recovery as the boundary: that event can run
after an off-list request or popup has already started.

**Consequences:** CLI `start --allow` sets `HEADLESS_NAVIGATION_ALLOWLIST` on
the spawned host. The injected agent runtime receives a JSON-encoded copy as
defense in depth and preflights `<a href>` plus submit controls (`formaction`,
then `form.action`, then the document URL). Page JS cannot widen the
host-trusted policy, and `onclick` that assigns `location` or calls
`window.open` is not a JS-visible target, so Linux fails those Document
requests at `Fetch.requestPaused` and closes extra page targets that
auto-attach off the list. Subresource requests (XHR, images, scripts) are
not filtered; the allowlist is a navigation policy, not a network firewall.
macOS continues to cancel in `decidePolicyFor` and ignore disallowed
`createWebViewWith` URLs. Protocol version stays 0.5 (additive ping field).
Patterns are hosts with optional `:port` and optional leading `*.`, capped at
32, case-insensitive, fail closed on `*` alone, non-ASCII, paths, schemes,
and credentials.

---

## 23. File upload attaches existing store basenames only

**Decision:** `upload` is a protocol command that names an existing basename
in the private artifact store and asks the engine to attach that on-disk file.
No CLI, protocol, or MCP command ingests an arbitrary local path. File bytes
never appear on the Unix socket, in protocol parameters, MCP, logs, flows,
snapshots, diagnostics, or errors. Downloads remain denied. There is no TCP
fixture server, no home-directory path on `upload`, and no arbitrary-JS verb.
`upload` targets a file input with the same grammar as `click`.

Artifact pathname integrity relies on the private per-user store. A malicious
same-UID process can inspect or replace files there, which is the documented
same-user limitation in `SECURITY.md`; operators must isolate untrusted agents
under a separate OS account when that boundary matters.

Linux Chromium attaches via `DOM.setFileInputFiles` using an isolated-world
objectId. Attachment success is completion: bounded `{ref, role, name}`
metadata is captured before attach, and a successful CDP response is not
followed by a second node lookup. macOS WKWebView returns
`UNSUPPORTED_CAPABILITY` until a native attach path exists that does not
evaluate page JavaScript or shuttle file bytes through JS. Capabilities
declare `fileUpload` accordingly; inspect advertises `upload` only when that
flag is true.

**Status:** partially implemented by #169 and revised 2026-09-12 after security
review. The operator-file staging criterion in #168 remains open and must not
be closed by the attach-only implementation.

**Rationale:** resume/import/image QA needs file inputs, and the existing store
has the confinement properties required for engine attachment. Any local-path
ingest command available to an agent, including a nominally local CLI or a
scriptable TTY confirmation, would let it copy arbitrary readable host files
into an uploadable location. That violates SECURITY.md. Putting bytes on the
wire would also exceed the frame boundary and leak contents into logs. WebKit
has no equivalent of `setFileInputFiles` without a JS hole.

**Consequences:** agent-facing surfaces cannot import operator files. Upload
remains useful for allowed artifacts already created in the store, and test
harnesses may seed their isolated store directly. Test seeding is not a user
workflow. #168 must remain open or be split so a trusted human staging surface
is designed, implemented, and tested separately. WebKit clients must skip
upload or fail closed. Replay of `upload` requires the same artifact basename
still in the store.

**Revisit trigger:** operator-file import requires a trusted native picker or
broker that proves explicit user approval on both supported platforms. WebKit
support separately requires a documented native attach API that does not
execute page JS or pass file bytes through the JS bridge.

---

## 24. Credential broker on the unsigned local tier

Numbered 24 because 22 and 23 are claimed by in-review PRs
[#170](https://github.com/LockInTime/headless/pull/170) (origin allowlist) and
[#169](https://github.com/LockInTime/headless/pull/169) (artifact upload).

**Decision:** Headless will grow a host-owned credential broker and durable
normal-profile login state without paying for Apple Developer Program
membership. Implement the local/community macOS tier and the Linux secret
backend now. Keep the stored record format compatible with a later Developer
ID build. Do not ship silent credential use on unsigned builds ([#166](https://github.com/LockInTime/headless/issues/166)
is out of this product).

The broker is the only component allowed to read password values from macOS
Keychain or Linux Secret Service / KWallet. The agent-facing protocol speaks
origin-bound aliases and short-lived challenge IDs, never password values.
Direct `fill` remains available for test passwords, with the existing
disclosure that Headless cannot erase a secret from a model-provider
transcript after the user typed it to the agent. Once the vault exists, the
default is aliases only.

Saved-credential use always requires current user presence: Touch ID or the
macOS account password on macOS; an unlocked approved Linux secret-service
prompt on Linux. Peer UID on the control socket is not authorization to
release a secret. If the OS vault is missing, locked, or a plaintext
Chromium fallback, fail closed.

**Status:** decided 2026-09-10 (owner). Implementation starts at
[#155](https://github.com/LockInTime/headless/issues/155), then
[#156](https://github.com/LockInTime/headless/issues/156) and
[#157](https://github.com/LockInTime/headless/issues/157).

**Rationale:** agents today put passwords through `fill`, so secrets show up
in tool transcripts. A vault is useful. It does not require notarization.
Keychain Services and Local Authentication work on ad-hoc local builds.
Developer ID buys Gatekeeper-friendly distribution and a stable signer
across updates ([#45](https://github.com/LockInTime/headless/issues/45)), not
the ability to store a password. Skipping the $99 is fine for this feature.
Skipping per-use confirmation on an unsigned binary is not: after that
toggle, Headless cannot prove a human chose the alias, and there is no
Apple-verified identity to hang a weaker policy on.

Durable cookies are the higher-value login gap. WKWebView already persists;
Linux Chromium currently keeps the profile under the runtime directory and
drops it across reboot. Fixing that is most of "stay logged into staging"
without a password manager.

**Guarantees**

- Password values never appear in snapshots, command output, MCP, logs,
  flows, recordings, diagnostics, errors, environment variables, or process
  arguments.
- Page JavaScript cannot enumerate aliases or query the vault.
- Records bind to a canonical exact HTTPS origin (localhost http is the
  documented development exception) plus an account identity and a
  user-chosen alias.
- Normal-profile aliases, cookies, and storage are invisible to private
  contexts ([#35](https://github.com/LockInTime/headless/issues/35)). Private
  contexts may hold only in-memory credentials enrolled in that context, and
  those die with the last session using it.
- Cookie import (backlog G9) stays rejected.
- Passkeys stay as decision 20: omitted unless Apple grants the restricted
  entitlement. The vault does not unblock WebAuthn.

**Residual risks we will state, not paper over**

- Same-user malware, root, and a replaced unsigned binary can still reach
  Keychain items the way any local process of that user can, subject to
  macOS prompts.
- Rebuilds and signing-identity changes may re-prompt or look like a
  different app. Document that. Do not invent a self-signed cert as public
  trust.
- Prompt injection can still _name_ an alias. Per-use user presence is what
  makes that fail closed on this tier.
- Login cookies are as stealable as in any persistent browser. Treat them as
  session secrets in the threat model, separate from vault passwords.

**macOS unsigned tier**

- Ad-hoc or source builds. Gatekeeper may require a manual open.
- Broker owns its Keychain items. No Keychain access groups.
- Every saved-credential use requires Touch ID or the macOS password.
- Capabilities report a local/unnotarized credential tier. Do not describe
  this as notarized or enterprise-ready.
- A later Developer ID build may add session-level or trusted-origin
  approvals only after a new decision. Notarization alone does not widen
  permissions.

**Linux**

- Secret Service or KWallet only. No Apple dependency. No Chromium basic
  plaintext store. Locked or missing backends return a specific error.

**Durable normal profile ([#155](https://github.com/LockInTime/headless/issues/155))**

- One per-user profile. Sessions keep sharing it (architecture §11).
- Cookies and site storage survive host and machine restart until the user
  logs out, clears, or uses a private context.
- Linux: private XDG data directory, mode `0700`, atomic setup, single-owner
  lock, migration from the current runtime profile only when that move is
  safe, explicit corruption recovery. Not the ephemeral runtime dir.
- macOS: keep the persistent WKWebView data store, but document and test the
  contract instead of leaving it implicit.
- No unrestricted `--profile-path`. No cookie-import command.

**Out of this decision**

- [#166](https://github.com/LockInTime/headless/issues/166) unsigned silent
  fill.
- [#158](https://github.com/LockInTime/headless/issues/158) Settings window.
  Interactive CLI plus a native save sheet are enough for the first cut.
- [#153](https://github.com/LockInTime/headless/issues/153) full settings
  registry. Needed later if "aliases only vs allow direct fill" becomes a
  persisted user-only setting. It does not block #155.
- Paying for Developer ID in order to start this work.

**Consequences:** #154 is the decision. Implementation PRs must keep
passwords off the socket, fail closed without a vault, and advertise the
unsigned tier honestly. Protocol additions (`credentials *`, `auth login`,
`AUTH_REQUIRED`) are compatible additions; do not bump 0.5 unless a breaking
change appears. Tagged macOS releases still fail closed without Developer ID
secrets; that remains #45 and is not a vault prerequisite.

**Revisit trigger:** a Developer ID identity is actually used for public
macOS distribution, and we want weaker-than-per-use confirmation. Write a
new decision. Do not turn #166 on just because notarization started working.

---

## 25. Typed settings are local, classified, and policy-free

**Decision:** application preferences use one typed registry that declares
each key's type, default, platform scope, effect timing, access class, storage
identity, and validation. The local CLI provides `config list`, `describe`,
`get`, `set`, and `reset`; these commands never enter the browser protocol or
MCP surface. Agent callers cannot discover user-only keys, cannot mutate
agent-readable keys, and can mutate only agent-writable keys. A future trusted
native surface may operate as the user, but ordinary CLI or PTY presence is not
proof of a human.

macOS stores preferences in the existing `com.headless.app` UserDefaults
domain. The initial `startup-presentation` definition deliberately retains its
existing physical `AgentStartupPresentation` key, so adopting the registry
does not copy, lose, or resurrect a prior value. Linux uses a bounded,
versioned XDG config file under a `0700` Headless directory, with a `0600`
lock and data file, descriptor-relative no-follow operations, strict decoding,
locking, atomic replacement, and file plus directory synchronization.

**Status:** implemented 2026-09-12 by
[#153](https://github.com/LockInTime/headless/issues/153).

**Rationale:** settings need one discoverable contract before more preferences
arrive, but moving host security boundaries into a writable preference would
turn policy into an opt-out. Access classification is enforced below parsing,
not merely documented. User-only authorization remains in a trusted native or
broker path, and credential secrets and approvals remain outside this store.

**Consequences:** safety invariants, diagnostic gates, sandbox behavior,
allowed navigation schemes, downloads, arbitrary JavaScript, remote control,
and credential authorization are not settings. Corrupt or insecure persisted
state fails closed. Adding a setting requires a registry entry and tests; a
wire-protocol version bump is unnecessary because config remains local-only.

---

## 26. Isolated sessions own one ephemeral browser context

**Decision:** `session create NAME --isolated` creates a session whose cookies,
storage, cache, permissions, and authentication state are separate from the
durable normal profile and every other isolated session. Each isolated session
owns exactly one engine context. Closing that session destroys the context;
there is no caller-selected profile path, context reuse, import, or persistence.

macOS uses a fresh non-persistent `WKWebsiteDataStore`. Linux creates a
Chromium browser context through the existing private DevTools pipe and
disposes it after closing its only target. `profile clear` closes all sessions,
including isolated sessions, then clears only the durable normal profile and
recreates the normal `default` session.

Private sessions cannot enumerate or retrieve normal-vault aliases,
credentials, or approvals. Interactive enrollment writes only to an in-memory
credential store owned by the isolated session. The store is exact-origin
bound and bounded, and erases every secret when the session closes, the host
stops, the profile is cleared, or crash recovery replaces the process. It does
not use Keychain, Secret Service, or the normal nonsecret index.

**Status:** implemented 2026-09-12 as the isolation slice of
[#35](https://github.com/LockInTime/headless/issues/35).

**Rationale:** a named session currently means another view into one durable
profile, not a privacy boundary. Engine-native ephemeral contexts provide a
clear, testable boundary without adding profile-path escape hatches or a second
host. One session per context keeps ownership and cleanup deterministic.

**Consequences:** session creation gains one optional compatible parameter.
Capabilities report the isolation contract. Normal sessions continue sharing
the durable profile. Hover, drag, select, scoped evaluation, and response-body
inspection are not part of this decision.

---

## 27. Interactive authentication keeps consent in the trusted host

**Decision:** `auth login --interactive` obtains the username and password only
through a host-owned native secure dialog on macOS or the foreground
`/dev/tty` on Linux. It never accepts password arguments or protocol fields.
The host fills once, verifies the resulting authentication state, and only
then presents a separate save decision whose default is No. An approved save
passes one bounded binary credential frame directly to the trusted broker over
stdin; the browser control socket, MCP, JSON, environment, and process
arguments continue to carry no secret value.

Interactive login may create a challenge from the current confirmed,
same-origin POST form. Existing challenge IDs remain session-, document-,
origin-, expiry-, and replay-bound. Additional verification, passkeys, failed
credentials, and unknown verification outcomes do not offer persistence. Raw
`fill` remains compatible and never implies save consent.

**Status:** implemented 2026-09-12 by
[#157](https://github.com/LockInTime/headless/issues/157).

**Consequences:** the candidate secret exists only in host memory for the
login and immediate save decision and is cleared on every return path. Broker
storage still applies exact-origin and case-insensitive alias uniqueness. The
Linux terminal path enables interactive login but does not weaken the separate
rule that durable saved-credential retrieval needs trusted per-use presence.

---

## 28. SDKs derive from one Swift-owned protocol contract

**Decision:** SDK generation starts from a deterministic machine-readable
contract emitted by `headless schema`. The Swift descriptors define every wire
command's parameter names, primitive types, required fields, byte and numeric
bounds, enum values, array limits, API scope, and transport timeout policy.
Those descriptors execute before
command-specific semantic validation. `sdk/protocol-schema.json` is a golden
artifact checked against the executable in tests, not a second hand-maintained
validator.

SDKs use only the existing newline-framed JSON protocol over the private
same-user Unix socket. They do not add TCP, remote control, arbitrary
JavaScript, a Chromium debug port, unrestricted profile paths, or direct
credential values. Authentication APIs carry aliases and challenge IDs only.
Page-derived results stay identified as untrusted, sensitive diagnostics keep
both gates, and unsupported engine behavior is capability-negotiated and fails
explicitly.

Wire compatibility is exact by `headlessProtocolVersion` and independent of
the product and SDK package versions. Compatible additions may retain the wire
version; removals, changed meanings, weaker validation, or incompatible
envelopes require a new wire version. The schema format has a separate integer
version. Clients reject unknown schema versions and mismatched response IDs or
wire versions before decoding command results.

Cancellation before send writes no request. Cancellation or timeout after send
closes the client connection but cannot claim the browser operation was rolled
back; clients report an unknown outcome and refresh state. SDK-owned hosts use
`headless start --supervised`, which refuses to attach to an existing host and
creates a private owner pipe after launching the host. Ownership is granted only
when the startup response PID matches that child. Closing launcher input, or the
launcher exiting, closes the private pipe, stops the owned host, and lets the
launcher reap it. SDKs never stop a shared host they discovered.

**Status:** accepted for [#163](https://github.com/LockInTime/headless/issues/163).

**Consequences:** TypeScript and Python clients generate or validate their
public command types from the golden schema and pin its digest. Schema, SDK,
shared fixtures, CLI-parser, protocol-validator, and MCP parity are tested
together. SDK package versions are independent of the wire version. A package
that also distributes the Headless product tracks product tags so its launcher
can resolve a matching release; standalone SDK packages may version
independently while declaring their supported wire version.
Deprecation, support-window, provenance, and security-reporting rules live with
the schema so client packages cannot silently invent a different policy.

---

## Decision log

| #   | Decision                                                    | Status                                                    | Date       |
| --- | ----------------------------------------------------------- | --------------------------------------------------------- | ---------- |
| 1   | Keep Swift core; Rust only via revisit trigger              | Decided                                                   | 2026-08-04 |
| 3   | Extract HostCore + BrowserEngine, typed errors              | Implemented                                               | 2026-08-10 |
| 5   | Remote stays SSH-only; no cloud offering                    | Decided (owner)                                           | 2026-08-04 |
| 6   | Windows = stretch via Chromium engine; WSL2/Docker interim  | Decided (owner); spike failed 2026-08-22, native deferred | 2026-08-04 |
| 8   | Real CDP input on Linux as capability upgrade               | Implemented                                               | 2026-08-13 |
| 12  | Version unification on git tag                              | Implemented                                               | 2026-08-04 |
| 14  | Run one conformance scenario against every engine           | Implemented                                               | 2026-08-10 |
| 15  | Package-manager distribution set                            | Decided (owner)                                           | 2026-08-04 |
| 16  | Preserve CLI value boundaries with `--` and shell quoting   | Decided                                                   | 2026-08-10 |
| 17  | Keep full MCP surface; annotate its maximum risk            | Decided                                                   | 2026-08-10 |
| 18  | Treat WebKit page diagnostics as bounded untrusted evidence | Decided                                                   | 2026-08-10 |
| 19  | Keep macOS agent startup behind the current app             | Implemented                                               | 2026-08-12 |
| 20  | Omit passkeys unless Apple provisions Developer ID release  | Implemented                                               | 2026-08-12 |
| 21  | Rust port of shared core, protocol layer first              | In progress                                               | 2026-08-22 |
| 22  | Optional host origin allowlist on `headless start`          | Implemented                                               | 2026-09-10 |
| 23  | Upload attaches existing store basenames only; downloads denied | Partially implemented; trusted staging remains #168      | 2026-09-10 |
| 24  | Credential broker on the unsigned local tier                | Decided                                                   | 2026-09-10 |
| 25  | Typed local settings registry; security policy stays fixed  | Implemented                                               | 2026-09-12 |
| 26  | Isolated sessions own one ephemeral browser context         | Implemented                                               | 2026-09-12 |
| 27  | Interactive authentication keeps consent in trusted host    | Implemented                                               | 2026-09-12 |
| 28  | SDKs derive from one Swift-owned protocol contract          | Decided                                                   | 2026-09-12 |

New decisions append here with the same format.
