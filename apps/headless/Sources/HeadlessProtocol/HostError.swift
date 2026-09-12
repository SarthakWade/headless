import Foundation

public enum HostErrorCode: String, CaseIterable, Sendable {
    case timedOut = "TIMEOUT"
    case elementNotFound = "ELEMENT_NOT_FOUND"
    case regionNotFound = "REGION_NOT_FOUND"
    case unsafeNavigation = "UNSAFE_NAVIGATION"
    case unsafeResourceType = "UNSAFE_RESOURCE_TYPE"
    case sensitiveDiagnosticsDisabled = "SENSITIVE_DIAGNOSTICS_DISABLED"
    case unsupportedCapability = "UNSUPPORTED_CAPABILITY"
    case missingParameter = "MISSING_PARAMETER"
    case invalidFlow = "INVALID_FLOW"
    case flowFailed = "FLOW_FAILED"
    case invalidCommand = "INVALID_COMMAND"
    case operationFailed = "OPERATION_FAILED"
}

public struct HostError: Error, CustomStringConvertible, Sendable {
    public let code: HostErrorCode
    public let message: String

    public init(code: HostErrorCode, message: String) {
        self.code = code
        self.message = code == .sensitiveDiagnosticsDisabled
            ? "Sensitive diagnostic values are disabled."
            : String(decoding: message.utf8.prefix(4_096), as: UTF8.self)
    }

    public var description: String { message }

    public var suggestion: String? {
        switch code {
        case .timedOut:
            return "Inspect the current page or wait for a narrower condition."
        case .elementNotFound:
            return "Run `headless inspect --interactive` to refresh element references."
        case .regionNotFound:
            return "Run `headless inspect --context outline` to refresh region references."
        case .unsafeNavigation:
            return "Agent-controlled sessions allow web navigation only, and must match the host allowlist when one is set."
        case .unsafeResourceType:
            return "Executable files, installers, scripts, and disk images are blocked."
        case .sensitiveDiagnosticsDisabled:
            return "Restart the host with HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1 only when cookie or storage values are required."
        case .unsupportedCapability:
            return "Use an engine that declares support for this capability."
        case .missingParameter, .invalidFlow, .flowFailed, .invalidCommand:
            return nil
        case .operationFailed:
            return nil
        }
    }
}

/// Wrap an agent operation in a JSON-safe result so JavaScript error codes
/// cross WebKit and CDP without being recovered from human-readable text.
public func agentEvaluationBody(_ body: String) -> String {
    """
    return await (async () => {
      try {
        const value = await (async () => {
          \(body)
        })();
        return {__headlessAgentResult: true, ok: true, value};
      } catch (error) {
        const code = typeof error?.headlessCode === 'string'
          ? error.headlessCode : 'OPERATION_FAILED';
        const message = String(error?.message || error || 'Browser operation failed').slice(0, 4096);
        return {__headlessAgentResult: true, ok: false, error: {code, message}};
      }
    })();
    """
}

public func unwrapAgentEvaluationResult(_ value: JSONValue) throws -> JSONValue {
    guard case .object(let envelope) = value,
          envelope["__headlessAgentResult"] == .bool(true),
          let ok = envelope["ok"]?.boolValue else {
        throw HostError(code: .operationFailed, message: "Browser returned an invalid agent result")
    }
    if ok { return envelope["value"] ?? .null }
    guard case .object(let error)? = envelope["error"] else {
        throw HostError(code: .operationFailed, message: "Browser returned an invalid agent error")
    }
    let code = error["code"]?.stringValue.flatMap(HostErrorCode.init(rawValue:)) ?? .operationFailed
    throw HostError(code: code, message: error["message"]?.stringValue ?? "Browser operation failed")
}
