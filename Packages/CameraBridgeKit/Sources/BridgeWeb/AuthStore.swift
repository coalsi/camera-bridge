import BridgeSupport
import Foundation

/// How fast a peer may guess the password. Five wrong passwords from one address lock that address out for 15 seconds, doubling
/// with each further failure up to 15 minutes; many failures from everywhere together (a spread-out guess) slow everyone
/// down for a minute. A right password clears the address's count. Memory is bounded (oldest addresses are forgotten).
///
/// A check is admitted (`begin`) before its password is hashed and counted (`finish`) after, and the checks still running count
/// as failures already: parallel guesses from one address cannot get past the five free ones, and at most `maximumInFlight`
/// checks run or wait anywhere (the next is refused at once, never queued behind them). An IPv6 address counts by its /64, the
/// prefix of one home network, so a host cannot hop between the addresses of its own network.
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
        /// Password checks running or waiting at once, from everywhere.
        var maximumInFlight = 4
    }

    private struct Entry: Sendable {
        var failures = 0
        var lastFailure = Date.distantPast
        var lockedUntil = Date.distantPast
        /// Checks admitted and not finished yet.
        var pending = 0
    }

    var policy = Policy()
    private var entries: [String: Entry] = [:]
    private var recent: [Date] = []
    private var globalLockedUntil = Date.distantPast
    private var pendingTotal = 0

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Addresses remembered (tests).
    var trackedAddressCount: Int { entries.count }

    /// Seconds to wait before `address` may try again, nil when it may.
    func retryAfter(address: String, now: Date) -> Int? {
        let until = max(entries[Self.key(for: address)]?.lockedUntil ?? .distantPast, globalLockedUntil)
        let remaining = until.timeIntervalSince(now)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }

    /// Admits one check from `address` (nil), or says how many seconds it must wait. Every admitted check is ended with `finish`.
    mutating func begin(address: String, now: Date) -> Int? {
        if let wait = retryAfter(address: address, now: now) { return wait }
        let key = Self.key(for: address)
        var entry = entries[key] ?? Entry()
        let failures = now.timeIntervalSince(entry.lastFailure) > policy.window ? 0 : entry.failures
        guard failures + entry.pending < policy.freeAttempts, pendingTotal < policy.maximumInFlight else { return 1 }
        entry.pending += 1
        pendingTotal += 1
        entries[key] = entry
        return nil
    }

    /// Ends a check `begin` admitted: `success` true for the right password, false for a wrong one, nil when no password was checked.
    /// True when this failure locked the address out, or everyone.
    @discardableResult
    mutating func finish(address: String, success: Bool?, now: Date) -> Bool {
        let key = Self.key(for: address)
        pendingTotal = max(0, pendingTotal - 1)
        if var entry = entries[key] {
            entry.pending = max(0, entry.pending - 1)
            entries[key] = entry
        }
        switch success {
        case true?: recordSuccess(address: address)
        case false?: return recordFailure(address: address, now: now)
        case nil: if let entry = entries[key], entry.pending == 0, entry.failures == 0 { entries[key] = nil }
        }
        return false
    }

    /// True when this failure locked the address out (its fifth in the window), or everyone (the global count reached).
    @discardableResult
    mutating func recordFailure(address: String, now: Date) -> Bool {
        let key = Self.key(for: address)
        var entry = entries[key] ?? Entry()
        if now.timeIntervalSince(entry.lastFailure) > policy.window { entry.failures = 0 }
        entry.failures += 1
        entry.lastFailure = now
        if entry.failures >= policy.freeAttempts {
            let exponent = min(entry.failures - policy.freeAttempts, 20)
            entry.lockedUntil = now.addingTimeInterval(min(policy.firstLockout * pow(2, Double(exponent)), policy.maximumLockout))
        }
        entries[key] = entry
        if entries.count > policy.maximumAddresses {
            // Never the ones with a check under way: their `finish` would find no entry.
            let oldest = entries.filter { $0.value.pending == 0 }.sorted { $0.value.lastFailure < $1.value.lastFailure }
                .prefix(entries.count - policy.maximumAddresses)
            for (key, _) in oldest { entries[key] = nil }
        }
        recent.append(now)
        recent.removeAll { now.timeIntervalSince($0) > policy.globalWindow }
        let wasLocked = globalLockedUntil > now
        if recent.count >= policy.globalFailures { globalLockedUntil = now.addingTimeInterval(policy.globalLockout) }
        return entry.failures == policy.freeAttempts || (!wasLocked && globalLockedUntil > now)
    }

    /// Addresses that must wait now.
    func lockedCount(now: Date) -> Int {
        entries.values.filter { $0.lockedUntil > now }.count
    }

    mutating func recordSuccess(address: String) {
        let key = Self.key(for: address)
        let pending = entries[key]?.pending ?? 0
        entries[key] = pending > 0 ? Entry(pending: pending) : nil
    }

    // MARK: Addresses

    /// What an address is counted under: an IPv6 address by its /64 ("2001:db8:1:2::/64"), an IPv4 address written as IPv6
    /// (`::ffff:192.0.2.7`) as that IPv4 address, anything else as it is.
    static func key(for address: String) -> String {
        var text = address.lowercased()
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }   // a link-local address's zone
        guard text.contains(":"), let groups = ipv6Groups(text) else { return address }
        if groups[0..<5].allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return [groups[6] >> 8, groups[6] & 0xFF, groups[7] >> 8, groups[7] & 0xFF].map(String.init).joined(separator: ".")
        }
        return groups[0..<4].map { String($0, radix: 16) }.joined(separator: ":") + "::/64"
    }

    /// The eight 16-bit groups of an IPv6 address in text form (with "::" and a trailing dotted IPv4 part), nil when it is not one.
    static func ipv6Groups(_ text: String) -> [UInt16]? {
        func parse(_ part: Substring) -> [UInt16]? {
            if part.isEmpty { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            var groups: [UInt16] = []
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, piece.contains(".") {
                    let octets = piece.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
                    guard octets.count == 4 else { return nil }
                    groups += [UInt16(octets[0]) << 8 | UInt16(octets[1]), UInt16(octets[2]) << 8 | UInt16(octets[3])]
                } else {
                    guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                    groups.append(value)
                }
            }
            return groups
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2, let head = parse(Substring(halves[0])) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = parse(Substring(halves[1])), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }
}

/// The administrator: one password, the bridge's name, the signed-in browsers and the Apple TVs, and the box's identity. Kept in
/// `<data>/web/auth.json` (0600 in a 0700 directory): the password as a PBKDF2 hash, a session as the SHA-256 of its token (the token
/// itself is only in the browser's cookie), an Apple TV as the SHA-256 of its key (the key is only on the TV), so a copy of the file signs
/// nobody in.
///
/// - `configure` runs once (first-run setup); a second attempt fails. Nothing else works until it has.
/// - A session lasts 7 days after its last use and 30 days at most. Changing the password signs every other browser out.
/// - An Apple TV is added with a code the owner types while signed in (`ViewerPairing` holds the requests, in memory only) and is handed
///   its key once. At most 20 are kept, a key unused for a year stops working, and changing the password keeps them all.
/// - `bridgeID()` is the box's identity, made the first time anyone asks and kept in the same file as the TVs. Both are optional in the
///   file: one written before them still reads.
/// - Passwords are 8 to 256 bytes long; hashing happens off the actor, one at a time, so guesses cannot pile up on the CPU.
/// - A file that is there but cannot be read or decoded is not a new bridge (offering setup would let anyone on the network claim it):
///   the store reads `auth.json.bak` instead when there is one, and without one it is `isDamaged`: configured, with no password that can
///   be right, until a factory reset. The damaged file is never written over. The store does not make the `.bak` itself (`persist` does
///   not ask `PrivateFiles` to keep the version it replaces): it is a copy that somebody put there.
/// - A sign-in works while the file cannot be written (a full or read-only data partition): the session is kept in memory and saved
///   once the disk takes it again, as are the box's identity and the removal of an Apple TV. A first-run setup that cannot be saved is
///   undone, and so is the adding of an Apple TV, so neither holds only until the next restart.
public actor AuthStore {
    public enum Failure: Error, Equatable, Sendable {
        case alreadyConfigured
        case notConfigured
        case passwordTooShort
        case passwordTooLong
        case wrongPassword
        case storageFailed
        /// `auth.json` is there but cannot be read (`isDamaged`).
        case unreadable
    }

    struct StoredSession: Codable, Equatable {
        var id: String
        var created: Date
        var lastSeen: Date
        /// The browser and system it signed in from ("Safari on iPhone", `BrowserLabel`) and the address: optional, so a file from before
        /// them still reads.
        var label: String?
        var address: String?
    }

    /// An Apple TV as the file keeps it.
    struct StoredViewer: Codable, Equatable {
        /// 32 random hex characters of its own, not derived from the key (`ViewerInfo.id`).
        var id: String
        /// The SHA-256 of the key, in hex: the key itself is only on the TV.
        var tokenHash: String
        var name: String
        var device: String?
        var created: Date
        /// Written to the file at most hourly, like a session's.
        var lastSeen: Date?
        var address: String?

        var info: ViewerInfo {
            ViewerInfo(id: id, name: name, device: device, created: created, lastSeen: lastSeen, address: address)
        }

        /// Its key has gone unused for a year (counted from when the TV was added until it is first used), so it stops working.
        func isIdle(at date: Date) -> Bool {
            date.timeIntervalSince(lastSeen ?? created) > AuthStore.viewerIdleLifetime
        }
    }

    struct Stored: Codable, Equatable {
        var version = 1
        var bridgeName = AuthStore.defaultBridgeName
        var password: StoredPassword?
        var sessions: [StoredSession] = []
        /// The read-only monitoring token (`GET monitor`), nil while monitoring is off. Kept as it is: the owner copies it into Home
        /// Assistant or Uptime Kuma from Settings, like the webhook's token, and it signs nobody in.
        var monitorToken: String?
        /// The box's identity (`bridgeID()`), nil until it is first asked for.
        var bridgeID: String?
        /// The Apple TVs. Optional, like `bridgeID`: a synthesized `Decodable` throws on a key that is missing even when the property has a
        /// default, and a file that cannot be decoded is taken for a damaged one, so a file written before Apple TVs would lock the owner out.
        var viewers: [StoredViewer]?
    }

    /// A signed-in browser, as the Signed-in browsers list shows it.
    public struct SessionInfo: Sendable, Equatable {
        /// Not the session's own id: a name derived from it, enough to sign it out and nothing else.
        public var id: String
        public var browser: String
        public var address: String?
        public var created: Date
        public var lastSeen: Date
        /// The browser that asked.
        public var current: Bool
    }

    /// Wrong passwords that came in a burst: an address locked out, or everyone slowed down. It lasts until a day passes without a wrong
    /// password, and every wrong one meanwhile is counted in it.
    public struct SignInAlert: Sendable, Equatable {
        public var since: Date
        public var last: Date
        public var count: Int
        /// The addresses they came from, the latest first (at most 5).
        public var addresses: [String]
        /// How many different addresses, all told.
        public var addressCount: Int
    }

    /// Failed sign-ins for monitoring.
    public struct SignInCounts: Sendable, Equatable {
        public var lastHour: Int
        public var lastDay: Int
        /// Addresses (an IPv6 network counts once) that must wait now.
        public var lockedAddresses: Int
        /// Too many wrong passwords from everywhere: every sign-in waits for now.
        public var everyoneWaits: Bool
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
    /// A burst of wrong passwords is forgotten after this long without one.
    static let quietDay: TimeInterval = 86_400
    /// The Apple TVs the box keeps; one has to be removed before another can be added.
    static let maximumViewers = 20
    /// A TV's key stops working after this long unused.
    static let viewerIdleLifetime: TimeInterval = 365 * 86_400
    /// What a device (an Apple TV, an iPhone) is called when it did not say.
    static let defaultViewerName = "Device"

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
    /// A change that could not be written yet (a new session, the box's identity, an Apple TV removed): saved on the next use of a session or
    /// of a TV's key (`saveOrRetryLater`).
    private var unsaved = false
    /// Wrong passwords of the last day, oldest first (at most `maximumFailuresKept`), and the burst they are in.
    private var failures: [(date: Date, address: String)] = []
    private var alert: SignInAlert?
    /// The Apple TVs that are asking to be added: in memory only.
    private var pairing = ViewerPairing()
    private static let maximumFailuresKept = 5_000
    private let damaged: Bool
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
        let backup = file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".bak", directoryHint: .notDirectory)
        switch Self.load(file) {
        case .stored(let found):
            stored = found
            damaged = false
        case .missing:
            stored = Stored()
            damaged = false
        case .unreadable(let why):
            if case .stored(let found) = Self.load(backup) {
                stored = found
                damaged = false
                log.notice("the web interface's \(file.lastPathComponent) could not be read (\(why)); using the copy from before its last change")
            } else {
                stored = Stored()
                damaged = true
                log.error("the web interface's \(file.lastPathComponent) could not be read (\(why)) and has no usable copy, so nobody can sign in. "
                    + "A factory reset sets a new password: an empty file named camera-bridge-factory-reset on the boot partition, then a restart.")
            }
        }
    }

    private enum Loaded {
        case missing
        case stored(Stored)
        case unreadable(String)
    }

    /// What is at `url`: nothing (no such file: a new bridge), the stored state, or a file that cannot be read or decoded.
    private static func load(_ url: URL) -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable("it cannot be opened")
        }
        guard let decoded = try? JSONDecoder.iso.decode(Stored.self, from: data) else { return .unreadable(data.isEmpty ? "it is empty" : "it is damaged") }
        return .stored(decoded)
    }

    /// True while there is a password, and while `auth.json` is damaged (see the type): then nobody can sign in and setup is not offered.
    public var isConfigured: Bool { stored.password != nil || damaged }

    /// `auth.json` is there but could not be read, and no backup could be: no password can be checked until a factory reset.
    public var isDamaged: Bool { damaged }

    public var bridgeName: String { stored.bridgeName }

    // MARK: Setup and password

    /// First-run setup: sets the password and the bridge's name. Fails when a password exists already.
    public func configure(password: String, bridgeName: String?) async throws {
        guard !damaged else { throw Failure.unreadable }
        guard stored.password == nil, !configuring else { throw Failure.alreadyConfigured }
        try Self.validate(password)
        configuring = true
        defer { configuring = false }
        let iterations = iterations
        let hash = await hashing.withLock { await Task.detached(priority: .userInitiated) { StoredPassword.make(password: password, iterations: iterations) }.value }
        let before = stored
        stored.password = hash
        if let name = Self.cleaned(bridgeName) { stored.bridgeName = name }
        do {
            try persist()
        } catch {
            stored = before   // not set up in memory only: the setup would open again, unseen, at the next restart
            throw error
        }
    }

    public func setBridgeName(_ name: String) throws {
        guard let name = Self.cleaned(name) else { return }
        stored.bridgeName = name
        try persist()
    }

    /// Whether `password` is the administrator's. A stored hash is always computed against, so a wrong guess costs the same time.
    public func verify(_ password: String) async -> Bool {
        guard let stored = stored.password, password.utf8.count <= Self.passwordLength.upperBound else { return false }
        passwordChecks += 1
        checksWaiting += 1
        mostChecksAtOnce = max(mostChecksAtOnce, checksWaiting)
        defer { checksWaiting -= 1 }
        return await hashing.withLock { await Task.detached(priority: .userInitiated) { stored.verify(password) }.value }
    }

    /// Password checks made, and the most that ran or waited at once (tests).
    private(set) var passwordChecks = 0
    private(set) var mostChecksAtOnce = 0
    private var checksWaiting = 0

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
    /// `userAgent` and `address`: what the Signed-in browsers list shows for it (the address as the request came, through the TLS front's
    /// `X-Forwarded-For`).
    public func createSession(userAgent: String? = nil, address: String? = nil) throws -> (token: String, session: Session) {
        let token = Secrets.randomToken()
        let id = Secrets.sha256Hex(token)
        let date = now()
        pruneSessions(date)
        stored.sessions.append(StoredSession(id: id, created: date, lastSeen: date, label: BrowserLabel.describe(userAgent),
                                             address: address.map { String($0.prefix(64)) }))
        if stored.sessions.count > Self.maximumSessions {
            stored.sessions.sort { $0.lastSeen > $1.lastSeen }
            stored.sessions = Array(stored.sessions.prefix(Self.maximumSessions))
        }
        // A data partition that is full or went read-only must not lock the owner out of the page that would tell them: the session
        // lives in memory and is written on its next use once the disk takes it (`persist` logged the failure).
        do { try persist() } catch { unsaved = true }
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
        if unsaved || date.timeIntervalSince(lastPersisted) > Self.persistInterval { try? persist() }
        return Session(id: id, csrfToken: Secrets.csrfToken(forSessionToken: token))
    }

    /// Whether the session `Session.id` names is still signed in (not signed out, removed from the list or expired).
    public func isSessionListed(_ id: String) -> Bool {
        pruneSessions(now())
        return stored.sessions.contains { Secrets.constantTimeEqual($0.id, id) }
    }

    public func endSession(token: String) {
        let id = Secrets.sha256Hex(token)
        stored.sessions.removeAll { $0.id == id }
        try? persist()
    }

    /// The signed-in browsers, the one used last first; `current` is the session id of the browser that asks.
    public func sessions(current: String?) -> [SessionInfo] {
        pruneSessions(now())
        return stored.sessions.sorted { $0.lastSeen > $1.lastSeen }.map { entry in
            SessionInfo(id: Self.publicID(entry.id), browser: entry.label ?? "A browser", address: entry.address, created: entry.created,
                        lastSeen: entry.lastSeen, current: entry.id == current)
        }
    }

    /// Signs out the browser `SessionInfo.id` names; false when there is none. The session id it had, so the caller knows whether it was
    /// its own.
    public func endSession(listedAs publicID: String) -> (ended: Bool, sessionID: String?) {
        guard let entry = stored.sessions.first(where: { Secrets.constantTimeEqual(Self.publicID($0.id), publicID) }) else { return (false, nil) }
        stored.sessions.removeAll { $0.id == entry.id }
        try? persist()
        return (true, entry.id)
    }

    /// What the list calls a session: derived from its id (itself the SHA-256 of the cookie's token), so the list gives away neither.
    static func publicID(_ sessionID: String) -> String {
        String(Secrets.sha256Hex("camera-bridge session list " + sessionID).prefix(24))
    }

    public var sessionCount: Int { stored.sessions.count }

    private func pruneSessions(_ date: Date) {
        stored.sessions.removeAll {
            date.timeIntervalSince($0.lastSeen) > Self.idleLifetime || date.timeIntervalSince($0.created) > Self.absoluteLifetime
        }
    }

    // MARK: Guessing

    /// What one password check from an address came to.
    public enum PasswordCheck: Equatable, Sendable {
        case right
        case wrong
        /// Not checked: too many wrong tries from this address (or everywhere), or too many checks under way; try again after so many seconds.
        case wait(Int)
    }

    /// Admits one check of a secret from `address` (the password, the setup code), or says how many seconds it must wait. Admission
    /// and counting happen on this actor, so checks that run at the same time count against the free attempts together (see
    /// `LoginLimiter`). Every nil is followed by `finishAttempt`.
    public func beginAttempt(address: String) -> Int? {
        limiter.begin(address: address, now: now())
    }

    /// Ends a check `beginAttempt` admitted: `success` true for the right secret, false for a wrong one, nil when nothing was checked.
    public func finishAttempt(address: String, success: Bool?) {
        let date = now()
        let lockedOut = limiter.finish(address: address, success: success, now: date)
        guard success == false else { return }
        log.notice("a wrong password was entered from \(address)")
        failures.append((date, address))
        failures.removeAll { date.timeIntervalSince($0.date) > Self.quietDay }
        if failures.count > Self.maximumFailuresKept { failures.removeFirst(failures.count - Self.maximumFailuresKept) }
        if var current = alert, date.timeIntervalSince(current.last) <= Self.quietDay {
            current.count += 1
            current.last = date
            if !current.addresses.contains(address) { current.addressCount += 1 }
            current.addresses = Array(([address] + current.addresses.filter { $0 != address }).prefix(5))
            alert = current
        } else if lockedOut {
            // The burst starts with the wrong passwords that led to it: those of the last hour.
            let recent = failures.filter { date.timeIntervalSince($0.date) <= 3_600 }
            var addresses: [String] = []
            for failure in recent.reversed() where !addresses.contains(failure.address) { addresses.append(failure.address) }
            alert = SignInAlert(since: date, last: date, count: recent.count, addresses: Array(addresses.prefix(5)), addressCount: addresses.count)
            log.warning("\(recent.count) wrong passwords in the last hour (latest from \(address)): sign-ins are paused for a while")
        }
    }

    /// The burst of wrong passwords under way, or of the last day; nil once a day has passed without one.
    public func signInAlert() -> SignInAlert? {
        guard let alert, now().timeIntervalSince(alert.last) <= Self.quietDay else {
            alert = nil
            return nil
        }
        return alert
    }

    /// Wrong passwords of the last hour and day, and the addresses waiting now.
    public func signInCounts() -> SignInCounts {
        let date = now()
        let day = failures.filter { date.timeIntervalSince($0.date) <= Self.quietDay }
        return SignInCounts(lastHour: day.filter { date.timeIntervalSince($0.date) <= 3_600 }.count, lastDay: day.count,
                            lockedAddresses: limiter.lockedCount(now: date), everyoneWaits: limiter.retryAfter(address: "", now: date) != nil)
    }

    // MARK: Monitoring

    /// Whether `GET monitor` answers, and its token: nil while off.
    public var monitorToken: String? { stored.monitorToken }

    /// Turns monitoring on (with a new token when there is none, or when `regenerate`) or off (the token is forgotten).
    public func setMonitoring(enabled: Bool, regenerate: Bool = false) throws {
        if !enabled {
            stored.monitorToken = nil
        } else if stored.monitorToken == nil || regenerate {
            stored.monitorToken = Secrets.randomToken()
        }
        try persist()
    }

    /// Whether `presented` is the monitoring token (false while monitoring is off).
    public func isMonitorToken(_ presented: String) -> Bool {
        guard let token = stored.monitorToken, !presented.isEmpty, presented.utf8.count <= 128 else { return false }
        return Secrets.constantTimeEqual(presented, token)
    }

    /// `password` checked against the administrator's, from `address`, through the limiter.
    public func checkPassword(_ password: String, address: String) async -> PasswordCheck {
        if let wait = beginAttempt(address: address) { return .wait(wait) }
        let right = await verify(password)
        finishAttempt(address: address, success: right)
        return right ? .right : .wrong
    }

    // MARK: Apple TVs

    /// An Apple TV that was added with a pairing code, as the Apple TV card lists it. Never its key: the box keeps only the key's SHA-256.
    public struct ViewerInfo: Sendable, Equatable {
        /// 32 random hex characters of its own, not derived from the key: it names the TV in the list and signs nobody in.
        public var id: String
        public var name: String
        /// The model as the TV sent it ("Apple TV 4K (3rd generation)"), shown as it came.
        public var device: String?
        public var created: Date
        /// When its key was last used, nil while it never was.
        public var lastSeen: Date?
        /// Where it last came from.
        public var address: String?
    }

    /// What a TV is given when it asks to be added: `request` and `secret` to ask again with, and the `code` to show on its screen.
    public struct PairingStart: Sendable, Equatable {
        public var request: String
        public var secret: String
        /// As it is shown, with the dash ("BCDF-GHJK").
        public var code: String
        /// Seconds the request lasts.
        public var expiresIn: Int
        /// Seconds the TV waits between questions.
        public var interval: Int
    }

    /// The answer to a TV asking whether its code was entered.
    public enum PairingStatus: Sendable, Equatable {
        case waiting
        /// The TV's key, plain, this once: the request is over with this answer.
        case approved(token: String, viewer: ViewerInfo)
        /// Ended, removed, never there, or asked with a wrong secret: the TV starts again with a new code.
        case gone
    }

    /// Why a pairing call did not go through.
    public enum PairingFailure: Error, Equatable, Sendable {
        /// Too many requests are open, from this address or in all: ask again after so many seconds.
        case busy(retryAfter: Int)
        /// The code opens nothing: unknown, ended, approved already, or not a code.
        case noSuchCode
        /// The box takes no more Apple TVs: one has to be removed first.
        case tooManyViewers
    }

    /// The box's identity: 32 lowercase hex characters, made the first time anyone asks and kept in `auth.json` from then on. An Apple
    /// TV knows the box by it, so it outlives restarts, updates and new passwords, and goes only with a factory reset.
    public func bridgeID() -> String {
        if let id = stored.bridgeID { return id }
        let id = Secrets.hex(Secrets.randomBytes(16))
        stored.bridgeID = id
        saveOrRetryLater()
        return id
    }

    /// A TV asks to be added from `address`. Its `name` and `device` are cleaned as the bridge's name is ("Apple TV" for no name). Throws
    /// `busy` when that address, or everyone together, has too many requests open.
    public func beginPairing(name: String?, device: String?, address: String) throws -> PairingStart {
        let date = now()
        removeLapsedViewers(date)
        let request = try pairing.open(name: Self.cleaned(name) ?? Self.defaultViewerName, device: Self.cleaned(device),
                                       address: String(address.prefix(64)), now: date)
        return PairingStart(request: request.id, secret: request.secret, code: ViewerPairing.displayed(request.code),
                            expiresIn: Int(pairing.policy.lifetime), interval: pairing.policy.interval)
    }

    /// The owner types the code a TV shows. The TV is added at once, and its next question is answered with its new key, which the box
    /// keeps only as a hash. Throws `noSuchCode` (the code stays as it was), `tooManyViewers`, `storageFailed` when the TV cannot be
    /// saved (it is not added then, and the code still waits), and `unreadable` while `auth.json` is damaged (`isDamaged`: nothing can be saved).
    public func approvePairing(code: String) throws -> ViewerInfo {
        // One reading of the clock for the whole call: a request found open here is still open when it is approved below, so a saved TV
        // always has its key waiting for it.
        let date = now()
        removeLapsedViewers(date)
        guard let code = ViewerPairing.normalized(code), let request = pairing.waiting(code: code, now: date) else { throw PairingFailure.noSuchCode }
        guard viewerList.count < Self.maximumViewers else { throw PairingFailure.tooManyViewers }
        let token = Secrets.hex(Secrets.randomBytes(32))
        let viewer = StoredViewer(id: Secrets.hex(Secrets.randomBytes(16)), tokenHash: Secrets.sha256Hex(token), name: request.name,
                                  device: request.device, created: date, address: request.address)
        let before = stored
        viewerList.append(viewer)
        do {
            try persist()
        } catch {
            stored = before   // not added in memory only: it would be gone at the next restart, with the key it was just given
            throw error
        }
        log.notice("an Apple TV was added (\(viewer.name))")
        pairing.approve(requestID: request.id, token: token, viewer: viewer.info, now: date)
        return viewer.info
    }

    /// What a TV that asks with its `request` and `secret` is told. Values that cannot be ours are `.gone` without a look.
    public func pairingStatus(request: String, secret: String) -> PairingStatus {
        guard Self.isLowercaseHex(request, count: 32), Self.isLowercaseHex(secret, count: 64) else { return .gone }
        let date = now()
        removeLapsedViewers(date)
        return pairing.status(request: request, secret: secret, now: date)
    }

    /// The Apple TVs, the one used last first (one not used yet counts from when it was added).
    public func viewers() -> [ViewerInfo] {
        removeLapsedViewers(now())
        return viewerList.sorted { ($0.lastSeen ?? $0.created) > ($1.lastSeen ?? $1.created) }.map(\.info)
    }

    /// The Apple TV a key belongs to; nil when there is none, or when the TV went unused for a year (it is removed then). A key is 64
    /// lowercase hex characters: anything else is refused at once. The use is kept, when and from `address`, and written to the file at
    /// most hourly, as a session's is.
    public func viewer(token: String, address: String?) -> ViewerInfo? {
        guard Self.isLowercaseHex(token, count: 64) else { return nil }
        let hash = Secrets.sha256Hex(token)
        guard let index = viewerList.firstIndex(where: { Secrets.constantTimeEqual($0.tokenHash, hash) }) else { return nil }
        let date = now()
        if viewerList[index].isIdle(at: date) {
            removeLapsedViewers(date)
            return nil
        }
        viewerList[index].lastSeen = date
        if let address { viewerList[index].address = String(address.prefix(64)) }
        if unsaved || date.timeIntervalSince(lastPersisted) > Self.persistInterval { try? persist() }
        return viewerList[index].info
    }

    /// Whether the TV that `ViewerInfo.id` names is still in the list (a live view asks every few seconds).
    public func isViewerListed(_ id: String) -> Bool {
        viewerList.contains { $0.id == id }
    }

    /// Removes the TV that `ViewerInfo.id` names, with the key that was waiting for it if one was. False when there is no such TV.
    public func removeViewer(id: String) -> Bool {
        removeLapsedViewers(now())
        guard let viewer = viewerList.first(where: { $0.id == id }) else { return false }
        viewerList.removeAll { $0.id == id }
        pairing.forget(viewerID: id)
        log.notice("an Apple TV was removed (\(viewer.name))")
        saveOrRetryLater()
        return true
    }

    /// Takes out the TVs nobody can use any more: those an approval added whose key nobody collected (`ViewerPairing.expire` names them),
    /// and those unused for a year. Every pairing call starts with this.
    private func removeLapsedViewers(_ date: Date) {
        var removed = false
        for id in pairing.expire(now: date) {
            guard let viewer = viewerList.first(where: { $0.id == id }) else { continue }
            viewerList.removeAll { $0.id == id }
            log.notice("an Apple TV whose key was never collected was removed (\(viewer.name))")
            removed = true
        }
        for viewer in viewerList where viewer.isIdle(at: date) {
            viewerList.removeAll { $0.id == viewer.id }
            log.notice("an Apple TV unused for a year was removed (\(viewer.name))")
            removed = true
        }
        if removed { saveOrRetryLater() }
    }

    /// The TVs as the file holds them: `Stored.viewers` is nil in a file from before Apple TVs.
    private var viewerList: [StoredViewer] {
        get { stored.viewers ?? [] }
        set { stored.viewers = newValue }
    }

    /// Whether `text` is `count` lowercase hex characters, the form of a request, a secret and a key.
    private static func isLowercaseHex(_ text: String, count: Int) -> Bool {
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9"), letters = UInt8(ascii: "a")...UInt8(ascii: "f")
        return text.utf8.count == count && text.utf8.allSatisfy { digits.contains($0) || letters.contains($0) }
    }

    // MARK: Storage

    /// Saves a change that is made in memory already. When the disk will not take it, the change stays and is saved on the next use
    /// (`createSession` does the same), so the call that noticed it does not fail.
    private func saveOrRetryLater() {
        do { try persist() } catch { unsaved = true }
    }

    private func persist() throws {
        guard !damaged else { throw Failure.unreadable }   // kept as it is, for whoever looks at it
        do {
            try PrivateFiles.prepareDirectory(file.deletingLastPathComponent())
            try PrivateFiles.write(try JSONEncoder.iso.encode(stored), to: file)
            lastPersisted = now()
            unsaved = false
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
