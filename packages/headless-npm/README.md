# `@lockintime/headless`

Typed Node.js SDK and verified npm launcher for the
[Headless agent browser](https://github.com/LockInTime/headless). Node.js 22 or
newer is required. The SDK has no runtime dependencies and talks directly to
Headless over its private per-user Unix socket. It does not start a network
service or use MCP as an internal transport.

## CLI launcher

```sh
npx @lockintime/headless help
npx -p @lockintime/headless headless-mcp
```

The launcher downloads the release matching its own package version from the
official GitHub repository, verifies the exact asset against `SHA256SUMS`,
validates the archive shape and embedded product version, and caches it in a
private per-user directory. It supports macOS 13+ on Apple Silicon and Intel,
plus Linux x86_64 and arm64. Windows users should use the published GHCR image.

Set `HEADLESS_NPM_CACHE` to an absolute directory to move the verified cache.
The release download origin is fixed and cannot be overridden.

Because this package distributes both the SDK and verified product launcher,
its version follows Headless product tags. The supported wire and schema
versions remain independent and are pinned in the generated SDK contract.

## Connect to a shared host

Replace repeated CLI calls with typed methods. Closing this client closes only
its active socket requests. It never stops a shared Headless host.

```ts
import { connect } from "@lockintime/headless";

// CLI: headless status
await using headless = await connect();

// CLI: headless visit https://example.com
const page = await headless.visit({ url: "https://example.com" });
if (page.untrustedContent) {
  console.log(page.value.title);
}
```

Every page-derived result is returned as `Untrusted<T>`. Callers must preserve
that trust marker when sending page content to an agent or another system.

## Supervised host

Use `launch()` when this process must own a new host. It invokes the installed
CLI with `headless start --background --supervised`, keeps the ownership pipe
open, verifies that the startup response and socket report the same host PID,
and reaps only that launcher during disposal. It fails rather than claiming an
already-running shared host.

```ts
import { launch } from "@lockintime/headless";

await using host = await launch({
  allow: ["example.com"],
  installationTimeoutMs: 300_000,
  startupTimeoutMs: 10_000,
});

const session = await host.client.openSession("research", { isolated: true });
await using scoped = session;
const snapshot = await scoped.inspect({ context: "actions" });
```

Session helpers expose only session-scoped commands. Host lifecycle and session
creation remain on `HeadlessClient`.

## Cancellation and authentication

Methods accept `{ signal, timeoutMs }` as their final argument. Cancellation or
timeout before any request byte is written is retry-safe. After a write,
`OperationOutcomeUnknown` means the SDK cannot know whether the browser action
completed. Never retry it automatically; inspect browser state first.

Saved-login methods accept only a challenge ID and account alias. There is no
password parameter in the authentication API:

```ts
await scoped.authLogin({
  challenge: "11111111-1111-4111-8111-111111111111",
  account: "work",
});
```
