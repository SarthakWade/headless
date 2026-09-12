import HeadlessProtocol
import Foundation

/// A deliberately stdio-only MCP adapter. It delegates to the same private
/// Unix socket as the CLI, so using it over `ssh vm headless-mcp` does not
/// create a browser control port on the VM or the network.
private func write(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

private func error(id: Any?, code: Int, message: String) {
    write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

private func toolResult(id: Any?, text: String, isError: Bool = false) {
    write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [
        "content": [["type": "text", "text": text]], "isError": isError,
    ]])
}

private let tool: [String: Any] = [
    "name": "headless",
    "description": "Run a Headless CLI browser command against the already-running local browser host. Commands may navigate or mutate page/session state; stop and session close are destructive. Supply argv without the headless binary name.",
    "annotations": [
        "title": "Headless browser command",
        "readOnlyHint": false,
        "destructiveHint": true,
        "idempotentHint": false,
        "openWorldHint": true,
    ],
    "inputSchema": [
        "type": "object", "additionalProperties": false,
        "properties": ["argv": ["type": "array", "items": ["type": "string"], "maxItems": 32]],
        "required": ["argv"],
    ],
]

while let line = readLine() {
    guard line.utf8.count <= headlessMaximumMessageBytes,
          let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = request["method"] as? String else {
        error(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        continue
    }
    let id = request["id"]
    switch method {
    case "initialize":
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": "headless", "version": headlessProductVersion,
                "headlessProtocolVersion": headlessProtocolVersion,
                "headlessSchemaVersion": headlessProtocolSchemaVersion,
            ],
        ]])
    case "notifications/initialized":
        continue
    case "tools/list":
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["tools": [tool]]])
    case "tools/call":
        guard let parameters = request["params"] as? [String: Any],
              parameters["name"] as? String == "headless",
              let arguments = parameters["arguments"] as? [String: Any],
              let argv = arguments["argv"] as? [String], !argv.isEmpty else {
            error(id: id, code: -32602, message: "tools/call requires headless argv")
            continue
        }
        do {
            let invocation = try CLIParser().parse(argv)
            if case .credentials = invocation.local {
                toolResult(
                    id: id,
                    text: "Credential commands require direct local user interaction and are unavailable over MCP.",
                    isError: true
                )
                continue
            }
            guard let command = invocation.request else {
                toolResult(id: id, text: "MCP accepts browser commands only; run `headless start` on the VM first.", isError: true)
                continue
            }
            let response = try LocalSocketClient().send(
                command, timeout: requestTimeout(for: command)
            )
            let encoded = try ProtocolCodec.encoder.encode(response)
            toolResult(id: id, text: String(decoding: encoded, as: UTF8.self), isError: !response.ok)
        } catch {
            toolResult(id: id, text: String(describing: error), isError: true)
        }
    default:
        if id != nil { error(id: id, code: -32601, message: "Method not found") }
    }
}
