#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import TestSupport
import Testing
@testable import HAP

/// An in-memory store whose state saves fail while `failSaves` is set (a full disk, an unwritable data directory).
private final class UnwritableStateStore: HAPStore {
    let base = InMemoryHAPStore()
    let failSaves = Box(false)

    func loadIdentity() throws -> HAPIdentity? { try base.loadIdentity() }
    func saveIdentity(_ identity: HAPIdentity) throws { try base.saveIdentity(identity) }
    func loadState() throws -> HAPPersistentState? { try base.loadState() }
    func saveState(_ state: HAPPersistentState) throws {
        if failSaves.value { throw HAPStoreError.writeFailed("state.json") }
        try base.saveState(state)
    }
    func deleteAll() throws { try base.deleteAll() }

    /// The pairings a relaunch would load.
    var savedPairings: [Pairing] { (try? base.loadState())?.pairings ?? [] }
}

/// Records every server event from now on (cancel the task when done).
private func recordEvents(of server: AccessoryServer) -> (events: Box<[AccessoryServerEvent]>, task: Task<Void, Never>) {
    let seen = Box<[AccessoryServerEvent]>([])
    let stream = server.events
    let task = Task {
        for await event in stream { seen.update { $0.append(event) } }
    }
    return (seen, task)
}

private func isPairingEvent(_ event: AccessoryServerEvent) -> Bool {
    switch event {
    case .paired, .unpaired: true
    default: false
    }
}

/// The `/pairings` List response as (identifier, admin) pairs, sorted by identifier.
private func listed(_ list: TLVReader) -> [(String, Bool)] {
    TLV8.splitList(list.items.filter { $0.type != 0x06 })
        .map { TLVReader(items: $0) }
        .compactMap { item in item.string(0x01).map { ($0, item.uint8(0x0B) == 1) } }
        .sorted { $0.0 < $1.0 }
}

/// Review finding (W4 round 4): pair-setup M6, Add Pairing and Remove Pairing answered success when the pairing change
/// could not be saved (`persist()` only logged), so a relaunch undid a change the controller had been told succeeded:
/// iOS kept a pairing the accessory had lost (No Response until removed from Home), a hub added for HKSV could not verify
/// after a restart, and a removed pairing came back (the accessory stayed `sf=0` and refused pair-setup). HAP-NodeJS saves
/// before it answers. A pairing change is now refused with kTLVError Unknown unless it was saved, and the accessory
/// keeps its previous pairings in memory (no `.paired` / `.unpaired`, no TXT change).
@Suite(.timeLimit(.minutes(1))) struct PairingSaveFailureTests {
    @Test func pairSetupIsRefusedWhenThePairingCannotBeSaved() async throws {
        let store = UnwritableStateStore()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, store: store)
        defer { await running.stop() }
        let (events, recorder) = recordEvents(of: running.server)
        defer { recorder.cancel() }

        store.failSaves.set(true)
        let client = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.pairing(step: 6, error: 1)) { try await client.pairSetup(code: running.setupCode) }
        #expect(await running.server.isPaired == false)
        #expect(store.savedPairings.isEmpty)
        #expect(await running.server.pairSetupOwner == nil, "the pair-setup slot is released")
        // The controller's keys are not accepted in memory either: memory and disk agree.
        let unsaved = try await HAPTestClient.connect(port: running.port, controllerID: client.controllerID, longTermKey: client.longTermKey,
                                                      pairing: running.accessoryPairing)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) { try await unsaved.pairVerify() }
        try await Task.sleep(for: .milliseconds(100))   // TXT updates are debounced 20 ms in these tests
        #expect(running.advertiser.currentTXT?["sf"] == "1")
        #expect(!events.value.contains(where: isPairingEvent), "\(events.value)")

        // Once the state can be saved again, pair-setup works (another controller, so its `.paired` is told apart).
        store.failSaves.set(false)
        let retry = try await HAPTestClient.connect(port: running.port)
        try await retry.pairSetup(code: running.setupCode)
        #expect(await running.server.isPaired)
        #expect(store.savedPairings.map(\.identifier) == [retry.controllerID])
        #expect(await eventually { events.value.contains(.paired(controllerID: retry.controllerID)) })
        #expect(events.value.filter(isPairingEvent) == [.paired(controllerID: retry.controllerID)])
    }

    @Test func addPairingIsRefusedWhenItCannotBeSaved() async throws {
        let store = UnwritableStateStore()
        let hub = TestAccessories.sensorHub()
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            guard context.session.isAdmin else { throw .insufficientPrivileges }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory, store: store)
        defer { await running.stop() }
        let admin = try await running.pairedClient()
        let guestKey = HAPLongTermKey()
        _ = try await admin.pairings(method: 3, identifier: "guest", publicKey: guestKey.publicKey, permissions: 0)
        let guest = try await HAPTestClient.connect(port: running.port, controllerID: "guest", longTermKey: guestKey,
                                                    pairing: running.accessoryPairing)
        try await guest.pairVerify()

        store.failSaves.set(true)
        let hubKey = HAPLongTermKey()
        let added = try await admin.pairings(method: 3, identifier: "hub-1", publicKey: hubKey.publicKey, permissions: 1)
        #expect(added.uint8(0x06) == 2 && added.uint8(0x07) == 1)
        let promoted = try await admin.pairings(method: 3, identifier: "guest", publicKey: guestKey.publicKey, permissions: 1)
        #expect(promoted.uint8(0x06) == 2 && promoted.uint8(0x07) == 1)

        // What the accessory lists is what a relaunch loads: the admin, and the guest still without admin rights.
        let expected = [(admin.controllerID, true), ("guest", false)].sorted { $0.0 < $1.0 }
        let list = listed(try await admin.pairings(method: 5))
        #expect(list.map(\.0) == expected.map(\.0) && list.map(\.1) == expected.map(\.1))
        let saved = store.savedPairings.map { ($0.identifier, $0.isAdmin) }.sorted { $0.0 < $1.0 }
        #expect(saved.map(\.0) == expected.map(\.0) && saved.map(\.1) == expected.map(\.1))
        // The hub cannot verify, and the guest's open session did not become an admin's.
        let hubClient = try await HAPTestClient.connect(port: running.port, controllerID: "hub-1", longTermKey: hubKey,
                                                        pairing: running.accessoryPairing)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) { try await hubClient.pairVerify() }
        let write = try await guest.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)])
        #expect(write.status == 207 && write.json?["characteristics"]?[0]?["status"] == -70401)

        // Once the state can be saved again, both changes go through.
        store.failSaves.set(false)
        #expect(try await admin.pairings(method: 3, identifier: "hub-1", publicKey: hubKey.publicKey, permissions: 1).uint8(0x07) == nil)
        #expect(try await admin.pairings(method: 3, identifier: "guest", publicKey: guestKey.publicKey, permissions: 1).uint8(0x07) == nil)
        #expect(Set(store.savedPairings.map(\.identifier)) == [admin.controllerID, "guest", "hub-1"])
        let allAdmins = store.savedPairings.allSatisfy(\.isAdmin)
        #expect(allAdmins)
        #expect(try await guest.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
    }

    @Test func removePairingIsRefusedWhenItCannotBeSaved() async throws {
        let store = UnwritableStateStore()
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory, store: store)
        defer { await running.stop() }
        let admin = try await running.pairedClient()
        let guestKey = HAPLongTermKey()
        _ = try await admin.pairings(method: 3, identifier: "guest", publicKey: guestKey.publicKey, permissions: 0)
        let guest = try await HAPTestClient.connect(port: running.port, controllerID: "guest", longTermKey: guestKey,
                                                    pairing: running.accessoryPairing)
        try await guest.pairVerify()
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })
        let (events, recorder) = recordEvents(of: running.server)
        defer { recorder.cancel() }

        store.failSaves.set(true)
        let removedGuest = try await admin.pairings(method: 4, identifier: "guest")
        #expect(removedGuest.uint8(0x06) == 2 && removedGuest.uint8(0x07) == 1)
        // Removing the last admin (which would remove every pairing) is refused too.
        let removedAdmin = try await admin.pairings(method: 4, identifier: admin.controllerID)
        #expect(removedAdmin.uint8(0x06) == 2 && removedAdmin.uint8(0x07) == 1)

        // Nothing changed: both sessions stay open, the accessory stays paired with both, as a relaunch would load it.
        #expect(try await admin.request("GET", "/accessories").status == 200)
        #expect(try await guest.request("GET", "/accessories").status == 200)
        #expect(await running.server.isPaired)
        #expect(listed(try await admin.pairings(method: 5)).map(\.0).sorted() == [admin.controllerID, "guest"].sorted())
        #expect(Set(store.savedPairings.map(\.identifier)) == [admin.controllerID, "guest"])
        // Still `sf=0`: pair-setup stays refused while paired.
        let intruder = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.pairing(step: 2, error: 6)) { try await intruder.pairSetup(code: running.setupCode) }
        try await Task.sleep(for: .milliseconds(100))   // TXT updates are debounced 20 ms in these tests
        #expect(running.advertiser.currentTXT?["sf"] == "0")
        #expect(!events.value.contains(where: isPairingEvent), "\(events.value)")

        // Once the state can be saved again, removing the last admin unpairs the accessory.
        store.failSaves.set(false)
        let removed = try await admin.pairings(method: 4, identifier: admin.controllerID)
        #expect(removed.uint8(0x06) == 2 && removed.uint8(0x07) == nil)
        #expect(await admin.waitUntilClosed())
        #expect(await guest.waitUntilClosed())
        #expect(store.savedPairings.isEmpty)
        #expect(await running.server.isPaired == false)
        #expect(await eventually { events.value.contains(.unpaired) })
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "1" })
    }
}
#endif
