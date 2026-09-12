import Foundation

public enum BrowserEngineName: String, CaseIterable, Sendable {
    case webkit
    case chromium
}

/// A machine-readable declaration of the behavior an engine actually exposes.
/// Named fields make new divergences a compiler-visible change instead of an
/// undocumented string added to the CLI output.
public struct BrowserEngineCapabilities: Sendable {
    public let engine: BrowserEngineName
    public let platforms: [String]
    public let unsupportedCommands: Set<CommandName>
    public let pdfOutput: String
    public let elementScreenshotCoordinates: String
    public let elementScreenshotBeyondViewport: Bool
    public let jpegEncoder: String
    public let cookieScope: String
    public let cookieFields: [String]
    public let backWithoutHistory: String
    public let recordingDuringNavigation: String
    public let qaDiagnosticSource: String
    public let qaDiagnosticSynchronization: String
    public let screenshotClipboard: Bool
    public let inputDispatch: String
    public let normalProfileStorage: String
    public let fileUpload: Bool

    public var supportedCommands: [CommandName] {
        CommandName.allCases.filter { !unsupportedCommands.contains($0) }
    }

    public var document: JSONValue {
        .object([
            "engine": .string(engine.rawValue),
            "platforms": .array(platforms.map(JSONValue.string)),
            "commands": .array(supportedCommands.map { .string($0.rawValue) }),
            "unsupportedCommands": .array(
                CommandName.allCases.filter(unsupportedCommands.contains).map { .string($0.rawValue) }
            ),
            "features": .object([
                "pdfScreenshot": .object([
                    "supported": .bool(true), "output": .string(pdfOutput),
                ]),
                "elementScreenshot": .object([
                    "coordinateSpace": .string(elementScreenshotCoordinates),
                    "beyondViewport": .bool(elementScreenshotBeyondViewport),
                ]),
                "jpeg": .object([
                    "encoder": .string(jpegEncoder), "quality": .number(88),
                ]),
                "cookies": .object([
                    "scope": .string(cookieScope),
                    "fields": .array(cookieFields.map(JSONValue.string)),
                ]),
                "backWithoutHistory": .string(backWithoutHistory),
                "recordingDuringNavigation": .string(recordingDuringNavigation),
                "qaDiagnostics": .object([
                    "source": .string(qaDiagnosticSource),
                    "synchronization": .string(qaDiagnosticSynchronization),
                ]),
                "networkEmulation": .bool(!unsupportedCommands.contains(.networkEmulate)),
                "networkMocking": .bool(
                    !unsupportedCommands.contains(.networkMockSet)
                        && !unsupportedCommands.contains(.networkMockClear)
                ),
                "screenshotClipboard": .bool(screenshotClipboard),
                "tourTimeoutMs": .number(65_000),
                "inputDispatch": .string(inputDispatch),
                "fileUpload": .bool(fileUpload),
                "normalProfile": .object([
                    "persistent": .bool(true),
                    "sharedAcrossSessions": .bool(true),
                    "storage": .string(normalProfileStorage),
                    "clearCommand": .string(CommandName.profileClear.rawValue),
                ]),
                "isolatedSessions": .object([
                    "supported": .bool(true),
                    "storage": .string("engine-native-ephemeral-context"),
                    "sharedAcrossSessions": .bool(false),
                    "normalVaultAvailable": .bool(false),
                    "ephemeralCredentials": .bool(true),
                    "destroyedOnClose": .bool(true),
                ]),
                "authentication": .object([
                    "challengeCommand": .string(CommandName.authLogin.rawValue),
                    "exactOriginAliases": .bool(true),
                    "challengeLifetimeSeconds": .number(AuthenticationChallengeStore.lifetime),
                    "singleUse": .bool(true),
                    "savedCredentialUse": .bool(engine == .webkit),
                    "userPresencePerSavedUse": .bool(engine == .webkit),
                    "automaticActionReplay": .bool(false),
                    "interactiveLogin": .bool(true),
                ]),
            ]),
        ])
    }

    public static let webkit = BrowserEngineCapabilities(
        engine: .webkit,
        platforms: ["macos"],
        unsupportedCommands: [.networkEmulate, .networkMockSet, .networkMockClear, .upload],
        pdfOutput: "rasterized-page-image",
        elementScreenshotCoordinates: "viewport",
        elementScreenshotBeyondViewport: false,
        jpegEncoder: "apple-imageio",
        cookieScope: "current-origin",
        cookieFields: ["name", "domain", "path", "secure", "httpOnly", "expiresAt"],
        backWithoutHistory: "operation-failed",
        recordingDuringNavigation: "continuous",
        qaDiagnosticSource: "webkit-page-bridge",
        qaDiagnosticSynchronization: "best-effort-page-world-observer",
        screenshotClipboard: true,
        inputDispatch: "synthetic-dom",
        normalProfileStorage: "persistent-wkwebsite-data-store",
        fileUpload: false
    )

    public static let chromium = BrowserEngineCapabilities(
        engine: .chromium,
        platforms: ["linux"],
        unsupportedCommands: [],
        pdfOutput: "vector-print",
        elementScreenshotCoordinates: "document",
        elementScreenshotBeyondViewport: true,
        jpegEncoder: "chromium-cdp",
        cookieScope: "browser-context",
        cookieFields: [
            "name", "domain", "path", "sameSite", "priority", "sourceScheme",
            "secure", "httpOnly", "session", "partitionKeyOpaque", "expiresAt",
        ],
        backWithoutHistory: "operation-failed",
        recordingDuringNavigation: "pause-and-retry",
        qaDiagnosticSource: "chromium-cdp",
        qaDiagnosticSynchronization: "runtime-round-trip-flush",
        screenshotClipboard: false,
        inputDispatch: "trusted-cdp",
        normalProfileStorage: "private-xdg-data-directory",
        fileUpload: true
    )

    public static func profile(for engine: BrowserEngineName) -> BrowserEngineCapabilities {
        switch engine {
        case .webkit: webkit
        case .chromium: chromium
        }
    }

    /// Generated from the engine enum so adding an engine cannot silently
    /// leave it out of the machine-readable capability document.
    public static let all: [BrowserEngineCapabilities] =
        BrowserEngineName.allCases.map { BrowserEngineCapabilities.profile(for: $0) }
}

public var currentBrowserEngineCapabilities: BrowserEngineCapabilities {
    #if os(macOS)
    .webkit
    #else
    .chromium
    #endif
}

private func stringArray<S: Sequence>(_ values: S) -> JSONValue where S.Element == String {
    .array(values.map(JSONValue.string))
}

public let capabilitiesDocument: JSONValue = {
    let profiles = BrowserEngineCapabilities.all
    let engines = Dictionary(uniqueKeysWithValues: profiles.map { profile in
        (profile.engine.rawValue, profile.document)
    })
    let screenshotExtensions = ScreenshotFormat.artifactExtensions.sorted()
    let recordingExtensions = RecordingFormat.artifactExtensions.sorted()
    #if os(macOS)
    let credentialBackend = "macos-login-keychain"
    let credentialSecurityTier = "local-unnotarized"
    #else
    let credentialBackend = "linux-secret-service"
    let credentialSecurityTier = "os-secure-store"
    #endif
    let artifactExtensions = ScreenshotFormat.artifactExtensions
        .union(RecordingFormat.artifactExtensions)
        .union(uploadArtifactExtensions)
        .sorted()
    return .object([
        "protocolVersion": .string(headlessProtocolVersion),
        "protocolSchema": .object([
            "command": .string("schema"),
            "schemaVersion": .number(Double(headlessProtocolSchemaVersion)),
        ]),
        "transport": stringArray(["local-unix-socket"]),
        "currentEngine": .string(currentBrowserEngineCapabilities.engine.rawValue),
        "commands": .array(CommandName.allCases.map { .string($0.rawValue) }),
        "engines": .object(engines),
        "artifacts": stringArray(artifactExtensions),
        "screenshotFormats": stringArray(screenshotExtensions),
        "pdfScreenshots": .string("full-page only"),
        "screenshotClipboard": .string("macOS image screenshots only"),
        "recordingFormats": stringArray(recordingExtensions),
        "recordingQuality": stringArray(RecordingQuality.allCases.map(\.rawValue)),
        "recordingProviders": stringArray(["browser-ffmpeg"]),
        "inspectContexts": stringArray(["summary", "outline", "text", "actions", "full"]),
        "inspectPruning": .object([
            "regionReferences": .string("@rN"),
            "maximumItems": .number(250),
            "budgetRangeEstimatedTokens": .array([.number(256), .number(16_000)]),
            "maximumOutlineDepth": .number(8),
        ]),
        "screenshotSeries": stringArray(["viewport", "section"]),
        "localCommands": stringArray([
            "config.describe", "config.get", "config.list", "config.reset", "config.set",
            "credentials.add", "credentials.list", "credentials.remove", "credentials.rename",
            "schema",
        ]),
        "settings": .object([
            "definitions": .array(SettingsRegistry.shared.definitions.compactMap { definition in
                definition.access == .userOnly ? nil : definition.document
            }),
            "storage": .object([
                "macos": .string("user-defaults"),
                "linux": .string("private-xdg-config-file"),
            ]),
            "securityInvariantsConfigurable": .bool(false),
        ]),
        "credentialVault": .object([
            "supported": .bool(true),
            "backend": .string(credentialBackend),
            "securityTier": .string(credentialSecurityTier),
            "availability": .string("checked-at-command-time"),
            "passwordTransport": .string("dedicated-local-broker"),
            "userPresence": .string(
                currentBrowserEngineCapabilities.engine == .webkit
                    ? "required-on-every-use-by-broker" : "unavailable-for-saved-use"
            ),
            "silentUse": .bool(false),
            "agentReceivesPasswords": .bool(false),
            "privateContextAccess": .bool(false),
            "privateEphemeralCredentials": .bool(true),
        ]),
        "security": .object([
            "tcpListener": .bool(false),
            "arbitraryJavaScript": .bool(false),
            "allowedNavigationSchemes": stringArray(["http", "https"]),
            "blockedRemoteResourceExtensions": stringArray(blockedRemoteResourceExtensions.sorted()),
            "cautionRemoteResourceExtensions": stringArray(cautionRemoteResourceExtensions.sorted()),
            "downloadsDenied": .bool(true),
            "remoteControl": .string("stdio MCP bridge or SSH forwarding only; no TCP listener"),
            "networkSimulation": .string("Chromium CDP host on Linux; explicitly unsupported on WebKit"),
            "sensitiveDiagnostics": .object([
                "default": .string("redacted"),
                "enableEnvironment": .string("HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1"),
            ]),
            "maximumMessageBytes": .number(Double(headlessMaximumMessageBytes)),
        ]),
    ])
}()
