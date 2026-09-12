import {
  COMMAND_METADATA,
  commandTimeoutMilliseconds,
  GeneratedCommandClient,
  GeneratedSessionCommandClient,
  MAXIMUM_COMMAND_TIMEOUT_MS,
  PROTOCOL_VERSION,
  type CommandName,
  type CommandOptions,
  type CommandParameters,
  type CommandResult,
  type HostStatus,
  type JsonValue,
} from "./generated.js";
import {
  ClientClosedError,
  CommandError,
  MalformedResponseError,
  OperationOutcomeUnknown,
  UnsupportedCapabilityError,
  ValidationError,
} from "./errors.js";
import { createRequest, decodeResponse, encodeRequest, validateSession } from "./protocol.js";
import { defaultSocketPath, UnixSocketTransport } from "./transport.js";

export interface ConnectOptions extends CommandOptions {
  readonly socketPath?: string;
}

export interface RequestOptions extends CommandOptions {
  readonly session?: string;
}

function timeoutFor<C extends CommandName>(
  command: C,
  parameters: CommandParameters[C],
  requested?: number,
): number {
  if (requested !== undefined) {
    if (!Number.isSafeInteger(requested) || requested < 1 || requested > MAXIMUM_COMMAND_TIMEOUT_MS) {
      throw new ValidationError(
        `timeoutMs must be an integer between 1 and ${MAXIMUM_COMMAND_TIMEOUT_MS}`,
      );
    }
    return requested;
  }
  return commandTimeoutMilliseconds(command, parameters);
}

function supportedCommands(status: HostStatus): ReadonlySet<CommandName> {
  const capabilities = status.capabilities;
  const commands = capabilities.commands;
  if (!Array.isArray(commands) || !commands.every((command) => typeof command === "string")) {
    throw new MalformedResponseError("host capabilities do not declare supported commands");
  }
  const known = new Set(Object.keys(COMMAND_METADATA));
  return new Set(commands.filter((command): command is CommandName => known.has(command)));
}

export class HeadlessClient extends GeneratedCommandClient {
  readonly socketPath: string;
  #transport: UnixSocketTransport;
  #hostStatus: HostStatus | undefined;
  #supportedCommands: ReadonlySet<CommandName> | undefined;
  #closed = false;

  constructor(options: { readonly socketPath?: string } = {}) {
    super();
    this.socketPath = options.socketPath ?? defaultSocketPath();
    this.#transport = new UnixSocketTransport(this.socketPath);
  }

  get capabilities(): Readonly<Record<string, JsonValue>> {
    if (!this.#hostStatus) throw new ValidationError("connect() must complete before reading capabilities");
    return this.#hostStatus.capabilities;
  }

  get hostStatus(): HostStatus {
    if (!this.#hostStatus) throw new ValidationError("connect() must complete before reading host status");
    return this.#hostStatus;
  }

  async connect(options: CommandOptions = {}): Promise<this> {
    if (this.#closed) throw new ClientClosedError();
    const status = await this.request("ping", {}, options);
    this.#supportedCommands = supportedCommands(status);
    this.#hostStatus = status;
    return this;
  }

  async request<C extends CommandName>(
    command: C,
    parameters: CommandParameters[C],
    options: RequestOptions = {},
  ): Promise<CommandResult<C>> {
    if (this.#closed) throw new ClientClosedError();
    if (options.session !== undefined) validateSession(options.session);
    if (command !== "ping" && !this.#supportedCommands) {
      throw new ValidationError("connect() must complete before browser commands are sent");
    }
    if (command !== "ping" && this.#supportedCommands && !this.#supportedCommands.has(command)) {
      throw new UnsupportedCapabilityError(command);
    }
    const request = createRequest(command, parameters, options.session);
    const frame = await this.#transport.send({
      frame: encodeRequest(request),
      requestId: request.id,
      timeoutMs: timeoutFor(command, parameters, options.timeoutMs),
      ...(options.signal === undefined ? {} : { signal: options.signal }),
    });
    try {
      const result = decodeResponse(frame, request.id, command);
      if (command === "ping") {
        const status = result as HostStatus;
        if (status.protocolVersion !== PROTOCOL_VERSION) {
          throw new MalformedResponseError(
            "ping result protocolVersion does not match the response envelope",
          );
        }
        supportedCommands(status);
      }
      return result;
    } catch (cause) {
      if (cause instanceof CommandError) throw cause;
      if (cause instanceof MalformedResponseError) {
        throw new OperationOutcomeUnknown(request.id, "read-failed", { cause });
      }
      throw cause;
    }
  }

  session(name: string): HeadlessSession {
    validateSession(name);
    return new HeadlessSession(this, name);
  }

  async openSession(
    name: string,
    options: { readonly isolated?: boolean; readonly signal?: AbortSignal; readonly timeoutMs?: number } = {},
  ): Promise<HeadlessSession> {
    const { isolated, ...commandOptions } = options;
    await this.sessionCreate(
      { name, ...(isolated === undefined ? {} : { isolated }) },
      commandOptions,
    );
    return this.session(name);
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#transport.close();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    this.close();
  }

  protected override invoke<C extends CommandName>(
    command: C,
    parameters: CommandParameters[C],
    options?: CommandOptions,
  ): Promise<CommandResult<C>> {
    return this.request(command, parameters, options);
  }
}

export class HeadlessSession extends GeneratedSessionCommandClient {
  readonly name: string;
  readonly #client: HeadlessClient;
  #closed = false;

  constructor(client: HeadlessClient, name: string) {
    super();
    validateSession(name);
    this.#client = client;
    this.name = name;
  }

  async close(options: CommandOptions = {}): Promise<void> {
    if (this.#closed) return;
    await this.#client.request("session.close", {}, { ...options, session: this.name });
    this.#closed = true;
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  protected override invoke<C extends CommandName>(
    command: C,
    parameters: CommandParameters[C],
    options?: CommandOptions,
  ): Promise<CommandResult<C>> {
    if (this.#closed) return Promise.reject(new ClientClosedError());
    return this.#client.request(command, parameters, { ...options, session: this.name });
  }
}

export async function connect(options: ConnectOptions = {}): Promise<HeadlessClient> {
  const { socketPath, ...commandOptions } = options;
  const client = new HeadlessClient(socketPath === undefined ? {} : { socketPath });
  try {
    return await client.connect(commandOptions);
  } catch (error) {
    client.close();
    throw error;
  }
}
