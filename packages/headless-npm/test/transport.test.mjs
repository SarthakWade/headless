import assert from "node:assert/strict";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import {
  CancelledBeforeSend,
  CommandError,
  connect,
  HeadlessClient,
  MalformedResponseError,
  MAXIMUM_MESSAGE_BYTES,
  OperationOutcomeUnknown,
  PROTOCOL_VERSION,
  ProtocolMismatchError,
  ResponseIdMismatchError,
  ResponseTooLargeError,
  TimeoutBeforeSend,
  UnsupportedCapabilityError,
  ValidationError,
} from "../dist/index.js";
import { UnixSocketTransport } from "../dist/transport.js";
import { hostStatus, privateSocketServer, uniqueSocketPath } from "./helpers.mjs";

test("connect negotiates capabilities and session helpers preserve untrusted results", async (t) => {
  const seen = [];
  const server = await privateSocketServer((request) => {
    seen.push(request);
    if (request.command === "ping") return hostStatus(request.id);
    if (request.command === "visit") {
      return {
        id: request.id,
        version: PROTOCOL_VERSION,
        ok: true,
        result: {
          url: request.parameters.url,
          title: "Untrusted",
          readyState: "complete",
          text: "page text",
          runningAnimations: 0,
          mutationQuietMs: 500,
          scrollY: 0,
          contentHeight: 900,
        },
      };
    }
    throw new Error(`unexpected command ${request.command}`);
  });
  t.after(() => server.close());
  const client = await connect({ socketPath: server.socketPath });
  t.after(() => client.close());
  const result = await client.session("work.one").visit({ url: "https://example.com" });
  assert.equal(result.untrustedContent, true);
  assert.equal(result.value.title, "Untrusted");
  assert.equal(seen[1].session, "work.one");
  assert.ok(client.capabilities.commands.includes("visit"));
});

test("commands cannot bypass capability negotiation", async () => {
  const client = new HeadlessClient({ socketPath: await uniqueSocketPath("not-contacted") });
  await assert.rejects(client.visit({ url: "https://example.com" }), /connect\(\) must complete/);
  client.close();
});

test("transport rejects paths outside the Swift runtime directory and malformed outbound frames", async (t) => {
  const server = await privateSocketServer((request) => hostStatus(request.id));
  t.after(() => server.close());
  const transport = new UnixSocketTransport(server.socketPath);
  await assert.rejects(
    transport.send({ frame: Buffer.from("{}"), requestId: "no-newline", timeoutMs: 100 }),
    ValidationError,
  );
  await assert.rejects(
    transport.send({ frame: Buffer.from("{}\n{}\n"), requestId: "two-frames", timeoutMs: 100 }),
    ValidationError,
  );
  await chmod(server.socketPath, 0o666);
  await assert.rejects(
    transport.send({ frame: Buffer.from("{}\n"), requestId: "public-socket", timeoutMs: 100 }),
    /socket is not private/,
  );
  await chmod(server.socketPath, 0o600);
  transport.close();

  const otherPrivateDirectory = await mkdtemp(join(tmpdir(), "headless-other-private."));
  t.after(() => rm(otherPrivateDirectory, { recursive: true, force: true }));
  assert.throws(
    () => new UnixSocketTransport(join(otherPrivateDirectory, "host.sock")),
    /direct child of the Headless runtime directory/,
  );
  await assert.rejects(
    connect({ socketPath: join(otherPrivateDirectory, "connect.sock") }),
    /direct child of the Headless runtime directory/,
  );
});

test("capability negotiation rejects unsupported commands before transport", async (t) => {
  let requests = 0;
  const server = await privateSocketServer((request) => {
    requests += 1;
    return hostStatus(request.id, process.pid, ["ping"]);
  });
  t.after(() => server.close());
  const client = await connect({ socketPath: server.socketPath });
  t.after(() => client.close());
  await assert.rejects(client.visit({ url: "https://example.com" }), UnsupportedCapabilityError);
  assert.equal(requests, 1);
});

test("timeout and cancellation before send are explicitly retry-safe", async () => {
  const transport = new UnixSocketTransport(await uniqueSocketPath("unused"), {
    validatePath: async () => delay(100),
  });
  await assert.rejects(
    transport.send({ frame: Buffer.from("{}\n"), requestId: "before-timeout", timeoutMs: 5 }),
    (error) => error instanceof TimeoutBeforeSend && error.retrySafe,
  );
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    transport.send({
      frame: Buffer.from("{}\n"),
      requestId: "before-cancel",
      timeoutMs: 100,
      signal: controller.signal,
    }),
    (error) => error instanceof CancelledBeforeSend && error.retrySafe,
  );
});

test("timeout, cancellation, and read failure after write report unknown outcome", async (t) => {
  const server = await privateSocketServer(async (request, socket) => {
    if (request.id === "read-failure") socket.destroy();
    return undefined;
  });
  t.after(() => server.close());
  const transport = new UnixSocketTransport(server.socketPath);
  await assert.rejects(
    transport.send({ frame: Buffer.from('{"id":"post-timeout"}\n'), requestId: "post-timeout", timeoutMs: 20 }),
    (error) => error instanceof OperationOutcomeUnknown && error.reason === "timed-out" && !error.retrySafe,
  );
  const controller = new AbortController();
  const pending = transport.send({
    frame: Buffer.from('{"id":"post-cancel"}\n'),
    requestId: "post-cancel",
    timeoutMs: 1_000,
    signal: controller.signal,
  });
  await delay(20);
  controller.abort();
  await assert.rejects(
    pending,
    (error) => error instanceof OperationOutcomeUnknown && error.reason === "cancelled",
  );
  await assert.rejects(
    transport.send({ frame: Buffer.from('{"id":"read-failure"}\n'), requestId: "read-failure", timeoutMs: 1_000 }),
    (error) => error instanceof OperationOutcomeUnknown && ["closed", "read-failed"].includes(error.reason),
  );
  transport.close();
});

test("post-write response failures preserve framing causes under unknown outcome", async (t) => {
  const modes = new Map();
  const server = await privateSocketServer((request, socket) => {
    const mode = modes.get(request.command);
    if (request.command === "ping") return hostStatus(request.id);
    if (mode === "malformed") return Buffer.from("not-json\n");
    if (mode === "empty") return Buffer.alloc(0);
    if (mode === "partial") return Buffer.from("{\"id\":\"partial\"");
    if (mode === "oversized") return Buffer.alloc(MAXIMUM_MESSAGE_BYTES + 1, 0x61);
    if (mode === "multiple") return Buffer.from("{}\n{}\n");
    if (mode === "delayed-multiple") {
      socket.write(`${JSON.stringify({
        id: request.id,
        version: PROTOCOL_VERSION,
        ok: true,
        result: { stopping: true },
      })}\n`);
      setTimeout(() => socket.end("{}\n"), 10);
      return undefined;
    }
    if (mode === "mismatch") {
      return { id: "another-request", version: PROTOCOL_VERSION, ok: true, result: { stopping: true } };
    }
    if (mode === "wrong-version") {
      return { id: request.id, version: "9.9", ok: true, result: { stopping: true } };
    }
    if (mode === "malformed-result") {
      return { id: request.id, version: PROTOCOL_VERSION, ok: true, result: {} };
    }
    if (mode === "command-error") {
      return {
        id: request.id,
        version: PROTOCOL_VERSION,
        ok: false,
        error: { code: "TIMEOUT", message: "host timed out" },
      };
    }
    return undefined;
  });
  t.after(() => server.close());
  const client = await connect({ socketPath: server.socketPath });
  t.after(() => client.close());
  modes.set("shutdown", "malformed");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof MalformedResponseError,
  );
  modes.set("shutdown", "oversized");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof ResponseTooLargeError,
  );
  modes.set("shutdown", "multiple");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof MalformedResponseError
      && /more than one/.test(error.cause.message),
  );
  modes.set("shutdown", "delayed-multiple");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof MalformedResponseError
      && /more than one/.test(error.cause.message),
  );
  modes.set("shutdown", "mismatch");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof ResponseIdMismatchError,
  );
  modes.set("shutdown", "wrong-version");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof ProtocolMismatchError,
  );
  modes.set("shutdown", "malformed-result");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof OperationOutcomeUnknown
      && error.cause instanceof MalformedResponseError
      && /missing stopping/.test(error.cause.message),
  );
  for (const mode of ["empty", "partial"]) {
    modes.set("shutdown", mode);
    await assert.rejects(
      client.shutdown(),
      (error) => error instanceof OperationOutcomeUnknown
        && error.cause instanceof MalformedResponseError,
    );
  }
  modes.set("shutdown", "command-error");
  await assert.rejects(
    client.shutdown(),
    (error) => error instanceof CommandError && error.code === "TIMEOUT",
  );
});
