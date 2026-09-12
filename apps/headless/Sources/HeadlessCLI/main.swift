import HeadlessProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func printJSON(_ value: JSONValue) {
    do {
        let data = try ProtocolCodec.encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        fputs("headless: failed to encode output: \(error)\n", stderr)
        exit(70)
    }
}

private func printResponse(_ response: CommandResponse) throws {
    FileHandle.standardOutput.write(try ProtocolCodec.encodeLine(response))
}

private struct HostLauncher {
    struct Launch {
        let response: CommandResponse
        let process: Process?
        let ownerHandle: FileHandle?
    }

    let client = LocalSocketClient()

    func ping() -> CommandResponse? {
        try? client.send(CommandRequest(command: .ping), timeout: 0.5)
    }

    func start(
        presentation: AgentStartupPresentation? = nil,
        allowlist: NavigationAllowlist = .unrestricted,
        supervised: Bool = false
    ) throws -> Launch {
        #if !os(macOS)
        if presentation != nil { throw SettingsError.unsupportedPlatform("startup-presentation") }
        #endif
        if let response = ping(), response.ok {
            if supervised { throw HostLaunchError.alreadyRunning }
            try validateRunningAllowlist(response, requested: allowlist)
            return Launch(response: response, process: nil, ownerHandle: nil)
        }
        #if os(Linux)
        // Report an unsupported browser directly to the operator instead of
        // hiding the host's startup error behind its detached stderr.
        _ = try ChromiumRuntimeResolver().resolve()
        #endif
        let executable = try resolveHostExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        var environment = ProcessInfo.processInfo.environment
        environment["HEADLESS_AGENT_HOST"] = "1"
        #if os(macOS)
        let configuredPresentation = try SettingsStore.production().effectiveRawValue("startup-presentation")
        guard let storedPresentation = AgentStartupPresentation(rawValue: configuredPresentation) else {
            throw SettingsError.corruptStorage
        }
        let effectivePresentation = presentation ?? storedPresentation
        #else
        let effectivePresentation = AgentStartupPresentation.background
        #endif
        environment["HEADLESS_START_FOREGROUND"] = effectivePresentation == .foreground ? "1" : "0"
        environment["HEADLESS_SUPERVISED"] = supervised ? "1" : "0"
        if allowlist.isRestricted {
            environment[headlessNavigationAllowlistEnvironmentKey] = allowlist.environmentValue
        } else {
            environment.removeValue(forKey: headlessNavigationAllowlistEnvironmentKey)
        }
        process.environment = environment
        let ownerPipe = supervised ? Pipe() : nil
        process.standardInput = ownerPipe?.fileHandleForReading ?? FileHandle.nullDevice
        if let hostLog = environment["HEADLESS_HOST_LOG"], hostLog.hasPrefix("/") {
            let logURL = URL(fileURLWithPath: hostLog)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logURL)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
            try ownerPipe?.fileHandleForReading.close()
        } catch {
            try? ownerPipe?.fileHandleForReading.close()
            try? ownerPipe?.fileHandleForWriting.close()
            throw error
        }

        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let response = ping(), response.ok {
                do {
                    try validateRunningAllowlist(response, requested: allowlist)
                    if supervised, runningHostProcessIdentifier(response) != process.processIdentifier {
                        throw HostLaunchError.ownershipMismatch
                    }
                    return Launch(
                        response: response, process: supervised ? process : nil,
                        ownerHandle: ownerPipe?.fileHandleForWriting
                    )
                } catch {
                    try? ownerPipe?.fileHandleForWriting.close()
                    terminateAndReap(process)
                    throw error
                }
            }
            if !process.isRunning {
                try? ownerPipe?.fileHandleForWriting.close()
                process.waitUntilExit()
                throw HostLaunchError.exited(process.terminationStatus)
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        try? ownerPipe?.fileHandleForWriting.close()
        terminateAndReap(process)
        throw HostLaunchError.timedOut
    }

    func waitForSupervisedHost(_ launch: Launch) -> Int32 {
        guard let process = launch.process, let ownerHandle = launch.ownerHandle else {
            return 0
        }
        while process.isRunning {
            var descriptor = pollfd(
                fd: STDIN_FILENO,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let status = poll(&descriptor, 1, 100)
            if status > 0 {
                var byte: UInt8 = 0
                let count = withUnsafeMutableBytes(of: &byte) { buffer in
                    read(STDIN_FILENO, buffer.baseAddress, 1)
                }
                if count >= 0 || errno != EINTR { break }
            } else if status < 0, errno != EINTR {
                break
            }
        }
        try? ownerHandle.close()
        let gracefulDeadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { terminateAndReap(process) }
        else { process.waitUntilExit() }
        return process.terminationStatus
    }

    private func terminateAndReap(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func validateRunningAllowlist(
        _ response: CommandResponse, requested allowlist: NavigationAllowlist
    ) throws {
        guard allowlist.isRestricted else { return }
        let running = runningAllowlist(from: response)
        if Set(running) != Set(allowlist.patterns) {
            throw HostLaunchError.allowlistMismatch(running: running, requested: allowlist.patterns)
        }
    }

    private func runningAllowlist(from response: CommandResponse) -> [String] {
        guard case .object(let result) = response.result,
              case .array(let values) = result["navigationAllowlist"] else {
            return []
        }
        return values.compactMap(\.stringValue)
    }

    private func runningHostProcessIdentifier(_ response: CommandResponse) -> Int32? {
        guard case .object(let result) = response.result,
              let value = result["pid"]?.numberValue,
              value.rounded() == value,
              value >= 1,
              value <= Double(Int32.max) else {
            return nil
        }
        return Int32(value)
    }

    private func resolveHostExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["HEADLESS_HOST_EXECUTABLE"] {
            candidates.append(URL(fileURLWithPath: override))
        }

        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let siblingDirectory = cli.deletingLastPathComponent()
        candidates.append(siblingDirectory.appendingPathComponent("headless-host"))
        candidates.append(
            siblingDirectory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/Headless")
        )
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Headless.app/Contents/MacOS/Headless")
        )

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HostLaunchError.notFound
    }
}

private enum HostLaunchError: Error, CustomStringConvertible {
    case notFound
    case alreadyRunning
    case ownershipMismatch
    case timedOut
    case exited(Int32)
    case allowlistMismatch(running: [String], requested: [String])

    var description: String {
        switch self {
        case .notFound: return "Could not find headless-host. Run the Headless build first."
        case .alreadyRunning:
            return "A shared Headless host is already running. Stop it before starting a supervised host."
        case .ownershipMismatch:
            return "A different Headless host answered during supervised startup."
        case .timedOut: return "Headless host did not become ready within 8 seconds."
        case .exited(let status): return "Headless host exited during startup (status \(status))."
        case .allowlistMismatch(let running, let requested):
            let runningText = running.isEmpty ? "unrestricted" : running.joined(separator: ", ")
            return "The running host navigation allowlist (\(runningText)) does not match (\(requested.joined(separator: ", "))). Run `headless stop` first."
        }
    }
}

private struct CredentialBrokerLauncher {
    func run(_ command: CredentialCLICommand) throws {
        let executable = try resolveExecutable()
        let arguments = [executable.path, "credentials"] + command.brokerArguments + ["--json"]
        let environment = sanitizedEnvironment(ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }.sorted()
        var argumentPointers = arguments.map { value in value.withCString(strdup) } + [nil]
        var environmentPointers = environment.map { value in value.withCString(strdup) } + [nil]
        defer {
            for case let pointer? in argumentPointers { free(UnsafeMutableRawPointer(pointer)) }
            for case let pointer? in environmentPointers { free(UnsafeMutableRawPointer(pointer)) }
        }
        #if canImport(Darwin)
        Darwin.execve(executable.path, &argumentPointers, &environmentPointers)
        #else
        Glibc.execve(executable.path, &argumentPointers, &environmentPointers)
        #endif
        throw CredentialBrokerLaunchError.unavailable
    }

    private func resolveExecutable() throws -> URL {
        let cli = try runningExecutableURL()
        let candidate = cli.deletingLastPathComponent().appendingPathComponent("headless-credential-broker")
        var info = stat()
        guard lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_uid == getuid() || info.st_uid == 0), (info.st_mode & 0o022) == 0,
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw CredentialBrokerLaunchError.unavailable
        }
        return candidate
    }

    private func runningExecutableURL() throws -> URL {
        #if os(macOS)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let status = buffer.withUnsafeMutableBufferPointer {
            _NSGetExecutablePath($0.baseAddress, &size)
        }
        guard status == 0 else { throw CredentialBrokerLaunchError.unavailable }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            throw CredentialBrokerLaunchError.unavailable
        }
        return URL(fileURLWithPath: path).standardizedFileURL
        #endif
    }

    private func sanitizedEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = [
            "HOME", "USER", "LOGNAME", "DISPLAY", "WAYLAND_DISPLAY", "LANG", "TERM", "COLORTERM",
            "__CF_USER_TEXT_ENCODING",
        ]
        var result = source.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        result["PATH"] = "/usr/bin:/bin"
        return result
    }
}

private enum CredentialBrokerLaunchError: Error, CustomStringConvertible {
    case unavailable

    var description: String {
        "The trusted headless-credential-broker executable is missing or insecure. Reinstall Headless."
    }
}

do {
    let invocation = try CLIParser().parse(Array(CommandLine.arguments.dropFirst()))
    if let local = invocation.local {
        switch local {
        case .help:
            print(agentHelp)
        case .version:
            print("headless \(headlessProductVersion)")
        case .capabilities:
            printJSON(capabilitiesDocument)
        case .schema:
            printJSON(protocolSchemaDocument)
        case .runtime:
            #if os(Linux)
            printJSON(try ChromiumRuntimeResolver().resolve().diagnostic)
            #else
            printJSON(.object([
                "engine": .string("webkit"), "source": .string("system-framework"),
                "supported": .bool(true), "transport": .string("native-webkit"),
            ]))
            #endif
        case .start(let presentation, let allowlist, let supervised):
            let launch = try HostLauncher().start(
                presentation: presentation, allowlist: allowlist, supervised: supervised
            )
            try printResponse(launch.response)
            if launch.process != nil { exit(HostLauncher().waitForSupervisedHost(launch)) }
        case .config(let command):
            let settings = try SettingsStore.production()
            switch command {
            case .list:
                printJSON(try settings.list())
            case .describe(let key):
                printJSON(try settings.describe(key))
            case .get(let key):
                printJSON(try settings.get(key))
            case .set(let key, let value):
                printJSON(try settings.set(key, rawValue: value))
            case .reset(let key):
                printJSON(try settings.reset(key))
            }
        case .credentials(let command):
            try CredentialBrokerLauncher().run(command)
        }
    } else if let request = invocation.request {
        let launcher = HostLauncher()
        let response: CommandResponse
        do {
            response = try launcher.client.send(request, timeout: requestTimeout(for: request))
        } catch LocalTransportError.connectionFailed where request.command != .ping && request.command != .shutdown {
            _ = try launcher.start()
            response = try launcher.client.send(request, timeout: requestTimeout(for: request))
        }
        try printResponse(response)
        if !response.ok { exit(1) }
    }
} catch let error as CLIParseError {
    fputs("headless: \(error.description)\n", stderr)
    exit(64)
} catch let error as CredentialCommandError {
    fputs("headless: \(error.description)\n", stderr)
    exit(64)
} catch let error as ProtocolValidationError {
    fputs("headless: \(error.description)\n", stderr)
    exit(64)
} catch let error as CaptureFormatError {
    fputs("headless: \(error.description)\n", stderr)
    exit(64)
} catch let error as LocalTransportError {
    let response = CommandResponse.failure(
        id: "unknown",
        code: "HOST_UNAVAILABLE",
        message: error.description,
        suggestion: "Run `headless start`."
    )
    try? printResponse(response)
    exit(69)
} catch let error as NavigationAllowlistError {
    fputs("headless: \(error.description)\n", stderr)
    exit(64)
} catch let error as HostLaunchError {
    let code: String
    let suggestion: String?
    if case .allowlistMismatch = error {
        code = "NAVIGATION_ALLOWLIST_CONFLICT"
        suggestion = "Run `headless stop` first."
    } else {
        code = "HOST_START_FAILED"
        suggestion = nil
    }
    let response = CommandResponse.failure(
        id: "unknown", code: code, message: error.description, suggestion: suggestion
    )
    try? printResponse(response)
    exit(69)
} catch let error as ChromiumRuntimeError {
    let response = CommandResponse.failure(
        id: "unknown", code: "UNSUPPORTED_BROWSER_RUNTIME", message: error.description,
        suggestion: "Run `headless runtime` after installing a supported Chromium runtime."
    )
    try? printResponse(response)
    exit(69)
} catch let error as SettingsError {
    let code: String
    switch error {
    case .unsupportedPlatform: code = "UNSUPPORTED_CAPABILITY"
    case .unknownKey, .invalidValue, .accessDenied: code = "INVALID_CONFIGURATION"
    case .insecureStorage, .corruptStorage, .operationFailed: code = "CONFIGURATION_FAILED"
    }
    let response = CommandResponse.failure(
        id: "unknown",
        code: code,
        message: error.description
    )
    try? printResponse(response)
    exit(69)
} catch let error as CredentialBrokerLaunchError {
    let response = CommandResponse.failure(
        id: "unknown", code: "VAULT_UNAVAILABLE", message: error.description
    )
    try? printResponse(response)
    exit(69)
} catch {
    fputs("headless: \(error)\n", stderr)
    exit(70)
}
