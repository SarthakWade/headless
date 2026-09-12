import CHeadlessSecurePrompt
import Foundation

public enum AuthenticationDetection: String, Sendable {
    case none
    case hint
    case confirmed
    case additionalVerification = "additional-verification"
    case passkey
    case crossOrigin = "cross-origin"
}

public struct AuthenticationForm: Equatable, Sendable {
    public let origin: String
    public let document: String?
    public let credentialOrigin: CredentialOrigin?
    public let detection: AuthenticationDetection
    public let accountTarget: String?
    public let passwordTarget: String?
    public let submitTarget: String?

    public init(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              let rawDetection = object["detection"]?.stringValue,
              let detection = AuthenticationDetection(rawValue: rawDetection),
              let rawOrigin = object["origin"]?.stringValue else {
            throw HostError(code: .operationFailed, message: "Browser returned an invalid authentication state")
        }
        guard rawOrigin.unicodeScalars.allSatisfy(\.isASCII), rawOrigin.utf8.count <= 2_048 else {
            throw HostError(code: .operationFailed, message: "Browser returned an invalid authentication origin")
        }
        if let url = URL(string: rawOrigin), ["http", "https"].contains(url.scheme?.lowercased()),
           url.host != nil, (url.path.isEmpty || url.path == "/"),
           url.query == nil, url.fragment == nil, url.user == nil, url.password == nil {
            self.origin = rawOrigin
            credentialOrigin = try? CredentialOrigin(rawValue: rawOrigin)
        } else {
            guard detection == .none else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid authentication origin")
            }
            self.origin = ""
            credentialOrigin = nil
        }
        self.detection = detection
        if let rawDocument = object["document"]?.stringValue {
            guard rawDocument.utf8.count == 32,
                  rawDocument.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII && ((scalar.value >= 48 && scalar.value <= 57)
                          || (scalar.value >= 97 && scalar.value <= 102))
                  }) else {
                throw HostError(code: .operationFailed, message: "Browser returned an invalid document identity")
            }
            document = rawDocument
        } else {
            guard detection == .none else {
                throw HostError(code: .operationFailed, message: "Browser omitted the document identity")
            }
            document = nil
        }
        accountTarget = try Self.target(object["accountTarget"])
        passwordTarget = try Self.target(object["passwordTarget"])
        submitTarget = try Self.target(object["submitTarget"])
        if detection == .confirmed, passwordTarget == nil {
            throw HostError(code: .operationFailed, message: "Browser returned an incomplete authentication form")
        }
    }

    private static func target(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        if value == .null { return nil }
        guard let target = value.stringValue, target.hasPrefix("@e"), target.utf8.count <= 16,
              !target.dropFirst(2).isEmpty, target.dropFirst(2).allSatisfy(\.isNumber) else {
            throw HostError(code: .operationFailed, message: "Browser returned an invalid authentication target")
        }
        return target
    }

    public var publicValue: JSONValue {
        .object([
            "origin": .string(origin),
            "detection": .string(detection.rawValue),
            "untrustedContent": .bool(true),
        ])
    }
}

public struct AuthenticationAlias: Equatable, Sendable {
    public let alias: CredentialAlias
    public let account: String

    public init(alias: CredentialAlias, account: String) throws {
        self.alias = alias
        self.account = try validatedAuthenticationAccount(account)
    }

    public var publicValue: JSONValue {
        .object(["alias": .string(alias.rawValue), "username": .string(account)])
    }
}

public final class AuthenticationSecret: @unchecked Sendable {
    private var storage: [UInt8]

    public init(_ bytes: [UInt8]) { storage = bytes }

    deinit { clear() }

    public var isEmpty: Bool { storage.isEmpty }

    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try storage.withUnsafeBytes(body)
    }

    public func clear() {
        storage.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            headless_secure_clear(base.assumingMemoryBound(to: UInt8.self), buffer.count)
        }
        storage.removeAll(keepingCapacity: false)
    }
}

public struct AuthenticationCredential: @unchecked Sendable {
    public let account: String
    public let password: AuthenticationSecret

    public init(account: String, password: AuthenticationSecret) throws {
        self.account = try validatedAuthenticationAccount(account)
        guard !password.isEmpty else { throw AuthenticationError.invalidBrokerResponse }
        self.password = password
    }

    public func copy() throws -> AuthenticationCredential {
        try AuthenticationCredential(
            account: account,
            password: AuthenticationSecret(password.withUnsafeBytes { Array($0) })
        )
    }
}

private func validatedAuthenticationAccount(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 320,
          !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw AuthenticationError.invalidBrokerResponse
    }
    return trimmed
}

public protocol AuthenticationBroker: Sendable {
    func aliases(for origin: CredentialOrigin) throws -> [AuthenticationAlias]
    func credential(for origin: CredentialOrigin, alias: CredentialAlias) throws -> AuthenticationCredential
    func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws
}

public extension AuthenticationBroker {
    func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws {
        credential.password.clear()
        throw AuthenticationError.vaultUnavailable
    }
}

public struct UnavailableAuthenticationBroker: AuthenticationBroker {
    public init() {}
    public func aliases(for origin: CredentialOrigin) throws -> [AuthenticationAlias] { [] }
    public func credential(for origin: CredentialOrigin, alias: CredentialAlias) throws -> AuthenticationCredential {
        throw AuthenticationError.vaultUnavailable
    }
    public func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws {
        credential.password.clear()
        throw AuthenticationError.vaultUnavailable
    }
}

public final class EphemeralAuthenticationBroker: @unchecked Sendable, AuthenticationBroker {
    public static let maximumRecords = 100

    private struct Record {
        let origin: CredentialOrigin
        let alias: CredentialAlias
        let account: String
        let password: AuthenticationSecret
    }

    private let lock = NSLock()
    private var records: [Record] = []

    public init() {}
    deinit { removeAll() }

    public func aliases(for origin: CredentialOrigin) throws -> [AuthenticationAlias] {
        try lock.withLock {
            try records.filter { $0.origin == origin }
                .sorted { $0.alias.rawValue < $1.alias.rawValue }
                .map { try AuthenticationAlias(alias: $0.alias, account: $0.account) }
        }
    }

    public func credential(
        for origin: CredentialOrigin, alias: CredentialAlias
    ) throws -> AuthenticationCredential {
        try lock.withLock {
            guard let record = records.first(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else { throw AuthenticationError.accountNotFound }
            return try AuthenticationCredential(
                account: record.account,
                password: AuthenticationSecret(record.password.withUnsafeBytes { Array($0) })
            )
        }
    }

    public func store(
        _ credential: AuthenticationCredential, for origin: CredentialOrigin, alias: CredentialAlias
    ) throws {
        try lock.withLock {
            guard records.count < Self.maximumRecords else {
                throw AuthenticationError.brokerFailed("private credential limit")
            }
            guard !records.contains(where: {
                $0.origin == origin
                    && $0.alias.rawValue.caseInsensitiveCompare(alias.rawValue) == .orderedSame
            }) else { throw AuthenticationError.credentialAliasExists }
            records.append(Record(
                origin: origin, alias: alias, account: credential.account,
                password: AuthenticationSecret(credential.password.withUnsafeBytes { Array($0) })
            ))
        }
    }

    public func removeAll() {
        lock.withLock {
            records.forEach { $0.password.clear() }
            records.removeAll(keepingCapacity: false)
        }
    }
}

public struct SecureTerminalAuthenticationPrompt {
    public init() {}

    public func readCredential() throws -> AuthenticationCredential {
        let accountBytes = try read(prompt: "Account username/email: ", hidden: false, maximum: 320)
        guard let account = String(bytes: accountBytes, encoding: .utf8) else {
            throw AuthenticationError.userPresenceDenied
        }
        return try AuthenticationCredential(
            account: account,
            password: AuthenticationSecret(
                try read(prompt: "Password: ", hidden: true, maximum: 4_096)
            )
        )
    }

    public func confirmSave() throws -> CredentialAlias? {
        let answerBytes = try read(prompt: "Save this credential? [y/N] ", hidden: false, maximum: 3)
        guard let answer = String(bytes: answerBytes, encoding: .utf8)?.lowercased(),
              answer == "y" || answer == "yes" else { return nil }
        let aliasBytes = try read(prompt: "Credential alias: ", hidden: false, maximum: 64)
        guard let alias = String(bytes: aliasBytes, encoding: .utf8) else {
            throw AuthenticationError.userPresenceDenied
        }
        return try CredentialAlias(rawValue: alias)
    }

    private func read(prompt: String, hidden: Bool, maximum: Int) throws -> [UInt8] {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = prompt.withCString {
            headless_read_tty_line($0, hidden ? 1 : 0, &pointer, &count)
        }
        guard result == Int32(HEADLESS_PROMPT_SUCCESS.rawValue), let pointer else {
            throw AuthenticationError.userPresenceUnavailable
        }
        defer { headless_clear_and_free(pointer, count + 1) }
        guard count <= maximum else { throw AuthenticationError.invalidBrokerResponse }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

public enum AuthenticationError: Error, Equatable, CustomStringConvertible {
    case challengeNotFound
    case challengeExpired
    case challengeConsumed
    case originChanged
    case formChanged
    case accountNotFound
    case credentialAliasExists
    case vaultUnavailable
    case vaultLocked
    case userPresenceUnavailable
    case userPresenceDenied
    case invalidBrokerResponse
    case brokerFailed(String)

    public var code: String {
        switch self {
        case .challengeNotFound: return AuthenticationProtocolErrorCode.challengeNotFound.rawValue
        case .challengeExpired: return AuthenticationProtocolErrorCode.challengeExpired.rawValue
        case .challengeConsumed: return AuthenticationProtocolErrorCode.challengeConsumed.rawValue
        case .originChanged: return AuthenticationProtocolErrorCode.originChanged.rawValue
        case .formChanged: return AuthenticationProtocolErrorCode.formChanged.rawValue
        case .accountNotFound: return AuthenticationProtocolErrorCode.accountNotFound.rawValue
        case .credentialAliasExists: return AuthenticationProtocolErrorCode.credentialAliasExists.rawValue
        case .vaultUnavailable: return AuthenticationProtocolErrorCode.vaultUnavailable.rawValue
        case .vaultLocked: return AuthenticationProtocolErrorCode.vaultLocked.rawValue
        case .userPresenceUnavailable: return AuthenticationProtocolErrorCode.userPresenceUnavailable.rawValue
        case .userPresenceDenied: return AuthenticationProtocolErrorCode.userPresenceDenied.rawValue
        case .invalidBrokerResponse: return AuthenticationProtocolErrorCode.invalidBrokerResponse.rawValue
        case .brokerFailed: return AuthenticationProtocolErrorCode.brokerFailed.rawValue
        }
    }

    public var description: String {
        switch self {
        case .challengeNotFound: return "Authentication challenge was not found for this session."
        case .challengeExpired: return "Authentication challenge expired. Inspect the current page again."
        case .challengeConsumed: return "Authentication challenge has already been used."
        case .originChanged: return "The top-level authentication origin changed. Inspect the page again."
        case .formChanged: return "The authentication form changed. Inspect the page again."
        case .accountNotFound: return "No saved account matches that alias for this origin."
        case .credentialAliasExists: return "That credential alias already exists for this origin."
        case .vaultUnavailable: return "An approved operating-system credential vault is unavailable."
        case .vaultLocked: return "The operating-system credential vault is locked."
        case .userPresenceUnavailable:
            return "A trusted per-use user-presence mechanism is unavailable."
        case .userPresenceDenied: return "Credential use was not authorized by the user."
        case .invalidBrokerResponse: return "The credential broker returned an invalid response."
        case .brokerFailed: return "The credential broker could not complete the request."
        }
    }
}

public final class AuthenticationChallengeStore: @unchecked Sendable {
    public static let lifetime: TimeInterval = 60
    public static let maximumChallenges = 64

    public struct Challenge: Equatable, Sendable {
        public let id: String
        public let session: String
        public let form: AuthenticationForm
        fileprivate let expiresAt: TimeInterval
        fileprivate var inUse: Bool
        fileprivate var consumed: Bool
    }

    private let lock = NSLock()
    private var challenges: [String: Challenge] = [:]
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func issue(session: String, form: AuthenticationForm) -> Challenge {
        lock.lock()
        defer { lock.unlock() }
        let issuedAt = now()
        purgeExpired(at: issuedAt)
        challenges = challenges.filter { $0.value.session != session }
        while challenges.count >= Self.maximumChallenges, let oldest = challenges.min(by: {
            $0.value.expiresAt < $1.value.expiresAt
        })?.key {
            challenges.removeValue(forKey: oldest)
        }
        let challenge = Challenge(
            id: UUID().uuidString.lowercased(), session: session, form: form,
            expiresAt: issuedAt + Self.lifetime, inUse: false, consumed: false
        )
        challenges[challenge.id] = challenge
        return challenge
    }

    public func begin(id: String, session: String, currentForm: AuthenticationForm) throws -> Challenge {
        lock.lock()
        defer { lock.unlock() }
        guard var challenge = challenges[id], challenge.session == session else {
            throw AuthenticationError.challengeNotFound
        }
        guard now() <= challenge.expiresAt else {
            challenges.removeValue(forKey: id)
            throw AuthenticationError.challengeExpired
        }
        guard !challenge.consumed, !challenge.inUse else { throw AuthenticationError.challengeConsumed }
        guard challenge.form.origin == currentForm.origin else { throw AuthenticationError.originChanged }
        guard challenge.form.document == currentForm.document else { throw AuthenticationError.formChanged }
        guard currentForm.detection == .confirmed,
              challenge.form.passwordTarget == currentForm.passwordTarget,
              challenge.form.accountTarget == currentForm.accountTarget,
              challenge.form.submitTarget == currentForm.submitTarget else {
            throw AuthenticationError.formChanged
        }
        challenge.inUse = true
        challenges[id] = challenge
        return challenge
    }

    public func validateActive(
        id: String, session: String, currentForm: AuthenticationForm
    ) throws -> Challenge {
        lock.lock()
        defer { lock.unlock() }
        guard let challenge = challenges[id], challenge.session == session else {
            throw AuthenticationError.challengeNotFound
        }
        guard now() <= challenge.expiresAt else {
            challenges.removeValue(forKey: id)
            throw AuthenticationError.challengeExpired
        }
        guard !challenge.consumed, challenge.inUse else {
            throw AuthenticationError.challengeConsumed
        }
        guard challenge.form.origin == currentForm.origin else {
            throw AuthenticationError.originChanged
        }
        guard challenge.form.document == currentForm.document else {
            throw AuthenticationError.formChanged
        }
        guard currentForm.detection == .confirmed,
              challenge.form.passwordTarget == currentForm.passwordTarget,
              challenge.form.accountTarget == currentForm.accountTarget,
              challenge.form.submitTarget == currentForm.submitTarget else {
            throw AuthenticationError.formChanged
        }
        return challenge
    }

    public func finish(id: String, consumed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var challenge = challenges[id] else { return }
        challenge.inUse = false
        challenge.consumed = consumed
        challenges[id] = challenge
    }

    public func invalidate(session: String) {
        lock.lock()
        challenges = challenges.filter { $0.value.session != session }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        challenges.removeAll()
        lock.unlock()
    }

    private func purgeExpired(at time: TimeInterval) {
        challenges = challenges.filter { time <= $0.value.expiresAt }
    }
}
