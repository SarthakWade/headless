import Foundation
import CoreFoundation

public let headlessProtocolVersion = "0.5"
public let headlessMaximumMessageBytes = 1_048_576

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

public enum CommandName: String, Codable, CaseIterable, Sendable {
    case ping
    case shutdown
    case profileClear = "profile.clear"
    case sessionCreate = "session.create"
    case sessionList = "session.list"
    case sessionClose = "session.close"
    case visit
    case inspect
    case click
    case fill
    case upload
    case press
    case scroll
    case back
    case reload
    case wait
    case tour
    case captureInfo = "capture.info"
    case screenshot
    case artifactList = "artifact.list"
    case recordStart = "record.start"
    case recordStatus = "record.status"
    case recordStop = "record.stop"
    case qaReport = "qa.report"
    case qaClear = "qa.clear"
    case consoleList = "console.list"
    case networkList = "network.list"
    case networkGet = "network.get"
    case stylesGet = "styles.get"
    case cookiesList = "cookies.list"
    case storageList = "storage.list"
    case visualCompare = "visual.compare"
    case performanceGet = "performance.get"
    case animationList = "animation.list"
    case reportCreate = "report.create"
    case flowStart = "flow.start"
    case flowStop = "flow.stop"
    case flowRun = "flow.run"
    case networkEmulate = "network.emulate"
    case networkMockSet = "network.mock.set"
    case networkMockClear = "network.mock.clear"
    case authLogin = "auth.login"
}

public struct CommandRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, version, command, session, parameters
    }

    public let id: String
    public let version: String
    public let command: CommandName
    public let session: String?
    public let parameters: [String: JSONValue]

    public init(
        id: String = UUID().uuidString,
        version: String = headlessProtocolVersion,
        command: CommandName,
        session: String? = nil,
        parameters: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.version = version
        self.command = command
        self.session = session
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ArbitraryCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unexpected = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unexpected,
                in: raw,
                debugDescription: "Unexpected request field: \(unexpected.stringValue)"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(String.self, forKey: .version)
        command = try container.decode(CommandName.self, forKey: .command)
        session = try container.decodeIfPresent(String.self, forKey: .session)
        parameters = try container.decode([String: JSONValue].self, forKey: .parameters)
    }

    public func validate() throws {
        guard version == headlessProtocolVersion else {
            throw ProtocolValidationError.unsupportedVersion(version)
        }
        guard !id.isEmpty, id.utf8.count <= 128 else {
            throw ProtocolValidationError.invalidRequestID
        }
        if let session {
            try validateIdentifier(session, field: "session")
        }
        try validateCommandParameters()
    }

    private func validateCommandParameters() throws {
        try protocolCommandDefinition(for: command).validate(parameters)
        func string(_ key: String, required: Bool = false, maximumBytes: Int = 8_192) throws -> String? {
            guard let value = parameters[key] else {
                if required { throw ProtocolValidationError.invalidParameter("Missing string parameter: \(key)") }
                return nil
            }
            guard case .string(let text) = value, (!required || !text.isEmpty), text.utf8.count <= maximumBytes else {
                throw ProtocolValidationError.invalidParameter("Invalid string parameter: \(key)")
            }
            return text
        }
        func number(_ key: String, minimum: Double, maximum: Double) throws -> Double? {
            guard let value = parameters[key] else { return nil }
            guard case .number(let number) = value, number.isFinite,
                  number >= minimum, number <= maximum else {
                throw ProtocolValidationError.invalidParameter("Invalid numeric parameter: \(key)")
            }
            return number
        }
        func boolean(_ key: String) throws {
            if let value = parameters[key], case .bool = value { return }
            if parameters[key] != nil { throw ProtocolValidationError.invalidParameter("Invalid boolean parameter: \(key)") }
        }
        func strings(_ key: String, maximumItems: Int, maximumBytes: Int) throws -> [String]? {
            guard let value = parameters[key] else { return nil }
            guard case .array(let values) = value, values.count <= maximumItems else {
                throw ProtocolValidationError.invalidParameter("Invalid string array parameter: \(key)")
            }
            let result = values.compactMap(\.stringValue)
            guard result.count == values.count,
                  result.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumBytes }) else {
                throw ProtocolValidationError.invalidParameter("Invalid string array parameter: \(key)")
            }
            return result
        }
        func target(allowValue: Bool, required: Bool = true) throws {
            let reference = try string("target", maximumBytes: 16)
            let role = try string("role", maximumBytes: 128)
            let name = try string("name", maximumBytes: 1_000)
            if let reference {
                guard role == nil, name == nil, reference.hasPrefix("@e"),
                      !reference.dropFirst(2).isEmpty,
                      reference.dropFirst(2).allSatisfy(\.isNumber) else {
                    throw ProtocolValidationError.invalidParameter("Invalid or conflicting element target")
                }
            } else if required && role == nil && name == nil {
                throw ProtocolValidationError.invalidParameter("Missing element target")
            }
            if allowValue { _ = try string("value", required: true, maximumBytes: 900_000) }
        }

        switch command {
        case .ping, .shutdown, .profileClear, .sessionList, .sessionClose, .back, .reload,
             .captureInfo, .artifactList, .recordStatus, .qaReport, .qaClear:
            break
        case .authLogin:
            if let challenge = try string("challenge", maximumBytes: 64),
               UUID(uuidString: challenge) == nil {
                throw ProtocolValidationError.invalidParameter("Invalid authentication challenge")
            }
            if let account = try string("account", maximumBytes: 64) {
                do { _ = try CredentialAlias(rawValue: account) }
                catch { throw ProtocolValidationError.invalidParameter("Invalid account alias") }
            }
            try boolean("interactive")
            let hasAccount = parameters["account"] != nil
            let interactive = parameters["interactive"]?.boolValue ?? false
            guard hasAccount != interactive,
                  interactive || parameters["challenge"] != nil else {
                throw ProtocolValidationError.invalidParameter(
                    "Choose either interactive login or one account alias"
                )
            }
        case .sessionCreate:
            if let name = try string("name", required: true, maximumBytes: 64) {
                try validateIdentifier(name, field: "session")
            }
            try boolean("isolated")
        case .visit:
            if let value = try string("url", required: true) { _ = try normalizedWebURL(value) }
        case .inspect:
            try boolean("interactive"); try boolean("text")
            if let context = try string("context", maximumBytes: 16),
               !["summary", "outline", "text", "actions", "full"].contains(context) {
                throw ProtocolValidationError.invalidParameter("Invalid inspect context")
            }
            _ = try string("task", maximumBytes: 512)
            if let within = try string("within", maximumBytes: 16) {
                guard within.hasPrefix("@r"), !within.dropFirst(2).isEmpty,
                      within.dropFirst(2).allSatisfy(\.isNumber) else {
                    throw ProtocolValidationError.invalidParameter("Invalid inspect region reference")
                }
            }
            for (key, minimum, maximum) in [
                ("limit", 1.0, 250.0), ("budget", 256.0, 16_000.0), ("depth", 0.0, 8.0),
            ] {
                if let value = try number(key, minimum: minimum, maximum: maximum),
                   value.rounded() != value {
                    throw ProtocolValidationError.invalidParameter("Invalid integer parameter: \(key)")
                }
            }
        case .click:
            try target(allowValue: false)
        case .fill:
            try target(allowValue: true)
        case .upload:
            try target(allowValue: false)
            if let artifact = try string("artifact", required: true, maximumBytes: 128) {
                try validateArtifactName(artifact, expectedExtensions: uploadArtifactExtensions)
            }
        case .press:
            _ = try string("key", required: true, maximumBytes: 32)
        case .scroll:
            let direction = try string("direction") ?? "down"
            guard ["up", "down", "top", "bottom"].contains(direction) else {
                throw ProtocolValidationError.invalidParameter("Invalid scroll direction")
            }
            _ = try number(
                "amount", minimum: ProtocolBounds.scrollAmount.lowerBound,
                maximum: ProtocolBounds.scrollAmount.upperBound
            )
        case .wait:
            try boolean("settled")
            _ = try string("url")
            _ = try string("text", maximumBytes: 30_000)
            _ = try number("timeoutMs", minimum: 100, maximum: 120_000)
        case .tour:
            try boolean("fullPage")
            _ = try number("pace", minimum: 100, maximum: 5_000)
        case .screenshot:
            try boolean("fullPage")
            try boolean("clipboard")
            try target(allowValue: false, required: false)
            let hasTarget = parameters["target"] != nil || parameters["role"] != nil || parameters["name"] != nil
            let series = try string("series", maximumBytes: 32)
            if let series, !["viewport", "section"].contains(series) {
                throw ProtocolValidationError.invalidParameter("Invalid screenshot series")
            }
            let format = try screenshotFormat(
                explicit: string("format", maximumBytes: 16),
                output: parameters["output"]?.stringValue
            )
            if series != nil && format == .pdf {
                throw ProtocolValidationError.invalidParameter("PDF is only supported for single screenshots")
            }
            if series != nil && parameters["clipboard"]?.boolValue == true {
                throw ProtocolValidationError.invalidParameter("Clipboard output is only supported for single screenshots")
            }
            if format == .pdf && parameters["clipboard"]?.boolValue == true {
                throw ProtocolValidationError.invalidParameter("Clipboard output is only supported for image screenshots")
            }
            if format == .pdf && (parameters["fullPage"]?.boolValue != true || hasTarget) {
                throw ProtocolValidationError.invalidParameter(
                    "PDF screenshots require fullPage without an element target"
                )
            }
            if series != nil && (parameters["fullPage"]?.boolValue == true || hasTarget || parameters["output"] != nil) {
                throw ProtocolValidationError.invalidParameter("Use screenshot series without --full-page, output file, or element target")
            }
            if parameters["fullPage"]?.boolValue == true && hasTarget {
                throw ProtocolValidationError.invalidParameter("Use either --full-page or an element target")
            }
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtensions: format.artifactExtensions)
            }
            if let outputPrefix = try string("outputPrefix", maximumBytes: 80) {
                guard series != nil else {
                    throw ProtocolValidationError.invalidParameter(
                        "Screenshot outputPrefix requires a screenshot series"
                    )
                }
                try validateArtifactPrefix(outputPrefix)
            }
        case .recordStart:
            let format = try recordingFormat(
                explicit: string("format", maximumBytes: 16),
                output: parameters["output"]?.stringValue
            )
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtensions: [format.fileExtension])
            }
            _ = try number("fps", minimum: 1, maximum: 30)
            if let quality = try string("quality", maximumBytes: 16) {
                _ = try RecordingQuality.parse(quality)
            }
        case .recordStop:
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtensions: RecordingFormat.artifactExtensions)
            }
        case .consoleList:
            if let level = try string("level", maximumBytes: 16),
               !["all", "log", "info", "debug", "warn", "error", "assert"].contains(level) {
                throw ProtocolValidationError.invalidParameter("Invalid console level")
            }
            _ = try number("limit", minimum: 1, maximum: 200)
        case .networkList:
            try boolean("failed")
            _ = try number("status", minimum: 100, maximum: 599)
            _ = try number("limit", minimum: 1, maximum: 200)
        case .networkGet:
            _ = try string("requestId", required: true, maximumBytes: 128)
        case .stylesGet:
            try target(allowValue: false)
            _ = try strings("properties", maximumItems: 64, maximumBytes: 128)
        case .cookiesList:
            try boolean("includeValues")
        case .storageList:
            let scope = try string("scope", maximumBytes: 16) ?? "all"
            guard ["local", "session", "all"].contains(scope) else {
                throw ProtocolValidationError.invalidParameter("Invalid storage scope")
            }
            try boolean("includeValues")
        case .visualCompare:
            for key in ["before", "after"] {
                if let name = try string(key, required: true, maximumBytes: 128) {
                    try validateArtifactName(name, expectedExtension: "png")
                }
            }
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtension: "png")
            }
        case .performanceGet, .animationList:
            break
        case .reportCreate:
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtension: "json")
            }
        case .flowStart:
            break
        case .flowStop:
            if let output = try string("output", maximumBytes: 128) {
                try validateArtifactName(output, expectedExtension: "json")
            }
        case .flowRun:
            if let input = try string("input", required: true, maximumBytes: 128) {
                try validateArtifactName(input, expectedExtension: "json")
            }
        case .networkEmulate:
            try boolean("offline")
            _ = try number(
                "latencyMs", minimum: ProtocolBounds.networkLatencyMilliseconds.lowerBound,
                maximum: ProtocolBounds.networkLatencyMilliseconds.upperBound
            )
            _ = try number(
                "downloadKbps", minimum: ProtocolBounds.networkThroughputKbps.lowerBound,
                maximum: ProtocolBounds.networkThroughputKbps.upperBound
            )
            _ = try number(
                "uploadKbps", minimum: ProtocolBounds.networkThroughputKbps.lowerBound,
                maximum: ProtocolBounds.networkThroughputKbps.upperBound
            )
        case .networkMockSet:
            if let url = try string("url", required: true, maximumBytes: 8_192) { _ = try normalizedWebURL(url) }
            _ = try number("status", minimum: 100, maximum: 599)
            _ = try string("body", required: true, maximumBytes: 65_536)
            if let contentType = try string("contentType", maximumBytes: 256),
               !contentType.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) {
                throw ProtocolValidationError.invalidParameter("Invalid content type")
            }
        case .networkMockClear:
            break
        }
    }
}

private struct ArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct CommandError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let suggestion: String?
    public let details: JSONValue?

    public init(code: String, message: String, suggestion: String? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
        self.details = details
    }
}

public struct CommandResponse: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: CommandError?

    /// Used only when the host could not read the request well enough to know
    /// its id. Clients treat it as "this reply is about your request even
    /// though it is not correlated", so nothing else may use it.
    public static let unknownRequestIdentifier = "unknown"

    public static func success(id: String, result: JSONValue = .object([:])) -> CommandResponse {
        CommandResponse(id: id, version: headlessProtocolVersion, ok: true, result: result, error: nil)
    }

    public static func failure(
        id: String, code: String, message: String, suggestion: String? = nil,
        details: JSONValue? = nil
    ) -> CommandResponse {
        CommandResponse(
            id: id,
            version: headlessProtocolVersion,
            ok: false,
            result: nil,
            error: CommandError(code: code, message: message, suggestion: suggestion, details: details)
        )
    }
}

public enum ProtocolValidationError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(String)
    case invalidRequestID
    case invalidIdentifier(field: String)
    case invalidURL(String)
    case unsafeResourceType(String)
    case invalidParameter(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported protocol version: \(version)"
        case .invalidRequestID: return "Request ID must contain 1–128 bytes"
        case .invalidIdentifier(let field): return "Invalid \(field); use letters, numbers, '.', '_' or '-'"
        case .invalidURL(let value): return "Unsupported URL: \(value)"
        case .unsafeResourceType(let type):
            return "Blocked unsafe remote resource type: .\(type)"
        case .invalidParameter(let message): return message
        }
    }
}

public func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 64 else {
        throw ProtocolValidationError.invalidIdentifier(field: field)
    }
    guard hasPortableNameCharacters(value) else {
        throw ProtocolValidationError.invalidIdentifier(field: field)
    }
}

public let uploadArtifactExtensions: Set<String> = [
    "csv", "gif", "jpeg", "jpg", "json", "pdf", "png", "txt", "webp",
]

public func validateArtifactName(_ value: String, expectedExtension: String) throws {
    try validateArtifactName(value, expectedExtensions: [expectedExtension])
}

public func validateArtifactName(_ value: String, expectedExtensions: Set<String>) throws {
    let normalizedExtensions = Set(expectedExtensions.map { $0.lowercased() })
    let extensionDescription = normalizedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    guard !value.isEmpty, value.utf8.count <= 128,
          value == URL(fileURLWithPath: value).lastPathComponent,
          !value.hasPrefix("."),
          normalizedExtensions.contains(URL(fileURLWithPath: value).pathExtension.lowercased()) else {
        throw ProtocolValidationError.invalidParameter(
            "Artifact output must be a simple \(extensionDescription) filename"
        )
    }
    guard hasPortableNameCharacters(value) else {
        throw ProtocolValidationError.invalidParameter("Artifact output contains unsupported characters")
    }
}

public func validateArtifactPrefix(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 80,
          value == URL(fileURLWithPath: value).lastPathComponent,
          !value.hasPrefix(".") else {
        throw ProtocolValidationError.invalidParameter("Artifact prefix must be a simple filename prefix")
    }
    guard hasPortableNameCharacters(value) else {
        throw ProtocolValidationError.invalidParameter("Artifact prefix contains unsupported characters")
    }
}

private let portableNameCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)

public func hasPortableNameCharacters(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy(portableNameCharacters.contains)
}

public enum ProtocolBounds {
    public static let scrollAmount = 0.1...100_000.0
    public static let networkLatencyMilliseconds = 0.0...120_000.0
    public static let networkThroughputKbps = -1.0...1_000_000.0
    public static let screenshotDimension = 16_384.0
    public static let screenshotPixels = 64_000_000.0
}

public struct BoundedScreenshotRectangle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ object: [String: JSONValue]) throws {
        guard let x = object["x"]?.numberValue, let y = object["y"]?.numberValue,
              let width = object["width"]?.numberValue,
              let height = object["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0,
              width <= ProtocolBounds.screenshotDimension,
              height <= ProtocolBounds.screenshotDimension,
              width * height <= ProtocolBounds.screenshotPixels else {
            throw HostError(
                code: .operationFailed,
                message: "Screenshot dimensions exceed safety limits"
            )
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public func browserTargetArguments(_ parameters: [String: JSONValue]) throws -> [String: Any] {
    if let target = parameters["target"]?.stringValue {
        guard target.hasPrefix("@e"), target.count <= 16 else {
            throw HostError(code: .operationFailed, message: "Invalid element reference")
        }
        return ["target": target]
    }
    var result: [String: Any] = [:]
    if let role = parameters["role"]?.stringValue { result["role"] = role }
    if let name = parameters["name"]?.stringValue { result["name"] = name }
    guard !result.isEmpty else {
        throw HostError(code: .operationFailed, message: "Missing command parameter: target")
    }
    return result
}

public func requireSensitiveDiagnosticsAccess(
    if requested: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard !requested || environment["HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS"] == "1" else {
        throw HostError(
            code: .sensitiveDiagnosticsDisabled,
            message: "Sensitive diagnostic values are disabled."
        )
    }
}

/// Agent navigation is deliberately limited to web URLs in P0. File URLs and
/// application schemes would let an untrusted page or prompt cross the browser
/// boundary and are not accepted by the host.
public func normalizedWebURL(_ input: String) throws -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192 else {
        throw ProtocolValidationError.invalidURL(input)
    }

    let lower = trimmed.lowercased()
    let candidate: String
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
        candidate = trimmed
    } else if trimmed.contains("://") {
        throw ProtocolValidationError.invalidURL(input)
    } else if isLocalDevelopmentAddress(lower) {
        candidate = "http://" + trimmed
    } else {
        // Reject explicit non-web schemes such as javascript:, data: and
        // mailto:. A colon followed by digits is retained as a normal port.
        if let colon = trimmed.firstIndex(of: ":") {
            let suffix = trimmed[trimmed.index(after: colon)...]
            if suffix.first?.isNumber != true {
                throw ProtocolValidationError.invalidURL(input)
            }
        }
        candidate = "https://" + trimmed
    }

    guard let url = URL(string: candidate), isWebNavigationURL(url) else {
        throw ProtocolValidationError.invalidURL(input)
    }
    if remoteResourceSafety(for: url) == .blocked {
        throw ProtocolValidationError.unsafeResourceType(url.pathExtension.lowercased())
    }
    return url
}

/// The agent is a browser controller, not a file-execution or installer
/// delivery mechanism. Direct navigation to active payloads is blocked even
/// when it is served over HTTP(S). Archive files remain visible to the agent
/// as a caution because they are commonly legitimate web downloads, but the
/// browser hosts deny downloads and never unpack them.
public enum RemoteResourceSafety: String, Sendable {
    case allowed
    case caution
    case blocked
}

public let blockedRemoteResourceExtensions: Set<String> = [
    "apk", "app", "bat", "cmd", "com", "deb", "dll", "dmg", "dylib",
    "exe", "img", "iso", "jar", "msi", "msp", "pif", "pkg", "ps1",
    "psm1", "scr", "sh", "so", "vbe", "vbs", "wsf", "zsh",
]

public let cautionRemoteResourceExtensions: Set<String> = [
    "7z", "bz2", "gz", "rar", "rpm", "tar", "tgz", "xz", "zip",
]

public func remoteResourceSafety(for url: URL) -> RemoteResourceSafety {
    let fileExtension = url.pathExtension.lowercased()
    if blockedRemoteResourceExtensions.contains(fileExtension) { return .blocked }
    if cautionRemoteResourceExtensions.contains(fileExtension) { return .caution }
    return .allowed
}

/// The same boundary is applied to explicit CLI visits and page-initiated
/// top-frame navigation. Embedded credentials are rejected so they cannot be
/// leaked through browser history, diagnostics, screenshots, or prompts.
/// When a process allowlist is set, matching it is an extra conjunct; it
/// cannot add schemes, credentials, or blocked extensions.
public func agentMayNavigate(
    to url: URL,
    allowlist: NavigationAllowlist = processNavigationAllowlist
) -> Bool {
    isWebNavigationURL(url)
        && remoteResourceSafety(for: url) != .blocked
        && allowlist.allows(url)
}

private func isWebNavigationURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil,
          url.user == nil,
          url.password == nil else {
        return false
    }
    return true
}

public func isLocalDevelopmentAddress(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: "//" + trimmed),
          let host = components.host?.lowercased() else { return false }
    return isLocalDevelopmentHost(host)
}

public let localDevelopmentHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]

public func isLocalDevelopmentHost(_ host: String) -> Bool {
    localDevelopmentHosts.contains(host.lowercased())
}

public enum ProtocolCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        guard data.count <= headlessMaximumMessageBytes else { throw CodecError.messageTooLarge }
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= headlessMaximumMessageBytes else {
            throw CodecError.messageTooLarge
        }
        let line = data.last == 0x0A ? data.dropLast() : data[...]
        return try decoder.decode(type, from: Data(line))
    }
}

public enum CodecError: Error, Equatable {
    case messageTooLarge
}

public enum JSONValueConversionError: Error {
    case unsupportedValue(String)
}

public extension JSONValue {
    static func foundationValue(_ value: Any) throws -> JSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(try value.map(foundationValue(_:)))
        case let value as [String: Any]:
            return .object(try value.mapValues(foundationValue(_:)))
        case is NSNull:
            return .null
        default:
            throw JSONValueConversionError.unsupportedValue(String(describing: type(of: value)))
        }
    }

}
