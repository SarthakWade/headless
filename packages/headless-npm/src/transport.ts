import { lstat } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  CancelledBeforeSend,
  ClientClosedError,
  ConnectionError,
  MalformedResponseError,
  OperationOutcomeUnknown,
  ResponseTooLargeError,
  TimeoutBeforeSend,
  ValidationError,
} from "./errors.js";
import { MAXIMUM_COMMAND_TIMEOUT_MS, MAXIMUM_MESSAGE_BYTES } from "./generated.js";

export function defaultSocketPath(environment: NodeJS.ProcessEnv = process.env): string {
  const override = environment.HEADLESS_SOCKET;
  if (override !== undefined) {
    validateSocketLocation(override, "HEADLESS_SOCKET");
    return override;
  }
  return join(runtimeDirectory(), "host.sock");
}

export function runtimeDirectory(): string {
  if (typeof process.getuid !== "function") {
    throw new ConnectionError("Headless local transport requires a Unix-like operating system");
  }
  return join("/tmp", `headless-${process.getuid()}`);
}

export function validateSocketLocation(socketPath: string, label = "socketPath"): void {
  if (!isAbsolute(socketPath)) throw new ValidationError(`${label} must be absolute`);
  const resolved = resolve(socketPath);
  if (resolved !== socketPath || dirname(resolved) !== runtimeDirectory()) {
    throw new ValidationError(
      `${label} must be a direct child of the Headless runtime directory ${runtimeDirectory()}`,
    );
  }
}

async function validatePrivateSocketPath(socketPath: string): Promise<void> {
  validateSocketLocation(socketPath);
  if (typeof process.getuid !== "function") {
    throw new ConnectionError("Headless local transport requires a Unix-like operating system");
  }
  const userId = process.getuid();
  let parent;
  try {
    parent = await lstat(dirname(socketPath));
  } catch (cause) {
    throw new ConnectionError("Headless runtime directory is unavailable", { cause });
  }
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== userId
    || (parent.mode & 0o077) !== 0) {
    throw new ConnectionError("Headless runtime directory is not private to the current user");
  }
  let socket;
  try {
    socket = await lstat(socketPath);
  } catch (cause) {
    throw new ConnectionError("Headless host is not running", { cause });
  }
  if (!socket.isSocket() || socket.isSymbolicLink() || socket.uid !== userId
    || (socket.mode & 0o077) !== 0) {
    throw new ConnectionError("Headless socket is not private to the current user");
  }
}

export interface TransportRequest {
  readonly frame: Buffer;
  readonly requestId: string;
  readonly signal?: AbortSignal;
  readonly timeoutMs: number;
}

interface TransportInternals {
  readonly createSocket?: (socketPath: string) => Socket;
  readonly validatePath?: (socketPath: string) => Promise<void>;
}

export class UnixSocketTransport {
  readonly socketPath: string;
  #closed = false;
  readonly #active = new Set<Socket>();
  readonly #createSocket: (socketPath: string) => Socket;
  readonly #validatePath: (socketPath: string) => Promise<void>;

  constructor(socketPath = defaultSocketPath(), internals: TransportInternals = {}) {
    validateSocketLocation(socketPath);
    this.socketPath = socketPath;
    this.#createSocket = internals.createSocket ?? ((path) => createConnection({ path }));
    this.#validatePath = internals.validatePath ?? validatePrivateSocketPath;
  }

  async send(request: TransportRequest): Promise<Buffer> {
    if (this.#closed) throw new ClientClosedError();
    if (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs < 1
      || request.timeoutMs > MAXIMUM_COMMAND_TIMEOUT_MS) {
      throw new ValidationError(
        `timeoutMs must be an integer between 1 and ${MAXIMUM_COMMAND_TIMEOUT_MS}`,
      );
    }
    const newline = request.frame.indexOf(0x0a);
    if (request.frame.byteLength > MAXIMUM_MESSAGE_BYTES) {
      throw new ValidationError(`request exceeds the ${MAXIMUM_MESSAGE_BYTES}-byte frame limit`);
    }
    if (newline < 0 || newline !== request.frame.byteLength - 1) {
      throw new ValidationError("request must contain exactly one terminal newline frame");
    }
    if (request.signal?.aborted) throw new CancelledBeforeSend();
    const startedAt = Date.now();
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (error?: Error): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        request.signal?.removeEventListener("abort", onAbort);
        if (error) reject(error);
        else resolve();
      };
      const onAbort = (): void => finish(new CancelledBeforeSend());
      request.signal?.addEventListener("abort", onAbort, { once: true });
      const timer = setTimeout(() => finish(new TimeoutBeforeSend()), request.timeoutMs);
      timer.unref();
      this.#validatePath(this.socketPath).then(() => finish(), (cause: unknown) => {
        finish(cause instanceof Error ? cause : new ConnectionError("socket validation failed"));
      });
    });
    if (this.#closed) throw new ClientClosedError();
    if (request.signal?.aborted) throw new CancelledBeforeSend();
    const remainingTimeoutMs = Math.max(1, request.timeoutMs - (Date.now() - startedAt));

    return new Promise<Buffer>((resolve, reject) => {
      let sent = false;
      let settled = false;
      let response = Buffer.alloc(0);
      const socket = this.#createSocket(this.socketPath);
      this.#active.add(socket);

      const finish = (error?: Error, frame?: Buffer): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        request.signal?.removeEventListener("abort", onAbort);
        this.#active.delete(socket);
        socket.destroy();
        if (error) reject(error);
        else if (frame) resolve(frame);
        else reject(new MalformedResponseError("Headless response was empty"));
      };

      const unknown = (
        reason: "cancelled" | "closed" | "read-failed" | "timed-out",
        cause?: Error,
      ): void => {
        finish(new OperationOutcomeUnknown(request.requestId, reason, cause ? { cause } : undefined));
      };

      const onAbort = (): void => {
        if (sent) unknown("cancelled");
        else finish(new CancelledBeforeSend());
      };
      request.signal?.addEventListener("abort", onAbort, { once: true });

      const timer = setTimeout(() => {
        if (sent) unknown("timed-out");
        else finish(new TimeoutBeforeSend());
      }, remainingTimeoutMs);
      timer.unref();

      socket.once("connect", () => {
        if (settled) return;
        if (request.signal?.aborted) {
          finish(new CancelledBeforeSend());
          return;
        }
        sent = true;
        socket.write(request.frame, (error) => {
          if (error && !settled) unknown("read-failed", error);
        });
      });
      socket.on("data", (chunk: Buffer) => {
        if (settled) return;
        response = Buffer.concat([response, chunk], response.byteLength + chunk.byteLength);
        const newline = response.indexOf(0x0a);
        if (response.byteLength > MAXIMUM_MESSAGE_BYTES
          || (response.byteLength === MAXIMUM_MESSAGE_BYTES && newline < 0)) {
          unknown("read-failed", new ResponseTooLargeError(MAXIMUM_MESSAGE_BYTES));
          return;
        }
        if (newline < 0) return;
        if (response.byteLength !== newline + 1) {
          unknown(
            "read-failed",
            new MalformedResponseError("Headless returned more than one response frame"),
          );
          return;
        }
      });
      socket.once("end", () => {
        if (settled) return;
        const newline = response.indexOf(0x0a);
        if (newline < 0) {
          const message = response.byteLength === 0
            ? "Headless response was empty"
            : "Headless response did not end with a newline";
          unknown("read-failed", new MalformedResponseError(message));
          return;
        }
        finish(undefined, response.subarray(0, newline));
      });
      socket.once("error", (cause: Error) => {
        if (settled) return;
        if (sent) unknown("read-failed", cause);
        else finish(new ConnectionError("could not connect to the Headless host", { cause }));
      });
      socket.once("close", () => {
        if (settled) return;
        if (sent) unknown("closed");
        else finish(new ConnectionError("Headless connection closed before the request was sent"));
      });
    });
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    for (const socket of this.#active) socket.destroy();
  }
}
