import { randomUUID } from "node:crypto";
import {
  COMMAND_METADATA,
  ERROR_DETAILS_METADATA,
  MAXIMUM_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  RESPONSE_ADDITIONAL_PROPERTIES,
  type AuthenticationRequired,
  type CommandName,
  type CommandParameters,
  type CommandResult,
  type JsonValue,
  type Untrusted,
} from "./generated.js";
import {
  AuthenticationRequiredError,
  CommandError,
  MalformedResponseError,
  ProtocolMismatchError,
  ResponseIdMismatchError,
  UnsupportedCapabilityError,
  ValidationError,
} from "./errors.js";

export interface CommandRequest<C extends CommandName = CommandName> {
  readonly id: string;
  readonly version: typeof PROTOCOL_VERSION;
  readonly command: C;
  readonly session?: string;
  readonly parameters: CommandParameters[C];
}

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPlainParameterRecord(value: unknown): value is UnknownRecord {
  if (!isRecord(value)) return false;
  const prototype = Object.getPrototypeOf(value) as unknown;
  if (prototype !== Object.prototype && prototype !== null) return false;
  return Object.values(Object.getOwnPropertyDescriptors(value))
    .every((descriptor) => "value" in descriptor);
}

function isJsonValue(value: unknown): value is JsonValue {
  const pending: unknown[] = [value];
  let inspected = 0;
  while (pending.length > 0) {
    if (inspected >= MAXIMUM_MESSAGE_BYTES) return false;
    inspected += 1;
    const candidate = pending.pop();
    if (candidate === null || typeof candidate === "string" || typeof candidate === "boolean") {
      continue;
    }
    if (typeof candidate === "number" && Number.isFinite(candidate)) continue;
    if (Array.isArray(candidate)) {
      for (const item of candidate) pending.push(item);
      continue;
    }
    if (isRecord(candidate)) {
      for (const item of Object.values(candidate)) pending.push(item);
      continue;
    }
    return false;
  }
  return true;
}

function byteLength(value: string): number {
  return Buffer.byteLength(value, "utf8");
}

function validateParameter(command: CommandName, definition: UnknownRecord, value: unknown): void {
  const name = String(definition.name);
  const label = `${command}.${name}`;
  const type = definition.type;
  if (type === "string") {
    if (typeof value !== "string") throw new ValidationError(`${label} must be a string`);
    if (definition.required === true && value.length === 0) {
      throw new ValidationError(`${label} must not be empty`);
    }
    if (typeof definition.minimumBytes === "number" && byteLength(value) < definition.minimumBytes) {
      throw new ValidationError(`${label} must contain at least ${definition.minimumBytes} UTF-8 bytes`);
    }
    if (typeof definition.maximumBytes === "number" && byteLength(value) > definition.maximumBytes) {
      throw new ValidationError(`${label} exceeds ${definition.maximumBytes} UTF-8 bytes`);
    }
    if (Array.isArray(definition.values)) {
      const candidate = definition.caseInsensitiveValues === true ? value.toLowerCase() : value;
      if (!definition.values.includes(candidate)) {
        throw new ValidationError(`${label} must be one of ${definition.values.join(", ")}`);
      }
    }
    return;
  }
  if (type === "boolean") {
    if (typeof value !== "boolean") throw new ValidationError(`${label} must be a boolean`);
    return;
  }
  if (type === "number" || type === "integer") {
    if (typeof value !== "number" || !Number.isFinite(value)
      || (type === "integer" && !Number.isInteger(value))) {
      throw new ValidationError(`${label} must be a finite ${type}`);
    }
    if (typeof definition.minimum === "number" && value < definition.minimum) {
      throw new ValidationError(`${label} must be at least ${definition.minimum}`);
    }
    if (typeof definition.maximum === "number" && value > definition.maximum) {
      throw new ValidationError(`${label} must be at most ${definition.maximum}`);
    }
    return;
  }
  if (type === "string-array") {
    if (!Array.isArray(value) || !value.every((item) => typeof item === "string" && item.length > 0)) {
      throw new ValidationError(`${label} must be an array of strings`);
    }
    if (typeof definition.maximumItems === "number" && value.length > definition.maximumItems) {
      throw new ValidationError(`${label} exceeds ${definition.maximumItems} items`);
    }
    const itemMaximumBytes = definition.itemMaximumBytes;
    if (typeof itemMaximumBytes === "number"
      && value.some((item) => byteLength(item) > itemMaximumBytes)) {
      throw new ValidationError(`${label} contains an item exceeding ${itemMaximumBytes} UTF-8 bytes`);
    }
    return;
  }
  throw new ValidationError(`unsupported generated parameter type for ${label}`);
}

export function validateParameters<C extends CommandName>(
  command: C,
  parameters: CommandParameters[C],
): void {
  if (!Object.hasOwn(COMMAND_METADATA, command)) {
    throw new ValidationError(`unknown Headless command: ${String(command)}`);
  }
  if (!isPlainParameterRecord(parameters)) {
    throw new ValidationError(`${command} parameters must be a plain data object`);
  }
  const definitions = COMMAND_METADATA[command].parameters as readonly UnknownRecord[];
  const known = new Map(definitions.map((definition) => [String(definition.name), definition]));
  for (const key of Object.keys(parameters)) {
    if (!known.has(key)) throw new ValidationError(`${command} received unknown parameter ${key}`);
  }
  for (const definition of definitions) {
    const name = String(definition.name);
    const value = parameters[name];
    if (value === undefined) {
      if (definition.required === true) throw new ValidationError(`${command} requires ${name}`);
    } else {
      validateParameter(command, definition, value);
    }
  }
  if (command === "session.create") {
    validateSession(String(parameters.name));
  }
}

export function validateSession(session: string): void {
  if (!session || byteLength(session) > 64 || !/^[A-Za-z0-9._-]+$/.test(session)) {
    throw new ValidationError(
      "session must contain 1 to 64 bytes using only letters, digits, dot, underscore, or hyphen",
    );
  }
}

export function createRequest<C extends CommandName>(
  command: C,
  parameters: CommandParameters[C],
  session?: string,
  id = randomUUID(),
): CommandRequest<C> {
  validateParameters(command, parameters);
  if (!id || byteLength(id) > 128) throw new ValidationError("request id is invalid");
  if (session !== undefined) {
    validateSession(session);
    if (COMMAND_METADATA[command].scope !== "session") {
      throw new ValidationError(`${command} is host-scoped and cannot target a session`);
    }
  }
  return {
    id,
    version: PROTOCOL_VERSION,
    command,
    ...(session === undefined ? {} : { session }),
    parameters,
  };
}

export function encodeRequest(request: CommandRequest): Buffer {
  let serialized: string;
  try {
    serialized = JSON.stringify(request);
  } catch (cause) {
    throw new ValidationError("request could not be encoded as JSON", { cause });
  }
  const encoded = Buffer.from(`${serialized}\n`, "utf8");
  if (encoded.byteLength > MAXIMUM_MESSAGE_BYTES) {
    throw new ValidationError(`request exceeds the ${MAXIMUM_MESSAGE_BYTES}-byte frame limit`);
  }
  return encoded;
}

function validateField(type: string, value: unknown): boolean {
  switch (type) {
  case "array": return Array.isArray(value) && value.every(isJsonValue);
  case "boolean": return typeof value === "boolean";
  case "json": return isJsonValue(value);
  case "number": return typeof value === "number" && Number.isFinite(value);
  case "object": return isRecord(value) && isJsonValue(value);
  case "string": return typeof value === "string";
  case "string-or-null": return typeof value === "string" || value === null;
  default: return false;
  }
}

interface RuntimeObjectSchema {
  readonly additionalProperties: boolean;
  readonly fields: readonly Readonly<{ name: string; required: boolean; type: string }>[];
}

function validateObjectSchema(
  label: string,
  schema: RuntimeObjectSchema,
  value: unknown,
): UnknownRecord {
  if (!isRecord(value)) throw new MalformedResponseError(`${label} must be an object`);
  const knownFields = new Set(schema.fields.map((field) => field.name));
  for (const field of schema.fields) {
    const fieldValue = value[field.name];
    if (fieldValue === undefined) {
      if (field.required) {
        throw new MalformedResponseError(`${label} is missing ${field.name}`);
      }
    } else if (!validateField(field.type, fieldValue)) {
      throw new MalformedResponseError(`${label} has invalid ${field.name}`);
    }
  }
  if (!schema.additionalProperties) {
    const unknown = Object.keys(value).find((field) => !knownFields.has(field));
    if (unknown !== undefined) throw new MalformedResponseError(`${label} has unknown field ${unknown}`);
  }
  if (!isJsonValue(value)) throw new MalformedResponseError(`${label} is not valid JSON`);
  return value;
}

function validateResult<C extends CommandName>(command: C, value: unknown): UnknownRecord {
  return validateObjectSchema(
    `${command} result`,
    COMMAND_METADATA[command].result.schema as RuntimeObjectSchema,
    value,
  );
}

function optionalString(record: UnknownRecord, key: string): string | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new MalformedResponseError(`response error ${key} must be a string`);
  return value;
}

export function decodeResponse<C extends CommandName>(
  frame: Buffer,
  expectedId: string,
  command: C,
): CommandResult<C> {
  let value: unknown;
  try {
    value = JSON.parse(frame.toString("utf8"));
  } catch (cause) {
    throw new MalformedResponseError("Headless returned malformed JSON", { cause });
  }
  if (!isRecord(value)) throw new MalformedResponseError("Headless response must be an object");
  if (!RESPONSE_ADDITIONAL_PROPERTIES) {
    const knownEnvelopeFields = new Set(["id", "version", "ok", "result", "error"]);
    const unknown = Object.keys(value).find((field) => !knownEnvelopeFields.has(field));
    if (unknown !== undefined) {
      throw new MalformedResponseError(`Headless response has unknown field ${unknown}`);
    }
  }
  if (typeof value.version !== "string") {
    throw new MalformedResponseError("Headless response is missing its protocol version");
  }
  if (value.version !== PROTOCOL_VERSION) {
    throw new ProtocolMismatchError(PROTOCOL_VERSION, value.version);
  }
  if (typeof value.id !== "string") throw new MalformedResponseError("Headless response is missing its id");
  if (value.id !== expectedId) throw new ResponseIdMismatchError(expectedId, value.id);
  if (typeof value.ok !== "boolean") throw new MalformedResponseError("Headless response is missing ok");

  if (!value.ok) {
    if (value.result !== undefined && value.result !== null) {
      throw new MalformedResponseError("failed Headless response contains a result");
    }
    if (!isRecord(value.error) || typeof value.error.code !== "string"
      || typeof value.error.message !== "string") {
      throw new MalformedResponseError("failed Headless response has an invalid error");
    }
    const suggestion = optionalString(value.error, "suggestion");
    const rawDetails = value.error.details;
    if (rawDetails !== undefined && !isJsonValue(rawDetails)) {
      throw new MalformedResponseError("response error details are not valid JSON");
    }
    if (value.error.code === "UNSUPPORTED_CAPABILITY") {
      throw new UnsupportedCapabilityError(command, value.error.message);
    }
    if (value.error.code === "AUTH_REQUIRED") {
      const validated = validateObjectSchema(
        "AUTH_REQUIRED details",
        ERROR_DETAILS_METADATA.AUTH_REQUIRED.schema as RuntimeObjectSchema,
        rawDetails,
      ) as unknown as AuthenticationRequired;
      const details = Object.freeze({
        untrustedContent: true as const,
        value: validated,
      }) satisfies Untrusted<AuthenticationRequired>;
      throw new AuthenticationRequiredError(value.error.message, suggestion, details);
    }
    throw new CommandError(value.error.code, value.error.message, suggestion, rawDetails);
  }

  if (value.error !== undefined && value.error !== null) {
    throw new MalformedResponseError("successful Headless response contains an error");
  }
  const result = validateResult(command, value.result);
  if (COMMAND_METADATA[command].result.mayContainUntrustedContent) {
    return Object.freeze({ untrustedContent: true as const, value: result }) as CommandResult<C>;
  }
  return result as CommandResult<C>;
}
