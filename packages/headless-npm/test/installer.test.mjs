import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { after, before, test } from "node:test";
import {
  checksumFromManifest,
  defaultCacheRoot,
  ensureInstalled,
  InstallCancelledError,
  InstallError,
  platformRelease,
  run,
  validateArchiveEntries,
} from "../lib/installer.mjs";

const root = mkdtempSync(join(tmpdir(), "headless-npm-test."));
const fixture = join(root, "fixture");
const version = "9.8.7";
const asset = `headless-${version}-linux-amd64.tar.gz`;
const archive = join(root, asset);
let server;
let baseURL;
let requestCount = 0;
let servedManifest;

before(async () => {
  mkdirSync(join(fixture, "Headless_HeadlessProtocol.resources"), { recursive: true });
  for (const executable of [
    "headless", "headless-host", "headless-mcp", "headless-credential-broker", "install-linux.sh",
  ]) {
    const body = executable === "headless"
      ? `#!/bin/sh\nif [ "$1" = --version ]; then echo 'headless ${version}'; else echo wrapper-ok; fi\n`
      : "#!/bin/sh\nexit 0\n";
    writeFileSync(join(fixture, executable), body, { mode: 0o755 });
    chmodSync(join(fixture, executable), 0o755);
  }
  writeFileSync(join(fixture, "Headless_HeadlessProtocol.resources", "AgentRuntime.js"), "// fixture\n");
  const packed = spawnSync("/usr/bin/tar", [
    "-czf",
    archive,
    "-C",
    fixture,
    "headless",
    "headless-host",
    "headless-mcp",
    "headless-credential-broker",
    "install-linux.sh",
    "Headless_HeadlessProtocol.resources",
  ], { encoding: "utf8" });
  assert.equal(packed.status, 0, packed.stderr);
  const archiveBytes = readFileSync(archive);
  const checksum = createHash("sha256").update(archiveBytes).digest("hex");
  servedManifest = `${checksum}  ${asset}\n`;
  server = createServer((request, response) => {
    requestCount += 1;
    if (request.url.endsWith("/SHA256SUMS")) {
      response.end(servedManifest);
    } else if (request.url.endsWith(`/${asset}`)) {
      response.setHeader("transfer-encoding", "chunked");
      response.write(archiveBytes.subarray(0, Math.ceil(archiveBytes.length / 2)));
      response.end(archiveBytes.subarray(Math.ceil(archiveBytes.length / 2)));
    } else {
      response.statusCode = 404;
      response.end();
    }
  });
  await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  baseURL = `http://127.0.0.1:${server.address().port}/v${version}`;
});

after(async () => {
  await new Promise((resolvePromise) => server.close(resolvePromise));
  rmSync(root, { recursive: true, force: true });
});

test("maps only supported release platforms", () => {
  assert.equal(platformRelease(version, "linux", "x64").asset, asset);
  assert.equal(platformRelease(version, "linux", "arm64").key, "linux-arm64");
  assert.equal(platformRelease(version, "darwin", "arm64").kind, "zip");
  assert.throws(() => platformRelease(version, "win32", "x64"), InstallError);
  assert.throws(() => platformRelease("../bad", "linux", "x64"), InstallError);
});

test("requires an absolute cache override", () => {
  assert.throws(
    () => defaultCacheRoot("linux", { HEADLESS_NPM_CACHE: "relative" }),
    /absolute path/,
  );
});

test("parses one exact manifest entry", () => {
  const digest = "a".repeat(64);
  assert.equal(checksumFromManifest(`${digest}  ${asset}\n`, asset), digest);
  assert.throws(() => checksumFromManifest("", asset), /exactly one/);
  assert.throws(
    () => checksumFromManifest(`${digest}  ${asset}\n${digest}  ${asset}\n`, asset),
    /exactly one/,
  );
});

test("rejects archive traversal and missing runtime files", () => {
  assert.throws(() => validateArchiveEntries("../escape\n", "tar.gz"), /unsafe path/);
  assert.throws(() => validateArchiveEntries("safe//file\n", "tar.gz"), /unsafe path/);
  assert.throws(() => validateArchiveEntries("safe/file\nsafe/file/\n", "tar.gz"), /duplicate path/);
  assert.throws(() => validateArchiveEntries("headless\n", "tar.gz"), /missing headless-host/);
  assert.throws(
    () => validateArchiveEntries("Headless.app/Contents/MacOS/Headless\noutside\n", "zip"),
    /missing Headless.app\/Contents\/Resources\/bin\/headless/,
  );
});

test("rejects a release whose checksum does not match", async () => {
  const validManifest = servedManifest;
  servedManifest = `${"0".repeat(64)}  ${asset}\n`;
  try {
    await assert.rejects(
      ensureInstalled({
        version,
        platform: "linux",
        architecture: "x64",
        cacheRoot: join(root, "bad-checksum-cache"),
        releaseBaseURL: baseURL,
        allowedHosts: new Set(["127.0.0.1"]),
        allowHTTP: true,
        allowCustomPort: true,
      }),
      /checksum mismatch/,
    );
  } finally {
    servedManifest = validManifest;
  }
});

test("downloads, verifies, installs, and reuses the cached release", async () => {
  const cacheRoot = join(root, "cache");
  const options = {
    version,
    platform: "linux",
    architecture: "x64",
    cacheRoot,
    releaseBaseURL: baseURL,
    allowedHosts: new Set(["127.0.0.1"]),
    allowHTTP: true,
    allowCustomPort: true,
  };
  const first = await ensureInstalled(options);
  assert.equal(first.release.asset, asset);
  const command = spawnSync(join(first.directory, first.release.executable), [], { encoding: "utf8" });
  assert.equal(command.status, 0);
  assert.equal(command.stdout.trim(), "wrapper-ok");
  const afterFirst = requestCount;
  const second = await ensureInstalled(options);
  assert.equal(second.directory, first.directory);
  assert.equal(requestCount, afterFirst, "a valid cache entry must not redownload");
});

test("cancellation interrupts lock waits without deleting another installer's lock", async () => {
  const cacheRoot = join(root, "cancel-lock-cache");
  const lockPath = join(cacheRoot, `v${version}`, "linux-amd64.lock");
  mkdirSync(lockPath, { recursive: true, mode: 0o700 });
  const controller = new AbortController();
  const pending = ensureInstalled({
    version,
    platform: "linux",
    architecture: "x64",
    cacheRoot,
    signal: controller.signal,
  });
  setTimeout(() => controller.abort(), 25);
  await assert.rejects(pending, InstallCancelledError);
  assert.equal(existsSync(lockPath), true);
});

test("cancellation aborts release fetches and rolls back owned staging", async () => {
  const cacheRoot = join(root, "cancel-fetch-cache");
  const controller = new AbortController();
  let fetchStarted;
  const started = new Promise((resolvePromise) => { fetchStarted = resolvePromise; });
  const fetchImpl = async (_url, options) => {
    fetchStarted();
    return new Promise((_resolve, rejectPromise) => {
      options.signal.addEventListener("abort", () => rejectPromise(options.signal.reason), { once: true });
    });
  };
  const pending = ensureInstalled({
    version,
    platform: "linux",
    architecture: "x64",
    cacheRoot,
    releaseBaseURL: `https://github.com/${version}`,
    fetchImpl,
    signal: controller.signal,
  });
  await started;
  controller.abort();
  await assert.rejects(pending, InstallCancelledError);
  assert.equal(existsSync(join(cacheRoot, `v${version}`, "linux-amd64")), false);
  assert.equal(existsSync(join(cacheRoot, `v${version}`, "linux-amd64.lock")), false);
});

test("cancellation interrupts asset streaming and removes partial downloads", async () => {
  const cacheRoot = join(root, "cancel-stream-cache");
  const controller = new AbortController();
  let request = 0;
  let assetStarted;
  const started = new Promise((resolvePromise) => { assetStarted = resolvePromise; });
  const fetchImpl = async (_url, options) => {
    request += 1;
    if (request === 1) {
      return new Response(`${"0".repeat(64)}  ${asset}\n`);
    }
    return new Response(new ReadableStream({
      start(stream) {
        stream.enqueue(new Uint8Array([1, 2, 3]));
        assetStarted();
        options.signal.addEventListener("abort", () => stream.error(options.signal.reason), { once: true });
      },
    }));
  };
  const pending = ensureInstalled({
    version,
    platform: "linux",
    architecture: "x64",
    cacheRoot,
    releaseBaseURL: `https://github.com/${version}`,
    fetchImpl,
    signal: controller.signal,
  });
  await started;
  controller.abort();
  await assert.rejects(pending, InstallCancelledError);
  assert.equal(existsSync(join(cacheRoot, `v${version}`, "linux-amd64")), false);
  assert.equal(existsSync(join(cacheRoot, `v${version}`, "linux-amd64.lock")), false);
});

test("cancellation terminates and reaps installer child processes", async () => {
  const pidFile = join(root, "cancelled-child.pid");
  const controller = new AbortController();
  const pending = run(process.execPath, [
    "--eval",
    `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);`,
  ], { signal: controller.signal });
  for (let attempt = 0; attempt < 100 && !existsSync(pidFile); attempt += 1) {
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  assert.equal(existsSync(pidFile), true);
  const pid = Number(readFileSync(pidFile, "utf8"));
  controller.abort();
  await assert.rejects(pending, InstallCancelledError);
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});

test("installer child output is bounded and the child is reaped", async () => {
  const pidFile = join(root, "oversized-output-child.pid");
  const pending = run(process.execPath, [
    "--eval",
    `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); process.stdout.write('x'.repeat(2 * 1024 * 1024)); setInterval(() => {}, 1000);`,
  ]);
  await assert.rejects(pending, /stdout exceeded/);
  const pid = Number(readFileSync(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});

test("installer subprocess timeout terminates and reaps a silent child", async () => {
  const pidFile = join(root, "timed-out-child.pid");
  const pending = run(process.execPath, [
    "--eval",
    `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);`,
  ], { timeoutMilliseconds: 250 });
  await assert.rejects(pending, /timed out after 250 ms/);
  const pid = Number(readFileSync(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});
