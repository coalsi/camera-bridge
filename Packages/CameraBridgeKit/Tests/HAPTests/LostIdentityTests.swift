#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import Testing
import TestSupport
@testable import HAP

/// The identity (device ID, Ed25519 key, setup code) lives in the `SecretStore` (the Keychain in the app), the pairings
/// in `state.json`. Review finding (W4 round 2): when only the identity went missing (a reset or lost login keychain, a
/// data directory restored without it) the server made a new identity and kept the old pairings, so it advertised
/// `sf=0` under a device ID no controller knows, refused pair-setup (M2 Error 6) and reported itself paired. Research
/// brief §4 ("Keys missing"): reset the pairing state and have the user remove and re-add the accessory.
@Suite(.timeLimit(.minutes(1))) struct LostIdentityTests {
    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "LostIdentityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func pairing(_ identifier: String) -> Pairing {
        Pairing(identifier: identifier, publicKey: Data(repeating: 1, count: 32), isAdmin: true)
    }

    @Test func serverWithoutItsIdentityDropsThePairingsOfTheLostOne() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore()
        let store = FileHAPStore(directory: root, secretStore: secrets, account: "hap.lost-identity")
        let name = "Lost-\(UUID().uuidString.prefix(8))"
        func accessory() -> Accessory {
            let accessory = Accessory(info: AccessoryInfo(name: name, manufacturer: "CameraBridge", model: "CB-Test", serialNumber: "SN-LOST",
                                                          firmwareRevision: "1.0.0"), category: .sensor)
            accessory.addService(Service(.motionSensor, name: "Motion"))
            return accessory
        }

        // Paired once; the controller-facing extras (recording options, alarm inputs) are stored alongside.
        let first = try await startServer(accessory: accessory(), store: store)
        _ = try await first.pairedClient()
        try await first.server.store(extra: Data([7]), forKey: "kept")
        #expect(await first.advertiser.waitForTXT { $0["sf"] == "0" })
        await first.stop()
        let oldID = first.accessoryPairing.accessoryPairingID

        // The Keychain item is gone; state.json is still there.
        try secrets.write(nil, account: "hap.lost-identity")
        let advertiser = RecordingAdvertiser()
        let configuration = AccessoryServerConfiguration(port: 0, advertise: true, serviceName: name, loopbackOnly: true)
        let server = AccessoryServer(accessory: accessory(), configuration: configuration, store: store, transport: PlatformNetworkTransport(),
                                     advertiser: advertiser)
        await server.setTimings(.fastTests)
        let events = server.events
        try await server.start()
        defer { await server.stop() }

        let newID = try await server.deviceID.description
        #expect(newID != oldID)
        #expect(await server.isPaired == false)
        #expect(await server.pairingsLostWithIdentity == 1)
        #expect(try store.loadState()?.pairings.isEmpty == true)
        #expect(try store.loadState()?.extras["kept"] == Data([7]), "only the pairings belonged to the lost identity")
        #expect(try store.loadIdentity()?.deviceID.description == newID)

        // Advertised as unpaired under the new identity.
        let txt = try #require(advertiser.currentTXT)
        #expect(txt["sf"] == "1")
        #expect(txt["id"] == newID)

        // Reported as an unpair (controllers' state is reset, the app shows the setup code again).
        var seen: [AccessoryServerEvent] = []
        for await event in events {
            seen.append(event)
            if event == .advertising { break }
        }
        #expect(seen.contains(.unpaired), "\(seen)")

        // A controller can pair again.
        let client = try await HAPTestClient.connect(port: try #require(await server.port))
        var m1 = TLVBuilder()
        m1.add(0x00, uint8: 0)
        m1.add(0x06, uint8: 1)
        let m2 = try await client.pairingRequest("/pair-setup", m1)
        #expect(m2.uint8(0x07) == nil, "error \(m2.uint8(0x07).map(String.init) ?? "")")
        #expect(m2.uint8(0x06) == 2 && m2.data(0x03) != nil)

        // The user is told what to do.
        let logged = sink.messages.filter { $0.contains(name) && $0.contains("Home app") }
        #expect(logged.count == 1, "\(sink.messages.filter { $0.contains(name) })")
    }

    @Test func loadOrCreateIdentityDiscardsPairingsOnlyWhenTheIdentityIsNew() throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore()
        let store = FileHAPStore(directory: root, secretStore: secrets, account: "hap.helper")

        // Nothing stored: a new identity, nothing to discard, no state written.
        let created = try store.loadOrCreateIdentity()
        #expect(created.created)
        #expect(created.discardedPairings == 0)
        #expect(try store.loadIdentity()?.deviceID == created.identity.deviceID)
        #expect(try store.loadState() == nil)

        // The identity is there: it and its pairings stay.
        var state = HAPPersistentState()
        state.pairings = [Self.pairing("hub"), Self.pairing("phone")]
        state.configNumber = 4
        state.aids = ["s": 2]
        state.extras = ["x": Data([1])]
        try store.saveState(state)
        let loaded = try store.loadOrCreateIdentity()
        #expect(!loaded.created)
        #expect(loaded.identity.deviceID == created.identity.deviceID && loaded.identity.setupCode == created.identity.setupCode)
        #expect(loaded.discardedPairings == 0)
        #expect(try store.loadState()?.pairings.count == 2)

        // The identity is gone: its pairings go with it, everything else stays.
        try secrets.write(nil, account: "hap.helper")
        let replaced = try store.loadOrCreateIdentity()
        #expect(replaced.created)
        #expect(replaced.identity.deviceID != created.identity.deviceID)
        #expect(replaced.discardedPairings == 2)
        let after = try #require(try store.loadState())
        #expect(after.pairings.isEmpty)
        #expect(after.configNumber == 4 && after.aids == ["s": 2] && after.extras == ["x": Data([1])])
        #expect(try store.loadIdentity()?.deviceID == replaced.identity.deviceID)
    }

    /// Review finding (W4 round 3): with the identity missing at launch, the engine (reading a stopped camera's setup
    /// code) and the camera's starting accessory server each read "none" through their own `FileHAPStore` over the same
    /// Keychain account and each created an identity; the Keychain kept only the last write, so the server could run
    /// with an identity other than the stored one (after a pairing, the next launch ran a device ID Home never saw).
    /// Creation is atomic per account across store instances: one identity, which both callers get.
    @Test func twoStoresOverOneAccountCreateOneIdentity() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = RendezvousSecretStore { $0 == "hap.race" }
        let setup = FileHAPStore(directory: root, secretStore: secrets, account: "hap.race")
        var state = HAPPersistentState()
        state.pairings = [Self.pairing("hub")]
        try setup.saveState(state)
        secrets.arm()
        let results = try await withThrowingTaskGroup(of: (HAPIdentity, Bool).self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let store = FileHAPStore(directory: root, secretStore: secrets, account: "hap.race")
                    let (identity, created, _) = try store.loadOrCreateIdentity()
                    return (identity, created)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 2)
        #expect(results.filter(\.1).count == 1, "one caller creates, the other finds it")
        #expect(Set(results.map(\.0.deviceID.description)).count == 1)
        #expect(try setup.loadIdentity()?.deviceID == results.first?.0.deviceID)
        #expect(secrets.writes.value["hap.race"] == 1)
        #expect(try setup.loadState()?.pairings.isEmpty == true)
    }

    /// Reset Pairing (review finding W4 round 3): a new identity, and none of the old pairings.
    @Test func replaceIdentityMakesANewAccessoryWithoutPairings() throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore()
        let store = FileHAPStore(directory: root, secretStore: secrets, account: "hap.reset")
        let old = try store.loadOrCreateIdentity().identity
        var state = HAPPersistentState()
        state.pairings = [Self.pairing("hub")]
        state.extras = ["kept": Data([1])]
        try store.saveState(state)
        let new = try store.replaceIdentity()
        #expect(new.deviceID != old.deviceID && new.setupCode != old.setupCode && new.setupID != old.setupID && new.longTermKey != old.longTermKey)
        #expect(try store.loadIdentity()?.deviceID == new.deviceID)
        let after = try #require(try store.loadState())
        #expect(after.pairings.isEmpty && after.extras == ["kept": Data([1])])
    }

    /// The stale pairings are removed before the new identity is saved: if saving the state fails, no identity is
    /// created (the next attempt starts over) rather than a new identity next to pairings nobody can verify with.
    @Test func noNewIdentityWhenThePairingsCannotBeDiscarded() throws {
        final class ReadOnlyStateStore: HAPStore {
            let base = InMemoryHAPStore()
            func loadIdentity() throws -> HAPIdentity? { try base.loadIdentity() }
            func saveIdentity(_ identity: HAPIdentity) throws { try base.saveIdentity(identity) }
            func loadState() throws -> HAPPersistentState? { try base.loadState() }
            func saveState(_ state: HAPPersistentState) throws { throw HAPStoreError.writeFailed("state.json") }
            func deleteAll() throws { try base.deleteAll() }
        }
        let store = ReadOnlyStateStore()
        var state = HAPPersistentState()
        state.pairings = [Self.pairing("hub")]
        try store.base.saveState(state)
        #expect(throws: HAPStoreError.writeFailed("state.json")) { try store.loadOrCreateIdentity() }
        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadState()?.pairings.count == 1)
    }
}
#endif
