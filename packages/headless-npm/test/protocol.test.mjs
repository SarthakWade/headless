import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  COMMAND_METADATA,
  commandTimeoutMilliseconds,
  AuthenticationRequiredError,
  CommandError,
  createRequest,
  decodeResponse,
  encodeRequest,
  MalformedResponseError,
  PROTOCOL_FIXTURES_SHA256,
  PROTOCOL_SCHEMA_SHA256,
  PROTOCOL_VERSION,
  ProtocolMismatchError,
  ResponseIdMismatchError,
  UnsupportedCapabilityError,
  ValidationError,
  validateParameters,
} from "../dist/index.js";
import { createHash } from "node:crypto";

const fixturesURL = new URL("../../../sdk/protocol-fixtures.json", import.meta.url);
const schemaURL = new URL("../../../sdk/protocol-schema.json", import.meta.url);
const authFixturesURL = new URL("./fixtures/auth-required.json", import.meta.url);
const fixturesBytes = await readFile(fixturesURL);
const fixtures = JSON.parse(fixturesBytes);
const authFixtures = JSON.parse(await readFile(authFixturesURL));

test("generated contract matches canonical schema and fixtures", async () => {
  const schemaBytes = await readFile(schemaURL);
  const schema = JSON.parse(schemaBytes);
  assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), PROTOCOL_SCHEMA_SHA256);
  assert.equal(createHash("sha256").update(fixturesBytes).digest("hex"), PROTOCOL_FIXTURES_SHA256);
  assert.equal(fixtures.protocolVersion, PROTOCOL_VERSION);
  assert.equal(Object.keys(COMMAND_METADATA).length, schema.commands.length);
});

test("canonical CLI fixtures encode and decode with identical wire shapes", () => {
  for (const fixture of fixtures.cases) {
    const request = createRequest(
      fixture.request.command,
      fixture.request.parameters,
      fixture.request.session,
      fixture.request.id,
    );
    assert.deepEqual(request, fixture.request, fixture.name);
    const result = decodeResponse(
      Buffer.from(JSON.stringify(fixture.response)),
      fixture.request.id,
      fixture.request.command,
    );
    const untrusted = COMMAND_METADATA[fixture.request.command].result.mayContainUntrustedContent;
    if (untrusted) {
      assert.deepEqual(result, { untrustedContent: true, value: fixture.response.result });
    } else {
      assert.deepEqual(result, fixture.response.result);
    }
  }
  for (const request of fixtures.directRequests) {
    assert.doesNotThrow(() => createRequest(request.command, request.parameters, undefined, request.id));
  }
  for (const request of fixtures.invalidRequests) {
    assert.throws(
      () => createRequest(request.command, request.parameters, undefined, request.id),
      ValidationError,
    );
  }
});

test("schema-driven validation mirrors portable Swift bounds", () => {
  assert.throws(() => validateParameters("unknown.command", {}), /unknown Headless command/);
  assert.throws(() => validateParameters("visit", { url: "" }), /must not be empty/);
  assert.throws(() => validateParameters("styles.get", { target: "@1", properties: [""] }), /array of strings/);
  assert.doesNotThrow(() => validateParameters("screenshot", { format: "PnG" }));
  assert.doesNotThrow(() => createRequest("visit", { url: "https://example.com" }, "session.one_2-test"));
  assert.throws(
    () => createRequest("visit", { url: "https://example.com" }, "spaces are unsafe"),
    /letters, digits/,
  );
  assert.throws(() => createRequest("session.create", { name: "spaces are unsafe" }), /letters, digits/);
  assert.throws(() => createRequest("ping", {}, "session"), /host-scoped/);
  assert.throws(
    () => validateParameters("auth.login", { challenge: "id", account: "work", password: "secret" }),
    /unknown parameter password/,
  );
});

test("generated scopes and timeout policies drive the SDK", () => {
  assert.equal(COMMAND_METADATA.ping.scope, "host");
  assert.equal(COMMAND_METADATA.visit.scope, "session");
  assert.equal(commandTimeoutMilliseconds("ping", {}), 15_000);
  assert.equal(commandTimeoutMilliseconds("wait", { timeoutMs: 100 }), 10_000);
  assert.equal(commandTimeoutMilliseconds("wait", { timeoutMs: 120_000 }), 125_000);
  assert.equal(commandTimeoutMilliseconds("tour", {}), 125_000);
  assert.equal(commandTimeoutMilliseconds("screenshot", {}), 30_000);
  assert.equal(commandTimeoutMilliseconds("screenshot", { series: "viewport" }), 125_000);
  assert.equal(commandTimeoutMilliseconds("record.stop", {}), 30_000);
  assert.equal(commandTimeoutMilliseconds("flow.run", { input: "flow.json" }), 125_000);
});

test("request framing contains exactly one terminal newline", () => {
  const frame = encodeRequest(createRequest("fill", { target: "@1", value: "line one\nline two" }, undefined, "frame"));
  assert.equal(frame.at(-1), 0x0a);
  assert.equal(frame.subarray(0, -1).includes(0x0a), false);
  assert.equal(JSON.parse(frame.subarray(0, -1)).parameters.value, "line one\nline two");
});

test("response validation accepts additive fields but rejects contract mismatches", () => {
  const valid = {
    id: "one",
    version: PROTOCOL_VERSION,
    ok: true,
    result: { stopping: true, futureResultField: "accepted" },
    futureEnvelopeField: { accepted: true },
  };
  assert.deepEqual(decodeResponse(Buffer.from(JSON.stringify(valid)), "one", "shutdown"), valid.result);
  assert.throws(
    () => decodeResponse(Buffer.from("not-json"), "one", "shutdown"),
    MalformedResponseError,
  );
  assert.throws(
    () => decodeResponse(Buffer.from(JSON.stringify({ ...valid, id: "two" })), "one", "shutdown"),
    ResponseIdMismatchError,
  );
  assert.throws(
    () => decodeResponse(Buffer.from(JSON.stringify({ ...valid, version: "9.9" })), "one", "shutdown"),
    ProtocolMismatchError,
  );
  assert.throws(
    () => decodeResponse(Buffer.from(JSON.stringify({ ...valid, result: {} })), "one", "shutdown"),
    MalformedResponseError,
  );
});

test("command failures map to typed errors", () => {
  const failure = (code) => Buffer.from(JSON.stringify({
    id: "failed",
    version: PROTOCOL_VERSION,
    ok: false,
    error: { code, message: "failed safely" },
  }));
  assert.throws(() => decodeResponse(failure("TIMEOUT"), "failed", "wait"), CommandError);
  assert.throws(
    () => decodeResponse(failure("UNSUPPORTED_CAPABILITY"), "failed", "upload"),
    UnsupportedCapabilityError,
  );
});

test("AUTH_REQUIRED details are generated, validated, and marked untrusted", () => {
  const failure = (details) => Buffer.from(JSON.stringify({
    id: "auth",
    version: PROTOCOL_VERSION,
    ok: false,
    error: { code: "AUTH_REQUIRED", message: "login required", details },
  }));
  assert.throws(
    () => decodeResponse(failure(authFixtures.valid), "auth", "click"),
    (error) => error instanceof AuthenticationRequiredError
      && error.details.untrustedContent === true
      && error.details.value.challenge === authFixtures.valid.challenge,
  );
  for (const fixture of authFixtures.invalid) {
    assert.throws(
      () => decodeResponse(failure(fixture.details), "auth", "click"),
      MalformedResponseError,
      fixture.name,
    );
  }
  assert.throws(
    () => decodeResponse(failure(undefined), "auth", "click"),
    MalformedResponseError,
  );
});
