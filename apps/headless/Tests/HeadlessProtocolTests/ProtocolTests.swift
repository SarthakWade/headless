import HeadlessProtocol
import CredentialBrokerCore
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private let tinyPNG = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
    0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
    0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure(description: message)
    } catch is TestFailure {
        throw TestFailure(description: message)
    } catch {
        return
    }
}

private func repositoryFile(_ relativePath: String) -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    return nil
}

private func expectSettingsError(
    _ expected: SettingsError, _ message: String, _ body: () throws -> Void
) throws {
    do {
        try body()
        throw TestFailure(description: message)
    } catch let error as SettingsError {
        try expect(error == expected, "\(message): received \(error)")
    } catch is TestFailure {
        throw TestFailure(description: message)
    } catch {
        throw TestFailure(description: "\(message): received \(error)")
    }
}

private func expectSettingsErrorForAuthentication(
    _ expected: AuthenticationError, _ message: String, _ body: () throws -> Void
) throws {
    do {
        try body()
        throw TestFailure(description: message)
    } catch let error as AuthenticationError {
        try expect(error == expected, "\(message): received \(error)")
    } catch is TestFailure {
        throw TestFailure(description: message)
    } catch {
        throw TestFailure(description: "\(message): received \(error)")
    }
}

private func settingsObject(_ value: JSONValue, _ message: String) throws -> [String: JSONValue] {
    guard case .object(let object) = value else { throw TestFailure(description: message) }
    return object
}

private func settingsArray(_ value: JSONValue?, _ message: String) throws -> [JSONValue] {
    guard case .array(let values)? = value else { throw TestFailure(description: message) }
    return values
}

private final class TestSettingsBackend: @unchecked Sendable, SettingsBackend {
    private let lock = NSLock()
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func configuredValue(for definition: SettingDefinition) throws -> String? {
        lock.withLock { values[definition.key] }
    }

    func setConfiguredValue(_ value: String, for definition: SettingDefinition) throws {
        lock.withLock { values[definition.key] = value }
    }

    func resetConfiguredValue(for definition: SettingDefinition) throws {
        _ = lock.withLock { values.removeValue(forKey: definition.key) }
    }
}

private final class ConcurrentSettingsErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    func append(_ error: Error) {
        lock.withLock { errors.append(String(describing: error)) }
    }

    var messages: [String] {
        lock.withLock { errors }
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value += interval } }
}

private func connectRawUnixSocket(path: String) throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw TestFailure(description: "raw socket creation failed") }

    #if canImport(Darwin)
    var noSigPipe: Int32 = 1
    guard setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(descriptor)
        throw TestFailure(description: "raw socket SIGPIPE configuration failed")
    }
    #endif

    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
        throw TestFailure(description: "raw socket path was too long")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    #endif
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            #if canImport(Darwin)
            Darwin.connect(descriptor, $0, length)
            #else
            Glibc.connect(descriptor, $0, length)
            #endif
        }
    }
    guard connected == 0 else {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
        throw TestFailure(description: "raw socket connection failed")
    }
    return descriptor
}

private func closeRawSocket(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}

private func writeRawSocket(_ data: Data, descriptor: Int32) throws -> Int {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return 0 }
        var sent = 0
        while sent < buffer.count {
            #if canImport(Darwin)
            let count = Darwin.send(descriptor, base.advanced(by: sent), buffer.count - sent, 0)
            #else
            let count = Glibc.send(
                descriptor, base.advanced(by: sent), buffer.count - sent, Int32(MSG_NOSIGNAL)
            )
            #endif
            if count < 0 {
                if errno == EINTR { continue }
                // The server deliberately closes after recognizing an
                // oversized frame. Darwin may surface that close before the
                // client's send count crosses the logical limit even though
                // the typed rejection response is already queued. The caller
                // verifies that response, which is the security contract.
                if errno == EPIPE || errno == ECONNRESET { return sent }
                throw TestFailure(description: "raw socket write failed before the size limit")
            }
            guard count > 0 else { return sent }
            sent += count
        }
        return sent
    }
}

private func readRawSocketLine(descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while result.count <= headlessMaximumMessageBytes {
        #if canImport(Darwin)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        #else
        let count = Glibc.read(descriptor, &buffer, buffer.count)
        #endif
        guard count > 0 else { throw TestFailure(description: "raw socket closed without a response") }
        if let newline = buffer[..<count].firstIndex(of: 0x0A) {
            result.append(contentsOf: buffer[..<newline])
            result.append(0x0A)
            return result
        }
        result.append(contentsOf: buffer[..<count])
    }
    throw TestFailure(description: "raw socket response exceeded the protocol limit")
}

private final class TestBrowserSession: BrowserEngineSession {
    let hostIsolated: Bool
    private(set) var agentControlEnableCount = 0
    var authenticationState: JSONValue = .object([
        "origin": .string("http://localhost"), "detection": .string("none"),
    ])
    private(set) var filledCredentialAccount: String?
    var authenticationStateAfterCredentialFill: JSONValue?
    var promptedAccount = "interactive@example.test"
    var promptedPassword = "interactive-secret"
    var saveAlias: CredentialAlias?
    private(set) var credentialPromptCount = 0
    private(set) var savePromptCount = 0

    init(isolated: Bool = false) {
        hostIsolated = isolated
    }

    func hostEnableAgentControl() { agentControlEnableCount += 1 }
    func hostVisit(_ url: URL) throws -> JSONValue { .object(["url": .string(url.absoluteString)]) }
    func hostInspect(parameters: [String: JSONValue]) throws -> JSONValue {
        .object(["engineResult": .bool(true), "parameters": .object(parameters)])
    }
    func hostClick(parameters: [String: JSONValue]) throws -> JSONValue { .object(["clicked": .bool(true)]) }
    func hostFill(parameters: [String: JSONValue]) throws -> JSONValue { .object(["filled": .bool(true)]) }
    private(set) var lastUploadPath: String?
    func hostUpload(parameters: [String: JSONValue], artifactURL: URL) throws -> JSONValue {
        lastUploadPath = artifactURL.path
        return .object([
            "uploaded": .string(parameters["target"]?.stringValue ?? "@e1"),
            "artifact": .string(artifactURL.lastPathComponent),
            "role": .string(parameters["role"]?.stringValue ?? "textbox"),
            "name": .string(parameters["name"]?.stringValue ?? ""),
        ])
    }
    func hostPress(parameters: [String: JSONValue]) throws -> JSONValue { .object(["pressed": .bool(true)]) }
    func hostScroll(parameters: [String: JSONValue]) throws -> JSONValue { .object(["scrolled": .bool(true)]) }
    func hostWait(parameters: [String: JSONValue]) throws -> JSONValue { .object(["waited": .bool(true)]) }
    func hostTour(parameters: [String: JSONValue]) throws -> JSONValue { .object(["toured": .bool(true)]) }
    func hostBack() throws -> JSONValue { .object(["back": .bool(true)]) }
    func hostReload() throws -> JSONValue { .object(["reloaded": .bool(true)]) }
    func hostCaptureInfo() throws -> JSONValue { .object(["engine": .string("fake")]) }
    func hostScreenshot(
        parameters: [String: JSONValue], format: ScreenshotFormat, copyToClipboard: Bool
    ) throws -> BrowserScreenshot { BrowserScreenshot(data: Data("image".utf8)) }
    func hostRecordingFrame() throws -> Data { Data("frame".utf8) }
    func hostScreenshotSeriesPlan(mode: String) throws -> JSONValue {
        .object([
            "initialY": .number(0), "totalPoints": .number(1), "truncated": .bool(false),
            "points": .array([.object(["y": .number(0), "label": .string("viewport")])]),
        ])
    }
    func hostScrollToCapturePoint(y: Double) throws -> JSONValue { .object(["y": .number(y)]) }
    func hostQAReport() throws -> JSONValue { .object(["issues": .array([])]) }
    func hostQAClear() throws -> JSONValue { .object(["cleared": .bool(true)]) }
    func hostConsole(level: String, limit: Int) throws -> JSONValue { .object(["entries": .array([])]) }
    func hostNetwork(failedOnly: Bool, status: Int?, limit: Int) throws -> JSONValue {
        .object(["requests": .array([])])
    }
    func hostNetworkDetail(requestID: String) throws -> JSONValue {
        .object(["requestId": .string(requestID)])
    }
    func hostStyles(parameters: [String: JSONValue]) throws -> JSONValue { .object(["styles": .array([])]) }
    func hostCookies(includeValues: Bool) throws -> JSONValue { .object(["cookies": .array([])]) }
    func hostStorage(scope: String, includeValues: Bool) throws -> JSONValue { .object(["scope": .string(scope)]) }
    func hostPerformance() throws -> JSONValue { .object(["metrics": .array([])]) }
    func hostAnimations() throws -> JSONValue { .object(["animations": .array([])]) }
    func hostAuthenticationState() throws -> JSONValue { authenticationState }
    func hostPromptCredential(origin: CredentialOrigin) throws -> AuthenticationCredential {
        credentialPromptCount += 1
        return try AuthenticationCredential(
            account: promptedAccount,
            password: AuthenticationSecret(Array(promptedPassword.utf8))
        )
    }
    func hostPromptCredentialSave(origin: CredentialOrigin, account: String) throws -> CredentialAlias? {
        savePromptCount += 1
        return saveAlias
    }
    func hostFillCredential(
        form: AuthenticationForm, credential: AuthenticationCredential
    ) throws -> JSONValue {
        filledCredentialAccount = credential.account
        credential.password.clear()
        authenticationState = authenticationStateAfterCredentialFill ?? .object([
            "origin": .string(form.origin), "detection": .string("none"),
        ])
        return .object(["submitted": .bool(true)])
    }
}

private final class TestAuthenticationBroker: @unchecked Sendable, AuthenticationBroker {
    let origin: CredentialOrigin
    let alias: CredentialAlias
    let account: String
    let password: [UInt8]
    var credentialError: AuthenticationError?
    private(set) var aliasLookupCount = 0
    private(set) var credentialLookupCount = 0
    private(set) var storedAlias: CredentialAlias?
    private(set) var storedAccount: String?
    private(set) var storedPassword: [UInt8]?

    init(origin: CredentialOrigin, alias: CredentialAlias, account: String, password: String) {
        self.origin = origin
        self.alias = alias
        self.account = account
        self.password = Array(password.utf8)
    }

    func aliases(for origin: CredentialOrigin) throws -> [AuthenticationAlias] {
        aliasLookupCount += 1
        guard origin == self.origin else { return [] }
        return [try AuthenticationAlias(alias: alias, account: account)]
    }

    func credential(
        for origin: CredentialOrigin, alias: CredentialAlias
    ) throws -> AuthenticationCredential {
        credentialLookupCount += 1
        if let credentialError { throw credentialError }
        guard origin == self.origin, alias == self.alias else {
            throw AuthenticationError.accountNotFound
        }
        return try AuthenticationCredential(
            account: account, password: AuthenticationSecret(password)
        )
    }

    func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws {
        guard origin == self.origin else { throw AuthenticationError.originChanged }
        storedAlias = alias
        storedAccount = credential.account
        storedPassword = credential.password.withUnsafeBytes { Array($0) }
    }
}

private final class TestCredentialPrompt: CredentialPrompting {
    let account: String
    private var passwords: [[UInt8]]

    init(account: String, passwords: [String]) {
        self.account = account
        self.passwords = passwords.map { Array($0.utf8) }
    }

    func readAccount() throws -> String { account }

    func readPassword() throws -> SensitiveBytes {
        guard !passwords.isEmpty else { throw CredentialVaultError.promptFailed }
        return SensitiveBytes(passwords.removeFirst())
    }

    func readPasswordConfirmation() throws -> SensitiveBytes {
        try readPassword()
    }
}

private final class TestCredentialSecretStore: CredentialSecretStore {
    let backendName = "fake-secure-vault"
    var records: [String: CredentialRecord] = [:]
    var storedSecretBytes: [UInt8] = []
    var storeError: CredentialVaultError?
    var removeError: CredentialVaultError?
    var afterStore: ((CredentialRecord) -> Void)?

    func store(_ secret: SensitiveBytes, for record: CredentialRecord) throws {
        if let storeError { throw storeError }
        storedSecretBytes = secret.withUnsafeBytes { Array($0) }
        records[record.id] = record
        afterStore?(record)
    }

    func load(recordID: String) throws -> SensitiveBytes {
        guard records[recordID] != nil, !storedSecretBytes.isEmpty else {
            throw CredentialVaultError.notFound
        }
        return SensitiveBytes(storedSecretBytes)
    }

    func remove(recordID: String) throws {
        if let removeError { throw removeError }
        records.removeValue(forKey: recordID)
    }
}

private final class TestBrowserEngine: BrowserEngine {
    typealias Session = TestBrowserSession

    let name = "fake"
    let platform = "test"
    let capabilities = BrowserEngineCapabilities.chromium
    private(set) var createdSessions: [TestBrowserSession] = []
    private(set) var closedSessions: [TestBrowserSession] = []
    private(set) var stopped = false
    private(set) var profileClearCount = 0

    func createSession() throws -> TestBrowserSession {
        let session = TestBrowserSession()
        createdSessions.append(session)
        return session
    }

    func createIsolatedSession() throws -> TestBrowserSession {
        let session = TestBrowserSession(isolated: true)
        createdSessions.append(session)
        return session
    }

    func closeSession(_ session: TestBrowserSession) { closedSessions.append(session) }
    func stop() { stopped = true }
    func clearProfile() throws { profileClearCount += 1 }
    func pingDetails() -> [String: JSONValue] { ["adapter": .string("test-adapter")] }
}

@main
struct ProtocolTests {
    typealias TestCase = (String, () throws -> Void)

    static func requestRoundTrip() throws {
        let request = CommandRequest(
            id: "request-1",
            command: .visit,
            session: "qa",
            parameters: ["url": .string("http://localhost:3000/dashboard")]
        )
        let data = try ProtocolCodec.encodeLine(request)
        try expect(try ProtocolCodec.decodeLine(CommandRequest.self, from: data) == request, "request should round-trip")
    }

    static func rejectsUnsafeNavigationSchemes() throws {
        for value in [
            "file:///etc/passwd", "javascript:alert(1)", "mailto:test@example.com",
            "https://user:password@example.com",
        ] {
            try expectThrows("expected \(value) to be rejected") {
                _ = try normalizedWebURL(value)
            }
        }
    }

    static func normalizesLocalhostToHTTP() throws {
        try expect(
            try normalizedWebURL("localhost:3000/designers/dashboard").absoluteString
                == "http://localhost:3000/designers/dashboard",
            "localhost should default to HTTP"
        )
        try expect(
            try normalizedWebURL("localhost.evil.example/path").absoluteString
                == "https://localhost.evil.example/path",
            "a localhost-looking public hostname must not be downgraded to HTTP"
        )
    }

    static func pageNavigationBoundary() throws {
        try expect(
            agentMayNavigate(to: URL(string: "https://example.com/dashboard")!),
            "ordinary HTTPS navigation should be allowed"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "https://user:secret@example.com/private")!),
            "credential-bearing page navigation should be rejected"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "data:text/html,unsafe")!),
            "non-web page navigation should be rejected"
        )
        try expect(
            !agentMayNavigate(to: URL(string: "https://example.com/installer.dmg")!),
            "remote installers should be rejected"
        )
        try expect(
            agentMayNavigate(to: URL(string: "https://example.com/walkthrough.mp4")!),
            "normal web media should remain allowed"
        )
        try expect(
            remoteResourceSafety(for: URL(string: "https://example.com/archive.zip")!) == .caution,
            "archives should be visible as caution resources"
        )
        try expectThrows("remote installers should fail explicit visits") {
            _ = try normalizedWebURL("https://example.com/installer.dmg")
        }
    }

    static func navigationAllowlist() throws {
        let unrestricted = NavigationAllowlist.unrestricted
        try expect(unrestricted.patterns.isEmpty, "empty allowlist should be unrestricted")
        try expect(!unrestricted.isRestricted, "empty allowlist should not be restricted")
        try expect(
            unrestricted.allows(URL(string: "https://example.com/dashboard")!),
            "unrestricted allowlist should permit any otherwise-legal host"
        )
        try expect(
            agentMayNavigate(to: URL(string: "https://example.com/dashboard")!, allowlist: unrestricted),
            "agentMayNavigate should stay open when the allowlist is empty"
        )

        let repeated = try CLIParser().parse([
            "start", "--allow", "localhost", "--allow", "*.staging.example.com",
        ])
        try expect(
            repeated.local == .start(
                presentation: nil,
                allowlist: try NavigationAllowlist.parse(["localhost", "*.staging.example.com"]),
                supervised: false
            ),
            "repeated --allow flags should parse in order"
        )

        let commaSeparated = try CLIParser().parse(["start", "--allow", "localhost,127.0.0.1"])
        try expect(
            commaSeparated.local == .start(
                presentation: nil,
                allowlist: try NavigationAllowlist.parse(["localhost", "127.0.0.1"]),
                supervised: false
            ),
            "comma-separated --allow values should parse"
        )

        let ordered = try NavigationAllowlist.parse(["127.0.0.1", "localhost"])
        let swapped = try NavigationAllowlist.parse(["localhost", "127.0.0.1"])
        try expect(
            Set(ordered.patterns) == Set(swapped.patterns),
            "swapped --allow order should compare equal as a set"
        )
        try expect(
            ordered.patterns == ["127.0.0.1", "localhost"],
            "canonical patterns should keep first-seen order"
        )
        try expect(
            swapped.patterns == ["localhost", "127.0.0.1"],
            "a later start with swapped --allow flags still preserves its own first-seen order"
        )

        let withBackground = try CLIParser().parse([
            "start", "--allow", "localhost", "--background",
        ])
        try expect(
            withBackground.local == .start(
                presentation: .background,
                allowlist: try NavigationAllowlist.parse(["localhost"]),
                supervised: false
            ),
            "start --allow should compose with --background"
        )
        let withForeground = try CLIParser().parse([
            "start", "--foreground", "--allow", "127.0.0.1",
        ])
        try expect(
            withForeground.local == .start(
                presentation: .foreground,
                allowlist: try NavigationAllowlist.parse(["127.0.0.1"]),
                supervised: false
            ),
            "start --allow should compose with --foreground"
        )

        let deduped = try NavigationAllowlist.parse(["LocalHost", "localhost", "LOCALHOST:3000"])
        try expect(
            deduped.patterns == ["localhost", "localhost:3000"],
            "allowlist patterns should canonicalize case and preserve first-seen order"
        )

        try expectThrows("bare * is not a host pattern") {
            _ = try NavigationAllowlist.parse(["*"])
        }
        try expectThrows("file: patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["file:"])
        }
        try expectThrows("scheme patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["https://example.com"])
        }
        try expectThrows("javascript: patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["javascript:alert(1)"])
        }
        try expectThrows("credential patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["user:secret@example.com"])
        }
        try expectThrows("path patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["example.com/path"])
        }
        try expectThrows("whitespace-only patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["   "])
        }
        try expectThrows("empty --allow should be a parse error") {
            _ = try CLIParser().parse(["start", "--allow"])
        }
        try expectThrows("empty --allow values should be a parse error") {
            _ = try CLIParser().parse(["start", "--allow", ""])
        }
        try expectThrows("non-ASCII patterns must be rejected") {
            _ = try NavigationAllowlist.parse(["exämple.com"])
        }
        try expectThrows("embedded wildcards must be rejected") {
            _ = try NavigationAllowlist.parse(["foo.*.example.com"])
        }

        var tooMany = ["start"]
        for index in 1...33 {
            tooMany.append(contentsOf: ["--allow", "host\(index).example.com"])
        }
        try expectThrows("more than 32 patterns should be rejected") {
            _ = try CLIParser().parse(tooMany)
        }
        let atCap = (1...32).map { "host\($0).example.com" }
        try expect(
            try NavigationAllowlist.parse(atCap).patterns.count == 32,
            "32 unique patterns should be accepted"
        )

        let wildcard = try NavigationAllowlist.parse(["*.example.com"])
        try expect(
            wildcard.allows(URL(string: "https://foo.example.com/")!),
            "wildcard should match one subdomain label"
        )
        try expect(
            wildcard.allows(URL(string: "https://a.b.example.com/")!),
            "wildcard should match nested subdomain labels"
        )
        try expect(
            !wildcard.allows(URL(string: "https://example.com/")!),
            "wildcard should not match the apex host"
        )
        try expect(
            !wildcard.allows(URL(string: "https://example.com.evil.test/")!),
            "wildcard should not match a suffix outside the parent domain"
        )
        try expect(
            !agentMayNavigate(
                to: URL(string: "https://example.com/")!,
                allowlist: wildcard
            ),
            "agentMayNavigate should deny an apex host for a subdomain wildcard"
        )

        let anyPort = try NavigationAllowlist.parse(["localhost"])
        try expect(anyPort.allows(URL(string: "http://localhost/")!), "localhost should match the default HTTP port")
        try expect(anyPort.allows(URL(string: "http://localhost:3000/")!), "localhost should match any port")
        try expect(anyPort.allows(URL(string: "https://localhost:8443/")!), "localhost should match HTTPS ports")
        let exactPort = try NavigationAllowlist.parse(["localhost:3000"])
        try expect(exactPort.allows(URL(string: "http://localhost:3000/")!), "localhost:3000 should match that port")
        try expect(!exactPort.allows(URL(string: "http://localhost:3001/")!), "localhost:3000 should reject other ports")
        try expect(!exactPort.allows(URL(string: "http://localhost/")!), "localhost:3000 should reject the default HTTP port")

        let loopback = try NavigationAllowlist.parse(["127.0.0.1"])
        try expect(loopback.allows(URL(string: "http://127.0.0.1:41739/")!), "IPv4 literals should match exactly")
        try expect(!loopback.allows(URL(string: "http://localhost/")!), "IPv4 literals should not match localhost")

        try CommandRequest(
            command: .visit, parameters: ["url": .string("https://example.com/dashboard")]
        ).validate()
        let visit = try CLIParser().parse(["visit", "example.com"])
        try expect(
            visit.request?.parameters["url"] == .string("https://example.com"),
            "visit should still accept example.com as a URL before host allowlist enforcement"
        )

        try expect(
            try NavigationAllowlist(environment: [:]).patterns.isEmpty,
            "missing env should be unrestricted"
        )
        try expect(
            try NavigationAllowlist(environment: [headlessNavigationAllowlistEnvironmentKey: ""]).patterns.isEmpty,
            "empty env should be unrestricted"
        )
        try expect(
            try NavigationAllowlist(
                environment: [headlessNavigationAllowlistEnvironmentKey: "localhost,127.0.0.1"]
            ).patterns == ["localhost", "127.0.0.1"],
            "env should parse canonical comma-separated patterns"
        )
        try expectThrows("invalid env patterns should fail closed") {
            _ = try NavigationAllowlist(environment: [headlessNavigationAllowlistEnvironmentKey: "*"])
        }

        let root = "/tmp/headless-allowlist-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let core = HostCore(
            engine: TestBrowserEngine(),
            artifacts: try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root]),
            defaultSession: TestBrowserSession(),
            navigationAllowlist: loopback,
            shutdownHandler: {}
        )
        defer { core.stop() }
        let ping = core.handle(CommandRequest(command: .ping))
        guard ping.ok, case .object(let pingResult) = ping.result else {
            throw TestFailure(description: "restricted host ping should succeed")
        }
        try expect(
            pingResult["navigationAllowlist"] == .array([.string("127.0.0.1")]),
            "ping should report canonical allowlist patterns"
        )
        let allowed = core.handle(CommandRequest(
            command: .visit, parameters: ["url": .string("http://127.0.0.1:41739/designers/dashboard")]
        ))
        try expect(allowed.ok, "visit to an allowlisted host should succeed")
        let denied = core.handle(CommandRequest(
            command: .visit, parameters: ["url": .string("https://example.com")]
        ))
        try expect(
            denied.error?.code == "UNSAFE_NAVIGATION",
            "host-side visit should deny a non-matching host after URL validation"
        )
        try expect(
            agentRuntimeJavaScript.contains("__headlessNavigationAllowlist"),
            "injected runtime should carry the process allowlist preamble"
        )
    }

    static func messageSizeLimit() throws {
        let exactPayload = String(repeating: "a", count: headlessMaximumMessageBytes - 3)
        let exactLine = try ProtocolCodec.encodeLine(exactPayload)
        try expect(exactLine.count == headlessMaximumMessageBytes, "framed message should fit the exact limit")
        try expect(
            try ProtocolCodec.decodeLine(String.self, from: exactLine) == exactPayload,
            "an exact-limit framed message should round-trip"
        )
        try expectThrows("encoding beyond the framed limit should be rejected") {
            _ = try ProtocolCodec.encodeLine(String(repeating: "a", count: headlessMaximumMessageBytes - 2))
        }
        let data = Data(repeating: 0x61, count: headlessMaximumMessageBytes + 1)
        try expectThrows("oversized messages should be rejected") {
            _ = try ProtocolCodec.decodeLine(CommandRequest.self, from: data)
        }
    }

    static func rejectsUnexpectedRequestFields() throws {
        let valid = Data(#"{"id":"request-1","version":"0.5","command":"ping","parameters":{}}"#.utf8)
        let decoded = try ProtocolCodec.decodeLine(CommandRequest.self, from: valid)
        try expect(decoded.command == .ping, "the strict-field control request should decode")

        let data = Data(#"{"id":"request-1","version":"0.5","command":"ping","parameters":{},"execute":"anything"}"#.utf8)
        try expectThrows("unexpected top-level request fields should be rejected") {
            _ = try ProtocolCodec.decodeLine(CommandRequest.self, from: data)
        }
    }

    static func identifierValidation() throws {
        try validateIdentifier("qa-session_1", field: "session")
        try expectThrows("path traversal identifier should be rejected") {
            try validateIdentifier("../other-user", field: "session")
        }
        try expectThrows("long identifier should be rejected") {
            try validateIdentifier(String(repeating: "a", count: 65), field: "session")
        }
    }

    static func durableBrowserProfileLifecycle() throws {
        let base = URL(fileURLWithPath: "/tmp/headless-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let migratedRoot = base.appendingPathComponent("migrated", isDirectory: true)
        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try expect(chmod(legacy.path, 0o700) == 0, "legacy profile permissions should be configurable")
        try Data("persisted".utf8).write(to: legacy.appendingPathComponent("state"))
        let migrated = try DurableBrowserProfile(rootURL: migratedRoot, legacyProfileURL: legacy)
        try expect(migrated.migration == .migrated, "a safe legacy profile should migrate")
        try expect(
            FileManager.default.fileExists(atPath: migrated.directoryURL.appendingPathComponent("state").path),
            "migration should retain browser state"
        )
        try expect(!FileManager.default.fileExists(atPath: legacy.path), "migration should remove the legacy profile")
        try expectThrows("a second owner should not acquire the same profile") {
            _ = try DurableBrowserProfile(rootURL: migratedRoot)
        }
        try Data("discard".utf8).write(to: migrated.directoryURL.appendingPathComponent("temporary"))
        try migrated.clear()
        try expect(
            !FileManager.default.fileExists(atPath: migrated.directoryURL.appendingPathComponent("temporary").path),
            "profile clear should remove existing state"
        )

        let unsafeRoot = base.appendingPathComponent("unsafe", isDirectory: true)
        let unsafeLegacy = base.appendingPathComponent("unsafe-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeLegacy, withIntermediateDirectories: false)
        try expect(chmod(unsafeLegacy.path, 0o700) == 0, "unsafe legacy permissions should be configurable")
        try FileManager.default.createSymbolicLink(
            at: unsafeLegacy.appendingPathComponent("external"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let skipped = try DurableBrowserProfile(rootURL: unsafeRoot, legacyProfileURL: unsafeLegacy)
        try expect(skipped.migration == .skippedUnsafe, "a legacy profile with symlinks should not migrate")
        try expect(FileManager.default.fileExists(atPath: unsafeLegacy.path), "unsafe legacy state should remain untouched")

        let recoveredRoot = base.appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredRoot, withIntermediateDirectories: false)
        try expect(chmod(recoveredRoot.path, 0o700) == 0, "recovery root permissions should be configurable")
        let corruptProfile = recoveredRoot.appendingPathComponent("chromium-profile", isDirectory: true)
        let staleMigration = recoveredRoot.appendingPathComponent(
            ".chromium-profile-migration-stale", isDirectory: true
        )
        try FileManager.default.createDirectory(at: staleMigration, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: corruptProfile, withIntermediateDirectories: false)
        try expect(chmod(corruptProfile.path, 0o755) == 0, "corrupt profile permissions should be configurable")
        let recovered = try DurableBrowserProfile(rootURL: recoveredRoot)
        try expect(recovered.migration == .recoveredCorruption, "owned invalid state should report recovery")
        var recoveredInfo = stat()
        try expect(lstat(recovered.directoryURL.path, &recoveredInfo) == 0, "recovered profile should exist")
        try expect((recoveredInfo.st_mode & 0o077) == 0, "recovered profile should be private")
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: recoveredRoot.path)
            .filter { $0.hasPrefix("chromium-profile.corrupt-") }
        try expect(quarantines.count == 1, "owned invalid profile state should be quarantined")
        try expect(!FileManager.default.fileExists(atPath: staleMigration.path), "stale migration state should be removed")
    }

    static func commandParameterValidation() throws {
        try CommandRequest(id: "clear-profile", command: .profileClear).validate()
        try expectThrows("profile clear should reject parameters") {
            try CommandRequest(command: .profileClear, parameters: ["path": .string("/tmp/profile")]).validate()
        }
        try CommandRequest(
            id: "isolated-session", command: .sessionCreate,
            parameters: ["name": .string("private"), "isolated": .bool(true)]
        ).validate()
        try expectThrows("isolated session flag must be boolean") {
            try CommandRequest(
                id: "invalid-isolated-session", command: .sessionCreate,
                parameters: ["name": .string("private"), "isolated": .string("true")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-scroll", command: .scroll,
            parameters: ["direction": .string("down"), "amount": .number(500)]
        ).validate()
        try expectThrows("unknown command parameters should be rejected") {
            try CommandRequest(
                id: "unknown-param", command: .ping,
                parameters: ["execute": .string("anything")]
            ).validate()
        }
        try expectThrows("invalid scroll direction should be rejected") {
            try CommandRequest(
                id: "invalid-scroll", command: .scroll,
                parameters: ["direction": .string("sideways")]
            ).validate()
        }
        try expectThrows("non-numeric element refs should be rejected") {
            try CommandRequest(
                id: "invalid-ref", command: .click,
                parameters: ["target": .string("@e../1")]
            ).validate()
        }
        try expectThrows("screenshot traversal should be rejected") {
            try CommandRequest(
                id: "bad-output", command: .screenshot,
                parameters: ["output": .string("../report.png")]
            ).validate()
        }
        try expectThrows("full-page and element screenshots should conflict") {
            try CommandRequest(
                id: "conflicting-screenshot", command: .screenshot,
                parameters: ["fullPage": .bool(true), "target": .string("@e1")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-screenshot-series", command: .screenshot,
            parameters: ["series": .string("viewport"), "outputPrefix": .string("dashboard-scroll")]
        ).validate()
        try CommandRequest(
            id: "valid-jpeg-screenshot", command: .screenshot,
            parameters: ["format": .string("jpeg"), "output": .string("dashboard.jpeg")]
        ).validate()
        try CommandRequest(
            id: "valid-pdf-screenshot", command: .screenshot,
            parameters: [
                "format": .string("pdf"), "fullPage": .bool(true),
                "output": .string("dashboard.pdf"),
            ]
        ).validate()
        try expectThrows("PDF screenshots should require full-page mode") {
            try CommandRequest(
                id: "bad-viewport-pdf", command: .screenshot,
                parameters: ["format": .string("pdf"), "output": .string("dashboard.pdf")]
            ).validate()
        }
        try expectThrows("PDF screenshots should reject element targets consistently") {
            try CommandRequest(
                id: "bad-target-pdf", command: .screenshot,
                parameters: [
                    "format": .string("pdf"), "fullPage": .bool(true),
                    "target": .string("@e1"), "output": .string("element.pdf"),
                ]
            ).validate()
        }
        try expectThrows("invalid screenshot series should be rejected") {
            try CommandRequest(
                id: "bad-screenshot-series", command: .screenshot,
                parameters: ["series": .string("footer")]
            ).validate()
        }
        try expectThrows("screenshot series should reject path prefixes") {
            try CommandRequest(
                id: "bad-screenshot-prefix", command: .screenshot,
                parameters: ["series": .string("section"), "outputPrefix": .string("../sections")]
            ).validate()
        }
        try expectThrows("output prefixes without a screenshot series should be rejected") {
            try CommandRequest(
                id: "unused-screenshot-prefix", command: .screenshot,
                parameters: ["outputPrefix": .string("ignored")]
            ).validate()
        }
        try expectThrows("screenshot series should not combine with a single output") {
            try CommandRequest(
                id: "bad-screenshot-series-output", command: .screenshot,
                parameters: ["series": .string("viewport"), "output": .string("one.png")]
            ).validate()
        }
        try expectThrows("screenshot series should reject PDF") {
            try CommandRequest(
                id: "bad-screenshot-series-pdf", command: .screenshot,
                parameters: ["series": .string("viewport"), "format": .string("pdf")]
            ).validate()
        }
        try expectThrows("screenshot series should reject clipboard") {
            try CommandRequest(
                id: "bad-screenshot-series-clipboard", command: .screenshot,
                parameters: ["series": .string("section"), "clipboard": .bool(true)]
            ).validate()
        }
        try expectThrows("screenshot output extension should match format") {
            try CommandRequest(
                id: "bad-screenshot-format-extension", command: .screenshot,
                parameters: ["format": .string("pdf"), "output": .string("dashboard.png")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-webm-recording", command: .recordStart,
            parameters: ["format": .string("webm"), "quality": .string("high"), "output": .string("flow.webm")]
        ).validate()
        try expectThrows("recording output extension should match start format") {
            try CommandRequest(
                id: "bad-recording-format-extension", command: .recordStart,
                parameters: ["format": .string("mov"), "output": .string("flow.mp4")]
            ).validate()
        }
        try CommandRequest(
            id: "valid-inspect-context", command: .inspect,
            parameters: [
                "context": .string("text"), "task": .string("search open ai"),
                "within": .string("@r12"), "limit": .number(8),
                "budget": .number(900), "depth": .number(2),
            ]
        ).validate()
        try expectThrows("invalid inspect context should be rejected") {
            try CommandRequest(
                id: "bad-inspect-context", command: .inspect,
                parameters: ["context": .string("debug")]
            ).validate()
        }
        try expectThrows("inspect task should remain bounded") {
            try CommandRequest(
                id: "long-inspect-task", command: .inspect,
                parameters: ["task": .string(String(repeating: "x", count: 513))]
            ).validate()
        }
        try expectThrows("invalid inspect region refs should be rejected") {
            try CommandRequest(
                id: "bad-inspect-region", command: .inspect,
                parameters: ["within": .string("@e1")]
            ).validate()
        }
        try expectThrows("inspect item limit should remain bounded") {
            try CommandRequest(
                id: "large-inspect-limit", command: .inspect,
                parameters: ["limit": .number(251)]
            ).validate()
        }
        try expectThrows("inspect token budget should retain a useful minimum") {
            try CommandRequest(
                id: "small-inspect-budget", command: .inspect,
                parameters: ["budget": .number(128)]
            ).validate()
        }
        try expectThrows("raw inspect limits should reject fractional values") {
            try CommandRequest(
                id: "fractional-inspect-limit", command: .inspect,
                parameters: ["limit": .number(1.5)]
            ).validate()
        }
    }

    static func cliVisit() throws {
        let invocation = try CLIParser().parse([
            "--session", "qa", "visit", "localhost:3000/designers/dashboard", "--json",
        ])
        try expect(invocation.jsonOutput, "--json should be retained")
        try expect(invocation.request?.command == .visit, "visit command should parse")
        try expect(invocation.request?.session == "qa", "session should parse")
        try expect(
            invocation.request?.parameters["url"] == .string("http://localhost:3000/designers/dashboard"),
            "visit URL should normalize"
        )
        try expect(!agentHelp.contains("--json"), "the no-op --json compatibility flag should stay out of help")
    }

    static func cliFillPreservesLiteralValue() throws {
        let value = "pass  --json\tto API"
        let invocation = try CLIParser().parse([
            "--session", "qa", "--json", "fill", "@e1", "--", value,
        ])
        try expect(invocation.jsonOutput, "global --json before the sentinel should parse")
        try expect(invocation.request?.session == "qa", "global --session before the sentinel should parse")
        try expect(invocation.request?.parameters["target"] == .string("@e1"), "fill target should parse")
        try expect(invocation.request?.parameters["value"] == .string(value), "fill text should preserve whitespace and literal flags")

        let literalFlag = try CLIParser().parse(["fill", "@e1", "--", "--json"])
        try expect(!literalFlag.jsonOutput, "--json after the sentinel should not become a global option")
        try expect(literalFlag.request?.parameters["value"] == .string("--json"), "a literal --json fill value should survive")

        let literalSession = try CLIParser().parse(["fill", "@e1", "--", "--session"])
        try expect(literalSession.request?.session == nil, "--session after the sentinel should not become a global option")
        try expect(literalSession.request?.parameters["value"] == .string("--session"), "a literal --session fill value should survive")

        try expectThrows("multi-word fill text must stay one shell argument") {
            _ = try CLIParser().parse(["fill", "@e1", "two", "words"])
        }
    }

    static func cliSemanticClick() throws {
        let invocation = try CLIParser().parse(["click", "--role", "button", "--name", "Continue"])
        try expect(
            invocation.request?.parameters == ["role": .string("button"), "name": .string("Continue")],
            "semantic target should parse"
        )
    }

    static func cliInspectContextAndTask() throws {
        let invocation = try CLIParser().parse([
            "inspect", "--context", "text", "--task", "search open ai",
            "--within", "@r4", "--limit", "6", "--budget", "800", "--depth", "2",
        ])
        try expect(invocation.request?.command == .inspect, "inspect command should parse")
        try expect(invocation.request?.parameters["context"] == .string("text"), "inspect context should parse")
        try expect(invocation.request?.parameters["interactive"] == .bool(false), "text context should not imply interactive output")
        try expect(invocation.request?.parameters["task"] == .string("search open ai"), "inspect task should parse")
        try expect(invocation.request?.parameters["within"] == .string("@r4"), "inspect region should parse")
        try expect(invocation.request?.parameters["limit"] == .number(6), "inspect limit should parse")
        try expect(invocation.request?.parameters["budget"] == .number(800), "inspect budget should parse")
        try expect(invocation.request?.parameters["depth"] == .number(2), "inspect depth should parse")
        try expectThrows("invalid inspect context should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--context", "debug"])
        }
        try expectThrows("invalid inspect region should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--within", "@e2"])
        }
        try expectThrows("fractional inspect limits should fail in the CLI") {
            _ = try CLIParser().parse(["inspect", "--limit", "1.5"])
        }
    }

    static func cliRejectsConflictingClickTarget() throws {
        try expectThrows("conflicting click targets should fail") {
            _ = try CLIParser().parse([
                "click", "@e12", "--role", "button", "--name", "Continue",
            ])
        }
    }

    static func cliWaitDefaultsToSettled() throws {
        let invocation = try CLIParser().parse(["wait"])
        try expect(invocation.request?.parameters["settled"] == .bool(true), "wait should default to settled")
    }

    static func cliRejectsUnboundedTimeout() throws {
        try expectThrows("unbounded timeout should fail") {
            _ = try CLIParser().parse(["wait", "--timeout", "9999999"])
        }
    }

    static func clientTimeoutsMatchCommandBounds() throws {
        let longWait = try CLIParser().parse(["wait", "--timeout", "90000"])
        try expect(
            longWait.request.map { requestTimeout(for: $0) } == 95,
            "wait timeout should include the five-second transport allowance"
        )
        let maximumWait = try CLIParser().parse(["wait", "--timeout", "120000"])
        try expect(maximumWait.request.map { requestTimeout(for: $0) } == 125, "wait timeout should remain capped")
        let shortWait = try CLIParser().parse(["wait", "--timeout", "100"])
        try expect(shortWait.request.map { requestTimeout(for: $0) } == 10, "wait timeout should retain the transport minimum")

        try expect(requestTimeout(for: CommandRequest(command: .tour)) == 125, "tour should use the long timeout")
        try expect(requestTimeout(for: CommandRequest(command: .flowRun)) == 125, "flow replay should use the long timeout")
        try expect(
            requestTimeout(for: CommandRequest(command: .screenshot, parameters: ["series": .string("viewport")])) == 125,
            "screenshot series should use the long timeout"
        )
        try expect(requestTimeout(for: CommandRequest(command: .screenshot)) == 30, "single screenshots should get 30 seconds")
        try expect(requestTimeout(for: CommandRequest(command: .recordStop)) == 30, "record stop should get 30 seconds")
        try expect(requestTimeout(for: CommandRequest(command: .ping)) == 15, "ordinary commands should use the shared default")
    }

    static func cliP1Artifacts() throws {
        let screenshot = try CLIParser().parse([
            "--session", "qa", "screenshot", "--role", "button", "--name", "Continue",
            "--output", "continue.png",
        ])
        try expect(screenshot.request?.command == .screenshot, "screenshot command should parse")
        try expect(screenshot.request?.parameters["output"] == .string("continue.png"), "screenshot output should parse")
        let jpegScreenshot = try CLIParser().parse([
            "screenshot", "--format", "jpeg", "--output", "continue.jpeg", "--clipboard",
        ])
        try expect(jpegScreenshot.request?.parameters["format"] == .string("jpeg"), "screenshot format should parse")
        try expect(jpegScreenshot.request?.parameters["clipboard"] == .bool(true), "screenshot clipboard should parse")
        let pdfScreenshot = try CLIParser().parse([
            "screenshot", "--format", "pdf", "--full-page", "--output", "page.pdf",
        ])
        try expect(pdfScreenshot.request?.parameters["fullPage"] == .bool(true), "PDF should parse in full-page mode")
        try expectThrows("viewport PDF should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "--format", "pdf", "--output", "page.pdf"])
        }
        try expectThrows("element PDF should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "@e1", "--format", "pdf", "--full-page"])
        }
        let viewportSeries = try CLIParser().parse([
            "screenshot", "--every-viewport", "--format", "jpg", "--output", "dashboard-scroll",
        ])
        try expect(viewportSeries.request?.command == .screenshot, "viewport screenshot series should parse")
        try expect(viewportSeries.request?.parameters["series"] == .string("viewport"), "viewport series should parse")
        try expect(viewportSeries.request?.parameters["format"] == .string("jpeg"), "viewport series format should parse")
        try expect(viewportSeries.request?.parameters["outputPrefix"] == .string("dashboard-scroll"), "series prefix should parse")
        let sectionSeries = try CLIParser().parse([
            "screenshot", "--by-section", "--output", "dashboard-sections.jpeg",
        ])
        try expect(sectionSeries.request?.parameters["series"] == .string("section"), "section series should parse")
        try expect(sectionSeries.request?.parameters["outputPrefix"] == .string("dashboard-sections"), "series prefix should strip image extension")
        try expectThrows("series screenshot must reject element targets") {
            _ = try CLIParser().parse(["screenshot", "--every-viewport", "@e1"])
        }
        try expectThrows("series screenshot must reject full-page mode") {
            _ = try CLIParser().parse(["screenshot", "--by-section", "--full-page"])
        }
        try expectThrows("series screenshot must reject PDF") {
            _ = try CLIParser().parse(["screenshot", "--by-section", "--format", "pdf"])
        }
        try expectThrows("series screenshot must reject clipboard") {
            _ = try CLIParser().parse(["screenshot", "--every-viewport", "--clipboard"])
        }
        let record = try CLIParser().parse([
            "record", "start", "--fps", "8", "--format", "webm", "--quality", "high", "--output", "flow.webm",
        ])
        try expect(record.request?.command == .recordStart, "record start should parse")
        try expect(record.request?.parameters["fps"] == .number(8), "record FPS should parse")
        try expect(record.request?.parameters["format"] == .string("webm"), "recording format should parse")
        try expect(record.request?.parameters["quality"] == .string("high"), "recording quality should parse")
        try expectThrows("unsupported recorder selectors should fail instead of being ignored") {
            _ = try CLIParser().parse(["record", "start", "--provider", "browser"])
        }
        try expectThrows("recording output mismatch should fail") {
            _ = try CLIParser().parse(["record", "start", "--format", "mov", "--output", "flow.mp4"])
        }
        try expectThrows("record requests should reject obsolete provider fields") {
            try CommandRequest(command: .recordStart, parameters: ["provider": .string("browser")]).validate()
        }
        try expectThrows("artifact path traversal should fail in the CLI") {
            _ = try CLIParser().parse(["screenshot", "--output", "../escape.png"])
        }
    }

    static func cliP2CommandsAndBoundaries() throws {
        let visual = try CLIParser().parse(["visual", "compare", "before.png", "after.png", "--output", "diff.png"])
        try expect(visual.request?.command == .visualCompare, "visual compare should parse")
        // Both hosts read these two names to locate the artifacts to diff. They
        // guard the lookup and answer MISSING_PARAMETER, but the validator is
        // what keeps a malformed request from reaching that path at all — if it
        // ever stopped requiring them, the guards would be the only thing
        // standing between a crafted request and a broken comparison.
        for missing in ["before", "after"] {
            try expectThrows("visual compare should require \(missing)") {
                var parameters: [String: JSONValue] = [
                    "before": .string("one.png"), "after": .string("two.png"),
                ]
                parameters.removeValue(forKey: missing)
                try CommandRequest(
                    id: "visual-compare-missing-\(missing)", command: .visualCompare,
                    parameters: parameters
                ).validate()
            }
        }
        try expect(visual.request?.parameters["before"] == .string("before.png"), "visual input should remain an artifact name")
        let flow = try CLIParser().parse(["flow", "run", "happy-path.json"])
        try expect(flow.request?.command == .flowRun, "flow run should parse")
        let mock = try CLIParser().parse(["network", "mock", "set", "localhost:3000/api", "--body", "{}", "--status", "201"])
        try expect(mock.request?.command == .networkMockSet, "network mock should parse")
        try expectThrows("visual compare must reject traversal") {
            _ = try CLIParser().parse(["visual", "compare", "../before.png", "after.png"])
        }
        try expectThrows("network mock body must remain bounded") {
            try CommandRequest(command: .networkMockSet, parameters: [
                "url": .string("https://example.com/api"), "body": .string(String(repeating: "x", count: 65_537)),
            ]).validate()
        }
        try expectThrows("network mock content type must not contain header control characters") {
            try CommandRequest(command: .networkMockSet, parameters: [
                "url": .string("https://example.com/api"), "body": .string("{}"),
                "contentType": .string("application/json\r\nX-Injected: yes"),
            ]).validate()
        }
    }

    static func cliCommandMatrix() throws {
        let remoteCommands: [([String], CommandName)] = [
            (["status"], .ping),
            (["stop"], .shutdown),
            (["profile", "clear"], .profileClear),
            (["session", "create", "qa"], .sessionCreate),
            (["session", "list"], .sessionList),
            (["session", "close", "qa"], .sessionClose),
            (["back"], .back),
            (["reload"], .reload),
            (["tour", "--pace", "750"], .tour),
            (["capture-info"], .captureInfo),
            (["artifacts", "list"], .artifactList),
            (["upload", "@e12", "--artifact", "resume.pdf"], .upload),
            (["qa", "report"], .qaReport),
            (["qa", "clear"], .qaClear),
            (["performance", "get"], .performanceGet),
            (["animations", "list"], .animationList),
            (["report", "create", "--output", "report.json"], .reportCreate),
            (["flow", "start"], .flowStart),
            (["flow", "stop", "--output", "flow.json"], .flowStop),
            (["network", "emulate", "--offline", "--latency", "100"], .networkEmulate),
            (["network", "mock", "clear"], .networkMockClear),
        ]
        for (arguments, command) in remoteCommands {
            let invocation = try CLIParser().parse(arguments)
            try expect(
                invocation.request?.command == command,
                "\(arguments.joined(separator: " ")) should parse as \(command.rawValue)"
            )
        }

        let localCommands: [([String], LocalCommand)] = [
            (["start"], .start(
                presentation: nil, allowlist: .unrestricted, supervised: false
            )),
            (["start", "--background"], .start(
                presentation: .background, allowlist: .unrestricted, supervised: false
            )),
            (["start", "--foreground"], .start(
                presentation: .foreground, allowlist: .unrestricted, supervised: false
            )),
            (["start", "--supervised"], .start(
                presentation: nil, allowlist: .unrestricted, supervised: true
            )),
            (["start", "--allow", "localhost"], .start(
                presentation: nil, allowlist: try NavigationAllowlist.parse(["localhost"]),
                supervised: false
            )),
            (
                ["start", "--allow", "localhost", "--allow", "127.0.0.1", "--background"],
                .start(
                    presentation: .background,
                    allowlist: try NavigationAllowlist.parse(["localhost", "127.0.0.1"]),
                    supervised: false
                )
            ),
            (["config", "get", "startup-presentation"], .config(.get("startup-presentation"))),
            (["config", "set", "startup-presentation", "background"], .config(.set(
                key: "startup-presentation", value: "background"
            ))),
            (["config", "set", "startup-presentation", "foreground"], .config(.set(
                key: "startup-presentation", value: "foreground"
            ))),
            (["credentials", "list"], .credentials(.list(origin: nil))),
            (["credentials", "list", "--origin", "https://example.com"], .credentials(.list(
                origin: try CredentialOrigin(rawValue: "https://example.com")
            ))),
            (["help"], .help),
            (["--help"], .help),
            (["version"], .version),
            (["--version"], .version),
            (["-V"], .version),
        ]
        for (arguments, command) in localCommands {
            let invocation = try CLIParser().parse(arguments)
            try expect(
                invocation.local == command && invocation.request == nil,
                "\(arguments.joined(separator: " ")) should stay local"
            )
        }
        try expectThrows("start presentation flags must be exclusive") {
            _ = try CLIParser().parse(["start", "--foreground", "--background"])
        }
        try expectThrows("start should reject unknown options") {
            _ = try CLIParser().parse(["start", "--front"])
        }
        try expectThrows("credential commands must reject browser sessions") {
            _ = try CLIParser().parse(["--session", "qa", "credentials", "list"])
        }

        let sessionCreate = try CLIParser().parse(["session", "create", "qa"])
        try expect(sessionCreate.request?.parameters["name"] == .string("qa"), "session create name should parse")
        try expect(
            sessionCreate.request?.parameters["isolated"] == nil,
            "normal session creation should remain compatible with older hosts"
        )
        let isolatedSession = try CLIParser().parse(["session", "create", "private", "--isolated"])
        try expect(
            isolatedSession.request?.parameters["isolated"] == .bool(true),
            "isolated session flag should parse"
        )
        try expectThrows("duplicate isolated flags should be rejected") {
            _ = try CLIParser().parse(["session", "create", "private", "--isolated", "--isolated"])
        }
        let sessionClose = try CLIParser().parse(["session", "close", "qa"])
        try expect(sessionClose.request?.session == "qa", "session close target should parse")
        let tour = try CLIParser().parse(["tour", "--pace", "750"])
        try expect(tour.request?.parameters["pace"] == .number(750), "tour pace should parse")
        let emulation = try CLIParser().parse([
            "network", "emulate", "--offline", "--latency", "100",
            "--download-kbps", "2000", "--upload-kbps", "500",
        ])
        try expect(emulation.request?.parameters["offline"] == .bool(true), "offline emulation should parse")
        try expect(emulation.request?.parameters["latencyMs"] == .number(100), "emulation latency should parse")
        try expectThrows("unknown trailing arguments should not be ignored") {
            _ = try CLIParser().parse(["performance", "get", "extra"])
        }
    }

    static func configCLICommandsAndArity() throws {
        let commands: [([String], ConfigCLICommand)] = [
            (["config", "list"], .list),
            (["config", "describe", "startup-presentation"], .describe("startup-presentation")),
            (["config", "get", "startup-presentation"], .get("startup-presentation")),
            (["config", "set", "startup-presentation", "foreground"], .set(
                key: "startup-presentation", value: "foreground"
            )),
            (["config", "reset", "startup-presentation"], .reset("startup-presentation")),
        ]
        for (arguments, command) in commands {
            let invocation = try CLIParser().parse(arguments)
            try expect(
                invocation.local == .config(command) && invocation.request == nil,
                "\(arguments.joined(separator: " ")) should remain local"
            )
            try expect(invocation.jsonOutput, "config commands should always produce JSON")

            var withSession = arguments
            withSession.insert(contentsOf: ["--session", "qa"], at: 0)
            try expectThrows("\(arguments[1]) should reject browser sessions") {
                _ = try CLIParser().parse(withSession)
            }
        }

        let invalidCommands = [
            ["config"],
            ["config", "list", "extra"],
            ["config", "describe"],
            ["config", "describe", "startup-presentation", "extra"],
            ["config", "get"],
            ["config", "get", "startup-presentation", "extra"],
            ["config", "set"],
            ["config", "set", "startup-presentation"],
            ["config", "set", "startup-presentation", "foreground", "extra"],
            ["config", "reset"],
            ["config", "reset", "startup-presentation", "extra"],
            ["config", "unknown"],
        ]
        for arguments in invalidCommands {
            try expectThrows("config should reject invalid arity: \(arguments.joined(separator: " "))") {
                _ = try CLIParser().parse(arguments)
            }
        }
        try expectThrows("a literal session option must not bypass config arity validation") {
            _ = try CLIParser().parse(["config", "list", "--", "--session", "qa"])
        }
    }

    static func settingsRegistryAndAccess() throws {
        let platforms: Set<SettingPlatform> = [.macOS, .linux]
        let definitions = [
            SettingDefinition(
                key: "z-string", valueType: .string(maximumLength: 8), defaultValue: "value",
                platforms: platforms, restartBehavior: .immediate, access: .agentWritable,
                summary: "Bounded string"
            ),
            SettingDefinition(
                key: "a-boolean", valueType: .boolean, defaultValue: "false",
                platforms: platforms, restartBehavior: .immediate, access: .agentWritable,
                summary: "Boolean"
            ),
            SettingDefinition(
                key: "m-integer", valueType: .integer(1...3), defaultValue: "2",
                platforms: platforms, restartBehavior: .nextHostStart, access: .agentReadable,
                summary: "Bounded integer"
            ),
            SettingDefinition(
                key: "n-enum", valueType: .enumeration(["first", "second"]), defaultValue: "first",
                platforms: platforms, restartBehavior: .immediate, access: .agentWritable,
                summary: "Enumeration"
            ),
            SettingDefinition(
                key: "private-policy", valueType: .boolean, defaultValue: "false",
                platforms: platforms, restartBehavior: .immediate, access: .userOnly,
                summary: "User-only policy"
            ),
        ]
        let registry = SettingsRegistry(definitions: definitions)
        try expect(
            registry.definitions.map(\.key) == [
                "a-boolean", "m-integer", "n-enum", "private-policy", "z-string",
            ],
            "registry definitions should have deterministic key order"
        )
        try expect(registry.helpLines.count == 4, "agent help should omit user-only definitions")
        try expect(registry.helpLines[0].contains("boolean"), "boolean metadata should reach generated help")
        try expect(registry.helpLines[1].contains("integer"), "integer metadata should reach generated help")
        try expect(registry.helpLines[2].contains("first|second"), "enum values should reach generated help")
        try expect(registry.helpLines[3].contains("string"), "string metadata should reach generated help")
        try expect(
            !registry.helpLines.joined(separator: "\n").contains("private-policy"),
            "user-only keys must not leak through generated agent help"
        )

        let backend = TestSettingsBackend()
        let settings = SettingsStore(registry: registry, platform: .macOS, backend: backend)
        let agentList = try settingsObject(try settings.list(), "settings list should be an object")
        let agentEntries = try settingsArray(agentList["settings"], "settings list should contain an array")
        let encodedAgentList = String(
            decoding: try ProtocolCodec.encoder.encode(JSONValue.array(agentEntries)), as: UTF8.self
        )
        try expect(agentEntries.count == 4, "agent listing should omit user-only settings")
        try expect(!encodedAgentList.contains("private-policy"), "user-only keys must not leak through list")
        try expectSettingsError(.unknownKey("private-policy"), "user-only describe should be indistinguishable from unknown") {
            _ = try settings.describe("private-policy", caller: .agent)
        }
        try expectSettingsError(.unknownKey("private-policy"), "user-only get should be indistinguishable from unknown") {
            _ = try settings.get("private-policy", caller: .agent)
        }
        try expectSettingsError(.unknownKey("private-policy"), "user-only set should be indistinguishable from unknown") {
            _ = try settings.set("private-policy", rawValue: "true", caller: .agent)
        }
        try expectSettingsError(.unknownKey("private-policy"), "user-only reset should be indistinguishable from unknown") {
            _ = try settings.reset("private-policy", caller: .agent)
        }
        try expectSettingsError(.accessDenied("m-integer"), "agent-readable settings must reject writes") {
            _ = try settings.set("m-integer", rawValue: "3", caller: .agent)
        }
        try expectSettingsError(.accessDenied("m-integer"), "agent-readable settings must reject reset") {
            _ = try settings.reset("m-integer", caller: .agent)
        }

        let userList = try settingsObject(try settings.list(caller: .user), "user settings list should be an object")
        try expect(
            try settingsArray(userList["settings"], "user settings list should contain an array").count == 5,
            "user callers should see user-only settings"
        )
        _ = try settings.set("private-policy", rawValue: "true", caller: .user)
        try expect(try settings.effectiveRawValue("private-policy", caller: .user) == "true", "user callers should mutate user-only settings")

        _ = try settings.set("a-boolean", rawValue: "true")
        _ = try settings.set("n-enum", rawValue: "second")
        _ = try settings.set("z-string", rawValue: "12345678")
        try expectSettingsError(.invalidValue("TRUE"), "boolean values should be strict") {
            _ = try settings.set("a-boolean", rawValue: "TRUE")
        }
        try expectSettingsError(.invalidValue("4"), "integers should remain bounded") {
            _ = try settings.set("m-integer", rawValue: "4", caller: .user)
        }
        try expectSettingsError(.invalidValue("third"), "enums should reject unknown values") {
            _ = try settings.set("n-enum", rawValue: "third")
        }
        try expectSettingsError(.invalidValue("123456789"), "strings should remain bounded") {
            _ = try settings.set("z-string", rawValue: "123456789")
        }

        let startupBackend = TestSettingsBackend()
        let macSettings = SettingsStore(platform: .macOS, backend: startupBackend)
        let listed = try settingsObject(try macSettings.list(), "startup list should be an object")
        let startupEntries = try settingsArray(listed["settings"], "startup list should contain settings")
        try expect(startupEntries.count == 1, "shared registry should expose one setting")
        let defaultEntry = try settingsObject(startupEntries[0], "startup entry should be an object")
        try expect(defaultEntry["startupPresentation"] == .string("background"), "list should preserve startupPresentation")
        try expect(defaultEntry["builtInDefault"] == .string("background"), "list should preserve builtInDefault")
        try expect(defaultEntry["configured"] == .null, "list should distinguish the built-in default")
        try expect(defaultEntry["supportedOnCurrentPlatform"] == .bool(true), "list should report platform support")

        let described = try settingsObject(try macSettings.describe("startup-presentation"), "describe should be an object")
        try expect(described["summary"] != nil, "describe should include the setting summary")
        try expect(described["restartBehavior"] == .string("next-host-start"), "describe should expose restart behavior")
        let initial = try settingsObject(try macSettings.get("startup-presentation"), "get should be an object")
        try expect(initial["value"] == .string("background"), "get should return the default")
        let changed = try settingsObject(
            try macSettings.set("startup-presentation", rawValue: "foreground"), "set should be an object"
        )
        try expect(changed["startupPresentation"] == .string("foreground"), "set should preserve startupPresentation")
        try expect(changed["configured"] == .bool(true), "set should report configured state")
        try expect(changed["takesEffect"] == .string("next-host-start"), "set should preserve takesEffect")
        let configured = try settingsObject(try macSettings.get("startup-presentation"), "configured get should be an object")
        try expect(configured["configured"] == .string("foreground"), "get should return the configured value")
        let reset = try settingsObject(try macSettings.reset("startup-presentation"), "reset should be an object")
        try expect(reset["startupPresentation"] == .string("background"), "reset should restore the default")
        try expect(reset["configured"] == .bool(false), "reset should report an unconfigured value")

        let linuxSettings = SettingsStore(platform: .linux, backend: TestSettingsBackend())
        let linuxDescription = try settingsObject(
            try linuxSettings.describe("startup-presentation"), "unsupported describe should remain discoverable"
        )
        try expect(linuxDescription["supportedOnCurrentPlatform"] == .bool(false), "describe should report unsupported settings")
        for operation in [
            { _ = try linuxSettings.get("startup-presentation") },
            { _ = try linuxSettings.set("startup-presentation", rawValue: "foreground") },
            { _ = try linuxSettings.reset("startup-presentation") },
        ] {
            try expectSettingsError(
                .unsupportedPlatform("startup-presentation"),
                "known settings should fail explicitly on unsupported platforms", operation
            )
        }
    }

    static func userDefaultsSettingsCompatibility() throws {
        let suite = "com.headless.tests.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw TestFailure(description: "isolated UserDefaults suite should be available")
        }
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            _ = defaults.synchronize()
        }
        defaults.set("foreground", forKey: "AgentStartupPresentation")
        defaults.set("preserve-me", forKey: "LastURL")
        try expect(defaults.synchronize(), "legacy defaults should synchronize")

        let backend = try UserDefaultsSettingsBackend(suiteName: suite)
        let settings = SettingsStore(platform: .macOS, backend: backend)
        try expect(
            try settings.effectiveRawValue("startup-presentation") == "foreground",
            "the physical legacy key should remain the canonical source"
        )
        _ = try settings.set("startup-presentation", rawValue: "background")
        try expect(
            defaults.string(forKey: "AgentStartupPresentation") == "background",
            "set should update the existing physical key"
        )
        try expect(defaults.object(forKey: "HeadlessSetting.startup-presentation") == nil, "set should not create a shadow key")
        _ = try settings.reset("startup-presentation")
        try expect(defaults.object(forKey: "AgentStartupPresentation") == nil, "reset should remove the physical key")
        try expect(defaults.string(forKey: "LastURL") == "preserve-me", "reset should preserve unrelated defaults")
        try expect(
            try settings.effectiveRawValue("startup-presentation") == "background",
            "reset should not resurrect the legacy value"
        )
    }

    static func fileSettingsBackendSecurityAndPersistence() throws {
        func privateRoot(_ label: String) -> URL {
            URL(fileURLWithPath: "/tmp/headless-settings-\(label)-\(UUID().uuidString)")
        }
        func writeRaw(_ text: String, root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try expect(chmod(root.path, 0o700) == 0, "test root should be private")
            let file = root.appendingPathComponent("settings.json")
            try Data(text.utf8).write(to: file)
            try expect(chmod(file.path, 0o600) == 0, "test settings file should be private")
        }
        func expectCorrupt(_ label: String, contents: String) throws {
            let root = privateRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            try writeRaw(contents, root: root)
            let backend = try FileSettingsBackend(rootURL: root)
            let settings = SettingsStore(platform: .macOS, backend: backend)
            try expectSettingsError(.corruptStorage, "\(label) storage should fail closed") {
                _ = try settings.get("startup-presentation")
            }
        }

        let xdgRoot = privateRoot("xdg")
        defer { try? FileManager.default.removeItem(at: xdgRoot) }
        let xdgBackend = try FileSettingsBackend(environment: ["XDG_CONFIG_HOME": xdgRoot.path])
        try expect(
            xdgBackend.rootURL == xdgRoot.appendingPathComponent("headless", isDirectory: true),
            "an absolute XDG config home should select the Headless settings directory"
        )
        try expectSettingsError(.insecureStorage, "relative XDG config homes should fail closed") {
            _ = try FileSettingsBackend(environment: ["XDG_CONFIG_HOME": "relative/config"])
        }

        let root = privateRoot("persistence")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SettingsStore(
            platform: .macOS, backend: try FileSettingsBackend(rootURL: root)
        )
        _ = try first.set("startup-presentation", rawValue: "foreground")
        let second = SettingsStore(
            platform: .macOS, backend: try FileSettingsBackend(rootURL: root)
        )
        try expect(try second.effectiveRawValue("startup-presentation") == "foreground", "settings should persist across backend instances")
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("settings.json").path
        )[.posixPermissions] as? NSNumber
        try expect(rootMode?.intValue == 0o700, "settings directory should be mode 0700")
        try expect(fileMode?.intValue == 0o600, "settings file should be mode 0600")
        _ = try second.reset("startup-presentation")
        let third = SettingsStore(platform: .macOS, backend: try FileSettingsBackend(rootURL: root))
        try expect(try third.effectiveRawValue("startup-presentation") == "background", "reset should persist the default state")

        try expectCorrupt("malformed", contents: "not-json")
        try expectCorrupt("unknown-key", contents: #"{"schemaVersion":1,"values":{"unknown":"value"}}"#)
        try expectCorrupt(
            "invalid-value", contents: #"{"schemaVersion":1,"values":{"startup-presentation":"automatic"}}"#
        )
        try expectCorrupt(
            "unknown-schema", contents: #"{"schemaVersion":2,"values":{"startup-presentation":"foreground"}}"#
        )
        try expectCorrupt(
            "duplicate-key",
            contents: #"{"schemaVersion":1,"values":{"startup-presentation":"background","startup-presentation":"foreground"}}"#
        )

        let oversizedRoot = privateRoot("oversized")
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        try writeRaw(String(repeating: "x", count: FileSettingsBackend.maximumFileBytes + 1), root: oversizedRoot)
        let oversized = SettingsStore(platform: .macOS, backend: try FileSettingsBackend(rootURL: oversizedRoot))
        try expectSettingsError(.corruptStorage, "oversized storage should fail closed") {
            _ = try oversized.get("startup-presentation")
        }

        let linkedRoot = privateRoot("symlink-root")
        let realRoot = privateRoot("symlink-target")
        defer {
            try? FileManager.default.removeItem(at: linkedRoot)
            try? FileManager.default.removeItem(at: realRoot)
        }
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try expect(chmod(realRoot.path, 0o700) == 0, "symlink target should be private")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let rootSymlink = SettingsStore(platform: .macOS, backend: try FileSettingsBackend(rootURL: linkedRoot))
        try expectSettingsError(.insecureStorage, "symlinked settings roots should be rejected") {
            _ = try rootSymlink.get("startup-presentation")
        }

        let fileLinkRoot = privateRoot("symlink-file")
        let linkTarget = privateRoot("file-target")
        defer {
            try? FileManager.default.removeItem(at: fileLinkRoot)
            try? FileManager.default.removeItem(at: linkTarget)
        }
        let linkInitializer = SettingsStore(platform: .macOS, backend: try FileSettingsBackend(rootURL: fileLinkRoot))
        _ = try linkInitializer.set("startup-presentation", rawValue: "foreground")
        try FileManager.default.removeItem(at: fileLinkRoot.appendingPathComponent("settings.json"))
        try Data(#"{"schemaVersion":1,"values":{}}"#.utf8).write(to: linkTarget)
        try expect(chmod(linkTarget.path, 0o600) == 0, "symlink target file should be private")
        try FileManager.default.createSymbolicLink(
            at: fileLinkRoot.appendingPathComponent("settings.json"), withDestinationURL: linkTarget
        )
        try expectSettingsError(.insecureStorage, "symlinked settings files should be rejected") {
            _ = try linkInitializer.get("startup-presentation")
        }

        let hardLinkRoot = privateRoot("hardlink")
        let secondLink = privateRoot("hardlink-copy")
        defer {
            try? FileManager.default.removeItem(at: hardLinkRoot)
            try? FileManager.default.removeItem(at: secondLink)
        }
        let hardLinkSettings = SettingsStore(platform: .macOS, backend: try FileSettingsBackend(rootURL: hardLinkRoot))
        _ = try hardLinkSettings.set("startup-presentation", rawValue: "foreground")
        try FileManager.default.linkItem(
            at: hardLinkRoot.appendingPathComponent("settings.json"), to: secondLink
        )
        try expectSettingsError(.insecureStorage, "multiply-linked settings files should be rejected") {
            _ = try hardLinkSettings.get("startup-presentation")
        }

        let permissiveRoot = privateRoot("permissive-root")
        defer { try? FileManager.default.removeItem(at: permissiveRoot) }
        try writeRaw(#"{"schemaVersion":1,"values":{}}"#, root: permissiveRoot)
        try expect(chmod(permissiveRoot.path, 0o755) == 0, "test root should become permissive")
        let permissiveRootSettings = SettingsStore(
            platform: .macOS, backend: try FileSettingsBackend(rootURL: permissiveRoot)
        )
        try expectSettingsError(.insecureStorage, "permissive settings roots should be rejected") {
            _ = try permissiveRootSettings.get("startup-presentation")
        }

        let permissiveFileRoot = privateRoot("permissive-file")
        defer { try? FileManager.default.removeItem(at: permissiveFileRoot) }
        try writeRaw(#"{"schemaVersion":1,"values":{}}"#, root: permissiveFileRoot)
        try expect(
            chmod(permissiveFileRoot.appendingPathComponent("settings.json").path, 0o644) == 0,
            "test file should become permissive"
        )
        let permissiveFileSettings = SettingsStore(
            platform: .macOS, backend: try FileSettingsBackend(rootURL: permissiveFileRoot)
        )
        try expectSettingsError(.insecureStorage, "permissive settings files should be rejected") {
            _ = try permissiveFileSettings.get("startup-presentation")
        }
    }

    static func fileSettingsBackendConcurrentWriters() throws {
        let root = URL(fileURLWithPath: "/tmp/headless-settings-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = (0..<12).map { index in
            SettingDefinition(
                key: String(format: "writer-%02d", index), valueType: .integer(0...100),
                defaultValue: "0", platforms: [.macOS, .linux], restartBehavior: .immediate,
                access: .agentWritable, summary: "Concurrent writer"
            )
        }
        let registry = SettingsRegistry(definitions: definitions)
        let errors = ConcurrentSettingsErrors()
        DispatchQueue.concurrentPerform(iterations: definitions.count) { index in
            do {
                let backend = try FileSettingsBackend(rootURL: root, registry: registry)
                let settings = SettingsStore(registry: registry, platform: .macOS, backend: backend)
                _ = try settings.set(definitions[index].key, rawValue: String(index + 1))
            } catch {
                errors.append(error)
            }
        }
        try expect(
            errors.messages.isEmpty,
            "concurrent writers should all complete: \(errors.messages.joined(separator: ", "))"
        )
        let reader = SettingsStore(
            registry: registry, platform: .macOS,
            backend: try FileSettingsBackend(rootURL: root, registry: registry)
        )
        for (index, definition) in definitions.enumerated() {
            try expect(
                try reader.effectiveRawValue(definition.key) == String(index + 1),
                "concurrent writes should not lose \(definition.key)"
            )
        }
    }

    static func credentialCommandSecurity() throws {
        try expect(
            try CredentialOrigin(rawValue: "HTTPS://EXAMPLE.COM:443/").rawValue == "https://example.com",
            "credential origins should be canonical"
        )
        try expect(
            try CredentialOrigin(rawValue: "localhost:4173").rawValue == "http://localhost:4173",
            "localhost credentials should use the documented development exception"
        )
        for unsafe in [
            "http://example.com", "http://0.0.0.0:4173", "https://user:pass@example.com",
            "https://example.com/login", "https://example.com?next=login", "https://example.com/#login",
            "https://éxample.com",
        ] {
            try expectThrows("unsafe credential origin should fail without echoing input") {
                _ = try CredentialOrigin(rawValue: unsafe)
            }
        }
        for unsafe in [".hidden", "work account", "wørk", "alias/../../secret", String(repeating: "a", count: 65)] {
            try expectThrows("unsafe credential alias should fail") {
                _ = try CredentialAlias(rawValue: unsafe)
            }
        }

        let invocation = try CLIParser().parse([
            "credentials", "add", "--origin", "https://example.com", "--alias", "work", "--interactive",
        ])
        guard case .credentials(let command)? = invocation.local else {
            throw TestFailure(description: "credential add should remain a local command")
        }
        let brokerArguments = command.brokerArguments.joined(separator: " ")
        try expect(!brokerArguments.lowercased().contains("password"), "broker argv must not carry passwords")
        try expectThrows("credential add must require interactive input") {
            _ = try CLIParser().parse([
                "credentials", "add", "--origin", "https://example.com", "--alias", "work",
            ])
        }
        do {
            _ = try CLIParser().parse([
                "credentials", "add", "--origin", "https://example.com", "--alias", "work",
                "--interactive", "synthetic-secret-that-must-not-echo",
            ])
            throw TestFailure(description: "credential positional secret should be rejected")
        } catch let error as CredentialCommandError {
            try expect(
                !error.description.contains("synthetic-secret-that-must-not-echo"),
                "credential parse errors must redact rejected values"
            )
        }
    }

    static func credentialVaultLifecycle() throws {
        let root = URL(fileURLWithPath: "/tmp/headless-credential-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try CredentialOrigin(rawValue: "https://example.com")
        let work = try CredentialAlias(rawValue: "work")
        let store = TestCredentialSecretStore()
        let metadata = CredentialMetadataStore(rootURL: root)
        let controller = CredentialVaultController(
            metadata: metadata, secrets: store,
            prompt: TestCredentialPrompt(account: "person@example.com", passwords: ["synthetic-secret", "synthetic-secret"])
        )

        let added = try controller.add(origin: origin, alias: work)
        let encoded = String(decoding: try ProtocolCodec.encoder.encode(added), as: UTF8.self)
        try expect(!encoded.contains("synthetic-secret"), "vault output must not contain password bytes")
        try expect(store.storedSecretBytes == Array("synthetic-secret".utf8), "fake vault should receive exact secret bytes")
        let listing = String(decoding: try ProtocolCodec.encoder.encode(controller.list(origin: origin)), as: UTF8.self)
        try expect(listing.contains("person@example.com"), "listing should expose approved username metadata")
        try expect(!listing.contains("synthetic-secret"), "listing must never contain passwords")

        let duplicate = CredentialVaultController(
            metadata: metadata, secrets: store,
            prompt: TestCredentialPrompt(account: "other@example.com", passwords: ["different", "different"])
        )
        do {
            _ = try duplicate.add(origin: origin, alias: try CredentialAlias(rawValue: "WORK"))
            throw TestFailure(description: "case-insensitive duplicate alias should fail")
        } catch CredentialVaultError.duplicateAlias {}

        let personal = try CredentialAlias(rawValue: "personal")
        _ = try controller.rename(origin: origin, alias: work, to: personal)
        let renamedListing = String(
            decoding: try ProtocolCodec.encoder.encode(controller.list(origin: origin)), as: UTF8.self
        )
        try expect(renamedListing.contains("personal"), "rename should update private index metadata")
        store.removeError = .vaultLocked
        do {
            _ = try controller.remove(origin: origin, alias: personal)
            throw TestFailure(description: "locked secure-store removal should fail")
        } catch CredentialVaultError.vaultLocked {}
        let afterRollback = String(decoding: try ProtocolCodec.encoder.encode(controller.list(origin: origin)), as: UTF8.self)
        try expect(afterRollback.contains("personal"), "failed removal should restore index metadata")
        store.removeError = nil
        _ = try controller.remove(origin: origin, alias: personal)
        let empty = String(decoding: try ProtocolCodec.encoder.encode(controller.list(origin: origin)), as: UTF8.self)
        try expect(empty.contains("\"total\":0"), "removed credential should leave no active metadata")

        let index = root.appendingPathComponent("credentials-index.json")
        try Data("not-json".utf8).write(to: index)
        _ = chmod(index.path, 0o600)
        try expectThrows("corrupt credential metadata should fail closed") {
            _ = try controller.list(origin: nil)
        }
    }

    static func credentialVaultRejectsMismatchedConfirmation() throws {
        let root = URL(fileURLWithPath: "/tmp/headless-credential-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestCredentialSecretStore()
        let controller = CredentialVaultController(
            metadata: CredentialMetadataStore(rootURL: root), secrets: store,
            prompt: TestCredentialPrompt(account: "person@example.com", passwords: ["first", "second"])
        )
        try expectThrows("mismatched password confirmation should fail") {
            _ = try controller.add(
                origin: try CredentialOrigin(rawValue: "https://example.com"),
                alias: try CredentialAlias(rawValue: "work")
            )
        }
        try expect(store.records.isEmpty, "mismatched confirmation must not reach the secure store")
    }

    static func credentialVaultRollsBackFailedMetadataCommit() throws {
        let root = URL(fileURLWithPath: "/tmp/headless-credential-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TestCredentialSecretStore()
        store.afterStore = { _ in
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("credentials-index.json")
            )
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("credentials-index.json"),
                withIntermediateDirectories: false
            )
        }
        let controller = CredentialVaultController(
            metadata: CredentialMetadataStore(rootURL: root), secrets: store,
            prompt: TestCredentialPrompt(account: "person@example.com", passwords: ["first", "first"])
        )
        try expectThrows("failed metadata commit should reject credential enrollment") {
            _ = try controller.add(
                origin: try CredentialOrigin(rawValue: "https://example.com"),
                alias: try CredentialAlias(rawValue: "work")
            )
        }
        try expect(store.records.isEmpty, "failed metadata commit must remove the new secure-store item")
    }

    static func credentialVaultRecoversInterruptedTransactions() throws {
        for kind in [CredentialTransactionKind.add, .remove] {
            let root = URL(
                fileURLWithPath: "/tmp/headless-credential-recovery-\(kind.rawValue)-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let record = try CredentialRecord(
                origin: CredentialOrigin(rawValue: "https://example.com"),
                alias: CredentialAlias(rawValue: "work"),
                account: "person@example.com"
            )
            let metadata = CredentialMetadataStore(rootURL: root)
            try metadata.withLockedState { transaction in
                transaction.state.pending = [CredentialPendingTransaction(kind: kind, record: record)]
                try transaction.save()
            }
            let store = TestCredentialSecretStore()
            store.records[record.id] = record
            let controller = CredentialVaultController(
                metadata: metadata, secrets: store,
                prompt: TestCredentialPrompt(account: "unused", passwords: [])
            )

            _ = try controller.list(origin: nil)
            try expect(store.records.isEmpty, "interrupted \(kind.rawValue) should remove the vault item")
            try metadata.withLockedState { transaction in
                try expect(
                    transaction.state.pending.isEmpty,
                    "interrupted \(kind.rawValue) journal should be cleared"
                )
            }
        }
    }

    static func chromiumRuntimeSelection() throws {
        let runtimeInvocation = try CLIParser().parse(["runtime"])
        try expect(runtimeInvocation.local == .runtime, "runtime diagnostics command should parse")

        let root = "/tmp/headless-runtime-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bundled = root + "/lib/headless/chromium/chromium"
        let system = root + "/system/chromium"
        let overrideLink = root + "/override-chromium"
        let snapWrapper = root + "/chromium-browser"
        try FileManager.default.createDirectory(
            atPath: (bundled as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: (system as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("bundled".utf8).write(to: URL(fileURLWithPath: bundled))
        try Data("system".utf8).write(to: URL(fileURLWithPath: system))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system)
        try FileManager.default.createSymbolicLink(atPath: overrideLink, withDestinationPath: system)
        try Data("#!/bin/sh\nexec /snap/bin/chromium \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: snapWrapper))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapWrapper)

        let bundledSelection = try ChromiumRuntimeResolver(
            environment: [:], hostExecutablePath: root + "/bin/headless-host",
            systemCandidates: [system]
        ).resolve()
        try expect(bundledSelection.source == .bundled, "bundled Chromium should be preferred")
        try expect(bundledSelection.executableURL.path == bundled, "bundled Chromium path should be selected")

        let overrideSelection = try ChromiumRuntimeResolver(
            environment: ["HEADLESS_CHROMIUM_EXECUTABLE": overrideLink],
            hostExecutablePath: root + "/bin/headless-host", systemCandidates: [bundled]
        ).resolve()
        try expect(overrideSelection.source == .override, "a valid explicit override should be authoritative")
        try expect(overrideSelection.executableURL.path == system, "override symlinks should resolve to a regular executable")

        try expectThrows("a missing override must not fall through to a supported default") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": root + "/missing"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("relative Chromium overrides should be rejected") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": "relative/chromium"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("Snap Chromium overrides should be rejected before launch") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": "/snap/bin/chromium"],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }
        try expectThrows("scripts that delegate to Snap Chromium should be rejected") {
            _ = try ChromiumRuntimeResolver(
                environment: ["HEADLESS_CHROMIUM_EXECUTABLE": snapWrapper],
                hostExecutablePath: root + "/bin/headless-host", systemCandidates: [system]
            ).resolve()
        }

        let nativeAfterSnap = try ChromiumRuntimeResolver(
            environment: [:], hostExecutablePath: root + "/unbundled/bin/headless-host",
            systemCandidates: ["/snap/bin/chromium", system]
        ).resolve()
        try expect(nativeAfterSnap.executableURL.path == system, "automatic selection should skip Snap for a native runtime")
    }

    static func artifactStoreRoundTrip() throws {
        let root = "/tmp/headless-artifact-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let artifact = try store.write(
            Data([0x89, 0x50, 0x4e, 0x47]), requestedName: "sample.png",
            extension: "png", prefix: "unused"
        )
        guard case .object(let metadata) = artifact else { throw TestFailure(description: "artifact metadata") }
        try expect(metadata["name"] == .string("sample.png"), "artifact name should be returned")
        guard case .object(let listing) = try store.list(), case .array(let artifacts)? = listing["artifacts"] else {
            throw TestFailure(description: "artifact listing")
        }
        try expect(artifacts.count == 1, "artifact listing should include the write")
        let rootMode = (try FileManager.default.attributesOfItem(atPath: root)[.posixPermissions] as? NSNumber)?.intValue
        let artifactMode = (try FileManager.default.attributesOfItem(atPath: root + "/sample.png")[.posixPermissions] as? NSNumber)?.intValue
        try expect(rootMode == 0o700, "artifact root should be private")
        try expect(artifactMode == 0o600, "artifact file should be private from creation")
        let recording = try store.reserve(
            requestedName: "recording.mp4", extension: "mp4", prefix: "unused"
        )
        let recordingMode = (try FileManager.default.attributesOfItem(atPath: recording.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(recordingMode == 0o600, "reserved recording should be private")
        _ = try store.writeReserved(Data("recording".utf8), to: recording)
        let finalized = try store.finalize(recording, renameTo: "final-recording.mp4")
        guard case .object(let finalizedMetadata) = finalized else {
            throw TestFailure(description: "finalized artifact metadata")
        }
        try expect(finalizedMetadata["name"] == .string("final-recording.mp4"), "artifact rename should return its final name")
        try expect(!FileManager.default.fileExists(atPath: recording.path), "artifact rename should remove its reserved source name")

        let collisionSource = try store.reserve(
            requestedName: "collision-source.mp4", extension: "mp4", prefix: "unused"
        )
        _ = try store.writeReserved(Data("source".utf8), to: collisionSource)
        _ = try store.write(
            Data("destination".utf8), requestedName: "collision.mp4",
            extension: "mp4", prefix: "unused"
        )
        try expectThrows("artifact finalization must never replace an existing destination") {
            _ = try store.finalize(collisionSource, renameTo: "collision.mp4")
        }
        try expect(
            try Data(contentsOf: URL(fileURLWithPath: root + "/collision.mp4")) == Data("destination".utf8),
            "artifact collision should preserve the existing destination"
        )
        try expect(FileManager.default.fileExists(atPath: collisionSource.path), "failed finalization should preserve its source")
        try expectThrows("artifact overwrite should be rejected") {
            _ = try store.write(Data(), requestedName: "sample.png", extension: "png", prefix: "unused")
        }
        let symlinkTarget = root + "-target"
        let symlinkRoot = root + "-link"
        defer {
            try? FileManager.default.removeItem(atPath: symlinkRoot)
            try? FileManager.default.removeItem(atPath: symlinkTarget)
        }
        try FileManager.default.createDirectory(atPath: symlinkTarget, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkRoot, withDestinationPath: symlinkTarget)
        try expectThrows("artifact root symlinks should be rejected") {
            _ = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": symlinkRoot])
        }
    }

    static func artifactReadsStayInsideBounds() throws {
        let root = "/tmp/headless-artifact-read-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let payload = Data("bounded artifact".utf8)
        _ = try store.write(
            payload, requestedName: "bounded.json", extension: "json", prefix: "unused"
        )
        try expect(
            try store.read(name: "bounded.json", expectedExtension: "json", maximumBytes: payload.count) == payload,
            "an exact-bound regular artifact should be readable"
        )
        try expectThrows("artifacts larger than the caller's bound should be rejected") {
            _ = try store.read(name: "bounded.json", expectedExtension: "json", maximumBytes: payload.count - 1)
        }
        try expectThrows("artifact reads should validate the expected extension") {
            _ = try store.read(name: "bounded.json", expectedExtension: "png", maximumBytes: payload.count)
        }

        let outside = root + "-outside.json"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try payload.write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/linked.json", withDestinationPath: outside
        )
        try expectThrows("artifact reads should reject symbolic links") {
            _ = try store.read(name: "linked.json", expectedExtension: "json", maximumBytes: payload.count)
        }

        try FileManager.default.createDirectory(atPath: root + "/folder.json", withIntermediateDirectories: false)
        try expectThrows("artifact reads should reject non-regular files") {
            _ = try store.read(name: "folder.json", expectedExtension: "json", maximumBytes: payload.count)
        }
    }

    static func flowRecordingOmitsSensitiveCommands() throws {
        let safeParameters: [String: JSONValue] = ["target": .string("@e1")]
        for command in replayableFlowCommands {
            let step = flowStepIfSafe(command: command, parameters: safeParameters)
            try expect(step?.command == command, "\(command.rawValue) should remain replayable")
            try expect(step?.parameters == safeParameters, "safe flow parameters should be retained")
        }

        let secret = "never-record-this-value"
        let fill = flowStepIfSafe(
            command: .fill,
            parameters: ["target": .string("@e1"), "value": .string(secret)]
        )
        try expect(fill == nil, "fill values must never become replayable flow steps")
        let uploadStep = flowStepIfSafe(
            command: .upload,
            parameters: ["target": .string("@e1"), "artifact": .string("resume.pdf")]
        )
        try expect(uploadStep?.command == .upload, "upload may be replayed by artifact basename")
        try expect(
            uploadStep?.parameters["artifact"] == .string("resume.pdf"),
            "recorded upload must keep the artifact basename"
        )
        for command in [CommandName.shutdown, .sessionClose, .cookiesList, .storageList] {
            try expect(
                flowStepIfSafe(command: command, parameters: [:]) == nil,
                "\(command.rawValue) should not be replayable"
            )
        }

        let commands = replayableFlowCommands.compactMap {
            flowStepIfSafe(command: $0, parameters: safeParameters)
        }
        let encoded = try ProtocolCodec.encoder.encode(RecordedFlow(commands: commands))
        try expect(!String(decoding: encoded, as: UTF8.self).contains(secret), "serialized flows must omit fill values")
    }

    static func visualComparisonInvokesBoundedTool() throws {
        let root = "/tmp/headless-visual-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let executable = root + "/ffmpeg"
        let script = """
        #!/bin/sh
        set -eu
        last=''
        for argument in "$@"; do last="$argument"; done
        printf '%s\n' "$@" > "$last"
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)

        let previous = ProcessInfo.processInfo.environment["HEADLESS_FFMPEG_EXECUTABLE"]
        setenv("HEADLESS_FFMPEG_EXECUTABLE", executable, 1)
        defer {
            if let previous { setenv("HEADLESS_FFMPEG_EXECUTABLE", previous, 1) }
            else { unsetenv("HEADLESS_FFMPEG_EXECUTABLE") }
        }

        let before = URL(fileURLWithPath: root + "/before.png")
        let after = URL(fileURLWithPath: root + "/after.png")
        let difference = URL(fileURLWithPath: root + "/difference.png")
        try Data([0x01]).write(to: before)
        try Data([0x02]).write(to: after)
        let result = try VisualComparison.compare(before: before, after: after, difference: difference)
        guard case .object(let metadata) = result else {
            throw TestFailure(description: "visual comparison metadata")
        }
        try expect(metadata["differenceGenerated"] == .bool(true), "visual comparison should report success")
        let arguments = try String(contentsOf: difference, encoding: .utf8)
        try expect(arguments.contains(before.path), "visual comparison should pass the before artifact")
        try expect(arguments.contains(after.path), "visual comparison should pass the after artifact")
        try expect(arguments.contains("blend=all_mode=difference"), "visual comparison should use difference blending")
        try expect(arguments.contains("-frames:v\n1"), "visual comparison should remain bounded to one output frame")

        let failingExecutable = root + "/ffmpeg-fail"
        try "#!/bin/sh\necho deliberate-failure >&2\nexit 7\n".write(
            toFile: failingExecutable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingExecutable)
        setenv("HEADLESS_FFMPEG_EXECUTABLE", failingExecutable, 1)
        try expectThrows("visual comparison should surface encoder failure") {
            _ = try VisualComparison.compare(before: before, after: after, difference: difference)
        }
    }

    static func recordingArgumentsAndFailureBounds() throws {
        let root = "/tmp/headless-recording-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let executable = root + "/ffmpeg"
        let script = """
        #!/bin/sh
        set -eu
        last=''
        for argument in "$@"; do last="$argument"; done
        printf '%s\n' "$@" > "$last.arguments"
        case "$last" in
          *exit-early*) dd bs=1 count=1 of=/dev/null 2>/dev/null; : > "$last"; exit 0 ;;
        esac
        cat >/dev/null
        : > "$last"
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)

        let nonExecutable = root + "/not-executable"
        try "not executable".write(toFile: nonExecutable, atomically: true, encoding: .utf8)
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": "relative/ffmpeg"],
                systemCandidates: []
            ) == nil,
            "relative ffmpeg overrides should be rejected"
        )
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": root], systemCandidates: []
            ) == nil,
            "ffmpeg directories should be rejected"
        )
        try expect(
            BrowserRecording.ffmpegExecutable(
                environment: ["HEADLESS_FFMPEG_EXECUTABLE": nonExecutable], systemCandidates: []
            ) == nil,
            "non-executable ffmpeg files should be rejected"
        )
        let resolved = BrowserRecording.ffmpegExecutable(
            environment: ["HEADLESS_FFMPEG_EXECUTABLE": executable], systemCandidates: []
        )
        try expect(resolved?.path == executable, "a regular absolute ffmpeg override should resolve")

        let previous = ProcessInfo.processInfo.environment["HEADLESS_FFMPEG_EXECUTABLE"]
        setenv("HEADLESS_FFMPEG_EXECUTABLE", executable, 1)
        defer {
            if let previous { setenv("HEADLESS_FFMPEG_EXECUTABLE", previous, 1) }
            else { unsetenv("HEADLESS_FFMPEG_EXECUTABLE") }
        }

        func argument(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        enum SyntheticInitialCaptureFailure: Error { case unavailable }
        var initialCaptureAttempts = 0
        do {
            _ = try BrowserRecording(
                outputURL: URL(fileURLWithPath: root + "/initial-failure.mp4"), fps: 8,
                captureFrame: {
                    initialCaptureAttempts += 1
                    throw SyntheticInitialCaptureFailure.unavailable
                }
            )
            throw TestFailure(description: "an unavailable initial frame should fail recording startup")
        } catch RecordingError.captureFailed {
            try expect(
                initialCaptureAttempts == 6,
                "recording startup should use six bounded attempts instead of polling for three seconds"
            )
        }

        let earlyExitRecording = try BrowserRecording(
            outputURL: URL(fileURLWithPath: root + "/exit-early.mp4"), fps: 4,
            captureFrame: { Data([0x01, 0x02, 0x03, 0x04]) }
        )
        let earlyExitDeadline = Date().addingTimeInterval(2)
        while Date() < earlyExitDeadline {
            guard case .object(let status) = earlyExitRecording.status(),
                  status["active"] == .bool(true) else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard case .object(let earlyExitStatus) = earlyExitRecording.status() else {
            throw TestFailure(description: "early-exit recording status")
        }
        try expect(earlyExitStatus["active"] == .bool(false), "encoder termination should update recording status")
        _ = try earlyExitRecording.stop(timeout: 2)

        for format in RecordingFormat.allCases {
            for quality in RecordingQuality.allCases {
                let output = URL(fileURLWithPath: root)
                    .appendingPathComponent("\(format.rawValue)-\(quality.rawValue).\(format.fileExtension)")
                let recording = try BrowserRecording(
                    outputURL: output, fps: 7.5, format: format, quality: quality,
                    captureFrame: { Data([0x89, 0x50, 0x4e, 0x47]) }
                )
                _ = try recording.stop(timeout: 2)
                let text = try String(contentsOfFile: output.path + ".arguments", encoding: .utf8)
                let arguments = text.split(separator: "\n").map(String.init)
                try expect(argument(after: "-f", in: arguments) == "image2pipe", "recording input should be image2pipe")
                try expect(argument(after: "-framerate", in: arguments) == "7.500", "recording FPS should retain precision")
                try expect(arguments.last == output.path, "recording output should be the final ffmpeg argument")
                switch format {
                case .mp4, .mov:
                    let expected = [RecordingQuality.fast: "6", .balanced: "4", .high: "2"][quality]
                    try expect(argument(after: "-c:v", in: arguments) == "mpeg4", "MP4/MOV should use mpeg4")
                    try expect(argument(after: "-q:v", in: arguments) == expected, "MP4/MOV quality mapping changed")
                    try expect(argument(after: "-movflags", in: arguments) == "+faststart", "MP4/MOV should remain streamable")
                case .webm:
                    let expectedCRF = [RecordingQuality.fast: "40", .balanced: "34", .high: "28"][quality]
                    let expectedDeadline = quality == .high ? "good" : "realtime"
                    try expect(argument(after: "-c:v", in: arguments) == "libvpx-vp9", "WebM should use VP9")
                    try expect(argument(after: "-crf", in: arguments) == expectedCRF, "WebM quality mapping changed")
                    try expect(argument(after: "-deadline", in: arguments) == expectedDeadline, "WebM deadline mapping changed")
                case .gif:
                    let expectedScale = [
                        RecordingQuality.fast: "scale=960:-1:flags=lanczos",
                        .balanced: "scale=1280:-1:flags=lanczos",
                        .high: "scale=-1:-1:flags=lanczos",
                    ][quality]
                    let filter = argument(after: "-vf", in: arguments)
                    try expect(filter?.contains("fps=7.500") == true, "GIF filter should retain FPS")
                    try expect(filter?.contains(expectedScale ?? "missing") == true, "GIF quality scale changed")
                    try expect(argument(after: "-loop", in: arguments) == "0", "GIF should loop continuously")
                }
            }
        }

        enum SyntheticCaptureFailure: Error { case unavailable }
        let failureLock = NSLock()
        var failureCalls = 0
        let failedOutput = URL(fileURLWithPath: root + "/capture-failure.mp4")
        let failedRecording = try BrowserRecording(
            outputURL: failedOutput, fps: 4, captureFrame: {
                failureLock.lock(); failureCalls += 1; let call = failureCalls; failureLock.unlock()
                if call == 1 { return Data([0x01]) }
                throw SyntheticCaptureFailure.unavailable
            }
        )
        let failureDeadline = Date().addingTimeInterval(5)
        while Date() < failureDeadline {
            guard case .object(let status) = failedRecording.status() else { break }
            if status["active"] == .bool(false) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard case .object(let failedStatus) = failedRecording.status() else {
            throw TestFailure(description: "failed recording status")
        }
        try expect(failedStatus["active"] == .bool(false), "consecutive capture failures should abort recording")
        try expect(failedStatus["droppedFrames"] == .number(12), "failure threshold should be max(10, fps × 3)")
        do {
            _ = try failedRecording.stop(timeout: 2)
            throw TestFailure(description: "capture failure should surface from stop")
        } catch RecordingError.captureFailed {
            // Expected.
        }

        let loopEntered = DispatchSemaphore(value: 0)
        let timeoutLock = NSLock()
        var timeoutCalls = 0
        let timeoutRecording = try BrowserRecording(
            outputURL: URL(fileURLWithPath: root + "/timeout.mp4"), fps: 1,
            captureFrame: {
                timeoutLock.lock(); timeoutCalls += 1; let call = timeoutCalls; timeoutLock.unlock()
                if call == 2 { loopEntered.signal() }
                return Data([0x01])
            }
        )
        try expect(loopEntered.wait(timeout: .now() + 1) == .success, "capture loop should start")
        do {
            _ = try timeoutRecording.stop(timeout: 0.01)
            throw TestFailure(description: "a bounded stop should report timeout")
        } catch RecordingError.timedOut {
            // Expected.
        }
        Thread.sleep(forTimeInterval: 1.1)
    }

    static func capabilitiesMatchProtocolCommands() throws {
        guard case .object(let document) = capabilitiesDocument,
              case .array(let rawCommands)? = document["commands"],
              case .object(let engines)? = document["engines"],
              case .array(let localCommands)? = document["localCommands"],
              case .object(let settings)? = document["settings"],
              case .array(let settingDefinitions)? = settings["definitions"],
              case .object(let security)? = document["security"] else {
            throw TestFailure(description: "capabilities document shape")
        }
        let commands = rawCommands.compactMap(\.stringValue)
        let expected = CommandName.allCases.map(\.rawValue)
        try expect(commands.count == expected.count, "capabilities should not omit or duplicate commands")
        try expect(Set(commands) == Set(expected), "capabilities should match CommandName.allCases")
        let localCommandNames = Set(localCommands.compactMap(\.stringValue))
        try expect(
            localCommandNames.isSuperset(of: [
                "config.describe", "config.get", "config.list", "config.reset", "config.set",
                "schema",
            ]),
            "capabilities should advertise every local config command"
        )
        try expect(
            !localCommandNames.contains("artifacts.add"),
            "capabilities must not advertise local-file ingest"
        )
        try expect(
            settingDefinitions == SettingsRegistry.shared.definitions.compactMap {
                $0.access == .userOnly ? nil : $0.document
            },
            "capability setting definitions should come from the registry"
        )
        try expect(
            settings["securityInvariantsConfigurable"] == .bool(false),
            "capabilities must keep security invariants outside settings"
        )
        try expect(
            engines.count == BrowserEngineName.allCases.count,
            "capabilities should contain exactly one profile for every engine"
        )
        try expect(
            BrowserEngineCapabilities.all.map(\.engine) == BrowserEngineName.allCases,
            "capability profiles should be generated in engine-enum order"
        )
        for engineName in BrowserEngineName.allCases {
            let profile = BrowserEngineCapabilities.profile(for: engineName)
            guard case .object(let engine)? = engines[profile.engine.rawValue],
                  case .array(let rawSupported)? = engine["commands"],
                  case .array(let rawUnsupported)? = engine["unsupportedCommands"],
                  case .object(let features)? = engine["features"] else {
                throw TestFailure(description: "missing engine capability profile: \(profile.engine.rawValue)")
            }
            let supported = Set(rawSupported.compactMap(\.stringValue))
            let unsupported = Set(rawUnsupported.compactMap(\.stringValue))
            try expect(supported.isDisjoint(with: unsupported), "engine command sets must not overlap")
            try expect(supported.union(unsupported) == Set(expected), "engine command sets must be exhaustive")
            try expect(
                features["tourTimeoutMs"] == .number(65_000),
                "both engine profiles should declare the shared tour timeout"
            )
            guard case .object(let features)? = engine["features"],
                  case .object(let normalProfile)? = features["normalProfile"] else {
                throw TestFailure(description: "engine should declare normal-profile behavior")
            }
            try expect(normalProfile["persistent"] == .bool(true), "normal profile should be durable")
            try expect(
                normalProfile["clearCommand"] == .string(CommandName.profileClear.rawValue),
                "normal profile should declare its explicit clear command"
            )
            try expect(
                features["backWithoutHistory"] == .string("operation-failed"),
                "both engines should fail consistently when back history is empty"
            )
        }
        try expect(
            BrowserEngineCapabilities.webkit.unsupportedCommands
                == [.networkEmulate, .networkMockSet, .networkMockClear, .upload],
            "WebKit unsupported commands should be explicit and exact"
        )
        try expect(
            BrowserEngineCapabilities.chromium.unsupportedCommands.isEmpty,
            "Chromium should implement every protocol command"
        )
        guard case .object(let webkitDocument) = BrowserEngineCapabilities.webkit.document,
              case .object(let webkitFeatures)? = webkitDocument["features"],
              case .object(let chromiumDocument) = BrowserEngineCapabilities.chromium.document,
              case .object(let chromiumFeatures)? = chromiumDocument["features"] else {
            throw TestFailure(description: "engine feature capability shape")
        }
        try expect(
            webkitFeatures["inputDispatch"] == .string("synthetic-dom"),
            "WebKit should declare its portable synthetic input path"
        )
        try expect(
            chromiumFeatures["inputDispatch"] == .string("trusted-cdp"),
            "Chromium should declare trusted CDP input"
        )
        try expect(
            webkitFeatures["fileUpload"] == .bool(false),
            "WebKit should declare file upload unsupported until a native attach path exists"
        )
        try expect(
            chromiumFeatures["fileUpload"] == .bool(true),
            "Chromium should declare file upload via DOM.setFileInputFiles"
        )
        guard case .array(let artifactFormats)? = document["artifacts"] else {
            throw TestFailure(description: "artifact capability shape")
        }
        try expect(
            Set(artifactFormats.compactMap(\.stringValue)).isSuperset(of: uploadArtifactExtensions),
            "capabilities artifacts list should include upload extensions"
        )
        try expect(
            document["currentEngine"] == .string(currentBrowserEngineCapabilities.engine.rawValue),
            "capabilities should identify the engine for this binary"
        )
        guard case .array(let screenshotFormats)? = document["screenshotFormats"],
              case .array(let recordingFormats)? = document["recordingFormats"],
              case .array(let recordingQuality)? = document["recordingQuality"] else {
            throw TestFailure(description: "generated capture capability shape")
        }
        try expect(
            Set(screenshotFormats.compactMap(\.stringValue)) == ScreenshotFormat.artifactExtensions,
            "screenshot capabilities should be generated from ScreenshotFormat"
        )
        try expect(
            Set(recordingFormats.compactMap(\.stringValue)) == RecordingFormat.artifactExtensions,
            "recording capabilities should be generated from RecordingFormat"
        )
        try expect(
            Set(recordingQuality.compactMap(\.stringValue)) == Set(RecordingQuality.allCases.map(\.rawValue)),
            "recording quality capabilities should be generated from RecordingQuality"
        )
        try expect(
            security["maximumMessageBytes"] == .number(Double(headlessMaximumMessageBytes)),
            "capabilities should publish the real frame bound"
        )
        try expect(security["tcpListener"] == .bool(false), "capabilities must not advertise TCP control")
        try expect(security["arbitraryJavaScript"] == .bool(false), "capabilities must not advertise arbitrary JavaScript")
    }

    static func sdkProtocolSchemaContract() throws {
        try expect(
            protocolCommandDefinitions.count == CommandName.allCases.count,
            "the SDK schema must describe every wire command exactly once"
        )
        try expect(
            Set(protocolCommandDefinitions.keys) == Set(CommandName.allCases),
            "the SDK schema command set must match CommandName"
        )
        for command in CommandName.allCases {
            let definition = protocolCommandDefinition(for: command)
            let result = protocolResultDefinition(for: command)
            try expect(
                definition.command == command,
                "the SDK schema must preserve the command identity"
            )
            try expect(
                Set(definition.parameters.map(\.name)).count == definition.parameters.count,
                "the SDK schema must not contain duplicate parameter names"
            )
            try expect(
                !result.name.isEmpty && Set(result.fields.map(\.name)).count == result.fields.count,
                "the SDK schema must define one coherent result shape per command"
            )
            try expect(
                definition.timeout.defaultMilliseconds > 0,
                "every SDK command must declare a positive transport timeout"
            )
        }
        let hostCommands: Set<CommandName> = [
            .ping, .shutdown, .profileClear, .sessionCreate, .sessionList, .artifactList,
        ]
        try expect(
            Set(protocolCommandDefinitions.values.filter { $0.scope == .host }.map(\.command))
                == hostCommands,
            "SDK host and session command scopes must match HostCore dispatch"
        )
        try expect(
            protocolCommandDefinition(for: .wait).timeout.milliseconds(
                for: ["timeoutMs": .number(90_000)]
            ) == 95_000,
            "SDK timeout metadata must preserve parameter-based wait deadlines"
        )
        try expect(
            protocolCommandDefinition(for: .screenshot).timeout.milliseconds(
                for: ["series": .string("viewport")]
            ) == 125_000,
            "SDK timeout metadata must preserve screenshot series deadlines"
        )
        try expect(
            protocolCommandDefinition(for: .visit).resultContainsUntrustedContent
                && protocolCommandDefinition(for: .captureInfo).resultContainsUntrustedContent,
            "page state and capture metadata must remain marked as untrusted"
        )

        let schemaInvocation = try CLIParser().parse(["schema"])
        try expect(schemaInvocation.local == .schema, "schema must remain a local CLI command")
        try expect(schemaInvocation.request == nil, "schema must not enter the browser protocol")
        try expectThrows("schema should reject unexpected arguments") {
            _ = try CLIParser().parse(["schema", "extra"])
        }

        let fill = protocolCommandDefinition(for: .fill)
        let sensitiveParameters = fill.parameters.filter(\.sensitive).map(\.name)
        try expect(sensitiveParameters == ["value"], "fill value sensitivity must be machine-readable")
        let authentication = protocolCommandDefinition(for: .authLogin)
        try expect(
            Set(authentication.parameters.map(\.name)) == ["challenge", "account", "interactive"],
            "authentication schema must expose aliases and challenge identifiers only"
        )
        try expect(
            authentication.parameters.allSatisfy { !$0.sensitive },
            "authentication schema must never define a password parameter"
        )
        let screenshotFormat = protocolCommandDefinition(for: .screenshot).parameters
            .first { $0.name == "format" }
        try expect(
            screenshotFormat?.values == ["png", "jpg", "jpeg", "pdf"],
            "the schema must expose every accepted screenshot spelling"
        )
        try expect(
            screenshotFormat?.caseInsensitiveValues == true,
            "the schema must preserve case-insensitive screenshot formats"
        )
        let recordingQuality = protocolCommandDefinition(for: .recordStart).parameters
            .first { $0.name == "quality" }
        try expect(
            recordingQuality?.values == RecordingQuality.allCases.map(\.rawValue),
            "the schema must derive recording quality values from the parser enum"
        )
        try expect(
            recordingQuality?.caseInsensitiveValues == true,
            "the schema must preserve case-insensitive recording quality values"
        )
        try expect(
            protocolErrorCodes.contains(AuthenticationError.challengeExpired.code)
                && protocolErrorCodes.contains("INVALID_INPUT")
                && protocolErrorCodes.contains("RESPONSE_TOO_LARGE"),
            "the schema must include authentication, validation, and transport failures"
        )

        let schemaData = try ProtocolCodec.encoder.encode(protocolSchemaDocument)
        try expect(
            schemaData.count < headlessMaximumMessageBytes,
            "the protocol schema must fit the protocol frame bound"
        )
        if let source = repositoryFile("sdk/protocol-schema.json") {
            let golden = try Data(contentsOf: source)
            try expect(
                try ProtocolCodec.decoder.decode(JSONValue.self, from: golden) == protocolSchemaDocument,
                "the checked-in SDK schema must match the Swift-owned contract"
            )
        } else if ProcessInfo.processInfo.environment["HEADLESS_REQUIRE_SDK_CONTRACT"] == "1" {
            throw TestFailure(description: "required sdk/protocol-schema.json was not found")
        }
    }

    static func sdkProtocolFixtures() throws {
        guard let source = repositoryFile("sdk/protocol-fixtures.json") else {
            if ProcessInfo.processInfo.environment["HEADLESS_REQUIRE_SDK_CONTRACT"] == "1" {
                throw TestFailure(description: "required sdk/protocol-fixtures.json was not found")
            }
            return
        }
        let document = try ProtocolCodec.decoder.decode(
            JSONValue.self, from: Data(contentsOf: source)
        )
        guard case .object(let root) = document,
              root["schemaVersion"] == .number(Double(headlessProtocolSchemaVersion)),
              root["protocolVersion"] == .string(headlessProtocolVersion),
              case .array(let cases)? = root["cases"],
              case .array(let directRequests)? = root["directRequests"],
              case .array(let invalidRequests)? = root["invalidRequests"] else {
            throw TestFailure(description: "SDK fixture envelope is invalid")
        }

        for fixture in cases {
            guard case .object(let fields) = fixture,
                  case .array(let rawArguments)? = fields["argv"],
                  case .object? = fields["request"],
                  let requestValue = fields["request"],
                  let responseValue = fields["response"] else {
                throw TestFailure(description: "SDK fixture case is invalid")
            }
            let arguments = rawArguments.compactMap(\.stringValue)
            try expect(arguments.count == rawArguments.count, "fixture argv must contain strings")
            let request = try ProtocolCodec.decoder.decode(
                CommandRequest.self, from: ProtocolCodec.encoder.encode(requestValue)
            )
            try request.validate()
            let invocation = try CLIParser().parse(arguments)
            guard let parsed = invocation.request else {
                throw TestFailure(description: "fixture argv did not produce a wire request")
            }
            try expect(parsed.command == request.command, "fixture CLI command drifted")
            try expect(parsed.session == request.session, "fixture CLI session drifted")
            try expect(parsed.parameters == request.parameters, "fixture CLI parameters drifted")

            let response = try ProtocolCodec.decoder.decode(
                CommandResponse.self, from: ProtocolCodec.encoder.encode(responseValue)
            )
            try expect(response.id == request.id, "fixture response id drifted")
            try expect(response.version == headlessProtocolVersion, "fixture response version drifted")
            guard response.ok, let result = response.result else {
                throw TestFailure(description: "fixture success response is invalid")
            }
            try protocolResultDefinition(for: request.command).validate(result)
        }

        for value in directRequests {
            let request = try ProtocolCodec.decoder.decode(
                CommandRequest.self, from: ProtocolCodec.encoder.encode(value)
            )
            try request.validate()
        }
        for value in invalidRequests {
            let request = try ProtocolCodec.decoder.decode(
                CommandRequest.self, from: ProtocolCodec.encoder.encode(value)
            )
            try expectThrows("invalid SDK fixture request was accepted") { try request.validate() }
        }
    }

    static func supervisedHostOwnerPipe() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--supervised-owner-child"]
        var environment = ProcessInfo.processInfo.environment
        environment["HEADLESS_SUPERVISED"] = "1"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        try expect(process.isRunning, "a supervised host must stay alive while its owner pipe is open")
        try input.fileHandleForWriting.close()
        try expect(
            finished.wait(timeout: .now() + 3) == .success,
            "a supervised host must stop when its owner pipe closes"
        )
        let marker = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        try expect(
            process.terminationStatus == 0 && marker.contains("owner-closed"),
            "the supervised owner monitor did not perform an orderly shutdown"
        )
    }

    static func oversizedSocketRequestIsRejected() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("oversized-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in
            CommandResponse.success(id: request.id, result: .object(["unexpected": .bool(true)]))
        }
        defer { server.stop() }

        let descriptor = try connectRawUnixSocket(path: socketPath)
        defer { closeRawSocket(descriptor) }
        var request = Data(repeating: 0x78, count: headlessMaximumMessageBytes + 8_192)
        request.append(0x0A)
        _ = try writeRawSocket(request, descriptor: descriptor)
        let response = try ProtocolCodec.decodeLine(
            CommandResponse.self, from: readRawSocketLine(descriptor: descriptor)
        )
        try expect(!response.ok, "oversized socket request should fail")
        try expect(response.error?.code == "INVALID_REQUEST", "oversized request should retain an explicit error code")
        try expect(response.result == nil, "oversized request must not reach the command handler")
    }

    static func differentPeerUserIsRejected() throws {
        #if os(Linux)
        // The Linux CI container runs this suite as root, which lets the test
        // launch one deliberately unprivileged peer. Normal developer runs
        // still exercise every other transport boundary without requiring
        // privilege escalation.
        guard getuid() == 0 else { return }
        let setpriv = "/usr/bin/setpriv"
        try expect(FileManager.default.isExecutableFile(atPath: setpriv), "Linux CI should provide setpriv")
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("peer-uid-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in CommandResponse.success(id: request.id) }
        defer {
            server.stop()
            _ = Glibc.chmod(LocalRuntime.directoryURL.path, 0o700)
        }
        // The production modes are 0700/0600. Open them only inside this
        // disposable test so a different uid can reach accept(), where the
        // credential check must still fail closed.
        try expect(Glibc.chmod(LocalRuntime.directoryURL.path, 0o777) == 0, "test runtime directory chmod failed")
        try expect(Glibc.chmod(socketPath, 0o666) == 0, "test socket chmod failed")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: setpriv)
        process.arguments = [
            "--reuid=65534", "--regid=65534", "--clear-groups",
            CommandLine.arguments[0], "--peer-denied-client", socketPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        try expect(process.terminationStatus == 0, "different-uid peer was not rejected: \(errorText)")
        #endif
    }

    static func screenshotSeriesHelpers() throws {
        let rawPlan = JSONValue.object([
            "initialY": .number(240),
            "truncated": .bool(true),
            "totalPoints": .number(100),
            "points": .array([
                .object(["y": .number(0), "label": .string("top"), "kind": .string("viewport")]),
                .object(["y": .number(900), "label": .string("bottom"), "kind": .string("viewport")]),
            ]),
        ])
        let plan = try parseScreenshotSeriesPlan(rawPlan)
        try expect(plan.initialY == 240, "series plans should retain the initial scroll position")
        try expect(plan.points.count == 2, "series plans should parse capture points")
        try expect(plan.truncated && plan.totalPoints == 100, "series plans should report truncation")
        try expectThrows("invalid initial scroll positions should fail") {
            _ = try parseScreenshotSeriesPlan(.object([
                "initialY": .number(-1),
                "points": .array([.object(["y": .number(0)])]),
            ]))
        }

        let root = "/tmp/headless-series-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let collisionName = try screenshotSeriesArtifactName(
            prefix: "capture", mode: "viewport", index: 2, count: plan.points.count,
            point: plan.points[1], format: .png
        )
        _ = try store.write(
            Data([0x01]), requestedName: collisionName, extension: "png", prefix: "unused"
        )
        try expectThrows("a later series collision should fail atomically") {
            _ = try reserveScreenshotSeriesArtifacts(
                store: store, points: plan.points, prefix: "capture",
                mode: "viewport", format: .png
            )
        }
        let firstName = try screenshotSeriesArtifactName(
            prefix: "capture", mode: "viewport", index: 1, count: plan.points.count,
            point: plan.points[0], format: .png
        )
        try expect(
            !FileManager.default.fileExists(atPath: root + "/" + firstName),
            "partial series reservations should be removed after a later collision"
        )
        try expect(RecordingFormat.webm.videoCodec == "vp9", "recording metadata should report the codec, not encoder")
        try expect(!agentRuntimeJavaScript.contains("hints.push('select')"), "inspect must not advertise a missing select command")
        try expect(
            agentRuntimeJavaScript.contains("__headlessFileUpload"),
            "upload hints must be gated on engine file-upload support"
        )
        try expect(
            agentRuntimeJavaScript.contains("hints.push('upload')"),
            "inspect must advertise upload on file inputs when the engine supports it"
        )
        try expect(!agentRuntimeJavaScript.contains("hints.push('slide')"), "inspect must not advertise a missing slide command")
    }

    static func diagnosticSummary() throws {
        let store = QADiagnosticStore()
        store.append(kind: "console", level: "error", message: "Next.js hydration mismatch")
        store.append(kind: "page-error", message: "uncaught")
        store.append(kind: "response", url: "http://127.0.0.1:3000/missing", status: 404)
        guard case .object(let report) = store.report(), case .object(let summary)? = report["summary"] else {
            throw TestFailure(description: "diagnostic report")
        }
        try expect(report["untrustedContent"] == .bool(true), "diagnostic reports should mark page evidence untrusted")
        try expect(summary["consoleErrors"] == .number(1), "console errors should be counted")
        try expect(summary["pageErrors"] == .number(1), "page errors should be counted")
        try expect(summary["httpErrors"] == .number(1), "HTTP errors should be counted")
        guard case .array(let issues)? = report["issues"] else { throw TestFailure(description: "diagnostic issues") }
        try expect(issues.count == 3, "each actionable diagnostic should have an issue")
        guard case .object(let firstIssue) = issues[0] else { throw TestFailure(description: "diagnostic issue shape") }
        try expect(firstIssue["untrustedContent"] == .bool(true), "derived diagnostic issues should stay untrusted")
        guard case .array(let events)? = report["events"], case .object(let firstEvent) = events[0] else {
            throw TestFailure(description: "diagnostic event shape")
        }
        try expect(firstEvent["untrustedContent"] == .bool(true), "diagnostic events should mark page evidence untrusted")
        let serialized = String(decoding: try ProtocolCodec.encoder.encode(report), as: UTF8.self)
        try expect(serialized.contains("framework-error"), "framework issues should be classified")
        try expect(serialized.contains("local-not-found"), "local 404s should be classified")
        guard case .object(let cleared) = store.clear() else { throw TestFailure(description: "diagnostic clear") }
        try expect(cleared["cleared"] == .number(3), "diagnostic clear should report count")
    }

    static func diagnosticsBoundAndRedacted() throws {
        let store = QADiagnosticStore()
        for _ in 0..<500 { store.append(kind: "console", level: "warn", message: "notice") }
        guard case .object(let exact) = store.report() else { throw TestFailure(description: "exact diagnostic report") }
        try expect(exact["truncated"] == .bool(false), "an exact diagnostic limit is not truncated")
        store.append(kind: "response", url: "https://user:secret@example.com/fail", status: 500)
        guard case .object(let overflow) = store.report() else { throw TestFailure(description: "overflow diagnostic report") }
        try expect(overflow["truncated"] == .bool(true), "overflow diagnostics should be marked truncated")
        let serialized = String(decoding: try ProtocolCodec.encoder.encode(overflow), as: UTF8.self)
        try expect(!serialized.contains("secret@"), "diagnostics must redact URL credentials")
        _ = store.clear()
        store.markTruncated()
        guard case .object(let externallyTruncated) = store.report() else {
            throw TestFailure(description: "externally truncated diagnostic report")
        }
        try expect(externallyTruncated["truncated"] == .bool(true), "diagnostic sources should report rejected events")
    }

    static func responsesFitTheProtocolFrame() throws {
        // 500 events each carrying a 4 KiB message is roughly 2 MB — twice the
        // frame. Before the response bound this encoded past the limit and the
        // agent saw INVALID_REQUEST for a valid `qa report`.
        let store = QADiagnosticStore()
        let wide = String(repeating: "d", count: 4_096)
        for _ in 0..<500 {
            store.append(kind: "console", level: "error", message: wide, url: "https://example.com/\(wide)")
        }
        let report = store.report()
        let encoded = try ProtocolCodec.encodeLine(
            CommandResponse.success(id: "report", result: report)
        )
        try expect(
            encoded.count <= headlessMaximumMessageBytes,
            "a full diagnostic report must fit the protocol frame"
        )
        guard case .object(let object) = report else { throw TestFailure(description: "report shape") }
        try expect(object["truncated"] == .bool(true), "a bounded report should report truncation")
        guard case .object(let summary)? = object["summary"],
              case .object(let omitted)? = object["omitted"],
              case .array(let events)? = object["events"],
              case .array(let issues)? = object["issues"] else {
            throw TestFailure(description: "report bounds")
        }
        try expect(summary["events"] == .number(500), "summary counts should describe every event")
        try expect((omitted["events"]?.numberValue ?? 0) > 0, "omitted events should be counted")
        try expect(
            events.count + Int(omitted["events"]?.numberValue ?? 0) == 500,
            "kept plus omitted events should account for the whole buffer"
        )
        // Issues carry the same message and URL as the events they describe, so
        // a count cap is not a size cap — bounding them by bytes is what keeps
        // the report inside the frame.
        try expect(
            issues.count + Int(omitted["issues"]?.numberValue ?? 0)
                == Int(summary["issues"]?.numberValue ?? 0),
            "kept plus omitted issues should account for every issue"
        )
    }

    static func artifactListingStaysBounded() throws {
        let root = "/tmp/headless-artifact-bound-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        for index in 0..<260 {
            _ = try store.write(Data("x".utf8), requestedName: "bound-\(index).json", extension: "json", prefix: "bound")
        }
        guard case .object(let listing) = try store.list(),
              case .array(let artifacts)? = listing["artifacts"] else {
            throw TestFailure(description: "artifact listing")
        }
        try expect(artifacts.count == 250, "artifact listing should stay bounded")
        try expect(listing["total"] == .number(260), "artifact listing should report the true total")
        try expect(listing["omitted"] == .number(10), "artifact listing should report what it left out")
        try expect(listing["truncated"] == .bool(true), "a bounded artifact listing is truncated")
        let encoded = try ProtocolCodec.encodeLine(
            CommandResponse.success(id: "artifacts", result: try store.list())
        )
        try expect(
            encoded.count <= headlessMaximumMessageBytes,
            "an artifact listing must fit the protocol frame"
        )
    }

    static func diagnosticServices() throws {
        let store = QADiagnosticStore()
        let typedHeaders = diagnosticStringHeaders([
            "X-String": "value", "X-Number": 42, "X-Object": ["nested": true],
        ])
        try expect(typedHeaders == ["X-String": "value"], "non-string CDP header values should be dropped")
        store.append(kind: "console", level: "warn", message: "first")
        store.append(kind: "console", level: "error", message: "second")
        store.append(
            kind: "response", url: "https://example.com/api", method: "POST", status: 500,
            requestID: "request-1", requestHeaders: ["Authorization": "Bearer secret", "X-Visible": "yes"],
            responseHeaders: ["Set-Cookie": "session=secret", "Content-Type": "application/json"], source: "test"
        )
        guard case .object(let console) = store.console(level: "error", limit: 10),
              case .array(let messages)? = console["messages"] else {
            throw TestFailure(description: "console service")
        }
        try expect(console["untrustedContent"] == .bool(true), "console output should mark page evidence untrusted")
        try expect(messages.count == 1, "console service should filter by level")
        guard case .object(let network) = store.network(failedOnly: true, status: nil, limit: 10),
              case .array(let requests)? = network["requests"] else {
            throw TestFailure(description: "network service")
        }
        try expect(network["untrustedContent"] == .bool(true), "network output should mark page evidence untrusted")
        try expect(requests.count == 1, "network service should find failed HTTP responses")
        let networkText = String(decoding: try ProtocolCodec.encoder.encode(network), as: UTF8.self)
        try expect(!networkText.contains("Bearer secret"), "network summaries must omit headers")
        let detail = store.networkDetail(requestID: "request-1")
        guard case .object(let detailObject) = detail else { throw TestFailure(description: "network detail shape") }
        try expect(detailObject["untrustedContent"] == .bool(true), "network detail should mark page evidence untrusted")
        let detailText = String(decoding: try ProtocolCodec.encoder.encode(detail), as: UTF8.self)
        try expect(detailText.contains("[redacted]"), "network details must redact sensitive headers")
        try expect(detailText.contains("X-Visible"), "network details should retain non-sensitive headers")

        var manyHeaders: [String: String] = [:]
        for index in (0..<70).reversed() {
            manyHeaders[String(format: "X-%03d", index)] = "value-\(index)"
        }
        store.append(kind: "response", requestID: "request-headers", requestHeaders: manyHeaders)
        guard case .object(let headerDetail) = store.networkDetail(requestID: "request-headers"),
              case .object(let requestEvent)? = headerDetail["request"],
              case .object(let boundedHeaders)? = requestEvent["requestHeaders"] else {
            throw TestFailure(description: "bounded diagnostic headers")
        }
        try expect(boundedHeaders.count == 64, "diagnostic headers should remain capped at 64")
        try expect(boundedHeaders["X-000"] == .string("value-0"), "header selection should use sorted keys")
        try expect(boundedHeaders["X-063"] == .string("value-63"), "the deterministic header boundary changed")
        try expect(boundedHeaders["X-064"] == nil, "headers beyond the sorted cap should be omitted")
    }

    static func diagnosticCLI() throws {
        let console = try CLIParser().parse(["console", "list", "--level", "error", "--limit", "25"])
        try expect(console.request?.command == .consoleList, "console command should parse")
        let network = try CLIParser().parse(["network", "get", "request-1"])
        try expect(network.request?.command == .networkGet, "network detail command should parse")
        let styles = try CLIParser().parse(["styles", "get", "--role", "button", "--name", "Continue", "--property", "display"])
        try expect(styles.request?.parameters["properties"] == .array([.string("display")]), "style property should parse")
        let storage = try CLIParser().parse(["storage", "list", "--scope", "local"])
        try expect(storage.request?.command == .storageList, "storage command should parse")
        do {
            _ = try CLIParser().parse(["qa", "bogus", "--x"])
            throw TestFailure(description: "unknown QA subcommands should fail")
        } catch let error as CLIParseError {
            try expect(error == .unknownCommand("qa bogus"), "unknown QA subcommands should win over trailing-option validation")
        }
    }

    static func localSocketRoundTrip() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        try server.start { request in
            CommandResponse.success(id: request.id, result: .object(["pong": .bool(true)]))
        }
        defer { server.stop() }
        let request = CommandRequest(id: "ping-1", command: .ping)
        let response = try LocalSocketClient(socketPath: socketPath).send(request, timeout: 2)
        try expect(response.ok, "socket response should succeed")
        try expect(response.id == request.id, "socket response should preserve request ID")
        try expect(response.result == .object(["pong": .bool(true)]), "socket response should decode")
    }

    static func rejectsMismatchedResponseIdentifier() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        // A host that answers with someone else's id is answering the wrong
        // question. One request per connection means the client can say so.
        try server.start { _ in
            CommandResponse.success(id: "a-different-request", result: .object(["pong": .bool(true)]))
        }
        defer { server.stop() }
        try expectThrows("a mismatched response identifier should be rejected") {
            _ = try LocalSocketClient(socketPath: socketPath)
                .send(CommandRequest(id: "ping-correlated", command: .ping), timeout: 2)
        }
        // The unknown-id sentinel stays usable, because a host that could not
        // read the request still has to be able to explain why.
        let sentinelPath = LocalRuntime.directoryURL
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
        let sentinelServer = LocalSocketServer(socketPath: sentinelPath)
        try sentinelServer.start { _ in
            CommandResponse.failure(
                id: CommandResponse.unknownRequestIdentifier,
                code: "INVALID_REQUEST", message: "unreadable"
            )
        }
        defer { sentinelServer.stop() }
        let sentinel = try LocalSocketClient(socketPath: sentinelPath)
            .send(CommandRequest(id: "ping-sentinel", command: .ping), timeout: 2)
        try expect(!sentinel.ok, "the sentinel reply should still reach the caller")
        try expect(sentinel.error?.code == "INVALID_REQUEST", "the sentinel reply should keep its reason")
    }

    static func liveSocketCannotBeReplaced() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("live-\(UUID().uuidString).sock").path
        let first = LocalSocketServer(socketPath: socketPath)
        try first.start { CommandResponse.success(id: $0.id) }
        defer { first.stop() }
        let second = LocalSocketServer(socketPath: socketPath)
        try expectThrows("a live host socket must not be unlinked") {
            try second.start { CommandResponse.success(id: $0.id) }
        }
        let response = try LocalSocketClient(socketPath: socketPath)
            .send(CommandRequest(id: "still-live", command: .ping), timeout: 2)
        try expect(response.ok, "first host should remain reachable")
    }

    static func serverRejectsSocketOutsidePrivateDirectory() throws {
        let server = LocalSocketServer(socketPath: "/tmp/headless-outside-\(UUID().uuidString).sock")
        try expectThrows("server should reject a socket outside its private runtime directory") {
            try server.start { CommandResponse.success(id: $0.id) }
        }
    }

    static func shutdownBypassesBusyRequest() throws {
        try LocalRuntime.preparePrivateDirectory()
        let socketPath = LocalRuntime.directoryURL
            .appendingPathComponent("shutdown-\(UUID().uuidString).sock").path
        let server = LocalSocketServer(socketPath: socketPath)
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        try server.start { request in
            if request.command == .visit {
                requestStarted.signal()
                _ = releaseRequest.wait(timeout: .now() + 2)
                requestFinished.signal()
            }
            return CommandResponse.success(id: request.id)
        }
        defer { server.stop() }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { requestFinished.signal() }
            _ = try? LocalSocketClient(socketPath: socketPath).send(
                CommandRequest(command: .visit, parameters: ["url": .string("http://localhost")]), timeout: 3
            )
        }
        try expect(requestStarted.wait(timeout: .now() + 1) == .success, "visit should begin")
        let shutdown = try LocalSocketClient(socketPath: socketPath).send(
            CommandRequest(command: .shutdown), timeout: 1
        )
        try expect(shutdown.ok, "shutdown should not wait for an in-flight browser request")
        releaseRequest.signal()
        _ = requestFinished.wait(timeout: .now() + 2)
    }

    static func nullTerminatedBufferScansIncrementally() throws {
        var buffer = NullTerminatedMessageBuffer()
        let chunk = [UInt8](repeating: 0x61, count: 8_192)
        let chunkSlice = chunk[...]
        let chunkCount = 30 * 1_024 * 1_024 / chunk.count

        for _ in 0..<chunkCount {
            buffer.append(contentsOf: chunkSlice)
            try expect(
                buffer.unscannedByteCount == chunk.count,
                "only newly appended CDP bytes should remain unscanned"
            )
            try expect(buffer.popFirst() == nil, "unterminated CDP payload should remain buffered")
            try expect(buffer.unscannedByteCount == 0, "the CDP scan cursor should advance to the buffer end")
        }
        try expect(
            buffer.bufferedByteCount == 30 * 1_024 * 1_024,
            "large chunked CDP payload should retain every byte"
        )
        buffer.append(contentsOf: [UInt8(0)][...])
        try expect(buffer.popFirst()?.count == 30 * 1_024 * 1_024, "terminator should release the complete CDP payload")
        try expect(buffer.bufferedByteCount == 0, "consumed CDP storage should compact")

        buffer.append(contentsOf: Array("one\0two\0".utf8)[...])
        try expect(buffer.popFirst() == Array("one".utf8), "first buffered CDP message changed")
        try expect(buffer.popFirst() == Array("two".utf8), "second buffered CDP message changed")
    }

    static func typedHostErrorsRoundTrip() throws {
        let success = try unwrapAgentEvaluationResult(.object([
            "__headlessAgentResult": .bool(true), "ok": .bool(true),
            "value": .object(["clicked": .string("@e1")]),
        ]))
        try expect(
            success == .object(["clicked": .string("@e1")]),
            "agent result envelope should preserve successful values"
        )

        do {
            _ = try unwrapAgentEvaluationResult(.object([
                "__headlessAgentResult": .bool(true), "ok": .bool(false),
                "error": .object([
                    "code": .string("ELEMENT_NOT_FOUND"),
                    "message": .string("reference expired"),
                ]),
            ]))
            throw TestFailure(description: "typed agent error should throw")
        } catch let error as HostError {
            try expect(error.code == .elementNotFound, "agent error code should survive the engine boundary")
            try expect(error.message == "reference expired", "agent error message should survive the engine boundary")
            try expect(error.suggestion?.contains("inspect --interactive") == true, "typed error should own its suggestion")
        }

        do {
            _ = try unwrapAgentEvaluationResult(.object([
                "__headlessAgentResult": .bool(true), "ok": .bool(false),
                "error": .object(["code": .string("PAGE_DEFINED_CODE"), "message": .string("failed")]),
            ]))
            throw TestFailure(description: "unknown agent error should throw")
        } catch let error as HostError {
            try expect(error.code == .operationFailed, "unknown error codes must fail closed")
        }
    }

    static func singleSourceContractConstants() throws {
        func javaScriptSet(named name: String) throws -> Set<String> {
            let marker = "const \(name) = new Set(["
            guard let start = agentRuntimeJavaScript.range(of: marker),
                  let end = agentRuntimeJavaScript.range(
                    of: "]);", range: start.upperBound..<agentRuntimeJavaScript.endIndex
                  ) else {
                throw TestFailure(description: "missing JavaScript set: \(name)")
            }
            return Set(agentRuntimeJavaScript[start.upperBound..<end.lowerBound]
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                })
        }

        try expect(
            javaScriptSet(named: "blockedResourceExtensions") == blockedRemoteResourceExtensions,
            "blocked resource extensions drifted between Swift and the isolated runtime"
        )
        try expect(
            javaScriptSet(named: "cautionResourceExtensions") == cautionRemoteResourceExtensions,
            "caution resource extensions drifted between Swift and the isolated runtime"
        )
        try expect(hasPortableNameCharacters("artifact-1_name.json"), "portable artifact characters changed")
        try expect(!hasPortableNameCharacters("artifact/name.json"), "path separators must not be portable name characters")
        try expect(
            localDevelopmentHosts == ["localhost", "127.0.0.1", "0.0.0.0", "::1"],
            "local development host allowlist changed"
        )
        let maximumScreenshot = try BoundedScreenshotRectangle([
            "x": .number(0), "y": .number(0),
            "width": .number(ProtocolBounds.screenshotDimension),
            "height": .number(ProtocolBounds.screenshotPixels / ProtocolBounds.screenshotDimension),
        ])
        try expect(
            maximumScreenshot.width * maximumScreenshot.height == ProtocolBounds.screenshotPixels,
            "the shared screenshot pixel bound should accept its exact limit"
        )
        try expectThrows("the shared screenshot bound should reject oversized captures") {
            _ = try BoundedScreenshotRectangle([
                "x": .number(0), "y": .number(0),
                "width": .number(ProtocolBounds.screenshotDimension),
                "height": .number(ProtocolBounds.screenshotDimension),
            ])
        }
        try expect(
            try browserTargetArguments(["target": .string("@e123")])["target"] as? String == "@e123",
            "shared target conversion should preserve validated references"
        )
        try expectThrows("shared target conversion should reject invalid references") {
            _ = try browserTargetArguments(["target": .string("#page-owned-selector")])
        }
        try requireSensitiveDiagnosticsAccess(
            if: true, environment: ["HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS": "1"]
        )
        try expectThrows("sensitive diagnostics should stay double-gated") {
            try requireSensitiveDiagnosticsAccess(if: true, environment: [:])
        }

        let minimumScroll = try CLIParser().parse([
            "scroll", "down", "--amount", String(ProtocolBounds.scrollAmount.lowerBound),
        ])
        try minimumScroll.request?.validate()
        try expectThrows("CLI should reject scroll amounts below the validator minimum") {
            _ = try CLIParser().parse(["scroll", "down", "--amount", "0.09"])
        }
        let maximumNetwork = try CLIParser().parse([
            "network", "emulate",
            "--latency", String(ProtocolBounds.networkLatencyMilliseconds.upperBound),
            "--download-kbps", String(ProtocolBounds.networkThroughputKbps.upperBound),
            "--upload-kbps", String(ProtocolBounds.networkThroughputKbps.lowerBound),
        ])
        try maximumNetwork.request?.validate()
        try expectThrows("CLI should reject latency above the validator maximum") {
            _ = try CLIParser().parse(["network", "emulate", "--latency", "120001"])
        }
        try expectThrows("CLI should reject throughput below the validator minimum") {
            _ = try CLIParser().parse(["network", "emulate", "--download-kbps", "-2"])
        }
    }

    static func docsCommandReferenceMatchesHelp() throws {
        let docPath = "docs/COMMANDS.md"
        guard let doc = try? String(contentsOfFile: docPath, encoding: .utf8) else {
            throw TestFailure(description: "missing \(docPath); run the suite from the apps/headless package root")
        }
        let helpLines = agentHelp.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = helpLines.firstIndex(of: "Commands:"),
              let end = helpLines.firstIndex(of: "Global options:"), start < end else {
            throw TestFailure(description: "agentHelp lost its Commands/Global options markers")
        }
        var checked = 0
        for line in helpLines[(start + 1)..<end] {
            let usage = line.trimmingCharacters(in: .whitespaces)
            if usage.isEmpty { continue }
            try expect(
                doc.contains(usage),
                "docs/COMMANDS.md should contain the agentHelp usage line: \(usage)"
            )
            checked += 1
        }
        try expect(checked >= 30, "expected to check every command line, checked \(checked)")
    }

    static func menuShortcutsHaveUniqueChords() throws {
        var seen: [String: String] = [:]
        var titles: [String: String] = [:]
        for spec in headlessMenuShortcuts {
            try expect(!spec.selector.isEmpty, "\(spec.title) is missing a selector")
            try expect(!spec.key.isEmpty, "\(spec.title) should not be in the keyed catalog without a chord")
            try expect(spec.selector.hasSuffix(":"), "\(spec.title) selector must be an ObjC action")
            if let previous = seen[spec.chordIdentity] {
                throw TestFailure(
                    description: "\(spec.title) collides with \(previous) on \(spec.chordIdentity)"
                )
            }
            seen[spec.chordIdentity] = spec.title
            if let previous = titles[spec.title] {
                throw TestFailure(description: "duplicate menu title \(spec.title) also used by \(previous)")
            }
            titles[spec.title] = spec.selector
        }
        let pin = headlessMenuShortcuts.first { $0.title == "Pin on Top" }
        try expect(pin?.key == "p" && pin?.command == true && pin?.option == true && pin?.shift == false,
                   "Pin on Top should be Cmd-Option-P, not Cmd-P")
        try expect(
            !headlessMenuShortcuts.contains { $0.key == "," },
            "Cmd-, is reserved for a future Settings window"
        )
        let snapshot = headlessMenuShortcuts.first { $0.title == "Save Snapshot to Desktop" }
        try expect(snapshot?.key == "s" && snapshot?.shift == true,
                   "snapshot capture should stay Cmd-Shift-S")
        let help = headlessMenuShortcuts.first { $0.title == "Headless Help" }
        try expect(help?.key == "/" && help?.shift == true,
                   "Headless Help should be Cmd-Shift-/")
        try expect(
            pin?.selector == "togglePin:" && pin?.target == .firstResponder,
            "Pin on Top must keep togglePin: on the first responder"
        )
        try expect(
            help?.selector == "showHelpPage:" && help?.target == .firstResponder,
            "Headless Help must keep showHelpPage: on the first responder"
        )
        let textEditingActions = [
            "Undo": "undo:", "Redo": "redo:", "Cut": "cut:", "Copy": "copy:",
            "Paste": "paste:", "Select All": "selectAll:",
        ]
        for (title, selector) in textEditingActions {
            let shortcut = headlessMenuShortcuts.first { $0.title == title }
            try expect(
                shortcut?.selector == selector && shortcut?.target == .firstResponder,
                "\(title) must target the active text responder"
            )
        }
        let fullScreen = headlessMenuShortcuts.first { $0.title == "Enter Full Screen" }
        try expect(
            fullScreen?.selector == "toggleFullScreen:" && fullScreen?.target == .firstResponder,
            "full screen must retain the standard responder-chain action"
        )
        let newWindow = headlessMenuShortcuts.first { $0.title == "New Window" }
        try expect(
            newWindow?.selector == "newWindow:" && newWindow?.target == .appDelegate,
            "New Window must target the app delegate"
        )
        let quit = headlessMenuShortcuts.first { $0.title == "Quit Headless" }
        try expect(
            quit?.selector == "terminate:" && quit?.target == .application,
            "Quit Headless must target NSApp"
        )
        let p0 = try String(contentsOfFile: "docs/P0.md", encoding: .utf8)
        try expect(
            p0.contains("Cmd-Option-P") && p0.contains("Cmd-Shift-S"),
            "P0 should document the Pin and snapshot chords"
        )
        let host = try String(contentsOfFile: "main.swift", encoding: .utf8)
        try expect(
            host.contains("&#8997;&#8984; P"),
            "start page should advertise Option-Command-P for pin"
        )
        try expect(
            !host.contains("<kbd>&#8984; P</kbd>"),
            "start page must not advertise Command-P for pin"
        )
        try expect(
            host.contains("NSSelectorFromString(spec.selector)"),
            "menu items must take their actions from the catalog"
        )
    }

    static func authenticationProtocolAndChallengeLifecycle() throws {
        let login = try CLIParser().parse([
            "--session", "work", "auth", "login", "--challenge",
            "53a0f495-7d21-42ae-a243-c1bc97af4630", "--account", "personal",
        ])
        try expect(login.request?.command == .authLogin, "auth login should parse as a remote command")
        try expect(login.request?.session == "work", "auth login should retain the browser session")
        try expect(
            login.request?.parameters["account"] == .string("personal"),
            "auth login should send only the alias"
        )
        try login.request?.validate()
        let interactive = try CLIParser().parse(["auth", "login", "--interactive"])
        try expect(
            interactive.request?.parameters == ["interactive": .bool(true)],
            "interactive auth must not put credentials or a synthetic challenge on the socket"
        )
        try interactive.request?.validate()
        try expectThrows("auth login should require a challenge") {
            _ = try CLIParser().parse(["auth", "login", "--account", "personal"])
        }
        try expectThrows("auth login should reject conflicting modes") {
            _ = try CLIParser().parse([
                "auth", "login", "--interactive", "--challenge",
                "53a0f495-7d21-42ae-a243-c1bc97af4630", "--account", "personal",
            ])
        }
        try expectThrows("auth login should reject invalid aliases") {
            _ = try CLIParser().parse([
                "auth", "login", "--challenge", "challenge", "--account", "not valid",
            ])
        }
        try expectThrows("auth login should reject unknown protocol parameters") {
            try CommandRequest(
                command: .authLogin,
                parameters: [
                    "challenge": .string("challenge"), "account": .string("personal"),
                    "password": .string("must-not-enter-the-protocol"),
                ]
            ).validate()
        }

        let origin = try CredentialOrigin(rawValue: "https://accounts.example.test")
        let form = try AuthenticationForm(.object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ]))
        let clock = TestMonotonicClock(10)
        let store = AuthenticationChallengeStore(now: { clock.now() })
        let challenge = store.issue(session: "work", form: form)
        _ = try store.begin(id: challenge.id, session: "work", currentForm: form)
        try expectSettingsErrorForAuthentication(
            .challengeConsumed, "concurrent challenge use must be rejected"
        ) {
            _ = try store.begin(id: challenge.id, session: "work", currentForm: form)
        }
        store.finish(id: challenge.id, consumed: false)
        _ = try store.begin(id: challenge.id, session: "work", currentForm: form)
        store.finish(id: challenge.id, consumed: true)
        try expectSettingsErrorForAuthentication(
            .challengeConsumed, "a completed challenge must remain single-use"
        ) {
            _ = try store.begin(id: challenge.id, session: "work", currentForm: form)
        }

        let expiring = store.issue(session: "work", form: form)
        _ = try store.begin(id: expiring.id, session: "work", currentForm: form)
        clock.advance(by: AuthenticationChallengeStore.lifetime + 1)
        try expectSettingsErrorForAuthentication(.challengeExpired, "expired challenge must fail") {
            _ = try store.validateActive(id: expiring.id, session: "work", currentForm: form)
        }
        let wrongOrigin = try AuthenticationForm(.object([
            "origin": .string("https://other.example.test"), "detection": .string("confirmed"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "passwordTarget": .string("@e2"),
        ]))
        let originBound = store.issue(session: "work", form: form)
        try expectSettingsErrorForAuthentication(.originChanged, "origin changes must invalidate use") {
            _ = try store.begin(id: originBound.id, session: "work", currentForm: wrongOrigin)
        }
        let reloadedForm = try AuthenticationForm(.object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("fedcba9876543210fedcba9876543210"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ]))
        let documentBound = store.issue(session: "work", form: form)
        try expectSettingsErrorForAuthentication(.formChanged, "same-origin reloads must invalidate use") {
            _ = try store.begin(id: documentBound.id, session: "work", currentForm: reloadedForm)
        }

        let credential = try AuthenticationCredential(
            account: "person@example.test", password: AuthenticationSecret(Array("frame-secret".utf8))
        )
        var frame = try AuthenticationCredentialFrame.encode(credential)
        defer { frame.resetBytes(in: 0..<frame.count) }
        let decoded = try AuthenticationCredentialFrame.decode(frame)
        defer { decoded.password.clear() }
        try expect(decoded.account == "person@example.test", "credential frame should preserve account")
        try expect(
            decoded.password.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == "frame-secret",
            "credential frame should preserve the secret only in protected memory"
        )
        try expectSettingsErrorForAuthentication(
            .invalidBrokerResponse, "truncated credential frames must fail closed"
        ) {
            _ = try AuthenticationCredentialFrame.decode(Data(frame.dropLast()))
        }
    }

    static func ephemeralAuthenticationBrokerLifecycle() throws {
        let broker = EphemeralAuthenticationBroker()
        let origin = try CredentialOrigin(rawValue: "https://accounts.example.test")
        let otherOrigin = try CredentialOrigin(rawValue: "https://other.example.test")
        let alias = try CredentialAlias(rawValue: "private")
        let credential = try AuthenticationCredential(
            account: "private@example.test",
            password: AuthenticationSecret(Array("ephemeral-secret".utf8))
        )
        try broker.store(credential, for: origin, alias: alias)
        credential.password.clear()

        let aliases = try broker.aliases(for: origin)
        try expect(aliases.count == 1, "ephemeral broker should list its exact-origin alias")
        try expect(try broker.aliases(for: otherOrigin).isEmpty, "aliases must not cross origins")
        let resolved = try broker.credential(for: origin, alias: alias)
        defer { resolved.password.clear() }
        try expect(
            resolved.password.withUnsafeBytes { Array($0) } == Array("ephemeral-secret".utf8),
            "ephemeral broker should return a copied secret"
        )
        let duplicate = try AuthenticationCredential(
            account: "other@example.test",
            password: AuthenticationSecret(Array("other-secret".utf8))
        )
        defer { duplicate.password.clear() }
        try expectSettingsErrorForAuthentication(
            .credentialAliasExists, "ephemeral aliases must be case-insensitively unique"
        ) {
            try broker.store(
                duplicate, for: origin, alias: CredentialAlias(rawValue: "PRIVATE")
            )
        }
        broker.removeAll()
        try expectSettingsErrorForAuthentication(
            .accountNotFound, "clearing an ephemeral broker must destroy its records"
        ) {
            _ = try broker.credential(for: origin, alias: alias)
        }
    }

    static func hostAuthenticationOrchestration() throws {
        let root = "/tmp/headless-auth-core-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = try CredentialOrigin(rawValue: "https://accounts.example.test")
        let alias = try CredentialAlias(rawValue: "personal")
        let broker = TestAuthenticationBroker(
            origin: origin, alias: alias, account: "person@example.test", password: "not-in-output"
        )
        let session = TestBrowserSession()
        session.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        session.authenticationStateAfterCredentialFill = .object([
            "origin": .string("https://app.example.test"), "detection": .string("none"),
        ])
        let core = HostCore(
            engine: TestBrowserEngine(),
            artifacts: try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root]),
            defaultSession: session,
            authenticationBroker: broker,
            shutdownHandler: {}
        )
        defer { core.stop() }
        let blocked = core.handle(CommandRequest(
            command: .inspect, parameters: ["interactive": .bool(true)]
        ))
        try expect(blocked.error?.code == "AUTH_REQUIRED", "confirmed login form should create a challenge")
        guard case .object(let details)? = blocked.error?.details,
              let challenge = details["challenge"]?.stringValue,
              case .array(let accounts)? = details["accounts"] else {
            throw TestFailure(description: "AUTH_REQUIRED should include structured challenge details")
        }
        try expect(accounts.count == 1, "only exact-origin aliases should be returned")
        try expect(details["untrustedContent"] == .bool(true), "page-derived auth metadata must be marked untrusted")
        let encodedBlocked = String(
            decoding: try ProtocolCodec.encoder.encode(blocked), as: UTF8.self
        )
        try expect(!encodedBlocked.contains("not-in-output"), "challenge responses must not expose passwords")

        let unknownAlias = core.handle(CommandRequest(
            command: .authLogin,
            parameters: ["challenge": .string(challenge), "account": .string("missing")]
        ))
        try expect(
            unknownAlias.error?.code == "AUTH_ACCOUNT_NOT_FOUND",
            "an unknown alias should fail without consuming the challenge"
        )
        try expect(session.filledCredentialAccount == nil, "an unknown alias must not fill the form")

        broker.credentialError = .userPresenceDenied
        let denied = core.handle(CommandRequest(
            command: .authLogin,
            parameters: ["challenge": .string(challenge), "account": .string(alias.rawValue)]
        ))
        try expect(
            denied.error?.code == "USER_PRESENCE_DENIED",
            "user-presence denial should be explicit and fail closed"
        )
        try expect(session.filledCredentialAccount == nil, "denial must not fill the form")
        broker.credentialError = nil

        let login = core.handle(CommandRequest(
            command: .authLogin,
            parameters: ["challenge": .string(challenge), "account": .string(alias.rawValue)]
        ))
        guard login.ok, case .object(let result) = login.result else {
            throw TestFailure(description: "saved alias login should succeed")
        }
        try expect(result["continuation"] == .string("redirected"), "login should report a verified redirect")
        try expect(result["originalActionReplayed"] == .bool(false), "login must not replay the blocked action")
        try expect(session.filledCredentialAccount == "person@example.test", "host should fill the selected account")
        let encodedLogin = String(decoding: try ProtocolCodec.encoder.encode(login), as: UTF8.self)
        try expect(!encodedLogin.contains("not-in-output"), "login output must not expose passwords")

        let replay = core.handle(CommandRequest(
            command: .authLogin,
            parameters: ["challenge": .string(challenge), "account": .string(alias.rawValue)]
        ))
        try expect(replay.error?.code == "AUTH_CHALLENGE_CONSUMED", "challenge replay must fail")

        session.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("fedcba9876543210fedcba9876543210"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        session.authenticationStateAfterCredentialFill = .object([
            "origin": .string(origin.rawValue), "detection": .string("none"),
        ])
        session.saveAlias = nil
        let declinedSave = core.handle(CommandRequest(
            command: .authLogin, parameters: ["interactive": .bool(true)]
        ))
        guard declinedSave.ok, case .object(let declinedResult) = declinedSave.result else {
            throw TestFailure(description: "interactive login with declined save should succeed")
        }
        try expect(declinedResult["continuation"] == .string("authenticated"), "removed form should verify login")
        try expect(declinedResult["saved"] == .bool(false), "save must default to declined")
        try expect(broker.storedAlias == nil, "declining save must not write the vault")

        session.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("abcdef0123456789abcdef0123456789"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        session.saveAlias = try CredentialAlias(rawValue: "interactive")
        let saved = core.handle(CommandRequest(
            command: .authLogin, parameters: ["interactive": .bool(true)]
        ))
        guard saved.ok, case .object(let savedResult) = saved.result else {
            throw TestFailure(description: "interactive login and save should succeed")
        }
        try expect(savedResult["saved"] == .bool(true), "explicit consent should save")
        try expect(broker.storedAlias?.rawValue == "interactive", "save should retain the chosen alias")
        try expect(broker.storedAccount == session.promptedAccount, "save should retain the entered account")
        try expect(broker.storedPassword == Array(session.promptedPassword.utf8), "save should retain the entered secret")

        let privateSession = TestBrowserSession(isolated: true)
        privateSession.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        let privateBroker = TestAuthenticationBroker(
            origin: origin, alias: alias, account: "private@example.test", password: "never-read"
        )
        let privateCore = HostCore(
            engine: TestBrowserEngine(),
            artifacts: try ArtifactStore(environment: [
                "HEADLESS_ARTIFACT_DIR": root + "-private",
            ]),
            defaultSession: privateSession,
            authenticationBroker: privateBroker,
            shutdownHandler: {}
        )
        defer {
            privateCore.stop()
            try? FileManager.default.removeItem(atPath: root + "-private")
        }
        let privateBlocked = privateCore.handle(CommandRequest(
            command: .inspect, parameters: ["interactive": .bool(true)]
        ))
        guard case .object(let privateDetails)? = privateBlocked.error?.details,
              let privateChallenge = privateDetails["challenge"]?.stringValue,
              case .array(let privateAccounts)? = privateDetails["accounts"] else {
            throw TestFailure(description: "isolated AUTH_REQUIRED should include structured details")
        }
        try expect(privateAccounts.isEmpty, "isolated challenges must not list normal-vault aliases")
        try expect(
            privateDetails["vaultStatus"] == .string("private-ephemeral"),
            "isolated challenges should disclose the ephemeral vault"
        )
        try expect(privateBroker.aliasLookupCount == 0, "isolated challenges must not query the normal broker")
        let privateLogin = privateCore.handle(CommandRequest(
            command: .authLogin,
            parameters: [
                "challenge": .string(privateChallenge), "account": .string(alias.rawValue),
            ]
        ))
        try expect(
            privateLogin.error?.code == "AUTH_ACCOUNT_NOT_FOUND",
            "unknown private aliases should fail closed"
        )
        try expect(privateBroker.credentialLookupCount == 0, "isolated login must not retrieve a normal secret")
        try expect(privateSession.filledCredentialAccount == nil, "isolated login must not fill a credential")

        privateSession.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("abcdef0123456789abcdef0123456789"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        privateSession.authenticationStateAfterCredentialFill = .object([
            "origin": .string(origin.rawValue), "detection": .string("none"),
        ])
        privateSession.saveAlias = try CredentialAlias(rawValue: "private")
        let privateEnrollment = privateCore.handle(CommandRequest(
            command: .authLogin, parameters: ["interactive": .bool(true)]
        ))
        try expect(privateEnrollment.ok, "private interactive enrollment should succeed")
        try expect(privateBroker.storedAlias == nil, "private save must not reach the normal broker")

        privateSession.authenticationState = .object([
            "origin": .string(origin.rawValue), "detection": .string("confirmed"),
            "document": .string("11111111111111111111111111111111"),
            "accountTarget": .string("@e1"), "passwordTarget": .string("@e2"),
            "submitTarget": .string("@e3"),
        ])
        let privateListed = privateCore.handle(CommandRequest(
            command: .inspect, parameters: ["interactive": .bool(true)]
        ))
        guard case .object(let listedDetails)? = privateListed.error?.details,
              let listedChallenge = listedDetails["challenge"]?.stringValue,
              case .array(let listedAccounts)? = listedDetails["accounts"] else {
            throw TestFailure(description: "private aliases should be listed in a new challenge")
        }
        try expect(listedAccounts.count == 1, "private challenge should list only its ephemeral alias")
        let privateAliasLogin = privateCore.handle(CommandRequest(
            command: .authLogin,
            parameters: [
                "challenge": .string(listedChallenge), "account": .string("private"),
            ]
        ))
        try expect(privateAliasLogin.ok, "private alias should remain usable in its context")
        try expect(privateBroker.credentialLookupCount == 0, "private alias use must not reach the normal broker")
    }

    static func sharedHostCoreDispatch() throws {
        let root = "/tmp/headless-host-core-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let defaultSession = TestBrowserSession()
        let engine = TestBrowserEngine()
        let core = HostCore(
            engine: engine,
            artifacts: try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root]),
            defaultSession: defaultSession,
            shutdownHandler: {}
        )
        defer { core.stop() }

        let ping = core.handle(CommandRequest(command: .ping))
        guard ping.ok, case .object(let pingResult) = ping.result else {
            throw TestFailure(description: "shared host ping should succeed")
        }
        try expect(pingResult["engine"] == .string("fake"), "ping should identify the engine")
        try expect(pingResult["platform"] == .string("test"), "ping should identify the platform")
        try expect(pingResult["productVersion"] == .string(headlessProductVersion), "ping should identify the product version")
        try expect(pingResult["adapter"] == .string("test-adapter"), "engine ping details should be merged")
        try expect(pingResult["capabilities"] != nil, "ping should publish the active engine profile")
        try expect(
            pingResult["navigationAllowlist"] == .array([]),
            "unrestricted ping should report an empty navigation allowlist"
        )

        let cleared = core.handle(CommandRequest(command: .profileClear))
        try expect(cleared.ok, "shared profile clear should succeed")
        try expect(engine.profileClearCount == 1, "profile clear should delegate to the engine")
        try expect(engine.closedSessions.count == 1, "profile clear should close the existing default session")
        try expect(engine.createdSessions.count == 1, "profile clear should create a clean default session")

        let created = core.handle(CommandRequest(
            command: .sessionCreate, parameters: ["name": .string("secondary")]
        ))
        try expect(created.ok, "shared session creation should succeed")
        try expect(engine.createdSessions.count == 2, "session creation should delegate to the engine")

        let isolated = core.handle(CommandRequest(
            command: .sessionCreate,
            parameters: ["name": .string("private"), "isolated": .bool(true)]
        ))
        guard isolated.ok, case .object(let isolatedResult) = isolated.result else {
            throw TestFailure(description: "isolated session creation should succeed")
        }
        try expect(isolatedResult["isolated"] == .bool(true), "session result should report isolation")
        try expect(engine.createdSessions.count == 3, "isolated creation should delegate to the engine")
        try expect(engine.createdSessions[2].hostIsolated, "engine should create an isolated session")
        let listed = core.handle(CommandRequest(command: .sessionList))
        guard listed.ok, case .object(let listedResult) = listed.result,
              case .array(let details)? = listedResult["details"] else {
            throw TestFailure(description: "session list should include typed details")
        }
        try expect(
            details.contains(.object(["name": .string("private"), "isolated": .bool(true)])),
            "session list should identify isolated sessions"
        )

        let inspected = core.handle(CommandRequest(
            command: .inspect, session: "secondary", parameters: ["interactive": .bool(true)]
        ))
        guard inspected.ok, case .object(let inspectResult) = inspected.result else {
            throw TestFailure(description: "shared inspect dispatch should succeed")
        }
        try expect(inspectResult["engineResult"] == .bool(true), "inspect should delegate to the session")
        try expect(
            engine.createdSessions[1].agentControlEnableCount == 2,
            "agent control should be enabled at creation and before command execution"
        )

        let capture = core.handle(CommandRequest(command: .captureInfo, session: "secondary"))
        guard capture.ok, case .object(let captureResult) = capture.result else {
            throw TestFailure(description: "shared capture info should succeed")
        }
        try expect(captureResult["engine"] == .string("fake"), "capture info should retain engine fields")
        try expect(captureResult["trace"] != nil, "capture info should include the shared trace")
        try expect(captureResult["recording"] != nil, "capture info should include recording state")

        let unsupported = core.handle(CommandRequest(command: .networkEmulate, session: "secondary"))
        try expect(
            unsupported.error?.code == "UNSUPPORTED_CAPABILITY",
            "unsupported engine features should return a typed capability error"
        )

        let closed = core.handle(CommandRequest(command: .sessionClose, session: "secondary"))
        try expect(closed.ok, "shared session close should succeed")
        try expect(engine.closedSessions.count == 2, "session close should delegate to the engine")
        let privateClosed = core.handle(CommandRequest(command: .sessionClose, session: "private"))
        try expect(privateClosed.ok, "isolated session close should succeed")
        try expect(engine.closedSessions.count == 3, "isolated close should delegate to the engine")
        let missing = core.handle(CommandRequest(command: .inspect, session: "secondary"))
        try expect(missing.error?.code == "SESSION_NOT_FOUND", "closed sessions should be removed from shared state")
    }

    static func artifactUploadCommands() throws {
        let semantic = try CLIParser().parse([
            "upload", "--role", "textbox", "--name", "Resume", "--artifact", "resume.pdf",
        ])
        try expect(semantic.request?.command == .upload, "semantic upload should parse")
        try expect(semantic.request?.parameters["artifact"] == .string("resume.pdf"), "upload artifact should parse")
        try expect(semantic.request?.parameters["role"] == .string("textbox"), "upload role should parse")
        try expect(semantic.request?.parameters["name"] == .string("Resume"), "upload name should parse")

        let targeted = try CLIParser().parse(["upload", "@e12", "--artifact", "resume.pdf"])
        try expect(targeted.request?.parameters["target"] == .string("@e12"), "upload ref should parse")
        try expect(targeted.request?.parameters["artifact"] == .string("resume.pdf"), "upload artifact with ref should parse")

        try expectThrows("upload without a target should fail in the CLI") {
            _ = try CLIParser().parse(["upload", "--artifact", "resume.pdf"])
        }
        try expectThrows("upload without --artifact should fail in the CLI") {
            _ = try CLIParser().parse(["upload", "@e12"])
        }
        try expectThrows("CLI must not expose local-file ingest") {
            _ = try CLIParser().parse(["artifacts", "add", "/etc/passwd", "--name", "resume.txt"])
        }

        try expectThrows("raw artifact.add protocol requests must be rejected as unknown") {
            _ = try ProtocolCodec.decodeLine(
                CommandRequest.self,
                from: Data(#"{"id":"request-1","version":"0.5","command":"artifact.add","parameters":{"source":"/tmp/resume.pdf","name":"resume.pdf"}}"#.utf8)
            )
        }
        try CommandRequest(
            command: .upload,
            parameters: ["target": .string("@e12"), "artifact": .string("resume.pdf")]
        ).validate()
        for name in ["payload.exe", "page.html", "image.svg", "../escape.pdf"] {
            try expectThrows("upload should reject \(name)") {
                try CommandRequest(
                    command: .upload,
                    parameters: ["target": .string("@e1"), "artifact": .string(name)]
                ).validate()
            }
        }
        try expectThrows("upload without a target should fail validation") {
            try CommandRequest(
                command: .upload,
                parameters: ["artifact": .string("resume.pdf")]
            ).validate()
        }
        try expectThrows("unknown upload parameters should be rejected") {
            try CommandRequest(
                command: .upload,
                parameters: ["target": .string("@e1"), "artifact": .string("resume.pdf"), "path": .string("/tmp/resume.pdf")]
            ).validate()
        }

        let root = "/tmp/headless-upload-artifact-\(UUID().uuidString)"
        let outsideArtifact = root + "-outside.png"
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideArtifact)
        }
        let store = try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root])
        let added = try store.write(
            tinyPNG, requestedName: "tiny.png", extension: "png", prefix: "test"
        )
        guard case .object(let addedMetadata) = added else {
            throw TestFailure(description: "artifact metadata")
        }
        try expect(addedMetadata["name"] == .string("tiny.png"), "write should return the artifact name")
        try expect(addedMetadata["kind"] == .string("png"), "write should report the file kind")
        let pngMode = (try FileManager.default.attributesOfItem(atPath: root + "/tiny.png")[.posixPermissions] as? NSNumber)?.intValue
        try expect(pngMode == 0o600, "stored upload artifact should be private")

        _ = try store.write(
            Data("hello".utf8), requestedName: "notes.txt", extension: "txt", prefix: "test"
        )
        guard case .object(let listing) = try store.list(),
              case .array(let artifacts)? = listing["artifacts"] else {
            throw TestFailure(description: "upload artifact listing")
        }
        let listedNames = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value else { return nil }
            return object["name"]?.stringValue
        }
        try expect(listedNames.contains("tiny.png"), "listing should include stored png")
        try expect(listedNames.contains("notes.txt"), "listing should include stored txt")
        let resolvedURL = try store.urlForExistingArtifact(name: "tiny.png")
        try expect(
            resolvedURL.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path,
            "resolved upload artifacts must stay inside the store"
        )
        try expectThrows("missing stored artifact should fail") {
            _ = try store.urlForExistingArtifact(name: "absent.pdf")
        }
        try tinyPNG.write(to: URL(fileURLWithPath: outsideArtifact))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/linked.png", withDestinationPath: outsideArtifact
        )
        try expectThrows("symlinked upload artifacts must not escape the store") {
            _ = try store.urlForExistingArtifact(name: "linked.png")
        }

        let session = TestBrowserSession()
        let engine = TestBrowserEngine()
        let core = HostCore(
            engine: engine,
            artifacts: try ArtifactStore(environment: ["HEADLESS_ARTIFACT_DIR": root]),
            defaultSession: session,
            shutdownHandler: {}
        )
        defer { core.stop() }

        try expect(session.agentControlEnableCount == 0, "artifact resolution must not enable page control")
        let uploaded = core.handle(CommandRequest(
            command: .upload,
            parameters: ["target": .string("@e1"), "artifact": .string("tiny.png")]
        ))
        try expect(uploaded.ok, "HostCore upload should resolve a stored artifact")
        try expect(session.lastUploadPath == root + "/tiny.png" || session.lastUploadPath == URL(fileURLWithPath: root + "/tiny.png").path, "engine must receive the store path, not the source path")
        let encoded = String(decoding: try ProtocolCodec.encoder.encode(uploaded), as: UTF8.self)
        try expect(!encoded.contains(root), "upload responses must not include the store path")
        try expect(!encoded.contains("\"path\""), "upload responses must not include a filesystem path")
        try expect(encoded.contains("tiny.png"), "upload responses should name the artifact")

        let missingUpload = core.handle(CommandRequest(
            command: .upload,
            parameters: ["target": .string("@e1"), "artifact": .string("absent.pdf")]
        ))
        try expect(missingUpload.error?.code == "ARTIFACT_ERROR", "missing upload artifacts should fail specifically")
    }

    static func main() {
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--supervised-owner-child" {
            let stopped = DispatchSemaphore(value: 0)
            guard let monitor = SupervisedHostOwnerMonitor.startIfRequested(onOwnerExit: {
                print("owner-closed")
                fflush(stdout)
                stopped.signal()
            }) else {
                fputs("supervision was not enabled\n", stderr)
                exit(1)
            }
            stopped.wait()
            monitor.stop()
            exit(0)
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--peer-denied-client" {
            do {
                let descriptor = try connectRawUnixSocket(path: CommandLine.arguments[2])
                defer { closeRawSocket(descriptor) }
                let response = try ProtocolCodec.decodeLine(
                    CommandResponse.self, from: readRawSocketLine(descriptor: descriptor)
                )
                guard response.error?.code == "PEER_DENIED" else {
                    fputs("expected PEER_DENIED\n", stderr)
                    exit(1)
                }
                exit(0)
            } catch {
                fputs("peer client failed: \(error)\n", stderr)
                exit(1)
            }
        }
        let tests: [TestCase] = [
            ("request round-trip", requestRoundTrip),
            ("unsafe navigation schemes", rejectsUnsafeNavigationSchemes),
            ("localhost normalization", normalizesLocalhostToHTTP),
            ("page navigation boundary", pageNavigationBoundary),
            ("navigation allowlist", navigationAllowlist),
            ("message size limit", messageSizeLimit),
            ("identifier validation", identifierValidation),
            ("durable browser profile lifecycle", durableBrowserProfileLifecycle),
            ("command parameter validation", commandParameterValidation),
            ("strict request fields", rejectsUnexpectedRequestFields),
            ("CLI visit", cliVisit),
            ("CLI fill literal value", cliFillPreservesLiteralValue),
            ("CLI semantic click", cliSemanticClick),
            ("CLI inspect context and task", cliInspectContextAndTask),
            ("CLI conflicting target", cliRejectsConflictingClickTarget),
            ("CLI settled wait", cliWaitDefaultsToSettled),
            ("CLI timeout bound", cliRejectsUnboundedTimeout),
            ("client timeout parity", clientTimeoutsMatchCommandBounds),
            ("CLI P1 artifacts", cliP1Artifacts),
            ("CLI P2 commands and boundaries", cliP2CommandsAndBoundaries),
            ("CLI command matrix", cliCommandMatrix),
            ("config CLI commands and arity", configCLICommandsAndArity),
            ("settings registry and access", settingsRegistryAndAccess),
            ("UserDefaults settings compatibility", userDefaultsSettingsCompatibility),
            ("file settings backend security and persistence", fileSettingsBackendSecurityAndPersistence),
            ("file settings backend concurrent writers", fileSettingsBackendConcurrentWriters),
            ("credential command security", credentialCommandSecurity),
            ("credential vault lifecycle", credentialVaultLifecycle),
            ("credential confirmation", credentialVaultRejectsMismatchedConfirmation),
            ("credential metadata rollback", credentialVaultRollsBackFailedMetadataCommit),
            ("credential transaction recovery", credentialVaultRecoversInterruptedTransactions),
            ("Chromium runtime selection", chromiumRuntimeSelection),
            ("artifact store round-trip", artifactStoreRoundTrip),
            ("artifact read boundaries", artifactReadsStayInsideBounds),
            ("flow recording safety", flowRecordingOmitsSensitiveCommands),
            ("visual comparison", visualComparisonInvokesBoundedTool),
            ("recording arguments and bounds", recordingArgumentsAndFailureBounds),
            ("capabilities match commands", capabilitiesMatchProtocolCommands),
            ("SDK protocol schema contract", sdkProtocolSchemaContract),
            ("SDK protocol fixtures", sdkProtocolFixtures),
            ("supervised host owner pipe", supervisedHostOwnerPipe),
            ("screenshot series helpers", screenshotSeriesHelpers),
            ("diagnostic summary", diagnosticSummary),
            ("diagnostic bounds and URL redaction", diagnosticsBoundAndRedacted),
            ("responses fit the protocol frame", responsesFitTheProtocolFrame),
            ("artifact listing stays bounded", artifactListingStaysBounded),
            ("diagnostic services", diagnosticServices),
            ("diagnostic CLI", diagnosticCLI),
            ("local socket round-trip", localSocketRoundTrip),
            ("response identifier correlation", rejectsMismatchedResponseIdentifier),
            ("live socket replacement protection", liveSocketCannotBeReplaced),
            ("private socket directory", serverRejectsSocketOutsidePrivateDirectory),
            ("shutdown bypasses busy request", shutdownBypassesBusyRequest),
            ("oversized socket request", oversizedSocketRequestIsRejected),
            ("different peer uid", differentPeerUserIsRejected),
            ("incremental NUL message buffering", nullTerminatedBufferScansIncrementally),
            ("typed host errors", typedHostErrorsRoundTrip),
            ("single-source contract constants", singleSourceContractConstants),
            ("shared host core dispatch", sharedHostCoreDispatch),
            ("authentication protocol and challenge lifecycle", authenticationProtocolAndChallengeLifecycle),
            ("ephemeral authentication broker lifecycle", ephemeralAuthenticationBrokerLifecycle),
            ("host authentication orchestration", hostAuthenticationOrchestration),
            ("docs command reference matches help", docsCommandReferenceMatchesHelp),
            ("menu shortcuts have unique chords", menuShortcutsHaveUniqueChords),
            ("artifact file upload boundaries", artifactUploadCommands),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures += 1
                fputs("✗ \(name): \(error)\n", stderr)
            }
        }
        print("\(tests.count - failures)/\(tests.count) protocol tests passed")
        if failures > 0 { exit(1) }
    }
}
