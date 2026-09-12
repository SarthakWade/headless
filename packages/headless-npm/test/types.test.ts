import {
  type AuthLoginParameters,
  type AuthenticationRequired,
  AuthenticationRequiredError,
  type CommandResult,
  HeadlessClient,
  HeadlessSession,
  type LaunchOptions,
  type Untrusted,
} from "../src/index.js";

type HasPasswordParameter = "password" extends keyof AuthLoginParameters ? true : false;
const hasPasswordParameter: HasPasswordParameter = false;
void hasPasswordParameter;
type SessionHasHostPing = "ping" extends keyof HeadlessSession ? true : false;
const sessionHasHostPing: SessionHasHostPing = false;
void sessionHasHostPing;

declare const client: HeadlessClient;
declare const session: HeadlessSession;
declare const authError: AuthenticationRequiredError;

const visit: Promise<CommandResult<"visit">> = client.visit({ url: "https://example.com" });
const scopedVisit: Promise<Untrusted<{ readonly url: string }>> = session.visit({
  url: "https://example.com",
});
const login: Promise<CommandResult<"auth.login">> = session.authLogin({
  challenge: "11111111-1111-4111-8111-111111111111",
  account: "work",
});
const authenticationRequired: Untrusted<AuthenticationRequired> = authError.details;

void visit;
void scopedVisit;
void login;
void authenticationRequired;

// @ts-expect-error launch has explicit startup and shutdown timeouts, not a command timeout.
const misleadingLaunchTimeout = { timeoutMs: 1 } satisfies LaunchOptions;
void misleadingLaunchTimeout;
