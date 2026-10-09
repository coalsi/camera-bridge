import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

@Suite struct PasswordHashTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    // RFC 7914 section 11 and the widely published PBKDF2-HMAC-SHA256 vectors.
    @Test func pbkdf2MatchesPublishedVectors() {
        let password = Array("password".utf8), salt = Array("salt".utf8)
        #expect(hex(PBKDF2.sha256(password: password, salt: salt, iterations: 1)) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(hex(PBKDF2.sha256(password: password, salt: salt, iterations: 2)) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(hex(PBKDF2.sha256(password: password, salt: salt, iterations: 4096)) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        #expect(hex(PBKDF2.sha256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, length: 64))
            == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    @Test func pbkdf2LongerThanOneBlockAndOddLengths() {
        let long = PBKDF2.sha256(password: Array("pass".utf8), salt: Array("NaCl".utf8), iterations: 3, length: 70)
        #expect(long.count == 70)
        #expect(Array(long.prefix(32)) == PBKDF2.sha256(password: Array("pass".utf8), salt: Array("NaCl".utf8), iterations: 3, length: 32))
    }

    @Test func costOfTheDefaultIterationCountStaysPractical() {
        let started = ContinuousClock.now
        _ = StoredPassword.make(password: "benchmark", iterations: AuthStore.defaultIterations)
        let elapsed = ContinuousClock.now - started
        // A login should not take seconds on a small machine; debug builds are several times slower than release.
        #expect(elapsed < .seconds(20), "600,000 iterations took \(elapsed)")
    }

    @Test func storedPasswordVerifiesOnlyTheRightPassword() {
        let stored = StoredPassword.make(password: "correct horse", iterations: 1_000)
        #expect(stored.verify("correct horse"))
        #expect(!stored.verify("correct horse "))
        #expect(!stored.verify(""))
        #expect(!stored.verify("Correct horse"))
    }

    @Test func eachHashHasItsOwnSaltAndNeverContainsThePassword() throws {
        let a = StoredPassword.make(password: "same password", iterations: 1_000)
        let b = StoredPassword.make(password: "same password", iterations: 1_000)
        #expect(a.salt != b.salt)
        #expect(a.hash != b.hash)
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!json.contains("same password"))
    }

    @Test func aDamagedOrHostileStoredCostIsRefused() {
        var stored = StoredPassword.make(password: "pw-pw-pw-pw", iterations: 1_000)
        #expect(stored.verify("pw-pw-pw-pw"))
        stored.iterations = 0
        #expect(!stored.verify("pw-pw-pw-pw"))
        stored.iterations = StoredPassword.maximumIterations + 1
        #expect(!stored.verify("pw-pw-pw-pw"))
        stored.iterations = 1_000
        stored.algorithm = "md5"
        #expect(!stored.verify("pw-pw-pw-pw"))
        stored.algorithm = StoredPassword.algorithmName
        stored.hash = "not base64 !!"
        #expect(!stored.verify("pw-pw-pw-pw"))
    }
}

@Suite struct SecretsTests {
    @Test func tokensAre256BitsAndDistinct() {
        let tokens = (0..<50).map { _ in Secrets.randomToken() }
        #expect(Set(tokens).count == 50)
        for token in tokens {
            #expect(token.count == 43)   // 32 bytes, base64url without padding
            #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test func constantTimeComparison() {
        #expect(Secrets.constantTimeEqual("abc", "abc"))
        #expect(!Secrets.constantTimeEqual("abc", "abd"))
        #expect(!Secrets.constantTimeEqual("abc", "abcd"))
        #expect(!Secrets.constantTimeEqual("", "a"))
        #expect(Secrets.constantTimeEqual("", ""))
        #expect(Secrets.constantTimeEqual([1, 2, 3], [1, 2, 3]))
    }

    @Test func csrfTokenFollowsTheSessionToken() {
        let a = Secrets.csrfToken(forSessionToken: "token-a")
        #expect(a == Secrets.csrfToken(forSessionToken: "token-a"))
        #expect(a != Secrets.csrfToken(forSessionToken: "token-b"))
        #expect(a != "token-a")
    }
}

@Suite struct LoginLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fiveFreeAttemptsThenALockoutThatDoubles() {
        var limiter = LoginLimiter()
        for _ in 0..<4 { limiter.recordFailure(address: "192.0.2.1", now: start) }
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start) == nil)
        limiter.recordFailure(address: "192.0.2.1", now: start)
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start) == 15)
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(14)) == 1)
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(15)) == nil)
        limiter.recordFailure(address: "192.0.2.1", now: start.addingTimeInterval(20))
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(20)) == 30)
        limiter.recordFailure(address: "192.0.2.1", now: start.addingTimeInterval(60))
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(60)) == 60)
    }

    @Test func theLockoutIsCapped() {
        var capped = LoginLimiter(policy: .init(window: 1_000_000))
        for index in 0..<40 { capped.recordFailure(address: "192.0.2.1", now: start.addingTimeInterval(Double(index))) }
        #expect((capped.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(39)) ?? 0) <= 900)
    }

    @Test func otherAddressesAreNotLockedAndSuccessClears() {
        var limiter = LoginLimiter()
        for _ in 0..<5 { limiter.recordFailure(address: "192.0.2.1", now: start) }
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start) != nil)
        #expect(limiter.retryAfter(address: "192.0.2.2", now: start) == nil)
        limiter.recordSuccess(address: "192.0.2.1")
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start) == nil)
    }

    @Test func oldFailuresAreForgotten() {
        var limiter = LoginLimiter()
        for _ in 0..<4 { limiter.recordFailure(address: "192.0.2.1", now: start) }
        limiter.recordFailure(address: "192.0.2.1", now: start.addingTimeInterval(1_000))   // past the 15 minute window: counts as the first
        #expect(limiter.retryAfter(address: "192.0.2.1", now: start.addingTimeInterval(1_000)) == nil)
    }

    @Test func manyAddressesTogetherSlowEveryone() {
        var limiter = LoginLimiter(policy: .init(globalFailures: 10))
        for index in 0..<10 { limiter.recordFailure(address: "198.51.100.\(index)", now: start) }
        #expect(limiter.retryAfter(address: "203.0.113.9", now: start) == 60)
        #expect(limiter.retryAfter(address: "203.0.113.9", now: start.addingTimeInterval(61)) == nil)
    }

    @Test func memoryIsBounded() {
        var limiter = LoginLimiter(policy: .init(globalFailures: 1_000_000, maximumAddresses: 20))
        for index in 0..<100 { limiter.recordFailure(address: "192.0.2.\(index)", now: start.addingTimeInterval(Double(index))) }
        #expect(limiter.trackedAddressCount == 20)
    }
}

@Suite struct AuthStoreTests {
    private func makeStore(_ directory: TemporaryDirectory, clock: Box<Date> = Box(Date(timeIntervalSince1970: 1_800_000_000))) -> AuthStore {
        AuthStore(directory: directory.url, iterations: 1_000, now: { clock.value })
    }

    @Test func setupOnceThenNever() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        #expect(await !store.isConfigured)
        try await store.configure(password: "long enough", bridgeName: "  Hall  ")
        #expect(await store.isConfigured)
        #expect(await store.bridgeName == "Hall")
        await #expect(throws: AuthStore.Failure.alreadyConfigured) { try await store.configure(password: "another one", bridgeName: nil) }
        #expect(await store.verify("long enough"))
        #expect(await !store.verify("long enough!"))
    }

    @Test func concurrentSetupsLetExactlyOneWin() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<6 { group.addTask { (try? await store.configure(password: "password-\(index)", bridgeName: nil)) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(results == 1)
    }

    @Test func passwordLengthLimits() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        await #expect(throws: AuthStore.Failure.passwordTooShort) { try await store.configure(password: "short", bridgeName: nil) }
        await #expect(throws: AuthStore.Failure.passwordTooLong) { try await store.configure(password: String(repeating: "x", count: 257), bridgeName: nil) }
        try await store.configure(password: String(repeating: "x", count: 256), bridgeName: nil)
    }

    @Test func theFileHoldsAHashAndSessionHashesNeverSecrets() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        try await store.configure(password: "my secret password", bridgeName: nil)
        let (token, _) = try await store.createSession()
        let file = directory.url.appending(path: "web/auth.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("my secret password"))
        #expect(!text.contains(token))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func everythingSurvivesARestart() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let first = makeStore(directory)
        try await first.configure(password: "survives restarts", bridgeName: "Garage")
        let (token, session) = try await first.createSession()
        let second = makeStore(directory)
        #expect(await second.isConfigured)
        #expect(await second.bridgeName == "Garage")
        #expect(await second.verify("survives restarts"))
        #expect(await second.session(token: token) == session)
    }

    @Test func sessionsExpireAfterIdleAndAbsoluteLifetimes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let (idle, _) = try await store.createSession()
        clock.set(clock.value.addingTimeInterval(6 * 86_400))
        #expect(await store.session(token: idle) != nil)   // seen again: the idle clock restarts
        clock.set(clock.value.addingTimeInterval(6 * 86_400))
        #expect(await store.session(token: idle) != nil)
        clock.set(clock.value.addingTimeInterval(8 * 86_400))
        #expect(await store.session(token: idle) == nil, "idle for more than 7 days")

        let (absolute, _) = try await store.createSession()
        for _ in 0..<5 {
            clock.set(clock.value.addingTimeInterval(6 * 86_400))
            _ = await store.session(token: absolute)
        }
        clock.set(clock.value.addingTimeInterval(1 * 86_400))
        #expect(await store.session(token: absolute) == nil, "older than 30 days, however often it was used")
    }

    @Test func unknownAndMalformedTokensAreRefused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        try await store.configure(password: "long enough", bridgeName: nil)
        #expect(await store.session(token: "") == nil)
        #expect(await store.session(token: "nope") == nil)
        #expect(await store.session(token: String(repeating: "a", count: 500)) == nil)
    }

    @Test func changingThePasswordSignsOutTheOtherBrowsers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        try await store.configure(password: "old password", bridgeName: nil)
        let (mine, mySession) = try await store.createSession()
        let (other, _) = try await store.createSession()
        await #expect(throws: AuthStore.Failure.wrongPassword) { try await store.changePassword(current: "nope nope", new: "new password", keeping: mySession.id) }
        try await store.changePassword(current: "old password", new: "new password", keeping: mySession.id)
        #expect(await store.session(token: mine) != nil)
        #expect(await store.session(token: other) == nil)
        #expect(await store.verify("new password"))
        #expect(await !store.verify("old password"))
    }

    @Test func endingASession() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        try await store.configure(password: "long enough", bridgeName: nil)
        let (token, _) = try await store.createSession()
        await store.endSession(token: token)
        #expect(await store.session(token: token) == nil)
    }

    @Test func aCorruptFileMeansNotConfiguredRatherThanACrash() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url.appending(path: "web", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appending(path: "auth.json"))
        let store = makeStore(directory)
        #expect(await !store.isConfigured)
    }

    @Test func sessionCountIsBounded() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory)
        try await store.configure(password: "long enough", bridgeName: nil)
        for _ in 0..<(AuthStore.maximumSessions + 10) { _ = try await store.createSession() }
        #expect(await store.sessionCount == AuthStore.maximumSessions)
    }
}
