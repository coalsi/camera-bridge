import BridgeSupport
import Foundation

/// How fast a peer may guess the password. Five wrong passwords from one address lock that address out for 15 seconds, doubling
/// with each further failure up to 15 minutes; many failures from everywhere together (a spread-out guess) slow everyone
/// down for a minute. A right password clears the address's count. Memory is bounded (oldest addresses are forgotten).
struct LoginLimiter: Sendable {
    struct Policy: Sendable {
        var freeAttempts = 5
        var firstLockout: TimeInterval = 15
        var maximumLockout: TimeInterval = 900
        /// Failures from one address older than this are forgotten.
        var window: TimeInterval = 900
        var globalFailures = 60
        var globalWindow: TimeInterval = 600
        var globalLockout: TimeInterval = 60
        var maximumAddresses = 512
    }

    private struct Entry: Sendable {
        var failures = 0
        var lastFailure = Date.distantPast
        var lockedUntil = Date.distantPast
    }

    var policy = Policy()
    private var entries: [String: Entry] = [:]
    private var recent: [Date] = []
    private var globalLockedUntil = Date.distantPast

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Addresses remembered (tests).
    var trackedAddressCount: Int { entries.count }

    /// Seconds to wait before `address` may try again, nil when it may.
    func retryAfter(address: String, now: Date) -> Int? {
        let until = max(entries[address]?.lockedUntil ?? .distantPast, globalLockedUntil)
        let remaining = until.timeIntervalSince(now)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }

    mutating func recordFailure(address: String, now: Date) {
        var entry = entries[address] ?? Entry()
        if now.timeIntervalSince(entry.lastFailure) > policy.window { entry.failures = 0 }
        entry.failures += 1
        entry.lastFailure = now
        if entry.failures >= policy.freeAttempts {
            let exponent = min(entry.failures - policy.freeAttempts, 20)
            entry.lockedUntil = now.addingTimeInterval(min(policy.firstLockout * pow(2, Double(exponent)), policy.maximumLockout))
        }
        entries[address] = entry
        if entries.count > policy.maximumAddresses {
            let oldest = entries.sorted { $0.value.lastFailure < $1.value.lastFailure }.prefix(entries.count - policy.maximumAddresses)
            for (key, _) in oldest { entries[key] = nil }
        }
        recent.append(now)
        recent.removeAll { now.timeIntervalSince($0) > policy.globalWindow }
        if recent.count >= policy.globalFailures { globalLockedUntil = now.addingTimeInterval(policy.globalLockout) }
    }

    mutating func recordSuccess(address: String) {
        entries[address] = nil
    }
}

/// The administrator: one password, the bridge's name, and the signed-in browsers. Kept in `<data>/web/auth.json` (0600 in a 0700
/// directory): the password as a PBKDF2 hash, a session as the SHA-256 of its token (the token itself is only in the browser's
/// cookie), so a copy of the file signs nobody in.
///
/// - `configure` runs once (first-run setup); a second attempt fails. Nothing else works until it has.
/// - A session lasts 7 days after its last use and 30 days at most. Changing the password signs every other browser out.
/// - Passwords are 8 to 256 bytes long; hashing happens off the actor, one at a time, so guesses cannot pile up on the CPU.
public actor AuthStore {
    public enum Failure: Error, Equatable, Sendable {
        case alreadyConfigured
        case notConfigured
        case passwordTooShort
        case passwordTooLong
        case wrongPassword
        case storageFailed
    }

    struct StoredSession: Codable, Equatable {
        var id: String
        var created: Date
        var lastSeen: Date
    }

    struct Stored: Codable, Equatable {
        var version = 1
        var bridgeName = AuthStore.defaultBridgeName
        var password: StoredPassword?
        var sessions: [StoredSession] = []
    }

    public static let defaultBridgeName = "Camera Bridge"
    public static let passwordLength = 8...256
    /// PBKDF2-HMAC-SHA256 rounds (OWASP's 2023 figure).
    public static let defaultIterations = 600_000
    static let idleLifetime: TimeInterval = 7 * 86_400
    static let absoluteLifetime: TimeInterval = 30 * 86_400
    static let maximumSessions = 50
    /// `lastSeen` is written to disk at most this often.
    static let persistInterval: TimeInterval = 3_600

    /// A signed-in browser.
    public struct Session: Sendable, Equatable {
        /// SHA-256 of the cookie token.
        public var id: String
        public var csrfToken: String
    }

    private let file: URL
    private let iterations: Int
    private let now: @Sendable () -> Date
    private let hashing = AsyncSerialLock()
    private var stored: Stored
    private var configuring = false
    private var limiter: LoginLimiter
    private var lastPersisted = Date.distantPast
    private let log = Log(category: "web")

    /// `directory`: the bridge's data directory (the store lives in `web/` below it).
    public init(directory: URL, iterations: Int = AuthStore.defaultIterations, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(directory: directory, iterations: iterations, limiter: LoginLimiter(), now: now)
    }

    init(directory: URL, iterations: Int, limiter: LoginLimiter, now: @escaping @Sendable () -> Date) {
        file = directory.appending(path: "web", directoryHint: .isDirectory).appending(path: "auth.json", directoryHint: .notDirectory)
        self.iterations = iterations
        self.now = now
        self.limiter = limiter
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder.iso.decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    public var isConfigured: Bool { stored.password != nil }

    public var bridgeName: String { stored.bridgeName }

    // MARK: Setup and password

    /// First-run setup: sets the password and the bridge's name. Fails when a password exists already.
    public func configure(password: String, bridgeName: String?) async throws {
        guard stored.password == nil, !configuring else { throw Failure.alreadyConfigured }
        try Self.validate(password)
        configuring = true
        defer { configuring = false }
        let iterations = iterations
        let hash = await hashing.withLock { await Task.detached(priority: .userInitiated) { StoredPassword.make(password: password, iterations: iterations) }.value }
        stored.password = hash
        if let name = Self.cleaned(bridgeName) { stored.bridgeName = name }
        try persist()
    }

    public func setBridgeName(_ name: String) throws {
        guard let name = Self.cleaned(name) else { return }
        stored.bridgeName = name
        try persist()
    }

    /// Whether `password` is the administrator's. A stored hash is always computed against, so a wrong guess costs the same time.
    public func verify(_ password: String) async -> Bool {
        guard let stored = stored.password, password.utf8.count <= Self.passwordLength.upperBound else { return false }
        return await hashing.withLock { await Task.detached(priority: .userInitiated) { stored.verify(password) }.value }
    }

    /// Changes the password; every session except `keeping` (a session id) signs out.
    public func changePassword(current: String, new: String, keeping sessionID: String?) async throws {
        guard stored.password != nil else { throw Failure.notConfigured }
        try Self.validate(new)
        guard await verify(current) else { throw Failure.wrongPassword }
        let iterations = iterations
        let hash = await hashing.withLock { await Task.detached(priority: .userInitiated) { StoredPassword.make(password: new, iterations: iterations) }.value }
        stored.password = hash
        stored.sessions.removeAll { $0.id != sessionID }
        try persist()
    }

    static func validate(_ password: String) throws {
        let count = password.utf8.count
        if count < passwordLength.lowerBound { throw Failure.passwordTooShort }
        if count > passwordLength.upperBound { throw Failure.passwordTooLong }
    }

    private static func cleaned(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    // MARK: Sessions

    /// A new session; the returned token goes into the cookie and is not stored.
    public func createSession() throws -> (token: String, session: Session) {
        let token = Secrets.randomToken()
        let id = Secrets.sha256Hex(token)
        let date = now()
        pruneSessions(date)
        stored.sessions.append(StoredSession(id: id, created: date, lastSeen: date))
        if stored.sessions.count > Self.maximumSessions {
            stored.sessions.sort { $0.lastSeen > $1.lastSeen }
            stored.sessions = Array(stored.sessions.prefix(Self.maximumSessions))
        }
        try persist()
        return (token, Session(id: id, csrfToken: Secrets.csrfToken(forSessionToken: token)))
    }

    /// The session behind a cookie token, nil when there is none or it expired.
    public func session(token: String) -> Session? {
        guard !token.isEmpty, token.utf8.count <= 128 else { return nil }
        let id = Secrets.sha256Hex(token)
        let date = now()
        guard let index = stored.sessions.firstIndex(where: { Secrets.constantTimeEqual($0.id, id) }) else { return nil }
        let entry = stored.sessions[index]
        if date.timeIntervalSince(entry.lastSeen) > Self.idleLifetime || date.timeIntervalSince(entry.created) > Self.absoluteLifetime {
            stored.sessions.remove(at: index)
            try? persist()
            return nil
        }
        stored.sessions[index].lastSeen = date
        if date.timeIntervalSince(lastPersisted) > Self.persistInterval { try? persist() }
        return Session(id: id, csrfToken: Secrets.csrfToken(forSessionToken: token))
    }

    public func endSession(token: String) {
        let id = Secrets.sha256Hex(token)
        stored.sessions.removeAll { $0.id == id }
        try? persist()
    }

    public var sessionCount: Int { stored.sessions.count }

    private func pruneSessions(_ date: Date) {
        stored.sessions.removeAll {
            date.timeIntervalSince($0.lastSeen) > Self.idleLifetime || date.timeIntervalSince($0.created) > Self.absoluteLifetime
        }
    }

    // MARK: Guessing

    /// Seconds `address` must wait before it may try the password, nil when it may.
    public func loginDelay(address: String) -> Int? {
        limiter.retryAfter(address: address, now: now())
    }

    public func recordLogin(address: String, success: Bool) {
        if success {
            limiter.recordSuccess(address: address)
        } else {
            limiter.recordFailure(address: address, now: now())
            log.notice("a wrong password was entered from \(address)")
        }
    }

    // MARK: Storage

    private func persist() throws {
        do {
            try PrivateFiles.prepareDirectory(file.deletingLastPathComponent())
            try PrivateFiles.write(try JSONEncoder.iso.encode(stored), to: file)
            lastPersisted = now()
        } catch {
            log.error("the web interface could not save its settings: \(Redact.string(String(describing: error)))")
            throw Failure.storageFailed
        }
    }
}

extension JSONEncoder {
    /// ISO 8601 dates, sorted keys (stable files and API output).
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
