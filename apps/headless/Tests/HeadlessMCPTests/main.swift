import Foundation
import HeadlessProtocol

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func object(_ value: Any?, _ message: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw TestFailure(description: message)
    }
    return value
}

func integer(_ value: Any?, _ message: String) throws -> Int {
    guard let number = value as? NSNumber else {
        throw TestFailure(description: message)
    }
    return number.intValue
}

func run() throws {
    guard CommandLine.arguments.count == 4 else {
        throw TestFailure(
            description: "usage: headless-mcp-tests /path/to/headless-mcp EXPECTED_VERSION /path/to/protocol-fixtures.json"
        )
    }

    let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let fixtureRoot = try object(
        JSONSerialization.jsonObject(with: fixtureData), "SDK fixture envelope was invalid"
    )
    guard let fixtureCases = fixtureRoot["cases"] as? [[String: Any]],
          let fixture = fixtureCases.first,
          let fixtureArguments = fixture["argv"] as? [String],
          let fixtureRequest = fixture["request"] as? [String: Any],
          let fixtureCommand = fixtureRequest["command"] as? String else {
        throw TestFailure(description: "SDK status fixture was absent")
    }
    let fixtureCallData = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "headless", "arguments": ["argv": fixtureArguments]],
    ])
    let fixtureCall = String(decoding: fixtureCallData, as: UTF8.self)

    try LocalRuntime.preparePrivateDirectory()
    let socketPath = LocalRuntime.directoryURL
        .appendingPathComponent("mcp-test-\(UUID().uuidString).sock").path
    let server = LocalSocketServer(socketPath: socketPath)
    try server.start { request in
        CommandResponse.success(
            id: request.id,
            result: .object(["ready": .bool(true), "command": .string(request.command.rawValue)])
        )
    }
    defer { server.stop() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    var environment = ProcessInfo.processInfo.environment
    environment["HEADLESS_SOCKET"] = socketPath
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        fixtureCall,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["stop"]}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["session","close","disposable"]}}}"#,
        "not-json",
        String(repeating: "x", count: headlessMaximumMessageBytes + 1),
        #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["fill","@e1","credentials"]}}}"#,
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["credentials","add","synthetic-password"]}}}"#,
        #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["credentials","list"]}}}"#,
        #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["start"]}}}"#,
        #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["config","list"]}}}"#,
        #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["artifacts","add","/tmp/resume.txt","--name","resume.txt"]}}}"#,
    ]

    try process.run()
    input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try expect(process.terminationStatus == 0, "MCP process failed: \(stderr)")

    let responses = try stdout.split(separator: "\n").map { line -> [String: Any] in
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try object(value, "MCP response was not a JSON object")
    }
    try expect(responses.count == 13, "expected thirteen MCP responses, received \(responses.count)")

    let initialize = try object(responses[0]["result"], "initialize result was absent")
    try expect(initialize["protocolVersion"] as? String == "2025-06-18", "initialize protocol version changed")
    let serverInfo = try object(initialize["serverInfo"], "initialize server info was absent")
    try expect(serverInfo["name"] as? String == "headless", "initialize server name changed")
    try expect(serverInfo["version"] as? String == CommandLine.arguments[2], "MCP product version changed")
    try expect(
        serverInfo["headlessProtocolVersion"] as? String == headlessProtocolVersion,
        "MCP wire version drifted from the SDK contract"
    )
    let mcpSchemaVersion = try integer(
        serverInfo["headlessSchemaVersion"], "MCP schema version was absent"
    )
    try expect(
        mcpSchemaVersion == headlessProtocolSchemaVersion,
        "MCP schema version drifted from the SDK contract"
    )

    let list = try object(responses[1]["result"], "tools/list result was absent")
    guard let tools = list["tools"] as? [[String: Any]], tools.count == 1 else {
        throw TestFailure(description: "tools/list did not expose exactly one tool")
    }
    try expect(tools[0]["name"] as? String == "headless", "tools/list exposed the wrong tool")
    let description = tools[0]["description"] as? String ?? ""
    try expect(!description.contains("safe Headless"), "destructive MCP tool was still described as safe")
    try expect(description.contains("stop and session close are destructive"), "destructive-command guidance was absent")
    let annotations = try object(tools[0]["annotations"], "MCP tool annotations were absent")
    try expect(annotations["readOnlyHint"] as? Bool == false, "MCP tool was marked read-only")
    try expect(annotations["destructiveHint"] as? Bool == true, "MCP tool was not marked destructive")
    try expect(annotations["idempotentHint"] as? Bool == false, "MCP tool was marked idempotent")
    try expect(annotations["openWorldHint"] as? Bool == true, "MCP tool was not marked open-world")

    let call = try object(responses[2]["result"], "tools/call result was absent")
    try expect(call["isError"] as? Bool == false, "browser tools/call unexpectedly failed")
    guard let content = call["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else {
        throw TestFailure(description: "browser tools/call content was absent")
    }
    let browserResponse = try object(
        JSONSerialization.jsonObject(with: Data(text.utf8)),
        "browser tools/call content was not a protocol response"
    )
    try expect(browserResponse["ok"] as? Bool == true, "browser protocol response was not successful")
    let browserResult = try object(browserResponse["result"], "browser protocol result was absent")
    try expect(browserResult["ready"] as? Bool == true, "browser command did not reach the local host")
    try expect(
        browserResult["command"] as? String == fixtureCommand,
        "MCP request drifted from the shared SDK fixture"
    )

    for (index, expectedCommand) in [(3, "shutdown"), (4, "session.close")] {
        let destructiveCall = try object(responses[index]["result"], "destructive tools/call result was absent")
        try expect(destructiveCall["isError"] as? Bool == false, "annotated destructive command was rejected")
        guard let destructiveContent = destructiveCall["content"] as? [[String: Any]],
              let destructiveText = destructiveContent.first?["text"] as? String else {
            throw TestFailure(description: "destructive tools/call content was absent")
        }
        let destructiveResponse = try object(
            JSONSerialization.jsonObject(with: Data(destructiveText.utf8)),
            "destructive tools/call content was not a protocol response"
        )
        let destructiveResult = try object(
            destructiveResponse["result"], "destructive browser protocol result was absent"
        )
        try expect(
            destructiveResult["command"] as? String == expectedCommand,
            "destructive command did not reach the local host"
        )
    }

    for index in 5...6 {
        let parseError = try object(responses[index]["error"], "invalid input did not return JSON-RPC error")
        let code = try integer(parseError["code"], "parse error code was absent")
        try expect(code == -32700, "invalid input returned the wrong error code")
    }

    let fillCall = try object(responses[7]["result"], "fill result was absent")
    try expect(fillCall["isError"] as? Bool == false, "credential-like fill value was rejected")

    let malformedCredentialCall = try object(
        responses[8]["result"], "malformed credential rejection result was absent"
    )
    guard let malformedCredentialContent = malformedCredentialCall["content"] as? [[String: Any]],
          let malformedCredentialText = malformedCredentialContent.first?["text"] as? String else {
        throw TestFailure(description: "malformed credential rejection text was absent")
    }
    try expect(
        !malformedCredentialText.contains("synthetic-password"),
        "MCP credential parse errors must redact rejected values"
    )

    let credentialCall = try object(responses[9]["result"], "credential rejection result was absent")
    try expect(credentialCall["isError"] as? Bool == true, "credential command was accepted over MCP")
    guard let credentialContent = credentialCall["content"] as? [[String: Any]],
          let credentialText = credentialContent.first?["text"] as? String else {
        throw TestFailure(description: "credential rejection text was absent")
    }
    try expect(
        credentialText.contains("direct local user interaction"),
        "credential rejection should direct the caller to a local terminal"
    )

    let localCall = try object(responses[10]["result"], "local-command result was absent")
    try expect(localCall["isError"] as? Bool == true, "local CLI command was accepted over MCP")
    guard let localContent = localCall["content"] as? [[String: Any]],
          let localText = localContent.first?["text"] as? String else {
        throw TestFailure(description: "local-command rejection text was absent")
    }
    try expect(localText.contains("browser commands only"), "local-command rejection guidance changed")

    let configCall = try object(responses[11]["result"], "config rejection result was absent")
    try expect(configCall["isError"] as? Bool == true, "config command was accepted over MCP")
    guard let configContent = configCall["content"] as? [[String: Any]],
          let configText = configContent.first?["text"] as? String else {
        throw TestFailure(description: "config rejection text was absent")
    }
    try expect(configText.contains("browser commands only"), "config rejection guidance changed")

    let ingestCall = try object(responses[12]["result"], "artifact ingest rejection result was absent")
    try expect(ingestCall["isError"] as? Bool == true, "artifact ingest was accepted over MCP")
    guard let ingestContent = ingestCall["content"] as? [[String: Any]],
          let ingestText = ingestContent.first?["text"] as? String else {
        throw TestFailure(description: "artifact ingest rejection text was absent")
    }
    try expect(
        ingestText.contains("artifacts list"),
        "artifact ingest rejection should expose only the supported list command"
    )
}

do {
    try run()
    print("✓ MCP stdio integration")
    print("MCP tests: 1 passed")
} catch {
    fputs("✗ MCP stdio integration: \(error)\n", stderr)
    exit(1)
}
