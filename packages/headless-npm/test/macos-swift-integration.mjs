import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { launch, PROTOCOL_VERSION } from "../dist/index.js";
import { runtimeDirectory } from "../dist/transport.js";

if (process.platform !== "darwin") throw new Error("macOS SDK integration requires macOS");
const executable = process.env.HEADLESS_TEST_CLI;
const hostExecutable = process.env.HEADLESS_TEST_HOST;
if (!executable || !isAbsolute(executable)) throw new Error("HEADLESS_TEST_CLI must be absolute");
if (!hostExecutable || !isAbsolute(hostExecutable)) {
  throw new Error("HEADLESS_TEST_HOST must be absolute");
}

const socketPath = join(runtimeDirectory(), `sdk-swift-${randomUUID()}.sock`);
let host;
try {
  host = await launch({
    executable,
    socketPath,
    environment: { HEADLESS_HOST_EXECUTABLE: hostExecutable },
  });
  assert.equal(host.client.hostStatus.ready, true);
  assert.equal(host.client.hostStatus.protocolVersion, PROTOCOL_VERSION);
  const status = await host.client.ping();
  assert.equal(status.pid, host.client.hostStatus.pid);
  const sessions = await host.client.sessionList();
  assert.ok(Array.isArray(sessions.sessions));
} finally {
  await host?.close();
  await rm(socketPath, { force: true });
}
