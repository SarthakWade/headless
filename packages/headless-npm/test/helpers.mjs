import { randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { join } from "node:path";
import { COMMAND_METADATA, MAXIMUM_MESSAGE_BYTES, PROTOCOL_VERSION } from "../dist/index.js";
import { runtimeDirectory } from "../dist/transport.js";

export const allCommands = Object.keys(COMMAND_METADATA);

export async function uniqueSocketPath(prefix = "sdk-test") {
  const directory = runtimeDirectory();
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== process.getuid()
    || (metadata.mode & 0o077) !== 0) {
    throw new Error(`test runtime directory is unsafe: ${directory}`);
  }
  return join(directory, `${prefix}-${randomUUID()}.sock`);
}

export function hostStatus(id, pid = process.pid, commands = allCommands) {
  return {
    id,
    version: PROTOCOL_VERSION,
    ok: true,
    result: {
      ready: true,
      pid,
      engine: "chromium",
      platform: "linux",
      productVersion: "1.1.0-test",
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { commands },
      recordingAvailable: false,
      artifactDirectory: "/private/test-artifacts",
      navigationAllowlist: [],
    },
  };
}

export async function privateSocketServer(handler) {
  const socketPath = await uniqueSocketPath();
  const server = createServer((socket) => {
    let requestBytes = Buffer.alloc(0);
    socket.on("error", () => {});
    socket.on("data", async (chunk) => {
      requestBytes = Buffer.concat([requestBytes, chunk], requestBytes.byteLength + chunk.byteLength);
      if (requestBytes.byteLength > MAXIMUM_MESSAGE_BYTES) {
        socket.destroy();
        return;
      }
      const newline = requestBytes.indexOf(0x0a);
      if (newline < 0) return;
      socket.removeAllListeners("data");
      const request = JSON.parse(requestBytes.subarray(0, newline).toString("utf8"));
      const response = await handler(request, socket);
      if (response === undefined || socket.destroyed) return;
      if (Buffer.isBuffer(response)) socket.end(response);
      else socket.end(`${JSON.stringify(response)}\n`);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  await chmod(socketPath, 0o600);
  return {
    socketPath,
    async close() {
      await new Promise((resolve) => server.close(resolve));
      await rm(socketPath, { force: true });
    },
  };
}
