export { connect, HeadlessClient, HeadlessSession } from "./client.js";
export type { ConnectOptions, RequestOptions } from "./client.js";
export {
  AuthenticationRequiredError,
  CancelledBeforeSend,
  ClientClosedError,
  CommandError,
  ConnectionError,
  HeadlessError,
  HostLaunchError,
  MalformedResponseError,
  OperationOutcomeUnknown,
  ProtocolMismatchError,
  ResponseIdMismatchError,
  ResponseTooLargeError,
  TimeoutBeforeSend,
  TransportError,
  UnsupportedCapabilityError,
  ValidationError,
} from "./errors.js";
export { HeadlessHost, launch } from "./lifecycle.js";
export type { HostExit, LaunchOptions } from "./lifecycle.js";
export { createRequest, decodeResponse, encodeRequest, validateParameters } from "./protocol.js";
export type { CommandRequest } from "./protocol.js";
export * from "./generated.js";
