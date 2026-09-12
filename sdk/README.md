# Headless SDK contract

`protocol-schema.json` is the checked-in SDK contract emitted by the Swift
implementation. `protocol-fixtures.json` contains representative requests and
responses consumed by Swift, MCP, and every generated SDK:

```sh
swift run --package-path apps/headless headless schema > sdk/protocol-schema.json
```

The protocol suite compares the schema byte-for-byte with `headless schema` and
also decodes it back to the Swift value. Do not edit the schema JSON by hand.

## Compatibility

The wire protocol and product versions are independent. SDKs support the exact
wire version in their bundled schema. An older client sends only commands and
parameters present in that schema. A newer client must reject an older host
before decoding a result for an unsupported wire version, and must use the
host capability document before issuing an engine-specific command.

Each command declares whether it is host-scoped or session-scoped and carries
the timeout policy used by the CLI and MCP adapter. Generated clients consume
those fields rather than maintaining their own command lists or deadlines.

Compatible additions retain the current wire version. Removing or changing a
field, command, constraint, error meaning, framing rule, or security guarantee
requires a protocol-version change and migration notes. The schema format has
its own integer version so generators can reject unknown metadata.

## Transport and cancellation

SDKs use the existing private, same-user Unix socket. They do not add TCP,
remote control, a Chromium debug port, or arbitrary JavaScript. Closing a
client connection before a request is written cancels it. Closing after send
does not roll back a browser operation, so the SDK must report an unknown
outcome and require a fresh inspection.

An SDK may terminate and reap only a host process that it launched and owns.
It must not stop an already-running shared host during cancellation, timeout,
or client shutdown.

Use `headless start --supervised` for an owned host. Omitting a presentation
option preserves the platform default; macOS callers may explicitly request
`--background` or `--foreground`. The command fails if a shared host already
exists, prints the normal startup response, and then remains attached to the
host. The launcher owns a private pipe to the host, so the host still stops if
the launcher is killed while another process retains the launcher's input
stream. The startup response PID must match the launched host before ownership
is granted. Closing the launcher input makes the host stop and lets the launcher
be awaited. A plain `headless start` remains detached and shared.

## Release policy

Generated SDKs pin a schema digest and wire version. Schema and client changes
are reviewed together. SDK package versions are independent of the wire
version. A package that also distributes Headless tracks product tags so its
launcher can resolve a matching release; standalone SDK packages may version
independently while declaring their supported wire versions. Before 1.0,
deprecations remain for at least one minor SDK release; after 1.0, removals
require a major SDK release. Security reports use the repository process in
`SECURITY.md` and must not include credentials, cookies, or private artifacts.

The initial support window covers wire protocol `0.5`, schema format `1`,
macOS 13 or newer, Linux amd64/arm64, Node.js 22 or newer, and CPython 3.11
through 3.14. The latest two minor SDK lines remain maintained for at least 12
months after supersession, whichever period is longer. Applicable security
fixes are backported to supported lines.
