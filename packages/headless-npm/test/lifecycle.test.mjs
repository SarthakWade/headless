import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import {
  connect,
  HostLaunchError,
  launch,
  LOCAL_LIFECYCLE,
  PROTOCOL_VERSION,
} from "../dist/index.js";
import { allCommands, hostStatus, privateSocketServer, uniqueSocketPath } from "./helpers.mjs";
import { packageVersion, platformRelease } from "../lib/installer.mjs";

async function socketFor(t, prefix) {
  const socketPath = await uniqueSocketPath(prefix);
  t.after(() => rm(socketPath, { force: true }));
  return socketPath;
}

function withDeadline(promise, milliseconds, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), milliseconds);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

async function mockLauncher(t) {
  const directory = await mkdtemp(join(tmpdir(), "headless-sdk-launcher."));
  const executable = join(directory, "headless-test.mjs");
  await writeFile(executable, `#!/usr/bin/env node
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { dirname } from "node:path";

const expectedPresentation = process.env.HEADLESS_TEST_EXPECT_PRESENTATION;
const expected = [
  "start",
  ...(expectedPresentation ? ["--" + expectedPresentation] : []),
  "--supervised",
];
if (JSON.stringify(process.argv.slice(2, 2 + expected.length)) !== JSON.stringify(expected)) {
  process.exit(64);
}
const mode = process.env.HEADLESS_TEST_MODE ?? "owned";
const socketPath = process.env.HEADLESS_SOCKET;
const commands = JSON.parse(process.env.HEADLESS_TEST_COMMANDS);
const pidFile = process.env.HEADLESS_TEST_PID_FILE;
if (pidFile) writeFileSync(pidFile, String(process.pid));
if (mode === "failure") process.exit(7);
if (mode === "failure-envelope") {
  process.stdout.write(JSON.stringify({
    id: "startup-failure",
    version: "${PROTOCOL_VERSION}",
    ok: false,
    error: {
      code: "NAVIGATION_ALLOWLIST_CONFLICT",
      message: "an incompatible host is already running",
      suggestion: "stop the existing host",
      details: { existing: ["one.example"], requested: ["two.example"] },
    },
  }) + "\\n");
  process.stdin.resume();
}

const status = (id, pid) => ({
  id,
  version: "${PROTOCOL_VERSION}",
  ok: true,
  result: {
    ready: true,
    pid,
    engine: "chromium",
    platform: "linux",
    productVersion: "1.1.0-test",
    protocolVersion: "${PROTOCOL_VERSION}",
    capabilities: { commands },
    recordingAvailable: false,
    artifactDirectory: "/private/test-artifacts",
    navigationAllowlist: [],
  },
});

let server;
if (mode !== "existing" && mode !== "no-frame" && mode !== "malformed" && mode !== "multiple") {
  mkdirSync(dirname(socketPath), { recursive: true, mode: 0o700 });
  rmSync(socketPath, { force: true });
  server = createServer((socket) => {
    let bytes = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      bytes = Buffer.concat([bytes, chunk]);
      const newline = bytes.indexOf(0x0a);
      if (newline < 0) return;
      const request = JSON.parse(bytes.subarray(0, newline));
      socket.end(JSON.stringify(status(request.id, Number(process.env.HEADLESS_TEST_SOCKET_PID ?? process.pid))) + "\\n");
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  chmodSync(socketPath, 0o600);
}

if (mode === "malformed") process.stdout.write("not-json\\n");
else if (mode === "multiple") {
  const line = JSON.stringify(status("startup", process.pid)) + "\\n";
  process.stdout.write(line + line);
} else if (mode !== "no-frame" && mode !== "failure-envelope") {
  process.stdout.write(JSON.stringify(status(
    "startup",
    Number(process.env.HEADLESS_TEST_STARTUP_PID ?? process.pid),
  )) + "\\n");
  if (mode === "delayed-multiple") {
    setTimeout(() => process.stdout.write(JSON.stringify(status("late", process.pid)) + "\\n"), 75);
  }
}

process.stdin.resume();
const stop = () => {
  if (server) server.close(() => process.exit(0));
  else process.exit(0);
};
process.stdin.on("end", stop);
process.on("SIGTERM", stop);
if (process.env.HEADLESS_TEST_EXIT_AFTER_MS) {
  setTimeout(stop, Number(process.env.HEADLESS_TEST_EXIT_AFTER_MS));
}
`);
  await chmod(executable, 0o755);
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { directory, executable };
}

function launchEnvironment(extra = {}) {
  return {
    HEADLESS_TEST_COMMANDS: JSON.stringify(allCommands),
    ...extra,
  };
}

test("supervised launch uses generated argv and owns only the matching host", async (t) => {
  const fixture = await mockLauncher(t);
  const socketPath = await socketFor(t, "owned");
  const signalListeners = {
    SIGINT: process.listenerCount("SIGINT"),
    SIGTERM: process.listenerCount("SIGTERM"),
  };
  const host = await launch({
    executable: fixture.executable,
    socketPath,
    environment: launchEnvironment(),
  });
  assert.deepEqual(LOCAL_LIFECYCLE.launch.argv, ["start", "--supervised"]);
  assert.equal(host.client.hostStatus.pid > 0, true);
  assert.deepEqual(
    { SIGINT: process.listenerCount("SIGINT"), SIGTERM: process.listenerCount("SIGTERM") },
    signalListeners,
  );
  host.client.close();
  const exitedEarly = await Promise.race([host.exited.then(() => true), delay(50, false)]);
  assert.equal(exitedEarly, false, "closing an SDK client must not stop its owned launcher implicitly");
  await host.close();
  assert.deepEqual(await host.exited, { code: 0, signal: null });
});

test("connect attaches to a shared host and close never shuts it down", async (t) => {
  const server = await privateSocketServer((request) => hostStatus(request.id, 7101));
  t.after(() => server.close());
  const first = await connect({ socketPath: server.socketPath });
  first.close();
  const second = await connect({ socketPath: server.socketPath });
  assert.equal(second.hostStatus.pid, 7101);
  second.close();
});

test("supervised launch derives foreground presentation argv from the schema", async (t) => {
  const fixture = await mockLauncher(t);
  const host = await launch({
    executable: fixture.executable,
    socketPath: await socketFor(t, "foreground"),
    presentation: "foreground",
    environment: launchEnvironment({ HEADLESS_TEST_EXPECT_PRESENTATION: "foreground" }),
  });
  await host.close();
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "bad-presentation"),
      presentation: "sideways",
    }),
    /presentation must be one of/,
  );
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "bad-timeout"),
      timeoutMs: 100,
    }),
    /does not accept timeoutMs/,
  );
});

test("concurrent shared host cannot be claimed or stopped by supervised launch", async (t) => {
  let requests = 0;
  const shared = await privateSocketServer((request) => {
    requests += 1;
    return hostStatus(request.id, 7201);
  });
  t.after(() => shared.close());
  const fixture = await mockLauncher(t);
  const launcherPidFile = join(fixture.directory, "race-launcher.pid");
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: shared.socketPath,
      environment: launchEnvironment({
        HEADLESS_TEST_MODE: "existing",
        HEADLESS_TEST_PID_FILE: launcherPidFile,
        HEADLESS_TEST_STARTUP_PID: "7202",
      }),
    }),
    (error) => error instanceof HostLaunchError && /pid 7202.*pid 7201/.test(error.message),
  );
  const launcherPid = Number(await readFile(launcherPidFile, "utf8"));
  assert.throws(() => process.kill(launcherPid, 0), /ESRCH/);
  const client = await connect({ socketPath: shared.socketPath });
  assert.equal(client.hostStatus.pid, 7201);
  client.close();
  assert.equal(requests, 2, "the failed ownership check and later attach should both reach the shared host");
});

test("missing binary and startup failure are typed and fully awaited", async (t) => {
  const fixture = await mockLauncher(t);
  const otherPrivateDirectory = await mkdtemp(join(tmpdir(), "headless-other-private."));
  t.after(() => rm(otherPrivateDirectory, { recursive: true, force: true }));
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: join(otherPrivateDirectory, "launch.sock"),
    }),
    /direct child of the Headless runtime directory/,
  );
  await assert.rejects(
    launch({ executable: join(fixture.directory, "missing"), socketPath: await socketFor(t, "missing") }),
    HostLaunchError,
  );
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "failed"),
      environment: launchEnvironment({ HEADLESS_TEST_MODE: "failure" }),
    }),
    (error) => error instanceof HostLaunchError && error.exitCode === 7,
  );
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "failure-envelope"),
      environment: launchEnvironment({ HEADLESS_TEST_MODE: "failure-envelope" }),
    }),
    (error) => error instanceof HostLaunchError
      && error.code === "NAVIGATION_ALLOWLIST_CONFLICT"
      && error.suggestion === "stop the existing host"
      && error.details.requested[0] === "two.example",
  );
  await assert.rejects(
    launch({ executable: "relative/headless", socketPath: await socketFor(t, "relative") }),
    /executable must be an absolute path/,
  );
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "relative-host"),
      environment: launchEnvironment({ HEADLESS_HOST_EXECUTABLE: "relative/host" }),
    }),
    /HEADLESS_HOST_EXECUTABLE must be an absolute path/,
  );
});

test("startup timeout terminates and reaps only its launcher", async (t) => {
  const fixture = await mockLauncher(t);
  const pidFile = join(fixture.directory, "launcher.pid");
  await assert.rejects(
    launch({
      executable: fixture.executable,
      socketPath: await socketFor(t, "timeout"),
      startupTimeoutMs: 500,
      shutdownTimeoutMs: 100,
      environment: launchEnvironment({
        HEADLESS_TEST_MODE: "no-frame",
        HEADLESS_TEST_PID_FILE: pidFile,
      }),
    }),
    HostLaunchError,
  );
  const pid = Number(await readFile(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});

test("installation has a separate bounded deadline", async (t) => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "headless-sdk-install-timeout."));
  t.after(() => rm(cacheRoot, { recursive: true, force: true }));
  const version = await packageVersion();
  const release = platformRelease(version);
  const lockPath = join(cacheRoot, `v${version}`, `${release.key}.lock`);
  await mkdir(lockPath, { recursive: true, mode: 0o700 });
  const startedAt = Date.now();
  await assert.rejects(
    launch({
      environment: { HEADLESS_NPM_CACHE: cacheRoot },
      installationTimeoutMs: 50,
    }),
    (error) => error instanceof HostLaunchError && /deadline/.test(error.message),
  );
  assert.ok(Date.now() - startedAt < 2_000, "installation ignored the launch deadline");
  assert.equal((await stat(lockPath)).isDirectory(), true);
});

test("malformed and multiple startup frames fail closed", async (t) => {
  const fixture = await mockLauncher(t);
  for (const mode of ["malformed", "multiple"]) {
    await assert.rejects(
      launch({
        executable: fixture.executable,
        socketPath: await socketFor(t, mode),
        environment: launchEnvironment({ HEADLESS_TEST_MODE: mode }),
      }),
      HostLaunchError,
    );
  }
});

test("unexpected owned host termination closes its client", async (t) => {
  const fixture = await mockLauncher(t);
  const host = await launch({
    executable: fixture.executable,
    socketPath: await socketFor(t, "terminates"),
    environment: launchEnvironment({ HEADLESS_TEST_EXIT_AFTER_MS: "150" }),
  });
  await withDeadline(host.exited, 2_000, "owned launcher did not exit");
  await assert.rejects(host.client.ping(), /client is closed/);
});

test("delayed extra startup output closes the client and reaps the owned launcher", async (t) => {
  const fixture = await mockLauncher(t);
  const pidFile = join(fixture.directory, "delayed.pid");
  const host = await launch({
    executable: fixture.executable,
    socketPath: await socketFor(t, "delayed"),
    environment: launchEnvironment({
      HEADLESS_TEST_MODE: "delayed-multiple",
      HEADLESS_TEST_PID_FILE: pidFile,
    }),
  });
  await withDeadline(host.exited, 2_000, "delayed startup violation did not stop the launcher");
  await assert.rejects(host.client.ping(), /client is closed/);
  const pid = Number(await readFile(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});

test("an unreferenced owned launcher is closed and reaped during natural Node exit", async (t) => {
  const fixture = await mockLauncher(t);
  const socketPath = await socketFor(t, "natural-exit");
  const pidFile = join(fixture.directory, "natural-exit.pid");
  const entrypoint = pathToFileURL(join(process.cwd(), "dist/index.js")).href;
  const script = `
    import { launch } from ${JSON.stringify(entrypoint)};
    await launch({
      executable: ${JSON.stringify(fixture.executable)},
      socketPath: ${JSON.stringify(socketPath)},
      environment: {
        HEADLESS_TEST_COMMANDS: ${JSON.stringify(JSON.stringify(allCommands))},
        HEADLESS_TEST_PID_FILE: ${JSON.stringify(pidFile)}
      }
    });
  `;
  const child = spawn(process.execPath, ["--input-type=module", "--eval", script], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const result = await Promise.race([
    new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal }))),
    delay(5_000).then(() => ({ timeout: true })),
  ]);
  if (result.timeout) child.kill("SIGKILL");
  assert.deepEqual(result, { code: 0, signal: null }, stderr);
  const pid = Number(await readFile(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
});
