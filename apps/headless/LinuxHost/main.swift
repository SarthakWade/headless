import HeadlessProtocol
import Foundation
#if canImport(Glibc)
import Glibc
#endif

final class ChromiumBrowserEngine: BrowserEngine {
    typealias Session = ChromiumBrowserEngineSession

    let name = "chromium"
    let platform = "linux"
    let capabilities = BrowserEngineCapabilities.chromium
    private let profile: DurableBrowserProfile
    private(set) var browser: ChromiumProcess

    init() throws {
        profile = try DurableBrowserProfile()
        browser = try ChromiumProcess(profileURL: profile.directoryURL)
    }

    func createSession() throws -> ChromiumBrowserEngineSession {
        ChromiumBrowserEngineSession(engine: self, browserSession: try browser.createSession())
    }

    func createIsolatedSession() throws -> ChromiumBrowserEngineSession {
        ChromiumBrowserEngineSession(engine: self, browserSession: try browser.createSession(isolated: true))
    }

    func closeSession(_ session: ChromiumBrowserEngineSession) {
        browser.closeSession(session.browserSession)
    }

    func stop() { browser.stop() }

    func clearProfile() throws {
        browser.stop()
        do {
            try profile.clear()
            browser = try ChromiumProcess(profileURL: profile.directoryURL)
        } catch {
            if let replacement = try? ChromiumProcess(profileURL: profile.directoryURL) {
                browser = replacement
            }
            throw error
        }
    }

    func pingDetails() -> [String: JSONValue] {
        [
            "browserExecutable": .string(browser.runtime.executableURL.path),
            "browserRuntimeSource": .string(browser.runtime.source.rawValue),
            "browserTransport": .string("inherited-devtools-pipe"),
            "profilePersistence": .string("durable"),
            "profileMigration": .string(profile.migration.rawValue),
        ]
    }

    func hostError(for error: Error) -> HostError? {
        guard let error = error as? CDPError else { return nil }
        switch error {
        case .timedOut:
            return HostError(code: .timedOut, message: error.description)
        default:
            return HostError(code: .operationFailed, message: error.description)
        }
    }
}

final class ChromiumBrowserEngineSession: BrowserEngineSession {
    unowned let engine: ChromiumBrowserEngine
    let browserSession: LinuxBrowserSession

    init(engine: ChromiumBrowserEngine, browserSession: LinuxBrowserSession) {
        self.engine = engine
        self.browserSession = browserSession
    }

    var hostIsolated: Bool { browserSession.isIsolated }

    func hostVisit(_ url: URL) throws -> JSONValue { try browserSession.visit(url) }
    func hostInspect(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.inspect(parameters: parameters)
    }
    func hostClick(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.click(parameters: parameters)
    }
    func hostFill(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.fill(parameters: parameters)
    }
    func hostUpload(parameters: [String: JSONValue], artifactURL: URL) throws -> JSONValue {
        try browserSession.upload(parameters: parameters, artifactURL: artifactURL)
    }
    func hostPress(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.press(parameters: parameters)
    }
    func hostScroll(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.scroll(parameters: parameters)
    }
    func hostWait(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.wait(parameters: parameters)
    }
    func hostTour(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.tour(parameters: parameters)
    }
    func hostBack() throws -> JSONValue { try browserSession.back() }
    func hostReload() throws -> JSONValue { try browserSession.reload() }
    func hostCaptureInfo() throws -> JSONValue {
        .object([
            "engine": .string("chromium"),
            "headless": .bool(engine.browser.headless),
            "browserPid": .number(Double(engine.browser.processIdentifier)),
            "browserExecutable": .string(engine.browser.runtime.executableURL.path),
            "browserRuntimeSource": .string(engine.browser.runtime.source.rawValue),
            "browserTransport": .string("inherited-devtools-pipe"),
            "targetId": .string(browserSession.targetID),
            "page": try browserSession.state(),
        ])
    }
    func hostScreenshot(
        parameters: [String: JSONValue], format: ScreenshotFormat, copyToClipboard: Bool
    ) throws -> BrowserScreenshot {
        if copyToClipboard {
            throw HostError(
                code: .unsupportedCapability,
                message: "Clipboard screenshots are only supported by the macOS WebKit engine."
            )
        }
        return BrowserScreenshot(data: try browserSession.screenshot(parameters: parameters, format: format))
    }
    func hostRecordingFrame() throws -> Data { try browserSession.recordingFrame() }
    func hostScreenshotSeriesPlan(mode: String) throws -> JSONValue {
        try browserSession.screenshotSeriesPlan(mode: mode)
    }
    func hostScrollToCapturePoint(y: Double) throws -> JSONValue {
        try browserSession.scrollToCapturePoint(y: y)
    }
    func hostQAReport() throws -> JSONValue { try browserSession.qaReport() }
    func hostQAClear() throws -> JSONValue { browserSession.diagnostics.clear() }
    func hostConsole(level: String, limit: Int) throws -> JSONValue {
        browserSession.console(level: level, limit: limit)
    }
    func hostNetwork(failedOnly: Bool, status: Int?, limit: Int) throws -> JSONValue {
        browserSession.network(failedOnly: failedOnly, status: status, limit: limit)
    }
    func hostNetworkDetail(requestID: String) throws -> JSONValue {
        browserSession.networkDetail(requestID: requestID)
    }
    func hostStyles(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.styles(parameters: parameters)
    }
    func hostCookies(includeValues: Bool) throws -> JSONValue {
        try browserSession.cookies(includeValues: includeValues)
    }
    func hostStorage(scope: String, includeValues: Bool) throws -> JSONValue {
        try browserSession.storage(scope: scope, includeValues: includeValues)
    }
    func hostPerformance() throws -> JSONValue { try browserSession.performance() }
    func hostAnimations() throws -> JSONValue { try browserSession.animations() }
    func hostEmulateNetwork(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.emulateNetwork(parameters: parameters)
    }
    func hostSetNetworkMock(parameters: [String: JSONValue]) throws -> JSONValue {
        try browserSession.setNetworkMock(parameters: parameters)
    }
    func hostClearNetworkMocks() throws -> JSONValue { try browserSession.clearNetworkMocks() }
    func hostAuthenticationState() throws -> JSONValue { try browserSession.authenticationState() }
}

do {
    #if canImport(Glibc)
    signal(SIGPIPE, SIG_IGN)
    #endif
    let navigationAllowlist = try NavigationAllowlist(environment: ProcessInfo.processInfo.environment)
    let engine = try ChromiumBrowserEngine()
    let artifacts = try ArtifactStore()
    let stopped = DispatchSemaphore(value: 0)
    let authenticationBroker: any AuthenticationBroker
    if let broker = try? CredentialBrokerProcessClient() {
        authenticationBroker = broker
    } else {
        authenticationBroker = UnavailableAuthenticationBroker()
    }
    let core = HostCore(
        engine: engine,
        artifacts: artifacts,
        defaultSession: try engine.createSession(),
        authenticationBroker: authenticationBroker,
        navigationAllowlist: navigationAllowlist,
        shutdownHandler: { stopped.signal() }
    )
    let server = LocalSocketServer()
    try server.start { request in core.handle(request) }
    let ownerMonitor = SupervisedHostOwnerMonitor.startIfRequested {
        stopped.signal()
    }

    #if canImport(Glibc)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    term.setEventHandler { stopped.signal() }
    interrupt.setEventHandler { stopped.signal() }
    term.resume()
    interrupt.resume()
    #endif

    stopped.wait()
    ownerMonitor?.stop()
    server.stop()
    core.stop()
} catch {
    fputs("headless-host: \(error)\n", stderr)
    exit(70)
}
