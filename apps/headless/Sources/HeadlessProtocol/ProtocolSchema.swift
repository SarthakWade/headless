import Foundation

public let headlessProtocolSchemaVersion = 1

public enum ProtocolParameterKind: String, Sendable {
    case string
    case number
    case integer
    case boolean
    case stringArray = "string-array"
}

public enum ProtocolResultValueKind: String, Sendable {
    case string
    case stringOrNull = "string-or-null"
    case number
    case boolean
    case object
    case array
    case json
}

public enum ProtocolCommandScope: String, Sendable {
    case host
    case session
}

public struct ProtocolTimeoutPolicy: Sendable {
    public let defaultMilliseconds: Int
    public let parameterName: String?
    public let parameterGraceMilliseconds: Int?
    public let minimumMilliseconds: Int?
    public let maximumMilliseconds: Int?
    public let parameterPresentOverrides: [String: Int]

    public func milliseconds(for parameters: [String: JSONValue]) -> Int {
        if let parameterName,
           let value = parameters[parameterName]?.numberValue,
           let grace = parameterGraceMilliseconds,
           let minimum = minimumMilliseconds,
           let maximum = maximumMilliseconds {
            return min(maximum, max(minimum, Int(value.rounded(.up)) + grace))
        }
        for name in parameterPresentOverrides.keys.sorted()
        where parameters[name] != nil {
            return parameterPresentOverrides[name] ?? defaultMilliseconds
        }
        return defaultMilliseconds
    }

    fileprivate var document: JSONValue {
        var fields: [String: JSONValue] = [
            "defaultMilliseconds": .number(Double(defaultMilliseconds)),
            "parameterPresentOverrides": .object(
                parameterPresentOverrides.mapValues { .number(Double($0)) }
            ),
        ]
        if let parameterName { fields["parameterName"] = .string(parameterName) }
        if let parameterGraceMilliseconds {
            fields["parameterGraceMilliseconds"] = .number(Double(parameterGraceMilliseconds))
        }
        if let minimumMilliseconds {
            fields["minimumMilliseconds"] = .number(Double(minimumMilliseconds))
        }
        if let maximumMilliseconds {
            fields["maximumMilliseconds"] = .number(Double(maximumMilliseconds))
        }
        return .object(fields)
    }
}

private func commandScope(for command: CommandName) -> ProtocolCommandScope {
    switch command {
    case .ping, .shutdown, .profileClear, .sessionCreate, .sessionList, .artifactList:
        return .host
    default:
        return .session
    }
}

private func timeoutPolicy(for command: CommandName) -> ProtocolTimeoutPolicy {
    switch command {
    case .wait:
        return ProtocolTimeoutPolicy(
            defaultMilliseconds: 15_000,
            parameterName: "timeoutMs", parameterGraceMilliseconds: 5_000,
            minimumMilliseconds: 10_000, maximumMilliseconds: 125_000,
            parameterPresentOverrides: [:]
        )
    case .tour, .flowRun:
        return ProtocolTimeoutPolicy(
            defaultMilliseconds: 125_000, parameterName: nil,
            parameterGraceMilliseconds: nil, minimumMilliseconds: nil,
            maximumMilliseconds: nil, parameterPresentOverrides: [:]
        )
    case .recordStop:
        return ProtocolTimeoutPolicy(
            defaultMilliseconds: 30_000, parameterName: nil,
            parameterGraceMilliseconds: nil, minimumMilliseconds: nil,
            maximumMilliseconds: nil, parameterPresentOverrides: [:]
        )
    case .screenshot:
        return ProtocolTimeoutPolicy(
            defaultMilliseconds: 30_000, parameterName: nil,
            parameterGraceMilliseconds: nil, minimumMilliseconds: nil,
            maximumMilliseconds: nil, parameterPresentOverrides: ["series": 125_000]
        )
    default:
        return ProtocolTimeoutPolicy(
            defaultMilliseconds: 15_000, parameterName: nil,
            parameterGraceMilliseconds: nil, minimumMilliseconds: nil,
            maximumMilliseconds: nil, parameterPresentOverrides: [:]
        )
    }
}

public enum AuthenticationProtocolErrorCode: String, CaseIterable, Sendable {
    case challengeNotFound = "AUTH_CHALLENGE_NOT_FOUND"
    case challengeExpired = "AUTH_CHALLENGE_EXPIRED"
    case challengeConsumed = "AUTH_CHALLENGE_CONSUMED"
    case originChanged = "AUTH_ORIGIN_CHANGED"
    case formChanged = "AUTH_FORM_CHANGED"
    case accountNotFound = "AUTH_ACCOUNT_NOT_FOUND"
    case credentialAliasExists = "CREDENTIAL_ALIAS_EXISTS"
    case vaultUnavailable = "VAULT_UNAVAILABLE"
    case vaultLocked = "VAULT_LOCKED"
    case userPresenceUnavailable = "USER_PRESENCE_UNAVAILABLE"
    case userPresenceDenied = "USER_PRESENCE_DENIED"
    case invalidBrokerResponse = "VAULT_RESPONSE_INVALID"
    case brokerFailed = "VAULT_OPERATION_FAILED"
}

public struct ProtocolResultField: Sendable {
    public let name: String
    public let kind: ProtocolResultValueKind
    public let required: Bool

    fileprivate var document: JSONValue {
        .object([
            "name": .string(name),
            "type": .string(kind.rawValue),
            "required": .bool(required),
        ])
    }
}

public struct ProtocolResultDefinition: Sendable {
    public let name: String
    public let fields: [ProtocolResultField]

    fileprivate var document: JSONValue {
        .object([
            "name": .string(name),
            "type": .string("object"),
            "additionalProperties": .bool(true),
            "fields": .array(fields.map(\.document)),
        ])
    }

    public func validate(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw ProtocolValidationError.invalidParameter("Invalid \(name) result: expected object")
        }
        for field in fields {
            guard let value = object[field.name] else {
                if field.required {
                    throw ProtocolValidationError.invalidParameter(
                        "Invalid \(name) result: missing \(field.name)"
                    )
                }
                continue
            }
            guard field.accepts(value) else {
                throw ProtocolValidationError.invalidParameter(
                    "Invalid \(name) result: \(field.name) must be \(field.kind.rawValue)"
                )
            }
        }
    }
}

private extension ProtocolResultField {
    func accepts(_ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.string, .string), (.number, .number), (.boolean, .bool),
             (.object, .object), (.array, .array), (.json, _):
            return true
        case (.stringOrNull, .string), (.stringOrNull, .null):
            return true
        default:
            return false
        }
    }
}

private func resultField(
    _ name: String, _ kind: ProtocolResultValueKind, required: Bool = true
) -> ProtocolResultField {
    ProtocolResultField(name: name, kind: kind, required: required)
}

private func result(
    _ name: String, _ fields: [ProtocolResultField] = []
) -> ProtocolResultDefinition {
    ProtocolResultDefinition(name: name, fields: fields)
}

public func protocolResultDefinition(for command: CommandName) -> ProtocolResultDefinition {
    switch command {
    case .ping:
        return result("HostStatus", [
            resultField("ready", .boolean), resultField("pid", .number),
            resultField("engine", .string), resultField("platform", .string),
            resultField("productVersion", .string), resultField("protocolVersion", .string),
            resultField("capabilities", .object), resultField("recordingAvailable", .boolean),
            resultField("artifactDirectory", .string), resultField("navigationAllowlist", .array),
        ])
    case .shutdown: return result("Shutdown", [resultField("stopping", .boolean)])
    case .profileClear:
        return result("ProfileClear", [resultField("cleared", .boolean), resultField("session", .string)])
    case .sessionCreate:
        return result("SessionCreate", [resultField("session", .string), resultField("isolated", .boolean)])
    case .sessionList:
        return result("SessionList", [resultField("sessions", .array), resultField("details", .array)])
    case .sessionClose: return result("SessionClose", [resultField("closed", .string)])
    case .visit, .back, .reload, .wait:
        return result("PageState", [
            resultField("url", .string), resultField("title", .string),
            resultField("readyState", .string), resultField("text", .string),
            resultField("runningAnimations", .number), resultField("mutationQuietMs", .number),
            resultField("scrollY", .number), resultField("contentHeight", .number),
        ])
    case .inspect:
        return result("Inspection", [
            resultField("url", .string), resultField("title", .string),
            resultField("contextMode", .string), resultField("viewport", .object),
            resultField("untrustedContent", .boolean),
            resultField("elements", .array, required: false),
            resultField("regions", .array, required: false),
            resultField("snippets", .array, required: false),
            resultField("text", .string, required: false),
        ])
    case .click:
        return result("Click", [
            resultField("clicked", .string), resultField("role", .string),
            resultField("name", .string),
        ])
    case .fill:
        return result("Fill", [resultField("filled", .string), resultField("valueLength", .number)])
    case .upload:
        return result("Upload", [
            resultField("uploaded", .string), resultField("role", .string),
            resultField("name", .string), resultField("artifact", .string),
        ])
    case .press: return result("Press", [resultField("pressed", .string)])
    case .scroll:
        return result("Scroll", [resultField("direction", .string), resultField("amount", .number)])
    case .tour:
        return result("Tour", [
            resultField("start", .number), resultField("end", .number),
            resultField("durationMs", .number),
        ])
    case .captureInfo:
        return result("CaptureInfo", [
            resultField("engine", .string), resultField("page", .object),
            resultField("trace", .array), resultField("recording", .object),
        ])
    case .screenshot:
        return result("Screenshot", [
            resultField("name", .string, required: false),
            resultField("path", .string, required: false),
            resultField("kind", .string, required: false),
            resultField("bytes", .number, required: false),
            resultField("createdAt", .number, required: false),
            resultField("artifacts", .array, required: false),
            resultField("truncated", .boolean, required: false),
        ])
    case .artifactList:
        return result("ArtifactList", [
            resultField("directory", .string), resultField("artifacts", .array),
            resultField("total", .number), resultField("omitted", .number),
            resultField("truncated", .boolean),
        ])
    case .recordStart, .recordStatus, .recordStop:
        return result("Recording", [
            resultField("active", .boolean), resultField("format", .string, required: false),
            resultField("quality", .string, required: false),
            resultField("name", .string, required: false),
        ])
    case .qaReport:
        return result("QAReport", [
            resultField("untrustedContent", .boolean), resultField("summary", .object),
            resultField("issues", .array), resultField("events", .array),
            resultField("omitted", .object), resultField("truncated", .boolean),
        ])
    case .qaClear: return result("QAClear", [resultField("cleared", .number)])
    case .consoleList:
        return result("ConsoleList", [
            resultField("untrustedContent", .boolean), resultField("messages", .array),
            resultField("returned", .number), resultField("available", .number),
        ])
    case .networkList:
        return result("NetworkList", [
            resultField("untrustedContent", .boolean), resultField("requests", .array),
            resultField("returned", .number), resultField("available", .number),
        ])
    case .networkGet:
        return result("NetworkDetail", [
            resultField("found", .boolean), resultField("requestId", .string, required: false),
            resultField("untrustedContent", .boolean),
            resultField("request", .object, required: false),
        ])
    case .stylesGet:
        return result("Styles", [
            resultField("ref", .string), resultField("role", .string),
            resultField("name", .string), resultField("box", .object),
            resultField("styles", .object),
        ])
    case .cookiesList:
        return result("CookieList", [
            resultField("cookies", .array), resultField("returned", .number),
            resultField("available", .number), resultField("truncated", .boolean),
        ])
    case .storageList:
        return result("StorageList", [resultField("origin", .string), resultField("stores", .array)])
    case .visualCompare:
        return result("VisualComparison", [
            resultField("name", .string), resultField("changedPixels", .number, required: false),
            resultField("differenceRatio", .number, required: false),
        ])
    case .performanceGet:
        return result("Performance", [
            resultField("url", .string), resultField("timing", .json),
            resultField("webVitals", .object), resultField("resources", .object),
        ])
    case .animationList:
        return result("AnimationList", [
            resultField("count", .number), resultField("animations", .array),
            resultField("truncated", .boolean),
        ])
    case .reportCreate, .flowStop:
        return result("Artifact", [
            resultField("name", .string), resultField("path", .string),
            resultField("kind", .string), resultField("bytes", .number),
            resultField("createdAt", .number),
        ])
    case .flowStart:
        return result("FlowStart", [resultField("recording", .boolean), resultField("note", .string)])
    case .flowRun:
        return result("FlowRun", [resultField("completed", .number), resultField("input", .string)])
    case .networkEmulate:
        return result("NetworkEmulation", [
            resultField("offline", .boolean), resultField("latencyMs", .number),
            resultField("downloadKbps", .number), resultField("uploadKbps", .number),
            resultField("engine", .string),
        ])
    case .networkMockSet:
        return result("NetworkMock", [
            resultField("url", .string), resultField("status", .number),
            resultField("activeMocks", .number),
        ])
    case .networkMockClear:
        return result("NetworkMockClear", [resultField("cleared", .number)])
    case .authLogin:
        return result("AuthenticationLogin", [
            resultField("origin", .string), resultField("account", .stringOrNull),
            resultField("saved", .boolean), resultField("continuation", .string),
            resultField("passwordExposed", .boolean),
            resultField("originalActionReplayed", .boolean),
        ])
    }
}

public struct ProtocolParameterDefinition: Sendable {
    public let name: String
    public let kind: ProtocolParameterKind
    public let required: Bool
    public let maximumBytes: Int?
    public let minimum: Double?
    public let maximum: Double?
    public let values: [String]?
    public let caseInsensitiveValues: Bool
    public let maximumItems: Int?
    public let itemMaximumBytes: Int?
    public let sensitive: Bool

    public init(
        _ name: String,
        kind: ProtocolParameterKind,
        required: Bool = false,
        maximumBytes: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        values: [String]? = nil,
        caseInsensitiveValues: Bool = false,
        maximumItems: Int? = nil,
        itemMaximumBytes: Int? = nil,
        sensitive: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.required = required
        self.maximumBytes = maximumBytes
        self.minimum = minimum
        self.maximum = maximum
        self.values = values
        self.caseInsensitiveValues = caseInsensitiveValues
        self.maximumItems = maximumItems
        self.itemMaximumBytes = itemMaximumBytes
        self.sensitive = sensitive
    }

    fileprivate func validate(_ value: JSONValue?) throws {
        guard let value else {
            if required {
                let type = kind == .string ? "string " : ""
                throw ProtocolValidationError.invalidParameter("Missing \(type)parameter: \(name)")
            }
            return
        }

        switch (kind, value) {
        case (.string, .string(let text)):
            guard (!required || !text.isEmpty),
                  maximumBytes.map({ text.utf8.count <= $0 }) ?? true,
                  values.map({ allowed in
                      if caseInsensitiveValues {
                          return allowed.contains { $0.caseInsensitiveCompare(text) == .orderedSame }
                      }
                      return allowed.contains(text)
                  }) ?? true else {
                throw ProtocolValidationError.invalidParameter("Invalid string parameter: \(name)")
            }
        case (.number, .number(let number)), (.integer, .number(let number)):
            guard number.isFinite,
                  minimum.map({ number >= $0 }) ?? true,
                  maximum.map({ number <= $0 }) ?? true,
                  kind != .integer || number.rounded() == number else {
                let type = kind == .integer ? "integer" : "numeric"
                throw ProtocolValidationError.invalidParameter("Invalid \(type) parameter: \(name)")
            }
        case (.boolean, .bool):
            return
        case (.stringArray, .array(let items)):
            guard maximumItems.map({ items.count <= $0 }) ?? true else {
                throw ProtocolValidationError.invalidParameter("Invalid string array parameter: \(name)")
            }
            let strings = items.compactMap(\.stringValue)
            guard strings.count == items.count,
                  strings.allSatisfy({ value in
                      !value.isEmpty && (itemMaximumBytes.map { value.utf8.count <= $0 } ?? true)
                  }) else {
                throw ProtocolValidationError.invalidParameter("Invalid string array parameter: \(name)")
            }
        default:
            let type: String
            switch kind {
            case .string: type = "string"
            case .number: type = "numeric"
            case .integer: type = "integer"
            case .boolean: type = "boolean"
            case .stringArray: type = "string array"
            }
            throw ProtocolValidationError.invalidParameter("Invalid \(type) parameter: \(name)")
        }
    }

    fileprivate var document: JSONValue {
        var result: [String: JSONValue] = [
            "name": .string(name),
            "type": .string(kind.rawValue),
            "required": .bool(required),
            "sensitive": .bool(sensitive),
        ]
        if let maximumBytes { result["maximumBytes"] = .number(Double(maximumBytes)) }
        if let minimum { result["minimum"] = .number(minimum) }
        if let maximum { result["maximum"] = .number(maximum) }
        if let values { result["values"] = .array(values.map(JSONValue.string)) }
        if caseInsensitiveValues { result["caseInsensitiveValues"] = .bool(true) }
        if let maximumItems { result["maximumItems"] = .number(Double(maximumItems)) }
        if let itemMaximumBytes { result["itemMaximumBytes"] = .number(Double(itemMaximumBytes)) }
        return .object(result)
    }
}

public struct ProtocolCommandDefinition: Sendable {
    public let command: CommandName
    public let scope: ProtocolCommandScope
    public let timeout: ProtocolTimeoutPolicy
    public let parameters: [ProtocolParameterDefinition]
    public let capabilityNegotiated: Bool
    public let resultContainsUntrustedContent: Bool
    public let constraints: [String]

    public init(
        _ command: CommandName,
        parameters: [ProtocolParameterDefinition] = [],
        capabilityNegotiated: Bool = false,
        resultContainsUntrustedContent: Bool = false,
        constraints: [String] = []
    ) {
        self.command = command
        self.scope = commandScope(for: command)
        self.timeout = timeoutPolicy(for: command)
        self.parameters = parameters
        self.capabilityNegotiated = capabilityNegotiated
        self.resultContainsUntrustedContent = resultContainsUntrustedContent
        self.constraints = constraints
    }

    public func validate(_ values: [String: JSONValue]) throws {
        let allowed = Set(parameters.map(\.name))
        if let unexpected = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ProtocolValidationError.invalidParameter(
                "Unexpected parameter for \(command.rawValue): \(unexpected)"
            )
        }
        for parameter in parameters {
            try parameter.validate(values[parameter.name])
        }
    }

    fileprivate var document: JSONValue {
        .object([
            "name": .string(command.rawValue),
            "scope": .string(scope.rawValue),
            "timeout": timeout.document,
            "parameters": .array(parameters.map(\.document)),
            "capabilityNegotiated": .bool(capabilityNegotiated),
            "result": .object([
                "schema": protocolResultDefinition(for: command).document,
                "mayContainUntrustedContent": .bool(resultContainsUntrustedContent),
            ]),
            "constraints": .array(constraints.map(JSONValue.string)),
        ])
    }
}

private func string(
    _ name: String, required: Bool = false, maximumBytes: Int = 8_192,
    values: [String]? = nil, caseInsensitiveValues: Bool = false,
    sensitive: Bool = false
) -> ProtocolParameterDefinition {
    ProtocolParameterDefinition(
        name, kind: .string, required: required, maximumBytes: maximumBytes,
        values: values, caseInsensitiveValues: caseInsensitiveValues, sensitive: sensitive
    )
}

private func number(
    _ name: String, minimum: Double, maximum: Double
) -> ProtocolParameterDefinition {
    ProtocolParameterDefinition(name, kind: .number, minimum: minimum, maximum: maximum)
}

private func integer(
    _ name: String, minimum: Double, maximum: Double
) -> ProtocolParameterDefinition {
    ProtocolParameterDefinition(name, kind: .integer, minimum: minimum, maximum: maximum)
}

private func boolean(_ name: String) -> ProtocolParameterDefinition {
    ProtocolParameterDefinition(name, kind: .boolean)
}

private func strings(
    _ name: String, maximumItems: Int, itemMaximumBytes: Int
) -> ProtocolParameterDefinition {
    ProtocolParameterDefinition(
        name, kind: .stringArray, maximumItems: maximumItems,
        itemMaximumBytes: itemMaximumBytes
    )
}

private let targetParameters = [
    string("target", maximumBytes: 16),
    string("role", maximumBytes: 128),
    string("name", maximumBytes: 1_000),
]

private func command(
    _ name: CommandName,
    _ parameters: [ProtocolParameterDefinition] = [],
    capabilityNegotiated: Bool = false,
    untrusted: Bool = false,
    constraints: [String] = []
) -> ProtocolCommandDefinition {
    ProtocolCommandDefinition(
        name, parameters: parameters, capabilityNegotiated: capabilityNegotiated,
        resultContainsUntrustedContent: untrusted, constraints: constraints
    )
}

public let protocolCommandDefinitions: [CommandName: ProtocolCommandDefinition] = {
    let definitions: [ProtocolCommandDefinition] = [
        command(.ping),
        command(.shutdown),
        command(.profileClear),
        command(.sessionCreate, [string("name", required: true, maximumBytes: 64), boolean("isolated")]),
        command(.sessionList),
        command(.sessionClose),
        command(.visit, [string("url", required: true)], untrusted: true),
        command(.inspect, [
            boolean("interactive"), boolean("text"),
            string("context", maximumBytes: 16, values: ["summary", "outline", "text", "actions", "full"]),
            string("task", maximumBytes: 512), string("within", maximumBytes: 16),
            integer("limit", minimum: 1, maximum: 250),
            integer("budget", minimum: 256, maximum: 16_000),
            integer("depth", minimum: 0, maximum: 8),
        ], untrusted: true),
        command(
            .click, targetParameters, untrusted: true,
            constraints: ["exactly one target reference or semantic role/name target"]
        ),
        command(
            .fill,
            targetParameters + [
                string("value", required: true, maximumBytes: 900_000, sensitive: true),
            ],
            untrusted: true,
            constraints: ["exactly one target reference or semantic role/name target"]
        ),
        command(
            .upload,
            targetParameters + [string("artifact", required: true, maximumBytes: 128)],
            capabilityNegotiated: true, untrusted: true,
            constraints: [
                "artifact must be an existing private-store basename",
                "exactly one target reference or semantic role/name target",
            ]
        ),
        command(.press, [string("key", required: true, maximumBytes: 32)], untrusted: true),
        command(.scroll, [
            string("direction", values: ["up", "down", "top", "bottom"]),
            number(
                "amount", minimum: ProtocolBounds.scrollAmount.lowerBound,
                maximum: ProtocolBounds.scrollAmount.upperBound
            ),
        ], untrusted: true),
        command(.back, untrusted: true),
        command(.reload, untrusted: true),
        command(.wait, [
            boolean("settled"), string("url"), string("text", maximumBytes: 30_000),
            number("timeoutMs", minimum: 100, maximum: 120_000),
        ], untrusted: true),
        command(.tour, [boolean("fullPage"), number("pace", minimum: 100, maximum: 5_000)], untrusted: true),
        command(.captureInfo, untrusted: true),
        command(.screenshot, targetParameters + [
            boolean("fullPage"), string("output", maximumBytes: 128),
            string("series", maximumBytes: 32, values: ["viewport", "section"]),
            string("outputPrefix", maximumBytes: 80),
            string(
                "format", maximumBytes: 16, values: ["png", "jpg", "jpeg", "pdf"],
                caseInsensitiveValues: true
            ),
            boolean("clipboard"),
        ], capabilityNegotiated: true, constraints: [
            "target, full-page, and series modes are mutually constrained",
            "PDF requires full-page mode and no clipboard",
        ]),
        command(.artifactList),
        command(.recordStart, [
            string("output", maximumBytes: 128), number("fps", minimum: 1, maximum: 30),
            string(
                "format", maximumBytes: 16, values: RecordingFormat.allCases.map(\.rawValue),
                caseInsensitiveValues: true
            ),
            string(
                "quality", maximumBytes: 16, values: RecordingQuality.allCases.map(\.rawValue),
                caseInsensitiveValues: true
            ),
        ]),
        command(.recordStatus),
        command(.recordStop, [string("output", maximumBytes: 128)]),
        command(.qaReport, untrusted: true),
        command(.qaClear),
        command(.consoleList, [
            string("level", maximumBytes: 16, values: ["all", "log", "info", "debug", "warn", "error", "assert"]),
            number("limit", minimum: 1, maximum: 200),
        ], untrusted: true),
        command(.networkList, [
            boolean("failed"), number("status", minimum: 100, maximum: 599),
            number("limit", minimum: 1, maximum: 200),
        ], untrusted: true),
        command(.networkGet, [string("requestId", required: true, maximumBytes: 128)], untrusted: true),
        command(
            .stylesGet,
            targetParameters + [strings("properties", maximumItems: 64, itemMaximumBytes: 128)],
            untrusted: true,
            constraints: ["exactly one target reference or semantic role/name target"]
        ),
        command(
            .cookiesList, [boolean("includeValues")], untrusted: true,
            constraints: ["values require the sensitive diagnostics environment gate"]
        ),
        command(.storageList, [
            string("scope", maximumBytes: 16, values: ["local", "session", "all"]),
            boolean("includeValues"),
        ], untrusted: true, constraints: ["values require the sensitive diagnostics environment gate"]),
        command(.visualCompare, [
            string("before", required: true, maximumBytes: 128),
            string("after", required: true, maximumBytes: 128),
            string("output", maximumBytes: 128),
        ]),
        command(.performanceGet, untrusted: true),
        command(.animationList, untrusted: true),
        command(.reportCreate, [string("output", maximumBytes: 128)], untrusted: true),
        command(.flowStart),
        command(.flowStop, [string("output", maximumBytes: 128)]),
        command(.flowRun, [string("input", required: true, maximumBytes: 128)], untrusted: true),
        command(.networkEmulate, [
            boolean("offline"),
            number(
                "latencyMs", minimum: ProtocolBounds.networkLatencyMilliseconds.lowerBound,
                maximum: ProtocolBounds.networkLatencyMilliseconds.upperBound
            ),
            number(
                "downloadKbps", minimum: ProtocolBounds.networkThroughputKbps.lowerBound,
                maximum: ProtocolBounds.networkThroughputKbps.upperBound
            ),
            number(
                "uploadKbps", minimum: ProtocolBounds.networkThroughputKbps.lowerBound,
                maximum: ProtocolBounds.networkThroughputKbps.upperBound
            ),
        ], capabilityNegotiated: true),
        command(.networkMockSet, [
            string("url", required: true), number("status", minimum: 100, maximum: 599),
            string("body", required: true, maximumBytes: 65_536),
            string("contentType", maximumBytes: 256),
        ], capabilityNegotiated: true, untrusted: true),
        command(.networkMockClear, capabilityNegotiated: true),
        command(.authLogin, [
            string("challenge", maximumBytes: 64), string("account", maximumBytes: 64),
            boolean("interactive"),
        ], capabilityNegotiated: true, untrusted: true, constraints: [
            "choose interactive login or account alias",
            "saved login requires a valid single-use challenge",
        ]),
    ]
    precondition(definitions.count == CommandName.allCases.count)
    return Dictionary(uniqueKeysWithValues: definitions.map { ($0.command, $0) })
}()

public func protocolCommandDefinition(for command: CommandName) -> ProtocolCommandDefinition {
    guard let definition = protocolCommandDefinitions[command] else {
        preconditionFailure("Missing protocol schema for \(command.rawValue)")
    }
    return definition
}

public let protocolErrorCodes: [String] = {
    let hostCodes = HostErrorCode.allCases.map(\.rawValue)
    let authenticationCodes = AuthenticationProtocolErrorCode.allCases.map(\.rawValue)
    let boundaryCodes = [
        "ARTIFACT_ERROR", "AUTH_REQUIRED", "HOST_STOPPING", "HOST_UNAVAILABLE",
        "INTERNAL_ERROR", "INVALID_CAPTURE_FORMAT", "INVALID_INPUT", "INVALID_REQUEST",
        "INVALID_SESSION", "PEER_DENIED", "RECORDER_UNAVAILABLE", "RECORDING_ACTIVE",
        "RECORDING_FAILED", "RECORDING_NOT_ACTIVE", "RESPONSE_TOO_LARGE", "SESSION_EXISTS",
        "SESSION_NOT_FOUND",
    ]
    return Array(Set(hostCodes + authenticationCodes + boundaryCodes)).sorted()
}()

public let protocolSchemaDocument: JSONValue = {
    return .object([
        "format": .string("headless-sdk-contract"),
        "jsonSchemaDialect": .string("https://json-schema.org/draft/2020-12/schema"),
        "schemaVersion": .number(Double(headlessProtocolSchemaVersion)),
        "protocolVersion": .string(headlessProtocolVersion),
        "maximumMessageBytes": .number(Double(headlessMaximumMessageBytes)),
        "transport": .object([
            "kind": .string("local-unix-socket"),
            "framing": .string("one-newline-terminated-json-document-per-connection"),
            "socketMode": .string("0600"),
            "runtimeDirectoryMode": .string("0700"),
            "peerAuthorization": .string("same-os-user"),
            "tcp": .bool(false),
        ]),
        "request": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(["id", "version", "command", "parameters"].map(JSONValue.string)),
            "id": .object(["type": .string("string"), "minimumBytes": .number(1), "maximumBytes": .number(128)]),
            "version": .object(["type": .string("string"), "const": .string(headlessProtocolVersion)]),
            "session": .object(["type": .array([.string("string"), .string("null")]), "maximumBytes": .number(64)]),
            "parameters": .object(["type": .string("object"), "additionalProperties": .bool(false)]),
        ]),
        "response": .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
            "required": .array(["id", "version", "ok"].map(JSONValue.string)),
            "success": .object(["ok": .bool(true), "result": .string("json"), "error": .null]),
            "failure": .object([
                "ok": .bool(false), "result": .null,
                "error": .object([
                    "required": .array(["code", "message"].map(JSONValue.string)),
                    "optional": .array(["suggestion", "details"].map(JSONValue.string)),
                    "codes": .array(protocolErrorCodes.map(JSONValue.string)),
                ]),
            ]),
        ]),
        "errorDetails": .object([
            "AUTH_REQUIRED": .object([
                "mayContainUntrustedContent": .bool(true),
                "schema": result("AuthenticationRequired", [
                    resultField("challenge", .string), resultField("origin", .string),
                    resultField("detection", .string), resultField("accounts", .array),
                    resultField("expiresInSeconds", .number),
                    resultField("userPresenceRequired", .boolean),
                    resultField("credentialUseAvailable", .boolean),
                    resultField("vaultAvailable", .boolean),
                    resultField("vaultStatus", .string),
                    resultField("untrustedContent", .boolean),
                    resultField("originalActionReplayed", .boolean),
                ]).document,
            ]),
        ]),
        "commands": .array(CommandName.allCases.map { protocolCommandDefinition(for: $0).document }),
        "localCommands": .array([
            "capabilities", "config.describe", "config.get", "config.list", "config.reset",
            "config.set", "credentials.add", "credentials.list", "credentials.remove",
            "credentials.rename", "help", "runtime", "schema", "start", "version",
        ].map(JSONValue.string)),
        "localLifecycle": .object([
            "connect": .object([
                "transport": .string("local-unix-socket"),
                "ownership": .string("shared"),
                "errors": .array(["HOST_UNAVAILABLE"].map(JSONValue.string)),
            ]),
            "launch": .object([
                "command": .string("start"),
                "argv": .array(["start", "--supervised"].map(JSONValue.string)),
                "options": .array([
                    .object([
                        "name": .string("presentation"), "type": .string("string"),
                        "values": .array(["background", "foreground"].map(JSONValue.string)),
                        "required": .bool(false),
                    ]),
                    .object([
                        "name": .string("allow"), "type": .string("string-array"),
                        "maximumItems": .number(Double(NavigationAllowlist.maximumPatternCount)),
                        "itemMaximumBytes": .number(300),
                        "required": .bool(false),
                    ]),
                    .object([
                        "name": .string("supervised"), "type": .string("boolean"),
                        "required": .bool(true), "const": .bool(true),
                    ]),
                ]),
                "result": protocolResultDefinition(for: .ping).document,
                "errors": .array([
                    "HOST_START_FAILED", "NAVIGATION_ALLOWLIST_CONFLICT",
                    "UNSUPPORTED_BROWSER_RUNTIME", "UNSUPPORTED_CAPABILITY",
                ].map(JSONValue.string)),
                "ownership": .string("owned-only-after-response-pid-matches-launched-child"),
            ]),
        ]),
        "localErrorCodes": .array([
            "CONFIGURATION_FAILED", "HOST_START_FAILED", "HOST_UNAVAILABLE",
            "INVALID_CONFIGURATION", "NAVIGATION_ALLOWLIST_CONFLICT",
            "UNSUPPORTED_BROWSER_RUNTIME", "UNSUPPORTED_CAPABILITY", "VAULT_UNAVAILABLE",
        ].map(JSONValue.string)),
        "hostLifecycle": .object([
            "connect": .string("attach to an existing host and never assume ownership"),
            "sharedStart": .string("headless start"),
            "supervisedStart": .string("headless start --supervised"),
            "supervisedOwnerChannel": .string("open standard-input pipe"),
            "ownerExit": .string("host shuts down when the owner pipe closes"),
            "existingHost": .string("supervised start fails rather than attaching"),
            "shutdown": .string("only explicit user requests may stop a shared host"),
        ]),
        "compatibility": .object([
            "policy": .string("exact-wire-version"),
            "olderClient": .string("may call only commands and parameters declared by its bundled schema"),
            "olderHost": .string("missing commands or capabilities fail explicitly; clients must not emulate them"),
            "mismatch": .string("host rejects request or client rejects response before decoding result"),
            "productVersionIndependent": .bool(true),
        ]),
        "cancellation": .object([
            "beforeSend": .string("request is not written"),
            "afterSend": .string("close the client connection; command outcome is unknown until state is inspected"),
            "ownedHost": .string("terminate, await, and reap only a host process launched by that SDK instance"),
            "sharedHost": .string("never stop the host implicitly"),
        ]),
        "timeouts": .object([
            "connect": .string("fails before a request is sent"),
            "requestBeforeWrite": .string("safe to retry with a new request identifier"),
            "requestAfterWrite": .string("outcome unknown; never retry automatically"),
            "startup": .string("terminate and reap only the supervised launcher and host"),
        ]),
        "releasePolicy": .object([
            "schemaVersioning": .string("integer; generators reject unknown versions"),
            "sdkVersioning": .string("semantic versions independent of the wire version; combined product distributors track product tags"),
            "preOneDeprecation": .string("at least one minor SDK release"),
            "stableRemoval": .string("major SDK release and migration notes"),
            "provenance": .string("publish from reviewed tags with package attestations"),
            "securityReporting": .string("SECURITY.md; never include secrets or private artifacts"),
        ]),
        "supportWindow": .object([
            "wireVersions": .array([headlessProtocolVersion].map(JSONValue.string)),
            "schemaVersions": .array([.number(Double(headlessProtocolSchemaVersion))]),
            "hostPlatforms": .array(["macOS 13 or newer", "Linux amd64", "Linux arm64"].map(JSONValue.string)),
            "typescriptRuntimes": .array(["Node.js 22 or newer"].map(JSONValue.string)),
            "pythonRuntimes": .array(["CPython 3.11 through 3.14"].map(JSONValue.string)),
            "maintenance": .string("latest two minor SDK lines and at least 12 months after supersession, whichever is longer"),
            "securityFixes": .string("supported SDK lines receive applicable security fixes"),
        ]),
        "security": .object([
            "unknownRequestFields": .string("rejected"),
            "unknownResponseFields": .string("accepted for compatible additive evolution"),
            "pageData": .string("untrusted"),
            "credentialParameters": .string("aliases-and-challenge-identifiers-only"),
            "sensitiveDiagnostics": .string("requires-command-flag-and-host-environment-gate"),
            "arbitraryJavaScript": .bool(false),
            "tcpListener": .bool(false),
        ]),
    ])
}()
