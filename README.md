# headless

[![CI](https://github.com/LockInTime/headless/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LockInTime/headless/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/LockInTime/headless?sort=semver)](https://github.com/LockInTime/headless/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Protocol](https://img.shields.io/badge/protocol-0.5-informational)](apps/headless/Sources/HeadlessProtocol/Protocol.swift)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)](#build-and-install)

Persistent browser control for agents, without Playwright scripts or screen
coordinates.

Headless began as a fork of
[antiwork/chromeless](https://github.com/antiwork/chromeless). With thanks to
Sahil Lavingia for the original foundation.

Supported platforms: macOS, Linux (including Ubuntu and the common Linux test
distros used in CI/Docker). Windows is not supported natively (planned as a
stretch goal; Docker/WSL2 is the interim path).

Product direction, architectural decisions, and the full improvements backlog
live in [docs/ROADMAP.md](docs/ROADMAP.md). Every known gap is also filed as a
[`backlog` issue](https://github.com/LockInTime/headless/labels/backlog),
grouped into [milestones](https://github.com/LockInTime/headless/milestones)
by roadmap phase and tracked on the
[Headless Roadmap board](https://github.com/orgs/LockInTime/projects/1).

Contributing: [AGENTS.md](AGENTS.md) for agents and the short version for
humans, [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide,
[SECURITY.md](SECURITY.md) to report a boundary bypass privately, and
[CHANGELOG.md](CHANGELOG.md) for what shipped when. New here? Start with a
[good first issue](https://github.com/LockInTime/headless/labels/good%20first%20issue).

P2 uses the same CLI everywhere Headless runs:

- macOS 13+: visible WKWebView windows.
- Linux (Ubuntu and other distros): sandboxed Chromium, headless by default or
  visible with `DISPLAY`.

## Computer use comparison

Three common agent browser paths, scored **1–5** as qualitative capability
judgments (not lab benchmarks):

| Dimension                     | Coordinate CU (regular browser) | Scripted (PW / Puppeteer / Selenium) | Headless |
| ----------------------------- | :-----------------------------: | :----------------------------------: | :------: |
| Targeting precision           |                2                |                  4                   |    5     |
| Safety / blast radius         |                2                |                  3                   |    5     |
| Evidence (shots, video, QA)   |                3                |                  3                   |    5     |
| Agent surface (tokens / glue) |                2                |                  3                   |    5     |
| Setup friction                |                3                |                  3                   |    4     |
| Platform coverage (host OS)   |                5                |                  5                   |    4     |
| Desktop / OS reach            |                5                |                  1                   |    1     |

- **Coordinate CU** — strong when the agent needs the whole desktop; weaker on
  precise web targeting (pixels drift), larger screenshot/prompt cost, and a
  broader OS blast radius. Runs on Windows, macOS, and Linux.
- **Scripted** — reliable selectors and driver APIs; more agent glue to write
  and maintain; evidence and security posture are usually bolted on. Broad
  host-OS support including Windows.
- **Headless** — semantic role/name/`@ref` actions, private socket + allowlisted
  commands, built-in record/screenshot/diagnostics; browser-only (no desktop).
  Runs on macOS and Linux (Ubuntu and common CI/test distros); Windows is the
  exception.

**Measured agent surface** (same P2 fixture flow, Docker ARM64, 27 Aug 2026 —
point-in-time): Headless warm **174** est. tokens vs Selenium **410** /
Puppeteer **499**. Full method and limits:
[BENCHMARK.md](apps/headless/docs/BENCHMARK.md).

## Agent workflow

```sh
headless start
headless session create qa
headless session create private-audit --isolated
headless --session qa visit localhost:3000/designers/dashboard
headless --session qa inspect --context summary --task "finish onboarding"
headless --session qa inspect --context outline --limit 20
headless --session qa inspect --context actions --task "click Continue"
headless --session qa record start --fps 10
headless --session qa tour --full-page
headless --session qa click --role button --name Continue
headless --session qa wait --url /next --settled
headless --session qa record stop --output dashboard-flow.mp4
headless --session qa screenshot --full-page --output next-page.png
headless --session qa screenshot --format jpg --output next-page.jpg --clipboard
headless --session qa screenshot --format pdf --full-page --output next-page.pdf
headless --session qa screenshot --every-viewport --output dashboard-scroll
headless --session qa screenshot --by-section --output dashboard-sections
headless --session qa qa report
headless --session qa console list --level error
headless --session qa network list --failed
headless --session qa styles get --role button --name Continue --property display
headless artifacts list
```

On macOS, agent startup opens visible browser windows behind the app currently
in use. Change the persistent default with `headless config set
startup-presentation foreground` or restore background startup with `headless
config set startup-presentation background`; inspect it with `headless config
get startup-presentation`. Use `config list` to discover settings, `config
describe KEY` for type and policy metadata, and `config reset KEY` to restore a
built-in default. `headless start --foreground` and `headless start
--background` are one-launch overrides. Settings and overrides apply only when
launching a new host and do not reorder an already-running host.

Settings declare their value type, default, supported platforms, access class,
and when changes take effect. `agent-readable` settings can be inspected but
not changed by an agent, `agent-writable` settings can also be changed, and
`user-only` settings are omitted from every agent CLI operation. The registry
is local-only and is not available through MCP or the browser protocol. macOS
retains the existing `com.headless.app` / `AgentStartupPresentation` preference;
Linux uses a bounded, versioned file in a private XDG configuration directory.
Security invariants such as sandboxing, navigation restrictions, diagnostic
gates, download denial, and the absence of arbitrary JavaScript and TCP control
are fixed policy, not settings.

Inspection is progressively disclosed instead of forcing an entire page into an
agent prompt. Start with `--context summary`, use `--context outline` to receive
structural region references such as `@r4`, then inspect only that region with
`--within @r4`. `--context text` returns bounded semantic snippets and
`--context actions` returns visible executable controls. `--task`, `--limit`,
`--budget`, and `--depth` rank and bound every focused response; `omitted` and
`contextStats` make pruning explicit. `--context full --text` remains the
explicit broad-page escape hatch.

Each control's `actions` list contains only protocol verbs that can run (`click`,
`fill`, or `upload`); unsupported controls never advertise nonexistent commands. Full
inspection retains roles, names, rendered media metadata, safety markers,
bounds, and element references such as `@e1`.
`capture-info` returns the browser surface, page state, action trace, and
recording state for an external recorder or QA harness.

For scrollable-page QA, use `screenshot --every-viewport --output PREFIX` for
up to 80 viewport-height scroll stops, always including the final bottom
position. Results report `truncated` and `totalPoints` when a longer page is
bounded. Use
`screenshot --by-section --output PREFIX` to capture around visible headings and
sections. Series capture restores the original scroll position. Add `--format
jpg` for JPEG series; PDF requires `--full-page` and is not a series format. The
output prefix creates numbered artifacts such as `dashboard-scroll-001.png` or
`dashboard-scroll-001.jpg`.

When an action fails, use the on-demand diagnostic commands instead of an
interactive DevTools UI: `console list`, `network list|get`, `styles get`,
`cookies list`, and `storage list`. Cookie and storage values stay redacted
unless the host was deliberately started with `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`.

Run `headless help` for every command or `headless capabilities` for the
JSON capability contract.

Normal sessions share one durable browser profile, so cookies and local
storage survive host restarts. Use the website's logout flow to remove one
account, or `headless profile clear` to close every session and erase the full
normal profile. Linux stores it in a private XDG data directory; macOS uses the
persistent WebKit data store. Headless does not accept imported cookies or a
caller-selected profile path.

Saved credentials use a dedicated local broker instead of the browser socket:

```sh
headless credentials add --origin https://example.com --alias work --interactive
headless credentials list --origin https://example.com
headless credentials rename --origin https://example.com --alias work --to client
headless credentials remove --origin https://example.com --alias client
headless auth login --challenge CHALLENGE_ID --account client
headless auth login --interactive
```

The interactive broker reads and confirms passwords only through the attached
terminal with echo disabled. Agents can see approved usernames and aliases,
but password values never enter arguments, MCP, browser commands, logs, flows,
or output. macOS uses the encrypted default user Keychain with a decrypt-only
ACL and reports the unsigned local security tier honestly. Linux requires an
available system Secret Service and never falls back to plaintext. Confirmed
top-level same-origin POST login forms return an origin-bound, session-bound,
document-bound, single-use
`AUTH_REQUIRED` challenge containing matching aliases. `auth login` performs a
fresh broker-owned user-presence check, fills inside the trusted host, submits
once, and reports the continuation without replaying the blocked action.
Heuristic hints and cross-origin frames never trigger credential retrieval.
Interactive login uses trusted native or terminal input rather than password
arguments. It asks whether to save only after verified success, defaults to
No, and requires a user-entered alias. Linux vault management is available,
but saved alias use fails closed until a trusted per-use confirmation surface
exists.

With `--session NAME` for an isolated session, interactive saves go only to an
in-memory vault owned by that session. Private challenges list only those
ephemeral aliases. Closing the session or terminating the host erases them;
the durable normal vault is never queried.

## Agent skill

This repository ships a portable browser-computer-use skill at
`.agents/skills/headless-computer-use/`. Skills-aware agents can invoke it as
`$headless-computer-use` to select a native or Docker runtime, drive the
snapshot-and-semantic-action loop, capture evidence, diagnose failures, and
clean up the session safely. If an agent does not auto-discover repository
skills, point it directly at that `SKILL.md` file.

Example prompt: `Use $headless-computer-use to launch this project's browser,
test the signup flow end to end, and return verified screenshot, video, and QA
report evidence.`

## Evidence capture

Built-in recording captures browser pixels through FFmpeg as MP4, MOV, WebM, or
GIF. Pick the container at `record start` with `--format`; the `record stop`
output must use the same extension. The status response includes FPS,
container, codec, quality, frame count, dropped frames, and duration. Recordings
do not include OS chrome or audio. For an OS recorder, OBS, or a CI recorder,
use `capture-info` to get the window or browser process and keep using the same
navigation commands.

Screenshots support PNG, JPG/JPEG, and full-page PDF. macOS can also copy
image screenshots to the clipboard with `--clipboard`; Linux rejects clipboard
capture because VM clipboards are not reliable by default. Screenshots support
the viewport, full page, one element, every viewport-height scroll stop, or each
visible section/heading. `inspect` exposes rendered media with its source,
decoded dimensions, load and playback state, safety marker, poster, and
accessible name; screenshots and recordings capture the visible media pixels.

## Build

### macOS

```sh
brew install --cask LockInTime/headless/headless
headless help
```

Beginning with the next signed release, macOS bundles are universal for Apple
Silicon and Intel, Developer ID signed, notarized, and stapled. The tap syncs
after publication, and the cask also links `headless-mcp`. To build locally
instead:

```sh
./apps/headless/build.sh
./apps/headless/Headless.app/Contents/Resources/bin/headless help
```

Requires Xcode Command Line Tools. The build checks for Swift, Apple utilities,
and a compatible SDK before compiling. Local builds target the current
architecture by default; set `HEADLESS_ARCHS="arm64 x86_64"` to reproduce the
universal release bundle.

### Linux

```sh
curl -fsSL https://github.com/LockInTime/headless/releases/latest/download/install.sh | sh
```

The release bootstrap supports Linux `amd64` and `arm64`, downloads the matching
tarball, verifies it against the release's `SHA256SUMS`, rejects unexpected
archive contents, and delegates to the packaged runtime preflight. Install a
specific release or prefix with:

```sh
curl -fsSL https://github.com/LockInTime/headless/releases/latest/download/install.sh \
  | HEADLESS_VERSION=1.1.0 sh -s -- --prefix /opt/headless
```

To build locally instead:

```sh
./apps/headless/build-linux.sh
apps/headless/build/linux/install-linux.sh
```

Only Docker is needed to build. The output includes a portable tarball and an
installer that checks Chromium and FFmpeg before copying the binaries. The
Docker image is the supported self-contained Linux runtime and uses Debian's
Chromium binary at `/usr/lib/chromium/chromium`.

### Windows (WSL2)

There is no native Windows build; the Swift toolchain cannot currently compile
the core for Windows (see architecture decision §6). Run Headless inside
WSL2 instead:

```powershell
wsl --install -d Ubuntu
```

Then, inside WSL2, follow the Linux install above. Chromium and FFmpeg come
from `apt` (`sudo apt install chromium ffmpeg`). Alternatively, run the
published GHCR image under Docker Desktop:

```sh
docker run --shm-size=1g ghcr.io/lockintime/headless:latest headless --version
```

### npm / npx

JavaScript-based agent harnesses can run the verified launcher without a
global install:

```sh
npx @lockintime/headless help
npx -p @lockintime/headless headless-mcp
```

SDK generators consume the Swift-owned contract printed by `headless schema`.
The checked-in `sdk/protocol-schema.json` is verified against that output in
the protocol suite. Wire compatibility is exact by protocol version and is
independent of the product release version. Clients must negotiate engine
capabilities and fail explicitly rather than emulate missing behavior.

The launcher selects the matching macOS or Linux release, verifies it against
the release `SHA256SUMS`, validates its archive and embedded product version,
and caches it privately for subsequent commands. Its download origin is fixed
to this repository.

Tagged releases publish a non-root amd64/arm64 image with Chromium and FFmpeg:

```sh
docker pull ghcr.io/lockintime/headless:1.1.0
docker run --rm ghcr.io/lockintime/headless:1.1.0 headless capabilities
```

Version and commit-SHA tags provide stable release references, while a digest
is the immutable deployment reference; `latest` tracks the newest release. The
image exposes no ports. Browser control remains on the private Unix socket
inside the container.

For a native Linux install, use a real Chromium binary supplied by the Linux
distribution. Ubuntu's `/snap/bin/chromium` launcher resolves to
`/usr/bin/snap`; it is rejected because repeated navigation is unreliable over
Chromium's inherited DevTools pipe. If automatic detection is unsuitable, set
`HEADLESS_CHROMIUM_EXECUTABLE` to an absolute, executable, non-Snap binary.
Invalid overrides fail closed instead of silently selecting a different
browser. FFmpeg is likewise selected only from its explicit absolute override
or the runtime allow-list, never an arbitrary PATH entry. Verify the exact
browser selection before starting the host:

```sh
headless runtime
headless start
```

Build an x86-64 binary from Apple Silicon with:

```sh
HEADLESS_LINUX_PLATFORM=linux/amd64 ./apps/headless/build-linux.sh
```

### GitHub Releases

Pushing a version tag publishes downloadable packages:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The tag is embedded as the product version in every binary. Verify an install
with `headless --version`; wire protocol compatibility is versioned
independently. See [CHANGELOG.md](CHANGELOG.md) for release history.

Assets: macOS `Headless.app` zip, Linux amd64/arm64 tarballs, the Linux
`install.sh` bootstrap, a multi-platform GHCR image, and `SHA256SUMS`. The
bootstrap verifies the selected Linux package automatically. For manual
installation, download the manifest beside the selected package and verify it
before installing:

```sh
sha256sum --ignore-missing -c SHA256SUMS              # Linux
shasum -a 256 --ignore-missing -c SHA256SUMS          # macOS
```

See the Actions `Release` workflow and the release notes on each tag for Linux
Chromium/FFmpeg install caveats.

The `Release` workflow can also be run manually with `dry_run` enabled. That
builds, verifies, and uploads all three workflow artifacts without creating a
GitHub Release. Pull requests that change release packaging run the same dry
run automatically.

## Tests

```sh
pnpm test                 # shared protocol/security suite
pnpm test:runtime         # deterministic large-document pruning suite
pnpm test:e2e:mac         # real WKWebView workflow
pnpm test:e2e:linux       # disposable Docker + sandboxed Chromium workflow
```

The Linux E2E container receives `SYS_ADMIN` so Chromium can initialize its
nested sandbox. Native VM deployment does not need that capability. A passing
Docker run retains verified PNG/JPG/PDF, MP4/WebM, JSON, and checksum evidence
under `apps/headless/build/qa-evidence/`.

Run the repeatable comparison against Selenium and Puppeteer with:

```sh
./apps/headless/benchmark.sh 5
```

See [P2](apps/headless/docs/P2.md) for comparison, flow, networking, and MCP
behavior, and [benchmark](apps/headless/docs/BENCHMARK.md) for the method, limits,
and measured results.

## Security boundary

- No TCP control or Chromium debugger port.
- `0600` Unix socket in a `0700` per-user directory, with peer-UID checks.
- Chromium control over inherited fd 3/4 pipes.
- Isolated browser helpers and allowlisted, bounded commands.
- `0600` artifacts in a `0700` per-user directory; no path traversal or
  overwrite.
- HTTP/HTTPS navigation only; no file URLs, credentials, external application
  schemes, arbitrary JavaScript, or shell execution.
- An agent session starts on a clean page and abandons any previously opened
  local-file or application page before it can be inspected.
- Remote executables, installers, scripts, libraries, and disk images are
  blocked by extension. Archives are reported as a caution and are never
  downloaded or unpacked.
- Page downloads are denied; only explicit Headless artifacts are written.
- Non-root, sandboxed Chromium on Linux.

Any process already running as the same OS user can access that user's browser
profile and socket. Run untrusted agents as separate OS users, and treat browser
output as potentially sensitive.

See [P0](apps/headless/docs/P0.md) for the control foundation,
[P1](apps/headless/docs/P1.md) for capture and diagnostics, and
[P2](apps/headless/docs/P2.md) for advanced QA workflows.
