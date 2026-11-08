import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The Apple TVs and the box's identity in `auth.json` (`AuthStore`): what the file keeps of a TV's key, how many TVs there can be, what
/// ends one, and the file of a box that was set up before any of it. The pairing requests themselves are `ViewerPairingTests`'.
@Suite struct ViewerStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    /// `seconds` after `t0`.
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func makeStore(_ directory: TemporaryDirectory, clock: Box<Date>) -> AuthStore {
        AuthStore(directory: directory.url, iterations: 1_000, now: { clock.value })
    }

    private func isLowercaseHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A TV that asks, is approved and collects its key.
    @discardableResult
    private func pair(_ store: AuthStore, name: String? = "Living Room", device: String? = "Apple TV 4K (3rd generation)",
                      address: String = "192.0.2.40") async throws -> (token: String, viewer: AuthStore.ViewerInfo) {
        let start = try await store.beginPairing(name: name, device: device, address: address)
        _ = try await store.approvePairing(code: start.code)
        let collected = try #require(await store.pairingStatus(request: start.request, secret: start.secret).approval)
        return (collected.token, collected.viewer)
    }

    // MARK: The box's identity

    @Test func theBoxKeepsOneIdentityForLife() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        let id = await store.bridgeID()   // the web interface asks at start, before the owner has set a password
        #expect(isLowercaseHex(id, count: 32), "\(id)")
        #expect(await store.bridgeID() == id)
        #expect(await !store.isConfigured, "an identity alone is not a set-up bridge: setup is still offered")
        #expect(await makeStore(directory, clock: clock).bridgeID() == id, "kept across a restart")
        #expect(await !makeStore(directory, clock: clock).isConfigured)

        try await store.configure(password: "long enough", bridgeName: "Hall")
        #expect(await store.bridgeID() == id)
        try await store.changePassword(current: "long enough", new: "another password", keeping: nil)
        #expect(await store.bridgeID() == id, "a new password is not a new box")
        #expect(await makeStore(directory, clock: clock).bridgeID() == id)

        let other = try TemporaryDirectory()
        defer { other.remove() }
        let different = await makeStore(other, clock: clock).bridgeID()
        #expect(isLowercaseHex(different, count: 32) && different != id, "another box, another identity")
    }

    /// An `auth.json` that cannot be decoded is taken for a damaged one, and then nobody can sign in: the fields this adds must not be
    /// required of a file written without them.
    @Test func aPasswordFileFromBeforeAppleTVsReadsAsItWas() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let password = StoredPassword.make(password: "long enough", iterations: 1_000)
        let written: [String: Any] = [
            "version": 1,
            "bridgeName": "Hallway",
            "sessions": [Any](),
            "password": [
                "algorithm": password.algorithm, "iterations": password.iterations, "salt": password.salt, "hash": password.hash,
            ] as [String: Any],
        ]
        let folder = directory.url.appending(path: "web", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: written).write(to: folder.appending(path: "auth.json"))

        let store = makeStore(directory, clock: clock)
        #expect(await store.isConfigured)
        #expect(await !store.isDamaged)
        #expect(await store.bridgeName == "Hallway")
        #expect(await store.verify("long enough"))
        #expect(await store.viewers().isEmpty)

        let id = await store.bridgeID()
        let restarted = makeStore(directory, clock: clock)
        #expect(await !restarted.isDamaged)
        #expect(await restarted.bridgeName == "Hallway")
        #expect(await restarted.verify("long enough"), "the password is still there once the identity is written beside it")
        #expect(await restarted.bridgeID() == id)
    }

    // MARK: Pairing and the file

    @Test func aTVPairsOnceAndTheFileHoldsOnlyItsKeysHash() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)

        let start = try await store.beginPairing(name: "Living Room", device: "Apple TV 4K (3rd generation)", address: "192.0.2.40")
        #expect(start.code.range(of: "^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$", options: .regularExpression) != nil, "\(start.code)")
        #expect(start.expiresIn == 600 && start.interval == 2)
        #expect(isLowercaseHex(start.request, count: 32) && isLowercaseHex(start.secret, count: 64))
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .waiting)
        #expect(await store.viewers().isEmpty, "nothing is added before the owner approves")

        clock.set(at(30))
        let typed = start.code.lowercased().replacingOccurrences(of: "-", with: " ")
        let added = try await store.approvePairing(code: typed)
        #expect(added == AuthStore.ViewerInfo(id: added.id, name: "Living Room", device: "Apple TV 4K (3rd generation)", created: at(30),
                                              lastSeen: nil, address: "192.0.2.40"))
        #expect(isLowercaseHex(added.id, count: 32))

        let collected = try #require(await store.pairingStatus(request: start.request, secret: start.secret).approval)
        #expect(isLowercaseHex(collected.token, count: 64))
        #expect(collected.viewer == added)
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .gone, "the key is handed out once")
        #expect(await store.viewer(token: collected.token, address: nil)?.id == added.id)

        let folder = directory.url.appending(path: "web", directoryHint: .isDirectory)
        let file = try String(contentsOf: folder.appending(path: "auth.json"), encoding: .utf8)
        #expect(file.contains(Secrets.sha256Hex(collected.token)))
        let secrets = [collected.token, start.secret, start.request, start.code, start.code.replacingOccurrences(of: "-", with: "")]
        for name in ["auth.json", "auth.json.bak"] {   // the copy from before the last change too, when something keeps one
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { continue }
            #expect(secrets.allSatisfy { !text.contains($0) }, "\(name) holds a key, secret or code")
        }
    }

    @Test func atMostTwentyTVsAndTheCodeStaysUsable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory, clock: Box(t0))
        try await store.configure(password: "long enough", bridgeName: nil)
        var ids: [String] = []
        for number in 1...20 {
            let tv = try await pair(store, name: "TV \(number)", address: "192.0.2.\(number)")
            ids.append(tv.viewer.id)
        }
        #expect(await store.viewers().count == 20)

        let start = try await store.beginPairing(name: "One too many", device: nil, address: "192.0.2.21")
        await #expect(throws: AuthStore.PairingFailure.tooManyViewers) { try await store.approvePairing(code: start.code) }
        #expect(await store.viewers().count == 20, "nothing was added")
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .waiting, "the code is still good")

        #expect(await store.removeViewer(id: ids[0]))
        let added = try await store.approvePairing(code: start.code)
        #expect(added.name == "One too many")
        #expect(await store.viewers().count == 20)
    }

    @Test func aCodeThatOpensNothingIsRefused() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: "Living Room", device: nil, address: "192.0.2.40")

        let unknown = (start.code.hasPrefix("B") ? "C" : "B") + start.code.dropFirst()   // well formed, and nobody was given it
        for typed in ["", "abc", "BCDFGHJ", "AEIOU-AEIOU", "BCDF-GHJK-LMNP", unknown] {
            await #expect(throws: AuthStore.PairingFailure.noSuchCode, "\(typed.debugDescription)") { try await store.approvePairing(code: typed) }
        }
        #expect(await store.viewers().isEmpty)

        _ = try await store.approvePairing(code: start.code)
        await #expect(throws: AuthStore.PairingFailure.noSuchCode, "approved already") { try await store.approvePairing(code: start.code) }
        #expect(await store.pairingStatus(request: start.request, secret: start.secret).approval != nil, "its TV collects the key")
        #expect(await store.viewers().map(\.name) == ["Living Room"], "one approval, one TV")

        let late = try await store.beginPairing(name: "Bedroom", device: nil, address: "192.0.2.41")
        clock.set(at(601))
        await #expect(throws: AuthStore.PairingFailure.noSuchCode, "ten minutes are up") { try await store.approvePairing(code: late.code) }
        #expect(await store.viewers().map(\.name) == ["Living Room"])
    }

    @Test func theFourthRequestFromOneAddressIsToldHowLongToWait() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        for _ in 0..<3 { _ = try await store.beginPairing(name: nil, device: nil, address: "192.0.2.40") }
        clock.set(at(100))
        await #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 500)) {
            try await store.beginPairing(name: nil, device: nil, address: "192.0.2.40")
        }
        _ = try await store.beginPairing(name: nil, device: nil, address: "192.0.2.41")
        clock.set(at(601))
        _ = try await store.beginPairing(name: nil, device: nil, address: "192.0.2.40")
    }

    // MARK: Using a key

    @Test func aKeyUnusedForAYearStopsWorking() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let used = try await pair(store, name: "Used", address: "192.0.2.41")
        let unused = try await pair(store, name: "Never used", address: "192.0.2.42")

        clock.set(at(364 * day))
        #expect(await store.viewer(token: used.token, address: "192.0.2.41")?.id == used.viewer.id, "a year has not passed")
        clock.set(at(365 * day + 1))
        #expect(await store.viewer(token: unused.token, address: "192.0.2.42") == nil, "a year since it was added, and never used")
        #expect(await store.viewers().map(\.name) == ["Used"])

        clock.set(at(364 * day + 365 * day + 1))
        #expect(await store.viewer(token: used.token, address: "192.0.2.41") == nil, "a year since it was used")
        #expect(await store.viewers().isEmpty)
        // Read with a clock from before it lapsed, so only the file can say whether it is gone.
        #expect(await makeStore(directory, clock: Box(t0)).viewers().isEmpty, "gone from the file too")
    }

    @Test func aTVUnusedForAYearMakesRoomForANewOne() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        var tvs: [(token: String, viewer: AuthStore.ViewerInfo)] = []
        for number in 1...20 {
            let tv = try await pair(store, name: "TV \(number)", address: "192.0.2.\(number)")
            tvs.append(tv)
        }
        clock.set(at(200 * day))
        for tv in tvs.dropLast() { _ = await store.viewer(token: tv.token, address: nil) }   // all but the last are used

        clock.set(at(365 * day - 100))
        let start = try await store.beginPairing(name: "New", device: nil, address: "192.0.2.50")   // the last is a hundred seconds short of a year
        clock.set(at(365 * day + 1))
        let added = try await store.approvePairing(code: start.code)   // twenty are listed, but by now the one nobody used has lapsed
        #expect(added.name == "New")
        let names = await store.viewers().map(\.name)
        #expect(names.count == 20 && names.contains("New") && !names.contains("TV 20"))
    }

    @Test func aKeysUseIsKeptAndWrittenAtMostHourly() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let tv = try await pair(store, address: "192.0.2.40")

        clock.set(at(10))
        let seen = try #require(await store.viewer(token: tv.token, address: "192.0.2.41"))
        #expect(seen.lastSeen == at(10) && seen.address == "192.0.2.41")
        let listed = try #require(await store.viewers().first)
        #expect(listed.lastSeen == at(10) && listed.address == "192.0.2.41")
        let before = try #require(await makeStore(directory, clock: clock).viewers().first)
        #expect(before.lastSeen == nil && before.address == "192.0.2.40", "not written yet: the file is as it was when the TV was added")

        clock.set(at(3_700))
        _ = await store.viewer(token: tv.token, address: "192.0.2.42")
        let after = try #require(await makeStore(directory, clock: clock).viewers().first)
        #expect(after.lastSeen == at(3_700) && after.address == "192.0.2.42", "an hour later both are written")
    }

    @Test func theListShowsTheTVUsedLastFirst() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let first = try await pair(store, name: "First", address: "192.0.2.41")
        clock.set(at(100))
        try await pair(store, name: "Second", address: "192.0.2.42")
        clock.set(at(200))
        try await pair(store, name: "Third", address: "192.0.2.43")
        #expect(await store.viewers().map(\.name) == ["Third", "Second", "First"], "never used: by when it was added")

        clock.set(at(300))
        _ = await store.viewer(token: first.token, address: nil)
        #expect(await store.viewers().map(\.name) == ["First", "Third", "Second"])
    }

    @Test func anAddressIsKeptAtMost64Characters() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory, clock: Box(t0))
        try await store.configure(password: "long enough", bridgeName: nil)
        let long = String(repeating: "a", count: 100)
        let tv = try await pair(store, address: long)
        #expect(tv.viewer.address == String(long.prefix(64)), "the address it asked from")
        let seen = try #require(await store.viewer(token: tv.token, address: long + "b"))
        #expect(seen.address == String(long.prefix(64)), "the address it last came from")
        #expect(await store.viewer(token: tv.token, address: nil)?.address == String(long.prefix(64)), "no address does not wipe the last one")
    }

    @Test func malformedRequestsAndKeysAreRefusedWithoutWork() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory, clock: Box(t0))
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: nil, device: nil, address: "192.0.2.40")
        let asks: [(String, String)] = [
            (String(start.request.dropLast()), start.secret), (start.request, String(start.secret.dropLast())),
            (start.request.uppercased(), start.secret), (start.request, start.secret.uppercased()),
            ("", ""), (String(repeating: "g", count: 32), String(repeating: "g", count: 64)), (start.request, String(repeating: "a", count: 500)),
        ]
        for (request, secret) in asks {
            #expect(await store.pairingStatus(request: request, secret: secret) == .gone, "\(request.count), \(secret.count)")
        }
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .waiting, "none of them touched the request")

        let tv = try await pair(store)
        let keys = ["", "abc", tv.token.uppercased(), String(tv.token.dropLast()), tv.token + "0", " " + tv.token, String(repeating: "g", count: 64),
                    String(repeating: "a", count: 500)]
        for key in keys { #expect(await store.viewer(token: key, address: nil) == nil, "\(key.count) characters") }
        #expect(await store.viewer(token: tv.token, address: nil)?.id == tv.viewer.id, "the key itself still works")
    }

    // MARK: Ending a TV

    @Test func removingATVEndsItsKeyAndItsWaitingApproval() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let tv = try await pair(store)
        #expect(await store.isViewerListed(tv.viewer.id))
        #expect(await store.removeViewer(id: tv.viewer.id))
        #expect(await store.viewer(token: tv.token, address: nil) == nil)
        #expect(await !store.isViewerListed(tv.viewer.id))
        #expect(await !store.removeViewer(id: tv.viewer.id), "there is nothing to remove the second time")
        #expect(await makeStore(directory, clock: clock).viewers().isEmpty, "removed from the file too")

        // Approved, and removed before it asked for its key.
        let start = try await store.beginPairing(name: "Bedroom", device: nil, address: "192.0.2.41")
        let added = try await store.approvePairing(code: start.code)
        #expect(await store.removeViewer(id: added.id))
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .gone, "the key that waited for it is not handed out")
    }

    @Test func anApprovalNobodyCollectsLeavesNoTV() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: "Living Room", device: nil, address: "192.0.2.40")
        clock.set(at(10))
        let added = try await store.approvePairing(code: start.code)
        #expect(await store.viewers().map(\.id) == [added.id], "listed while its request lasts")

        clock.set(at(601))
        #expect(await store.viewers().isEmpty, "nobody holds its key, so it is not a TV")
        #expect(await makeStore(directory, clock: clock).viewers().isEmpty, "and not in the file")
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .gone)
    }

    @Test func anApprovalInTheLastSecondsStillReachesItsTV() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: "Living Room", device: nil, address: "192.0.2.40")
        clock.set(at(590))
        let added = try await store.approvePairing(code: start.code)

        clock.set(at(640))   // its ten minutes are over; a minute from the approval is not
        let collected = try #require(await store.pairingStatus(request: start.request, secret: start.secret).approval)
        #expect(collected.viewer == added)
        clock.set(at(700))
        #expect(await store.viewers().map(\.id) == [added.id], "a TV that has its key stays")
        #expect(await store.viewer(token: collected.token, address: nil)?.id == added.id)
    }

    /// `ViewerPairing.approve` does nothing for a request that has ended, so an approval that read the clock again after saving the TV could
    /// find its request over by then and leave a TV in the list whose key nobody can collect. The clock here moves on with every reading.
    @Test func approvingJustBeforeTheEndDoesNotLoseTheKey() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let step = Box<TimeInterval>(0)   // how far each reading of the clock moves it on
        let store = AuthStore(directory: directory.url, iterations: 1_000, now: {
            clock.update { reading in
                defer { reading = reading.addingTimeInterval(step.value) }
                return reading
            }
        })
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: "Living Room", device: nil, address: "192.0.2.40")   // open until t0 + 600

        clock.set(at(599.5))
        step.set(0.6)
        let added = try await store.approvePairing(code: start.code)
        step.set(0)
        #expect(clock.value > at(600), "the request's ten minutes ran out while the call was saving the TV")
        let collected = try #require(await store.pairingStatus(request: start.request, secret: start.secret).approval,
                                     "the key is waiting for its TV")
        #expect(collected.viewer == added)
        #expect(await store.viewer(token: collected.token, address: nil)?.id == added.id)
    }

    @Test func anApprovalThatCannotBeSavedIsUndone() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory, clock: Box(t0))
        try await store.configure(password: "long enough", bridgeName: nil)
        let start = try await store.beginPairing(name: "Living Room", device: nil, address: "192.0.2.40")
        let folder = directory.url.appending(path: "web").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)   // the data partition went read-only
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        guard !FileManager.default.isWritableFile(atPath: folder) else { return }   // running as root: every folder can be written

        await #expect(throws: AuthStore.Failure.storageFailed) { try await store.approvePairing(code: start.code) }
        #expect(await store.viewers().isEmpty, "a TV that would be gone at the next restart is not added")
        #expect(await store.pairingStatus(request: start.request, secret: start.secret) == .waiting, "the code still waits")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        let added = try await store.approvePairing(code: start.code)
        #expect(await store.viewers().map(\.id) == [added.id], "the disk takes it again")
    }

    @Test func changingThePasswordKeepsTheTVs() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = Box(t0)
        let store = makeStore(directory, clock: clock)
        try await store.configure(password: "long enough", bridgeName: nil)
        let tv = try await pair(store)
        try await store.changePassword(current: "long enough", new: "another password", keeping: nil)
        #expect(await store.viewer(token: tv.token, address: nil)?.id == tv.viewer.id)
        #expect(await makeStore(directory, clock: clock).viewer(token: tv.token, address: nil)?.id == tv.viewer.id, "and after a restart")
    }

    // MARK: Names

    @Test func namesAndModelsAreCleaned() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = makeStore(directory, clock: Box(t0))
        try await store.configure(password: "long enough", bridgeName: nil)
        let long = String(repeating: "x", count: 80), cut = String(repeating: "x", count: 60)
        let cases: [(name: String?, device: String?, shownName: String, shownDevice: String?)] = [
            ("  Den\u{7}  ", "  Apple TV HD\u{7} ", "Den", "Apple TV HD"),
            ("", "  ", "Device", nil),
            (nil, nil, "Device", nil),
            ("   ", "", "Device", nil),
            (long, long, cut, cut),
        ]
        for (name, device, shownName, shownDevice) in cases {
            let tv = try await pair(store, name: name, device: device)
            #expect(tv.viewer.name == shownName && tv.viewer.device == shownDevice, "\(name.debugDescription)")
            let listed = try #require(await store.viewer(token: tv.token, address: nil))
            #expect(listed.name == shownName && listed.device == shownDevice, "as the list shows it: \(name.debugDescription)")
        }
    }
}

private extension AuthStore.PairingStatus {
    /// The key and the TV of an answer that handed them out.
    var approval: (token: String, viewer: AuthStore.ViewerInfo)? {
        if case .approved(let token, let viewer) = self { return (token, viewer) }
        return nil
    }
}
