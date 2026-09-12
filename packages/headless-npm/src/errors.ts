import type {
  AuthenticationRequired,
  CommandErrorCode,
  JsonValue,
  LifecycleErrorCode,
  Untrusted,
} from "./generated.js";

export class HeadlessError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class ValidationError extends HeadlessError {}

export class ClientClosedError extends HeadlessError {
  constructor() {
    super("the Headless client is closed");
  }
}

export class TransportError extends HeadlessError {
  readonly retrySafe: boolean;

  constructor(message: string, retrySafe: boolean, options?: ErrorOptions) {
    super(message, options);
    this.retrySafe = retrySafe;
  }
}

export class ConnectionError extends TransportError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, true, options);
  }
}

export class TimeoutBeforeSend extends TransportError {
  constructor(message = "the request timed out before any bytes were sent") {
    super(message, true);
  }
}

export class CancelledBeforeSend extends TransportError {
  constructor(message = "the request was cancelled before any bytes were sent") {
    super(message, true);
  }
}

export class OperationOutcomeUnknown extends TransportError {
  readonly requestId: string;
  readonly reason: "cancelled" | "closed" | "read-failed" | "timed-out";

  constructor(
    requestId: string,
    reason: "cancelled" | "closed" | "read-failed" | "timed-out",
    options?: ErrorOptions,
  ) {
    super(
      `request ${requestId} was sent but its outcome is unknown (${reason}); inspect host state before continuing`,
      false,
      options,
    );
    this.requestId = requestId;
    this.reason = reason;
  }
}

export class MalformedResponseError extends TransportError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, false, options);
  }
}

export class ResponseTooLargeError extends MalformedResponseError {
  constructor(maximumBytes: number) {
    super(`Headless response exceeded the ${maximumBytes}-byte frame limit`);
  }
}

export class ProtocolMismatchError extends MalformedResponseError {
  readonly expectedVersion: string;
  readonly actualVersion: string;

  constructor(expectedVersion: string, actualVersion: string) {
    super(`Headless protocol mismatch: expected ${expectedVersion}, received ${actualVersion}`);
    this.expectedVersion = expectedVersion;
    this.actualVersion = actualVersion;
  }
}

export class ResponseIdMismatchError extends MalformedResponseError {
  readonly expectedId: string;
  readonly actualId: string;

  constructor(expectedId: string, actualId: string) {
    super(`Headless response id mismatch: expected ${expectedId}, received ${actualId}`);
    this.expectedId = expectedId;
    this.actualId = actualId;
  }
}

export class CommandError extends HeadlessError {
  readonly code: CommandErrorCode | string;
  readonly suggestion: string | undefined;
  readonly details: JsonValue | Untrusted<JsonValue> | undefined;

  constructor(
    code: CommandErrorCode | string,
    message: string,
    suggestion?: string,
    details?: JsonValue | Untrusted<JsonValue>,
  ) {
    super(message);
    this.code = code;
    this.suggestion = suggestion;
    this.details = details;
  }
}

export class AuthenticationRequiredError extends CommandError {
  declare readonly details: Untrusted<AuthenticationRequired>;

  constructor(
    message: string,
    suggestion: string | undefined,
    details: Untrusted<AuthenticationRequired>,
  ) {
    super("AUTH_REQUIRED", message, suggestion, details);
  }
}

export class UnsupportedCapabilityError extends CommandError {
  readonly command: string;

  constructor(command: string, message = `the connected Headless host does not support ${command}`) {
    super("UNSUPPORTED_CAPABILITY", message);
    this.command = command;
  }
}

export class HostLaunchError extends HeadlessError {
  readonly code: LifecycleErrorCode;
  readonly suggestion: string | undefined;
  readonly details: JsonValue | undefined;
  readonly exitCode: number | null | undefined;
  readonly signal: NodeJS.Signals | null | undefined;

  constructor(
    message: string,
    options: ErrorOptions & {
      readonly code?: LifecycleErrorCode;
      readonly suggestion?: string;
      readonly details?: JsonValue;
      readonly exitCode?: number | null;
      readonly signal?: NodeJS.Signals | null;
    } = {},
  ) {
    super(message, options);
    this.code = options.code ?? "HOST_START_FAILED";
    this.suggestion = options.suggestion;
    this.details = options.details;
    this.exitCode = options.exitCode;
    this.signal = options.signal;
  }
}
