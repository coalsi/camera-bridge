#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAP
import Testing
import TestSupport
@testable import BridgeEngine

/// Removing a camera keeps its Apple Home pairing for 30 days, and adding the same camera again gives it back (the real engine, stopped:
/// identities come from the store).
@Suite(.serialized) struct RemovedCameraPairingEngineTests {
    @MainActor private func camera(serial: String, name: String = "Porch") -> CameraConfiguration {
        var camera = EngineFixture.demoCamera(name: name)
        camera.serialNumber = serial
        return camera
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func removedThenAddedAgainKeepsThePairingAndAnotherCameraGetsItsOwn() async throws {
        let fixture = try await EngineFixture()
        let engine = fixture.engine
        let secrets = fixture.environment.platform.secrets
        let first = camera(serial: "EX-0001")
        try await engine.addCamera(first, password: nil)
        let store = HAPStorage.store(for: first.id, dataDirectory: fixture.directory.url, secrets: secrets)
        #expect(await fixture.waitFor { (try? store.loadIdentity()) != nil }, "the stopped engine creates the identity for its setup code")
        let identity = try #require(try store.loadIdentity())
        var state = try store.loadState() ?? HAPPersistentState()
        state.pairings = [Pairing(identifier: "controller-1", publicKey: Data(repeating: 7, count: 32), isAdmin: true)]
        try store.saveState(state)

        await engine.removeCamera(id: first.id)
        #expect(engine.configurations.isEmpty)
        #expect(try secrets.read(account: HAPStorage.account(for: first.id)) == nil)
        #expect(RemovedHAPIdentities.entries(in: fixture.directory.url).map(\.serialNumber) == ["EX-0001"])

        let again = camera(serial: "EX-0001", name: "Porch again")
        try await engine.addCamera(again, password: nil)
        let back = HAPStorage.store(for: again.id, dataDirectory: fixture.directory.url, secrets: secrets)
        #expect(try back.loadIdentity()?.deviceID == identity.deviceID, "Home sees the old accessory")
        #expect(try back.loadState()?.pairings.map(\.identifier) == ["controller-1"])
        #expect(await fixture.waitFor { fixture.status(again.id)?.isPaired == true })

        let other = camera(serial: "EX-0002", name: "Garage")
        try await engine.addCamera(other, password: nil)
        let otherStore = HAPStorage.store(for: other.id, dataDirectory: fixture.directory.url, secrets: secrets)
        #expect(await fixture.waitFor { (try? otherStore.loadIdentity()) != nil })
        #expect(try otherStore.loadIdentity()?.deviceID != identity.deviceID, "a different camera gets a new identity")
        #expect(try otherStore.loadState()?.pairings.isEmpty ?? true)
        await fixture.tearDown()
    }
}
#endif
