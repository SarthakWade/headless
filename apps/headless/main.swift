// headless — the browser that isn't there.
//
// A single-file macOS browser with zero chrome: no tabs, no toolbar, no
// address bar — just the page, in a bare rounded window. Built on WKWebView
// (the Safari engine). Made for clean screenshots and fullscreen video.
//
//   ⌘L  search / open url        ⇧⌘S  snapshot page → Desktop
//   ⌘R  reload                   ⌥⌘P  pin window on top
//   ⌘[ ⌘]  back / forward        ⌃⌘F  fullscreen
//   ⌘= ⌘- ⌘0  zoom               ⌘drag  move the window
//
// CLI screenshot mode:
//   headless https://example.com --snap out.png --size 1440x900 --wait 2

import Cocoa
import HeadlessProtocol
import Security
import WebKit

let normalWebsiteDataStore: WKWebsiteDataStore = {
    if let rawIdentifier = ProcessInfo.processInfo.environment["HEADLESS_E2E_DATA_STORE_ID"] {
        guard let identifier = UUID(uuidString: rawIdentifier) else {
            fputs("headless: invalid E2E website data store identifier\n", stderr)
            exit(64)
        }
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
        fputs("headless: isolated E2E website data stores require macOS 14 or newer\n", stderr)
        exit(69)
    }
    return .default()
}()

// MARK: - Passkey capability

// WKWebView performs WebAuthn (passkeys via iCloud Keychain / Touch ID) only for
// apps signed with Apple's restricted web-browser.public-key-credential
// entitlement, which needs an Apple-issued provisioning profile — macOS kills
// ad-hoc builds that claim it. So: if this build carries the entitlement,
// passkeys just work; if not, hide the WebAuthn API so sites feature-detect the
// absence and offer their fallback sign-in (password, phone prompt) instead of
// a passkey ceremony that is guaranteed to fail. See README for enabling it.
let hasPasskeyEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
}()

/// The CLI starts the app in this mode. It must never inherit a manually
/// browsed page (including a local file) into the agent's default session.
let isAgentHost = ProcessInfo.processInfo.environment["HEADLESS_AGENT_HOST"] == "1"

private enum WindowPresentation {
    case foreground
    case background
}

private let agentWindowPresentation: WindowPresentation =
    isAgentHost && ProcessInfo.processInfo.environment["HEADLESS_START_FOREGROUND"] != "1"
        ? .background
        : .foreground

// MARK: - URL smarts

func smartURL(_ input: String) -> URL? {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if t.hasPrefix("/") || t.hasPrefix("~") {
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    }
    if t.contains("://") { return URL(string: t) }
    let lower = t.lowercased()
    if isLocalDevelopmentAddress(lower) { return URL(string: "http://" + t) }
    if !t.contains(" "), t.contains(".") { return URL(string: "https://" + t) }
    let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
    return URL(string: "https://www.google.com/search?q=" + q)
}

// MARK: - Launch options

struct SnapJob { let path: String; let wait: TimeInterval }

struct LaunchOptions {
    var url: URL? = nil
    var snap: SnapJob? = nil
    var size: NSSize? = nil
}

func parseLaunchOptions() -> LaunchOptions {
    var opts = LaunchOptions()
    var snapPath: String? = nil
    var wait: TimeInterval = 1.0
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--help", "-h":
            print("""
            headless — the browser that isn't there

            usage: headless [url] [options]
              --snap <path>     load the page, save a PNG of it, and quit
              --size <WxH>      window size in points (e.g. 1440x900)
              --wait <seconds>  extra settle time before --snap (default 1.0)

            examples:
              headless youtube.com
              headless localhost:3000 --snap shot.png --size 1280x800
            """)
            exit(0)
        case "--snap":
            i += 1
            if i < args.count { snapPath = args[i] }
        case "--size":
            i += 1
            if i < args.count {
                let parts = args[i].lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { opts.size = NSSize(width: parts[0], height: parts[1]) }
            }
        case "--wait":
            i += 1
            if i < args.count { wait = Double(args[i]) ?? 1.0 }
        default:
            if a.hasPrefix("-") {
                fputs("headless: ignoring unknown option \(a)\n", stderr)
            } else if let u = smartURL(a) {
                opts.url = u
            }
        }
        i += 1
    }
    if let p = snapPath {
        let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        opts.snap = SnapJob(path: abs, wait: wait)
    }
    return opts
}

let launchOptions = parseLaunchOptions()

// MARK: - Start page

let startPageHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>headless</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { background: #0a0a0e; color: #e8e8ee; font: 15px/1.6 -apple-system, system-ui;
         display: flex; align-items: center; justify-content: center;
         -webkit-user-select: none; cursor: default; }
  main { text-align: center; max-width: 680px; padding: 48px; animation: in .6s ease-out; }
  @keyframes in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
  h1 { font-size: 46px; font-weight: 650; letter-spacing: -.02em; margin: 0 0 6px; color: #fff; }
  p.tag { color: #85858f; margin: 0 0 46px; font-size: 16px; }
  .keys { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
          justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 48px; color: #55555e; font-size: 12px; }
</style></head>
<body><main>
  <h1>headless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="keys">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; drag</kbd></div>    <div>move the window</div>
    <div class="k"><kbd>&#8963;&#8984; F</kbd></div><div>fullscreen</div>
    <div class="k"><kbd>&#8679;&#8984; S</kbd></div><div>snapshot the page &rarr; desktop</div>
    <div class="k"><kbd>&#8997;&#8984; P</kbd></div> <div>pin on top of every window</div>
    <div class="k"><kbd>&#8984; [</kbd> <kbd>&#8984; ]</kbd></div><div>back / forward</div>
    <div class="k"><kbd>esc</kbd></div>             <div>bail out &mdash; back to this page</div>
    <div class="k"><kbd>&#8984; =</kbd> <kbd>&#8984; &minus;</kbd> <kbd>&#8984; 0</kbd></div><div>zoom</div>
    <div class="k"><kbd>&#8679;&#8984; C</kbd></div><div>copy current url</div>
  </div>
  <footer>&#8984;N new window &nbsp;&middot;&nbsp; &#8984;R reload &nbsp;&middot;&nbsp; &#8984;W close</footer>
</main></body></html>
"""

// MARK: - Views

final class BrowserWebView: WKWebView {
    // Bare Esc escapes back to the start page — unless fullscreen needs it,
    // or the ⌘L HUD is open (its field is first responder and handles Esc itself).
    var onEscape: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           window?.styleMask.contains(.fullScreen) != true,
           fullscreenState == .notInFullscreen,
           onEscape?() == true {
            return
        }
        super.keyDown(with: event)
    }

    // ⌘-drag anywhere moves the window; mouse buttons 4/5 go back/forward.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, canGoBack { goBack(); return }
        if event.buttonNumber == 4, canGoForward { goForward(); return }
        super.otherMouseUp(with: event)
    }
}

final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    let webView: BrowserWebView
    let qaBridge: WebKitQABridge
    let isIsolatedSession: Bool
    private let progressBar = NSView()
    private let hud = NSVisualEffectView()
    private let hudField = NSTextField()
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var mouseMonitor: Any?
    private var snapJob: SnapJob?
    private var toastHide: DispatchWorkItem?
    private var lastProgress: CGFloat = 0
    private var onStartPage = false
    private var pendingRestoredStartupURL: URL?
    private var pendingAgentNavigation: WKNavigation?
    private var pendingAgentNavigationFailed = false
    private var agentControlEnabled = false
    var onClose: (() -> Void)?

    init(
        url: URL?, restoredStartupURL: URL? = nil, size: NSSize?, snap: SnapJob?, isPrimary: Bool,
        isIsolated: Bool = false
    ) {
        isIsolatedSession = isIsolated
        let diagnosticsBridge = WebKitQABridge()
        qaBridge = diagnosticsBridge
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = isIsolated ? .nonPersistent() : normalWebsiteDataStore
        conf.preferences.isElementFullscreenEnabled = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.allowsAirPlayForMediaPlayback = true
        conf.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        conf.userContentController.add(diagnosticsBridge, name: "headlessQA")
        conf.userContentController.addUserScript(WKUserScript(
            source: webKitQAScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        conf.userContentController.addUserScript(WKUserScript(
            source: "globalThis.__headlessFileUpload = false;\n" + agentRuntimeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: agentWorld
        ))
        if !hasPasskeyEntitlement {
            let hideWebAuthn = WKUserScript(
                source: """
                (function () {
                  try {
                    delete window.PublicKeyCredential;
                    delete window.AuthenticatorResponse;
                    delete window.AuthenticatorAttestationResponse;
                    delete window.AuthenticatorAssertionResponse;
                  } catch (e) {}
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false)
            conf.userContentController.addUserScript(hideWebAuthn)
        }
        webView = BrowserWebView(frame: .zero, configuration: conf)
        snapJob = snap

        let contentSize = size ?? NSSize(width: 1160, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Headless"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 220)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        setTrafficLights(visible: false)

        let container = LayoutReportingView(frame: NSRect(origin: .zero, size: contentSize))
        container.onLayout = { [weak self] in self?.layoutOverlays() }
        window.contentView = container

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        container.addSubview(webView)

        buildOverlays(in: container)
        observeWebView()

        window.center()
        if isPrimary && snap == nil {
            window.setFrameUsingName("HeadlessMain")
            window.setFrameAutosaveName("HeadlessMain")
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 30, y: key.frame.maxY - 30))
        }
        if let size { window.setContentSize(size) }

        installMouseMonitor()

        if let url {
            pendingRestoredStartupURL = restoredStartupURL
            load(url)
        } else {
            loadStartPage()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func promptCredential(origin: CredentialOrigin) throws -> AuthenticationCredential {
        try onAgentMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Sign in to \(origin.rawValue)"
            alert.informativeText = "The password is used only for this login unless you separately choose to save it."
            let account = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
            account.placeholderString = "Username or email"
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            password.placeholderString = "Password"
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
            accessory.addSubview(account)
            accessory.addSubview(password)
            alert.accessoryView = accessory
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                account.stringValue = ""
                password.stringValue = ""
                throw AuthenticationError.userPresenceDenied
            }
            let accountValue = account.stringValue
            let passwordBytes = Array(password.stringValue.utf8)
            account.stringValue = ""
            password.stringValue = ""
            return try AuthenticationCredential(
                account: accountValue, password: AuthenticationSecret(passwordBytes)
            )
        }
    }

    func promptCredentialSave(
        origin: CredentialOrigin, account: String
    ) throws -> CredentialAlias? {
        try onAgentMain {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Save this credential?"
            alert.informativeText = "\(account) for \(origin.rawValue). Saving is optional and requires an alias."
            let alias = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            alias.placeholderString = "Alias, for example work"
            alert.accessoryView = alias
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Save")
            guard alert.runModal() == .alertSecondButtonReturn else {
                alias.stringValue = ""
                return nil
            }
            defer { alias.stringValue = "" }
            return try CredentialAlias(rawValue: alias.stringValue)
        }
    }

    // MARK: Chrome (what little there is)

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .mouseMoved {
                // Reveal the traffic lights only when hovering the top-left corner.
                guard let contentView = self.window?.contentView else { return event }
                let p = event.locationInWindow
                let nearCorner = p.y > contentView.bounds.height - 44 && p.x < 96
                self.setTrafficLights(visible: self.isFullScreen || nearCorner)
            } else if !self.hud.isHidden {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if !self.hud.frame.contains(p) { self.hideHUD() }
            }
            return event
        }
    }

    private func buildOverlays(in container: NSView) {
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.alphaValue = 0
        container.addSubview(progressBar)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 26
        hud.layer?.cornerCurve = .continuous
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hud.isHidden = true
        hud.alphaValue = 0
        hudField.isBezeled = false
        hudField.isBordered = false
        hudField.drawsBackground = false
        hudField.focusRingType = .none
        hudField.font = .systemFont(ofSize: 16)
        hudField.textColor = .labelColor
        hudField.placeholderString = "Search or enter address"
        hudField.usesSingleLineMode = true
        hudField.cell?.isScrollable = true
        hudField.cell?.wraps = false
        hudField.delegate = self
        hud.addSubview(hudField)
        container.addSubview(hud)

        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 17
        toastView.layer?.cornerCurve = .continuous
        toastView.layer?.masksToBounds = true
        toastView.isHidden = true
        toastView.alphaValue = 0
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastView.addSubview(toastLabel)
        container.addSubview(toastView)
    }

    private func layoutOverlays() {
        guard let contentView = window?.contentView else { return }
        let b = contentView.bounds
        let hudW = min(620, max(280, b.width - 48))
        let hudH: CGFloat = 52
        hud.frame = NSRect(x: (b.width - hudW) / 2, y: b.height - hudH - 84, width: hudW, height: hudH)
        hudField.frame = NSRect(x: 20, y: (hudH - 22) / 2, width: hudW - 40, height: 22)

        toastLabel.sizeToFit()
        let ts = toastLabel.frame.size
        let tw = ts.width + 32
        let th: CGFloat = 34
        toastView.frame = NSRect(x: (b.width - tw) / 2, y: 28, width: tw, height: th)
        toastLabel.frame = NSRect(x: 16, y: (th - ts.height) / 2, width: ts.width, height: ts.height)

        progressBar.frame = NSRect(x: 0, y: b.height - 2, width: b.width * lastProgress, height: 2)
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Headless" : t
            },
            webView.observe(\.url) { wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
            },
        ]
    }

    private func progressChanged(_ progress: Double) {
        lastProgress = CGFloat(progress)
        if let width = window?.contentView?.bounds.width {
            progressBar.frame.size.width = width * lastProgress
        }
        if progress >= 1.0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.lastProgress = 0
                self?.layoutOverlays()
            })
        } else {
            progressBar.alphaValue = 1
        }
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        pendingRestoredStartupURL = nil
        load(url)
    }

    func beginAgentNavigation(to url: URL) -> Bool {
        pendingRestoredStartupURL = nil
        onStartPage = false
        pendingAgentNavigationFailed = false
        pendingAgentNavigation = webView.load(URLRequest(url: url))
        return pendingAgentNavigation != nil
    }

    func agentNavigationStatus() -> (pending: Bool, failed: Bool) {
        (pendingAgentNavigation != nil, pendingAgentNavigationFailed)
    }

    private func load(_ url: URL) {
        onStartPage = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Once a window is driven through the local agent protocol, abandon any
    /// legacy local page before its contents can become agent-visible.
    func enableAgentControl() {
        if !agentControlEnabled,
           let currentURL = webView.url,
           currentURL.absoluteString != "about:blank",
           !agentMayNavigate(to: currentURL) {
            // Older builds allowed a user to open file or application URLs.
            // Do not make restored legacy content readable to an agent.
            loadStartPage()
        }
        agentControlEnabled = true
    }

    func loadStartPage() {
        pendingRestoredStartupURL = nil
        onStartPage = true
        webView.loadHTMLString(startPageHTML, baseURL: nil)
    }

    private func escapeToStart() -> Bool {
        if onStartPage { return false }
        loadStartPage()
        return true
    }

    // MARK: HUD (the ⌘L address bar)

    func showHUD() {
        if let u = webView.url, !onStartPage, u.absoluteString != "about:blank" {
            hudField.stringValue = u.absoluteString
        } else {
            hudField.stringValue = ""
        }
        hud.isHidden = false
        layoutOverlays()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
        }
        hudField.selectText(nil)
    }

    func hideHUD() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hud.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    private func commitHUD() {
        let text = hudField.stringValue
        hideHUD()
        if let url = smartURL(text) { navigate(to: url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideHUD(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitHUD(); return true }
        return false
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        layoutOverlays()
        toastHide?.cancel()
        toastView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.toastView.animator().alphaValue = 0
            }, completionHandler: { self.toastView.isHidden = true })
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    // MARK: Snapshots

    private func writePNG(from image: NSImage, to path: String) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return (cg.width, cg.height)
        } catch {
            return nil
        }
    }

    private func runSnapJob(_ job: SnapJob) {
        DispatchQueue.main.asyncAfter(deadline: .now() + job.wait) { [weak self] in
            guard let self else { exit(3) }
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let dims = self.writePNG(from: image, to: job.path) else {
                    fputs("headless: snapshot failed: \(error?.localizedDescription ?? "could not write PNG")\n", stderr)
                    exit(3)
                }
                print("saved \(job.path) (\(dims.0)x\(dims.1) px)")
                exit(0)
            }
        }
    }

    // MARK: Menu actions

    @objc func openLocation(_ sender: Any?) { showHUD() }

    @objc func reloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reload() }
    }

    @objc func hardReloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reloadFromOrigin() }
    }

    @objc func goBackAction(_ sender: Any?) { webView.goBack() }
    @objc func goForwardAction(_ sender: Any?) { webView.goForward() }

    @objc func zoomInPage(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom * 1.1, 5.0) }
    @objc func zoomOutPage(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom / 1.1, 0.25) }
    @objc func resetZoom(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc func saveSnapshot(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "headless \(formatter.string(from: Date())).png"
        let environment = ProcessInfo.processInfo.environment
        let path: String
        let successMessage: String
        if let testPath = environment["HEADLESS_E2E_MENU_SNAPSHOT_PATH"] {
            let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            let candidate = URL(fileURLWithPath: testPath).standardizedFileURL
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard environment["HEADLESS_E2E_DATA_STORE_ID"] != nil,
                  testPath.hasPrefix("/"),
                  parent.path.hasPrefix(temporaryRoot + "/"),
                  FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !FileManager.default.fileExists(
                      atPath: parent.appendingPathComponent(candidate.lastPathComponent).path
                  ) else {
                showToast("Snapshot failed")
                return
            }
            path = parent.appendingPathComponent(candidate.lastPathComponent).path
            successMessage = "Saved test snapshot"
        } else {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            path = desktop.appendingPathComponent(name).path
            successMessage = "Saved “\(name)” to Desktop"
        }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            if let image, self.writePNG(from: image, to: path) != nil {
                self.showToast(successMessage)
            } else {
                self.showToast("Snapshot failed")
            }
        }
    }

    @objc func copyPageURL(_ sender: Any?) {
        guard let u = webView.url, u.absoluteString != "about:blank" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let window else { return }
        let pinned = window.level == .floating
        let nextState: NSControl.StateValue = pinned ? .off : .on
        window.level = pinned ? .normal : .floating
        (sender as? NSMenuItem)?.state = nextState
        showToast(nextState == .on ? "Pinned on top" : "Unpinned")
    }

    @objc func showHelpPage(_ sender: Any?) { loadStartPage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)): return webView.canGoBack
        case #selector(goForwardAction(_:)): return webView.canGoForward
        case #selector(copyPageURL(_:)):
            return webView.url != nil && webView.url?.absoluteString != "about:blank"
        case #selector(togglePin(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { setTrafficLights(visible: true) }
    func windowDidExitFullScreen(_ notification: Notification) { setTrafficLights(visible: false) }

    func windowWillClose(_ notification: Notification) {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        observations.removeAll()
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        qaBridge.beginDocument()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        qaBridge.didCommitDocument()
        let u = webView.url?.absoluteString
        if u != nil && u != "about:blank" {
            pendingRestoredStartupURL = nil
            onStartPage = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completeAgentNavigation(navigation, failed: false)
        if let job = snapJob {
            snapJob = nil
            runSnapJob(job)
        } else if onStartPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.onStartPage, self.window?.isKeyWindow == true else { return }
                self.showHUD()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeAgentNavigation(navigation, failed: true)
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeAgentNavigation(navigation, failed: true)
        handleLoadError(error)
    }

    private func completeAgentNavigation(_ navigation: WKNavigation?, failed: Bool) {
        guard let navigation, pendingAgentNavigation === navigation else { return }
        pendingAgentNavigation = nil
        pendingAgentNavigationFailed = failed
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        // Ignore cancelled loads and "frame load interrupted" (downloads, redirects).
        if e.code == NSURLErrorCancelled || e.code == 102 { return }
        qaBridge.store.append(kind: "request-failed", message: e.localizedDescription,
                              url: webView.url?.absoluteString)
        if let restoredURL = pendingRestoredStartupURL {
            pendingRestoredStartupURL = nil
            if UserDefaults.standard.string(forKey: "LastURL") == restoredURL.absoluteString {
                UserDefaults.standard.removeObject(forKey: "LastURL")
            }
            loadStartPage()
            showToast("Previous page unavailable")
            return
        }
        if launchOptions.snap != nil {
            fputs("headless: load failed: \(e.localizedDescription)\n", stderr)
            exit(1)
        }
        showToast("Couldn’t load — \(e.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           !(onStartPage && url.absoluteString == "about:blank"),
           !agentMayNavigate(to: url) {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            // Convert explicit download intent into WKDownload so the
            // delegate below can classify and cancel it deterministically.
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            qaBridge.store.append(kind: "response", url: response.url?.absoluteString,
                                  method: "GET", status: Double(response.statusCode))
            if response.value(forHTTPHeaderField: "Content-Disposition")?
                .lowercased().contains("attachment") == true {
                decisionHandler(.download)
                return
            }
        }
        if !navigationResponse.canShowMIMEType {
            // Unsupported navigation responses would otherwise become
            // implicit downloads. Route them through the same fail-closed
            // cancellation and diagnostic path.
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    // WebKit creates a WKDownload for attachment responses and `download`
    // links. Agent sessions must never turn page-controlled bytes into files
    // on the host; only ArtifactStore owns explicit screenshot/recording
    // outputs. Cancelling here also covers otherwise safe-looking archives.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        blockDownload(download, url: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        blockDownload(download, url: navigationResponse.response.url)
    }

    private func blockDownload(_ download: WKDownload, url: URL?) {
        qaBridge.store.append(kind: "download-blocked", message: "Blocked page-initiated download", url: url?.absoluteString)
        download.cancel { _ in }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No tabs, no popups: target=_blank loads right here.
        if let url = navigationAction.request.url,
           agentMayNavigate(to: url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

// MARK: - App delegate

private func onAgentMain<T>(_ body: @escaping () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [BrowserWindowController] = []
    private let agentServer = LocalSocketServer()
    private var hostCore: HostCore<WebKitBrowserEngine>?
    private var ownerMonitor: SupervisedHostOwnerMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let artifacts: ArtifactStore
        do { artifacts = try ArtifactStore() }
        catch {
            fputs("headless: artifact directory failed: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let navigationAllowlist: NavigationAllowlist
        do {
            navigationAllowlist = try NavigationAllowlist(environment: ProcessInfo.processInfo.environment)
        } catch {
            fputs("headless: \(error)\n", stderr)
            if isAgentHost { exit(64) }
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let restoredStartupURL: URL? = {
            guard !isAgentHost, launchOptions.url == nil, launchOptions.snap == nil,
                  let value = UserDefaults.standard.string(forKey: "LastURL") else { return nil }
            return URL(string: value)
        }()
        let url = isAgentHost ? nil : launchOptions.url ?? restoredStartupURL
        let primaryController = openWindow(
            url: url,
            restoredStartupURL: restoredStartupURL,
            size: launchOptions.size,
            snap: launchOptions.snap,
            isPrimary: true,
            presentation: agentWindowPresentation
        )
        let engine = WebKitBrowserEngine(
            create: { [weak self] isolated in
                guard let self else {
                    throw HostError(code: .operationFailed, message: "Headless host is stopping.")
                }
                return onAgentMain {
                    self.openWindow(
                        url: nil, presentation: agentWindowPresentation, isIsolated: isolated
                    )
                }
            },
            close: { controller in onAgentMain { controller.close() } }
        )
        let authenticationBroker: any AuthenticationBroker
        if let broker = try? CredentialBrokerProcessClient() {
            authenticationBroker = broker
        } else {
            authenticationBroker = UnavailableAuthenticationBroker()
        }
        let core = HostCore(
            engine: engine,
            artifacts: artifacts,
            defaultSession: primaryController,
            authenticationBroker: authenticationBroker,
            navigationAllowlist: navigationAllowlist,
            shutdownHandler: { DispatchQueue.main.async { NSApp.terminate(nil) } }
        )
        hostCore = core
        ownerMonitor = SupervisedHostOwnerMonitor.startIfRequested {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        do {
            try agentServer.start { [weak self] request in
                self?.hostCore?.handle(request) ?? CommandResponse.failure(
                    id: request.id, code: "HOST_STOPPING", message: "Headless host is stopping."
                )
            }
        } catch {
            fputs("headless: agent socket failed: \(error)\n", stderr)
        }
        if launchOptions.snap != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("headless: --snap timed out\n", stderr)
                exit(2)
            }
        }
    }

    @discardableResult
    private func openWindow(
        url: URL?,
        restoredStartupURL: URL? = nil,
        size: NSSize? = nil,
        snap: SnapJob? = nil,
        isPrimary: Bool = false,
        presentation: WindowPresentation = .foreground,
        isIsolated: Bool = false
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(
            url: url,
            restoredStartupURL: restoredStartupURL,
            size: size,
            snap: snap,
            isPrimary: isPrimary,
            isIsolated: isIsolated
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
            self.hostCore?.sessionDidClose(controller)
        }
        controllers.append(controller)
        switch presentation {
        case .foreground:
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .background:
            controller.window?.orderBack(nil)
        }
        return controller
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }

    // Agent hosts must stay alive when the last session window closes; the CLI
    // owns process lifetime via `headless stop` / shutdown.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !isAgentHost }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ownerMonitor?.stop()
        hostCore?.stop()
        agentServer.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(url: url) }
    }

    // MARK: Menu

    private func menuItem(from spec: MenuShortcutSpec) -> NSMenuItem {
        let item = NSMenuItem(
            title: spec.title,
            action: NSSelectorFromString(spec.selector),
            keyEquivalent: spec.key
        )
        var mask: NSEvent.ModifierFlags = []
        if spec.command { mask.insert(.command) }
        if spec.shift { mask.insert(.shift) }
        if spec.option { mask.insert(.option) }
        if spec.control { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
        switch spec.target {
        case .application:
            item.target = NSApp
        case .appDelegate:
            item.target = self
        case .firstResponder:
            item.target = nil
        }
        return item
    }

    private func appendShortcuts(to menu: NSMenu, named menuName: String) {
        for spec in headlessMenuShortcuts where spec.menu == menuName {
            if spec.separatorBefore { menu.addItem(.separator()) }
            menu.addItem(menuItem(from: spec))
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Headless",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        for spec in headlessMenuShortcuts where spec.menu == "Headless" && spec.title != "Quit Headless" {
            appMenu.addItem(menuItem(from: spec))
        }
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        if let quit = headlessMenuShortcuts.first(where: { $0.title == "Quit Headless" }) {
            appMenu.addItem(menuItem(from: quit))
        }
        main.addItem(withTitle: "Headless", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        appendShortcuts(to: fileMenu, named: "File")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        appendShortcuts(to: editMenu, named: "Edit")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: "View")
        appendShortcuts(to: viewMenu, named: "View")
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let historyMenu = NSMenu(title: "History")
        appendShortcuts(to: historyMenu, named: "History")
        main.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu

        let windowMenu = NSMenu(title: "Window")
        appendShortcuts(to: windowMenu, named: "Window")
        let zoom = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        if let minimize = windowMenu.items.firstIndex(where: { $0.title == "Minimize" }) {
            windowMenu.insertItem(zoom, at: minimize + 1)
        } else {
            windowMenu.insertItem(zoom, at: 0)
        }
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        appendShortcuts(to: helpMenu, named: "Help")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Boot

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
