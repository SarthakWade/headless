import { spawn, type ChildProcess } from "node:child_process";
import { isAbsolute, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { setImmediate as defer } from "node:timers/promises";
import { defaultCacheRoot, ensureInstalled } from "../lib/installer.mjs";
import { connect, type ConnectOptions, HeadlessClient } from "./client.js";
import {
  CommandError,
  HeadlessError,
  HostLaunchError,
  ValidationError,
} from "./errors.js";
import {
  LIFECYCLE_ERROR_CODES,
  LAUNCH_PRESENTATIONS,
  LOCAL_LIFECYCLE,
  MAXIMUM_MESSAGE_BYTES,
  type HostStatus,
  type JsonValue,
  type LaunchPresentation,
  type LifecycleErrorCode,
} from "./generated.js";
import { decodeResponse } from "./protocol.js";
import { defaultSocketPath, validateSocketLocation } from "./transport.js";

const STARTUP_OUTPUT_LIMIT = 64 * 1024;
const DEFAULT_INSTALLATION_TIMEOUT_MS = 300_000;
const DEFAULT_STARTUP_TIMEOUT_MS = 10_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5_000;

export interface LaunchOptions extends Omit<ConnectOptions, "timeoutMs"> {
  readonly allow?: readonly string[];
  readonly environment?: Readonly<NodeJS.ProcessEnv>;
  readonly executable?: string;
  readonly installationTimeoutMs?: number;
  readonly presentation?: LaunchPresentation;
  readonly shutdownTimeoutMs?: number;
  readonly startupTimeoutMs?: number;
}

export interface HostExit {
  readonly code: number | null;
  readonly signal: NodeJS.Signals | null;
}

interface ChildState {
  readonly exited: Promise<HostExit>;
  readonly startup: Promise<HostStatus>;
  readonly violation: Promise<Error>;
  readonly startupViolation: () => Error | undefined;
  readonly output: () => string;
  readonly spawnError: () => Error | undefined;
}

function boundedOutput(child: ChildProcess): ChildState {
  let diagnostics = "";
  let error: Error | undefined;
  let violation: Error | undefined;
  let stdout = Buffer.alloc(0);
  let startupComplete = false;
  let resolveStartup: ((status: HostStatus) => void) | undefined;
  let rejectStartup: ((cause: Error) => void) | undefined;
  let resolveViolation: ((cause: Error) => void) | undefined;
  const startup = new Promise<HostStatus>((resolve, reject) => {
    resolveStartup = resolve;
    rejectStartup = reject;
  });
  const violationPromise = new Promise<Error>((resolve) => {
    resolveViolation = resolve;
  });
  const failStartup = (cause: Error): void => {
    if (violation === undefined) {
      violation = cause;
      resolveViolation?.(cause);
    }
    if (!startupComplete) {
      startupComplete = true;
      rejectStartup?.(cause);
    }
  };
  const appendDiagnostics = (chunk: Buffer): void => {
    if (Buffer.byteLength(diagnostics, "utf8") >= STARTUP_OUTPUT_LIMIT) return;
    diagnostics += chunk.toString("utf8");
    if (Buffer.byteLength(diagnostics, "utf8") > STARTUP_OUTPUT_LIMIT) {
      diagnostics = Buffer.from(diagnostics, "utf8")
        .subarray(0, STARTUP_OUTPUT_LIMIT).toString("utf8");
    }
  };
  child.stderr?.on("data", appendDiagnostics);
  child.stdout?.on("data", (chunk: Buffer) => {
    appendDiagnostics(chunk);
    if (startupComplete) {
      if (chunk.byteLength > 0) failStartup(new HostLaunchError("supervised launcher emitted multiple startup frames"));
      return;
    }
    stdout = Buffer.concat([stdout, chunk], stdout.byteLength + chunk.byteLength);
    if (stdout.byteLength > MAXIMUM_MESSAGE_BYTES) {
      failStartup(new HostLaunchError("supervised launcher startup response exceeded the frame limit"));
      return;
    }
    const newline = stdout.indexOf(0x0a);
    if (newline < 0) return;
    if (stdout.byteLength !== newline + 1) {
      failStartup(new HostLaunchError("supervised launcher emitted multiple startup frames"));
      return;
    }
    let decoded: unknown;
    try {
      decoded = JSON.parse(stdout.subarray(0, newline).toString("utf8"));
      if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)
        || typeof (decoded as Record<string, unknown>).id !== "string") {
        throw new Error("startup response has no request id");
      }
      const id = (decoded as Record<string, unknown>).id as string;
      const status = decodeResponse(stdout.subarray(0, newline), id, "ping");
      startupComplete = true;
      resolveStartup?.(status);
    } catch (cause) {
      if (cause instanceof CommandError && isLifecycleErrorCode(cause.code)) {
        failStartup(new HostLaunchError(cause.message, {
          code: cause.code,
          ...(cause.suggestion === undefined ? {} : { suggestion: cause.suggestion }),
          ...(cause.details === undefined ? {} : { details: cause.details as JsonValue }),
          cause,
        }));
      } else {
        failStartup(new HostLaunchError("supervised launcher returned an invalid startup response", {
          cause,
        }));
      }
    }
  });
  const exited = new Promise<HostExit>((resolve) => {
    child.once("error", (cause) => {
      error = cause;
      failStartup(new HostLaunchError("could not spawn the supervised Headless launcher", { cause }));
      resolve({ code: null, signal: null });
    });
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  return {
    exited,
    startup,
    violation: violationPromise,
    startupViolation: () => violation,
    output: () => diagnostics.trim(),
    spawnError: () => error,
  };
}

function isLifecycleErrorCode(code: string): code is LifecycleErrorCode {
  return (LIFECYCLE_ERROR_CODES as readonly string[]).includes(code);
}

function setReferenced(handle: unknown, referenced: boolean): void {
  if (typeof handle !== "object" || handle === null) return;
  const referenceable = handle as { ref?: () => void; unref?: () => void };
  if (referenced) referenceable.ref?.();
  else referenceable.unref?.();
}

function setChildReferenced(child: ChildProcess, referenced: boolean): void {
  setReferenced(child, referenced);
  setReferenced(child.stdin, referenced);
  setReferenced(child.stdout, referenced);
  setReferenced(child.stderr, referenced);
}

async function waitForExit(child: ChildProcess, exited: Promise<HostExit>, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) {
    await exited;
    return true;
  }
  return Promise.race([
    exited.then(() => true),
    delay(timeoutMs, false, { ref: false }),
  ]);
}

async function terminateAndAwait(
  child: ChildProcess,
  exited: Promise<HostExit>,
  timeoutMs: number,
): Promise<void> {
  setChildReferenced(child, true);
  child.stdin?.end();
  if (await waitForExit(child, exited, timeoutMs)) return;
  child.kill("SIGTERM");
  if (await waitForExit(child, exited, timeoutMs)) return;
  child.kill("SIGKILL");
  await exited;
}

const ownedHosts = new Set<HeadlessHost>();
let hooksInstalled = false;

const closeBeforeExit = (): void => {
  for (const host of ownedHosts) host.close().catch(() => {});
};

function installOwnershipHooks(): void {
  if (hooksInstalled) return;
  hooksInstalled = true;
  process.on("beforeExit", closeBeforeExit);
}

function removeOwnershipHooksIfUnused(): void {
  if (!hooksInstalled || ownedHosts.size > 0) return;
  hooksInstalled = false;
  process.removeListener("beforeExit", closeBeforeExit);
}

export class HeadlessHost {
  readonly client: HeadlessClient;
  readonly exited: Promise<HostExit>;
  readonly #launcher: ChildProcess;
  readonly #shutdownTimeoutMs: number;
  #closePromise: Promise<void> | undefined;

  constructor(
    client: HeadlessClient,
    launcher: ChildProcess,
    exited: Promise<HostExit>,
    violation: Promise<Error>,
    shutdownTimeoutMs: number,
  ) {
    this.client = client;
    this.#launcher = launcher;
    this.exited = exited;
    this.#shutdownTimeoutMs = shutdownTimeoutMs;
    ownedHosts.add(this);
    installOwnershipHooks();
    exited.finally(() => {
      this.client.close();
      ownedHosts.delete(this);
      removeOwnershipHooksIfUnused();
    });
    void violation.then(() => this.close()).catch(() => {});
    setChildReferenced(launcher, false);
  }

  close(): Promise<void> {
    if (this.#closePromise) return this.#closePromise;
    this.client.close();
    this.#closePromise = terminateAndAwait(
      this.#launcher,
      this.exited,
      this.#shutdownTimeoutMs,
    ).finally(() => {
      ownedHosts.delete(this);
      removeOwnershipHooksIfUnused();
    });
    return this.#closePromise;
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }
}

function validateBoundedTimeout(name: string, value: number, maximum: number): void {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw new ValidationError(`${name} must be an integer between 1 and ${maximum}`);
  }
}

async function executableFor(options: LaunchOptions, signal: AbortSignal): Promise<string> {
  if (options.executable !== undefined) {
    if (!options.executable) throw new ValidationError("executable must not be empty");
    if (!isAbsolute(options.executable)) throw new ValidationError("executable must be an absolute path");
    return options.executable;
  }
  let installed;
  try {
    const environment = { ...process.env, ...options.environment };
    installed = await ensureInstalled({
      cacheRoot: defaultCacheRoot(process.platform, environment),
      signal,
    });
  } catch (cause) {
    if (options.signal?.aborted) {
      throw new HostLaunchError("supervised launch was cancelled during installation", { cause });
    }
    if (signal.aborted) {
      throw new HostLaunchError(
        "verified Headless installation did not complete before the deadline",
        { cause },
      );
    }
    throw new HostLaunchError("could not install the Headless launcher", { cause });
  }
  return join(installed.directory, installed.release.executable);
}

function startupError(state: ChildState, exit: HostExit): HostLaunchError {
  const cause = state.spawnError();
  const details = state.output();
  const suffix = details ? `: ${details}` : "";
  return new HostLaunchError(`supervised Headless launcher exited before readiness${suffix}`, {
    ...(cause === undefined ? {} : { cause }),
    exitCode: exit.code,
    signal: exit.signal,
  });
}

export async function launch(options: LaunchOptions = {}): Promise<HeadlessHost> {
  if ((options as Readonly<Record<string, unknown>>).timeoutMs !== undefined) {
    throw new ValidationError(
      "launch does not accept timeoutMs; use startupTimeoutMs and per-command timeouts",
    );
  }
  const startupTimeoutMs = options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS;
  const installationTimeoutMs = options.installationTimeoutMs ?? DEFAULT_INSTALLATION_TIMEOUT_MS;
  const shutdownTimeoutMs = options.shutdownTimeoutMs ?? DEFAULT_SHUTDOWN_TIMEOUT_MS;
  validateBoundedTimeout("installationTimeoutMs", installationTimeoutMs, 600_000);
  validateBoundedTimeout("startupTimeoutMs", startupTimeoutMs, 120_000);
  validateBoundedTimeout("shutdownTimeoutMs", shutdownTimeoutMs, 30_000);
  const hostExecutable = options.environment?.HEADLESS_HOST_EXECUTABLE;
  if (hostExecutable !== undefined && !isAbsolute(hostExecutable)) {
    throw new ValidationError("HEADLESS_HOST_EXECUTABLE must be an absolute path");
  }
  if (options.signal?.aborted) throw new HostLaunchError("supervised launch was cancelled before spawn");

  const installationDeadlineSignal = AbortSignal.timeout(installationTimeoutMs);
  const installationSignal = options.signal === undefined
    ? installationDeadlineSignal
    : AbortSignal.any([options.signal, installationDeadlineSignal]);
  const executable = await executableFor(options, installationSignal);
  if (options.signal?.aborted) throw new HostLaunchError("supervised launch was cancelled before spawn");
  if (installationDeadlineSignal.aborted) {
    throw new HostLaunchError("verified Headless installation did not complete before the deadline");
  }
  const deadline = Date.now() + startupTimeoutMs;
  const deadlineSignal = AbortSignal.timeout(startupTimeoutMs);
  const startupSignal = options.signal === undefined
    ? deadlineSignal
    : AbortSignal.any([options.signal, deadlineSignal]);
  const socketPath = options.socketPath ?? defaultSocketPath(options.environment ?? process.env);
  validateSocketLocation(socketPath);
  const presentation = options.presentation ?? "background";
  if (!(LAUNCH_PRESENTATIONS as readonly string[]).includes(presentation)) {
    throw new ValidationError(`presentation must be one of ${LAUNCH_PRESENTATIONS.join(", ")}`);
  }
  const presentationFlags = new Set(LAUNCH_PRESENTATIONS.map((value) => `--${value}`));
  const generatedPresentationFlags = LOCAL_LIFECYCLE.launch.argv
    .filter((argument) => presentationFlags.has(argument));
  if (generatedPresentationFlags.length !== 1) {
    throw new ValidationError("generated launch argv has an invalid presentation flag");
  }
  const argumentsList: string[] = LOCAL_LIFECYCLE.launch.argv.map((argument) => (
    presentationFlags.has(argument) ? `--${presentation}` : argument
  ));
  const allowDefinition = LOCAL_LIFECYCLE.launch.options.find((option) => option.name === "allow");
  const allow = options.allow ?? [];
  if (!allowDefinition || allow.length > allowDefinition.maximumItems) {
    throw new ValidationError("allowlist has too many patterns");
  }
  for (const pattern of allow) {
    if (!pattern || Buffer.byteLength(pattern, "utf8") > allowDefinition.itemMaximumBytes) {
      throw new ValidationError("allowlist patterns are empty or exceed the schema limit");
    }
    argumentsList.push("--allow", pattern);
  }
  const child = spawn(executable, argumentsList, {
    env: {
      ...process.env,
      ...options.environment,
      HEADLESS_SOCKET: socketPath,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const state = boundedOutput(child);
  let client: HeadlessClient | undefined;
  let abortListener: (() => void) | undefined;
  const aborted = new Promise<never>((_resolve, reject) => {
    abortListener = () => reject(new HostLaunchError(
      options.signal?.aborted
        ? "supervised launch was cancelled during startup"
        : "supervised Headless launcher did not become ready before the deadline",
    ));
    startupSignal.addEventListener("abort", abortListener, { once: true });
  });
  try {
    const startup = await Promise.race([
      state.startup,
      state.exited.then((exit) => { throw startupError(state, exit); }),
      delay(Math.max(1, deadline - Date.now()), undefined, { ref: false }).then(() => {
        throw new HostLaunchError("supervised Headless launcher did not become ready before the deadline");
      }),
      aborted,
    ]);
    if (!Number.isSafeInteger(startup.pid) || startup.pid <= 0) {
      throw new HostLaunchError("supervised launcher returned an invalid host pid");
    }
    if (!startup.ready) {
      throw new HostLaunchError("supervised launcher reported a host that is not ready");
    }
    await defer(undefined, { ref: false });
    if (state.startupViolation()) throw state.startupViolation();
    if (child.exitCode !== null || child.signalCode !== null || state.spawnError() !== undefined) {
      throw startupError(state, await state.exited);
    }
    const remaining = deadline - Date.now();
    if (remaining < 1) {
      throw new HostLaunchError("supervised Headless launcher did not become ready before the deadline");
    }
    client = await connect({
      socketPath,
      timeoutMs: remaining,
      signal: startupSignal,
    });
    if (!Number.isSafeInteger(client.hostStatus.pid) || client.hostStatus.pid <= 0) {
      throw new HostLaunchError("connected Headless host returned an invalid pid");
    }
    if (client.hostStatus.pid !== startup.pid) {
      throw new HostLaunchError(
        `supervised launcher reported host pid ${startup.pid}, but the socket belongs to pid ${client.hostStatus.pid}`,
      );
    }
    await defer(undefined, { ref: false });
    if (state.startupViolation()) throw state.startupViolation();
    if (child.exitCode !== null || child.signalCode !== null || state.spawnError() !== undefined) {
      throw startupError(state, await state.exited);
    }
    return new HeadlessHost(client, child, state.exited, state.violation, shutdownTimeoutMs);
  } catch (error) {
    const cancelledByUser = options.signal?.aborted === true;
    const timedOut = deadlineSignal.aborted;
    client?.close();
    await terminateAndAwait(child, state.exited, shutdownTimeoutMs);
    if (cancelledByUser) {
      throw new HostLaunchError("supervised launch was cancelled during startup", { cause: error });
    }
    if (timedOut) {
      throw new HostLaunchError(
        "supervised Headless launcher did not become ready before the deadline",
        { cause: error },
      );
    }
    if (error instanceof HeadlessError) throw error;
    throw new HostLaunchError("supervised Headless launch failed", { cause: error });
  } finally {
    if (abortListener) startupSignal.removeEventListener("abort", abortListener);
  }
}
