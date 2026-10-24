import BridgeSupport
import Foundation
import HAP
import Testing
import TestSupport
@testable import BridgeEngine

/// A removed camera's Apple Home pairing is kept for 30 days (`RemovedHAPIdentities`): moved aside on removal, nothing deleted; given back to
/// the same camera added again within that time (same serial number, MAC or id); never to another camera; deleted by the sweep after.
@Suite struct RemovedHAPIdentitiesTests {
    private let day: TimeInterval = 86_400
    private let removedAt = Date(timeIntervalSince1970: 1_792_800_000)

    /// A camera's HAP identity with one controller paired, as an accessory server leaves them.
    private func pairedCamera(_ id: UUID, in directory: URL, secrets: any SecretStore) throws -> HAPIdentity {
        let store = HAPStorage.store(for: id, dataDirectory: directory, secrets: secrets)
        let identity = HAPIdentity.generate()
        try store.saveIdentity(identity)
        var state = HAPPersistentState()
        state.pairings = [Pairing(identifier: "controller-1", publicKey: Data(repeating: 7, count: 32), isAdmin: true)]
        state.configNumber = 5
        try store.saveState(state)
        return identity
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func removingMovesTheIdentityAndPairingsAsideAndDeletesNothing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let id = UUID()
        _ = try pairedCamera(id, in: directory.url, secrets: secrets)
        try RemovedHAPIdentities.keep(cameraID: id, serialNumber: " ex-0001 ", mac: "02-00-5E-00-53-01", dataDirectory: directory.url,
                                      secrets: secrets, now: removedAt)

        #expect(!exists(HAPStorage.directory(for: id, in: directory.url)))
        #expect(try secrets.read(account: HAPStorage.account(for: id)) == nil)
        let kept = RemovedHAPIdentities.directory(for: id, in: directory.url)
        #expect(exists(kept.appending(path: "state.json")) && exists(kept.appending(path: "removed.json")))
        #expect(try secrets.read(account: "hap-removed.\(id.uuidString)") != nil)
        #expect(directory.contents().contains("hap-removed"))
        #expect(RemovedHAPIdentities.entries(in: directory.url)
                == [RemovedHAPIdentity(cameraID: id, removedAt: removedAt, serialNumber: "EX-0001", mac: "02005e005301")])
    }

    @Test func theSameCameraAddedAgainWithin30DaysKeepsItsPairing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let old = UUID(), new = UUID()
        let identity = try pairedCamera(old, in: directory.url, secrets: secrets)
        try RemovedHAPIdentities.keep(cameraID: old, serialNumber: "EX-0001", mac: nil, dataDirectory: directory.url, secrets: secrets, now: removedAt)

        let restored = try RemovedHAPIdentities.restore(cameraID: new, serialNumber: "ex-0001", mac: nil, dataDirectory: directory.url, secrets: secrets,
                                                        now: removedAt.addingTimeInterval(29 * day))
        #expect(restored?.cameraID == old)
        let store = HAPStorage.store(for: new, dataDirectory: directory.url, secrets: secrets)
        #expect(try store.loadIdentity()?.deviceID == identity.deviceID)
        #expect(try store.loadIdentity()?.setupCode == identity.setupCode)
        #expect(try store.loadState()?.pairings.map(\.identifier) == ["controller-1"])
        #expect(try store.loadState()?.configNumber == 5)
        #expect(try store.loadOrCreateIdentity().created == false, "the accessory server finds it and keeps its pairings")
        #expect(RemovedHAPIdentities.entries(in: directory.url).isEmpty, "the entry is used up")
        #expect(try secrets.read(account: "hap-removed.\(old.uuidString)") == nil)
    }

    @Test func theSameMACOrTheSameIDIsTheSameCamera() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let byMAC = UUID(), sameID = UUID()
        let first = try pairedCamera(byMAC, in: directory.url, secrets: secrets)
        let second = try pairedCamera(sameID, in: directory.url, secrets: secrets)
        try RemovedHAPIdentities.keep(cameraID: byMAC, serialNumber: nil, mac: "02:00:5e:00:53:01", dataDirectory: directory.url, secrets: secrets, now: removedAt)
        try RemovedHAPIdentities.keep(cameraID: sameID, serialNumber: nil, mac: nil, dataDirectory: directory.url, secrets: secrets, now: removedAt)
        let later = removedAt.addingTimeInterval(day)

        let other = UUID()
        #expect(try RemovedHAPIdentities.restore(cameraID: other, serialNumber: "EX-0002", mac: "02-00-5E-00-53-01", dataDirectory: directory.url,
                                                 secrets: secrets, now: later)?.cameraID == byMAC)
        #expect(try HAPStorage.store(for: other, dataDirectory: directory.url, secrets: secrets).loadIdentity()?.deviceID == first.deviceID)
        #expect(try RemovedHAPIdentities.restore(cameraID: sameID, serialNumber: nil, mac: nil, dataDirectory: directory.url, secrets: secrets,
                                                 now: later)?.cameraID == sameID)
        #expect(try HAPStorage.store(for: sameID, dataDirectory: directory.url, secrets: secrets).loadIdentity()?.deviceID == second.deviceID)
    }

    @Test func aDifferentCameraNeverTakesAnothersIdentity() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let old = UUID()
        _ = try pairedCamera(old, in: directory.url, secrets: secrets)
        try RemovedHAPIdentities.keep(cameraID: old, serialNumber: "EX-0001", mac: "02:00:5e:00:53:01", dataDirectory: directory.url, secrets: secrets,
                                      now: removedAt)
        let later = removedAt.addingTimeInterval(day)
        func restore(_ id: UUID = UUID(), serial: String?, mac: String?) throws -> RemovedHAPIdentity? {
            try RemovedHAPIdentities.restore(cameraID: id, serialNumber: serial, mac: mac, dataDirectory: directory.url, secrets: secrets, now: later)
        }
        #expect(try restore(serial: "EX-0002", mac: nil) == nil, "another serial number")
        #expect(try restore(serial: nil, mac: nil) == nil, "nothing that tells it")
        #expect(try restore(serial: "", mac: "00:00:00:00:00:00") == nil, "empty values tell nothing")
        #expect(try restore(serial: "EX-0002", mac: "02:00:5e:00:53:01") == nil, "the same MAC but another serial number")
        #expect(try restore(serial: "EX-0001", mac: "02:00:5e:00:53:02") == nil, "the same serial number but another MAC")
        #expect(try restore(old, serial: "EX-0002", mac: nil) == nil, "the same id with another serial number")

        // A camera that already has an identity of its own keeps it.
        let busy = UUID()
        let own = try pairedCamera(busy, in: directory.url, secrets: secrets)
        #expect(try restore(busy, serial: "EX-0001", mac: nil) == nil)
        #expect(try HAPStorage.store(for: busy, dataDirectory: directory.url, secrets: secrets).loadIdentity()?.deviceID == own.deviceID)
        #expect(RemovedHAPIdentities.entries(in: directory.url).count == 1, "the kept entry waits for its own camera")
    }

    @Test func after30DaysTheCameraGetsANewIdentityAndTheSweepDeletesTheOldOne() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let old = UUID(), fresh = UUID(), new = UUID()
        let identity = try pairedCamera(old, in: directory.url, secrets: secrets)
        _ = try pairedCamera(fresh, in: directory.url, secrets: secrets)
        try RemovedHAPIdentities.keep(cameraID: old, serialNumber: "EX-0001", mac: nil, dataDirectory: directory.url, secrets: secrets, now: removedAt)
        try RemovedHAPIdentities.keep(cameraID: fresh, serialNumber: "EX-0003", mac: nil, dataDirectory: directory.url, secrets: secrets,
                                      now: removedAt.addingTimeInterval(20 * day))
        let after = removedAt.addingTimeInterval(30 * day)

        #expect(try RemovedHAPIdentities.restore(cameraID: new, serialNumber: "EX-0001", mac: nil, dataDirectory: directory.url, secrets: secrets,
                                                 now: after) == nil)
        let created = try HAPStorage.store(for: new, dataDirectory: directory.url, secrets: secrets).loadOrCreateIdentity()
        #expect(created.created && created.identity.deviceID != identity.deviceID, "a new identity")

        #expect(RemovedHAPIdentities.sweep(dataDirectory: directory.url, secrets: secrets, now: removedAt.addingTimeInterval(29 * day)) == 0)
        #expect(RemovedHAPIdentities.sweep(dataDirectory: directory.url, secrets: secrets, now: after) == 1)
        #expect(!exists(RemovedHAPIdentities.directory(for: old, in: directory.url)))
        #expect(try secrets.read(account: "hap-removed.\(old.uuidString)") == nil)
        #expect(RemovedHAPIdentities.entries(in: directory.url).map(\.cameraID) == [fresh], "the newer entry stays")
        #expect(try secrets.read(account: "hap-removed.\(fresh.uuidString)") != nil)
    }

    @Test func forgettingACameraKeepsItsPairingWhenAsked() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let secrets = InMemorySecretStore()
        let credentials = CredentialStore(secrets: secrets)
        let id = UUID()
        _ = try pairedCamera(id, in: directory.url, secrets: secrets)
        try credentials.setPassword("secret", for: id)
        try credentials.forgetCamera(id, dataDirectory: directory.url, keepingHomePairing: true, serialNumber: "EX-0001", now: removedAt)
        #expect(try credentials.password(for: id) == nil, "the password is deleted as before")
        #expect(RemovedHAPIdentities.entries(in: directory.url).map(\.cameraID) == [id])
        let new = UUID()
        #expect(try credentials.restoreHomePairing(for: new, serialNumber: "EX-0001", dataDirectory: directory.url, now: removedAt)?.cameraID == id)
        #expect(credentials.sweepRemovedHomePairings(dataDirectory: directory.url) == 0)
    }
}
