# Headless Python SDK

`lockintime-headless` is the zero-runtime-dependency Python client for the local
[Headless](https://github.com/LockInTime/headless) browser host. It supports CPython
3.11 through 3.14 on macOS and Linux.

The SDK connects directly to Headless's private per-user Unix socket. It never opens
a TCP port, evaluates arbitrary JavaScript, or receives a credential password. The
typed API and runtime validators are generated from the repository's canonical SDK
schema. SDK versions use semantic versioning independently of the wire protocol.

## Install

```sh
python -m pip install lockintime-headless
```

The `headless` CLI must already be installed and available on `PATH` when using
`launch()`. `connect()` only attaches to an existing host and never shuts it down.

## Synchronous client

```python
from headless_sdk import Untrusted, connect

with connect() as client:
    client.session_create(name="research")
    session = client.session("research")
    page = session.visit(url="https://example.com")
    assert isinstance(page, Untrusted)
    print(page.value["title"])
```

The equivalent CLI flow is:

```sh
headless start --background
headless session create research
headless --session research visit https://example.com
```

## Asynchronous client

```python
import asyncio

from headless_sdk import aconnect


async def main() -> None:
    async with await aconnect() as client:
        session = await client.open_session("research")
        page = await session.inspect(text=True)
        print(page.value["text"])


asyncio.run(main())
```

Pass an `asyncio.Event` as `cancel=` or cancel the calling task. A cancellation or
timeout before any bytes are written is retry-safe. Once request bytes have been
written, timeout, cancellation, transport, framing, or response-validation failures
raise `OperationOutcomeUnknown`. Do not retry that operation until you inspect host
state.

## Supervised host ownership

```python
from headless_sdk import launch

with launch(presentation="background", allow=["example.com"]) as host:
    print(host.client.host_status["pid"])
```

`launch()` runs `headless start --background --supervised`, keeps the owner pipe open,
and grants ownership only after the startup response PID matches the connected host
PID. Closing the wrapper terminates and reaps only that owned launcher. It cannot
adopt or stop a concurrently started shared host. Use `presentation="foreground"`
to request the foreground app behavior. Custom executable paths must be absolute.

## Authentication and untrusted data

Page-derived results are wrapped in `Untrusted[T]`; validate them before using them
in privileged operations. `AUTH_REQUIRED` becomes `AuthenticationRequiredError` and
its details are also untrusted. Login accepts only a challenge plus credential alias,
or interactive mode:

```python
from headless_sdk import AuthenticationRequiredError

try:
    session.click(role="button", name="Continue")
except AuthenticationRequiredError as error:
    aliases = error.details.value["accounts"]
    session.auth_login(
        challenge=error.details.value["challenge"],
        account=aliases[0]["alias"],
    )
```

There is intentionally no password parameter. Password enrollment remains a trusted
CLI or native UI operation. Sensitive cookie and storage values still require both
the command flag and the host's diagnostics environment gate.

## Compatibility and security limits

- The SDK requires the exact bundled wire protocol version. A mismatch fails before
  result decoding.
- Capabilities are negotiated on connect. Missing commands raise
  `UnsupportedCapabilityError`; the SDK does not emulate them.
- Socket paths must be direct children of `/tmp/headless-<uid>`. The directory and
  socket must be owned by the current user, non-symlinks, and private (`0700` and
  `0600`, respectively).
- The transport accepts exactly one newline-terminated JSON response up to 1 MiB.
- The same-user boundary prevents other OS users from connecting. It does not defend
  against a malicious process already running as your OS account.
- `connect()` never owns the host. Stop shared hosts only through an explicit user
  action.

Report security problems according to the repository
[security policy](https://github.com/LockInTime/headless/security/policy). Do not put
secrets, cookies, private artifacts, or credential material in reports.

## Release controls

Python packages publish only from a `python-v<package-version>` tag whose commit is
already merged into `main`. The GitHub `pypi` environment allows only `python-v*` tags
and requires independent reviewer approval with administrator bypass disabled. PyPI
trusted publishing is bound to that environment; no long-lived package token is stored
in the repository.

## Development checks

From `packages/headless-python`:

```sh
python -m pip install -e '.[dev]'
python scripts/generate.py --check
ruff check .
ruff format --check .
mypy
pytest
python -m build
python scripts/verify_package.py
```

Publishing uses PyPI trusted publishing from reviewed `python-v*` tags. The package
has its own semantic version and is not released by Headless product `v*` tags.
