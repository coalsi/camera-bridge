#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAP
import HAPCore
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// HomeKit identities and published status against concurrent operations (review findings W4 round 3): the status
/// loop runs outside the operations lock, reads identities of cameras without a runtime, and publishes what it read.
@Suite(.serialized) struct RuntimeIdentityAndStatusTests {
    /// A `SecretStore` whose next read of `account` (once armed) blocks its thread until `release()` (at most 10 s).
    final class HoldingSecretStore: SecretStore {
        let base: any SecretStore
        let account: String
        let armed = Box(false)
        let holding = Box(false)
        let released = Box(false)

        init(base: any SecretStore, account: String) {
            self.base = base
            self.account = account
        }

        func read(account: String) throws -> Data? {
            if account == self.account, armed.update({ armed -> Bool in
                defer { armed = false }
                return armed
            }) {
                holding.set(true)
                let deadline = Date().addingTimeInterval(10)
                while !released.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            }
            return try base.read(account: account)
        }

        func write(_ data: Data?, account: String) throws { try base.write(data, account: account) }
        func release() { released.set(true) }
    }

    static func pairing(_ identifier: String) -> Pairing {
        Pairing(identifier: identifier, publicKey: Data(repeating: 1, count: 32), isAdmin: true)
    }

    /// Review finding (W4 round 3): with the identity lost (Keychain reset) and pairings on disk, the status loop (reading
    /// the setup code of a camera without a runtime yet) and the camera's starting accessory server each created an
    /// identity through their own `FileHAPStore`; the Keychain kept one, the server could run with the other, and after
    /// the user paired again the next launch ran a device ID Home never saw. One identity now, the one stored.
    @MainActor @Test(.timeLimit(.minutes(1))) func aCameraThatLostItsIdentityStartsWithTheOneTheKeychainKeeps() async throws {
        let fixture = try await EngineFixture()
        let camera = EngineFixture.demoCamera(name: "Porch")
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        #expect(await fixture.waitFor { fixture.status(camera.id)?.connection == .online && fixture.status(camera.id)?.hapPort != nil })
        await fixture.engine.stop()   // the picture size is remembered: the next start publishes the accessory at once

        let account = HAPStorage.account(for: camera.id)
        let base = fixture.environment.platform.secrets
        let store = HAPStorage.store(for: camera.id, dataDirectory: fixture.directory.url, secrets: base)
        var state = try store.loadState() ?? HAPPersistentState()
        state.pairings = [Self.pairing("home-hub")]
        try store.saveState(state)
        try base.write(nil, account: account)

        // Every read of the identity meets another one: two callers that would each create it both find none.
        let secrets = RendezvousSecretStore(base: base) { $0 == account }
        var environment = fixture.environment
        environment.platform.secrets = secrets
        let engine = BridgeEngine(environment: environment, tuning: .testing)
        secrets.arm()
        await engine.start()
        #expect(await fixture.waitFor { engine.cameras.first { $0.id == camera.id }?.hapPort != nil })
        let server = try #require(await engine.runtimes[camera.id]?.server)
        let running = try await server.deviceID
        let stored = try #require(try store.loadIdentity())

        #expect(running == stored.deviceID, "the accessory runs with the identity the Keychain keeps")
        #expect(secrets.writes.value[account] == 1, "one identity was created")
        #expect(try store.loadState()?.pairings.isEmpty == true)
        #expect(await fixture.waitFor { engine.cameras.first { $0.id == camera.id }?.setupCode == stored.setupCode.formatted })
        await engine.stop()
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): a status refresh reading one camera's identity while another camera was removed went
    /// on to the removed camera with its stale list, found its identity deleted and created a new one (a key for a camera
    /// that no longer exists, left in the Keychain), and published the removed camera's row again.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRefreshUnderWayWhenACameraIsRemovedDoesNotBringItBack() async throws {
        let fixture = try await EngineFixture()
        let kept = EngineFixture.demoCamera(name: "Yard")
        let removed = EngineFixture.demoCamera(name: "Shed")
        try await fixture.engine.addCamera(kept, password: nil)
        try await fixture.engine.addCamera(removed, password: nil)
        let base = fixture.environment.platform.secrets
        let removedAccount = HAPStorage.account(for: removed.id)
        #expect(try base.read(account: removedAccount) != nil)

        let secrets = HoldingSecretStore(base: base, account: HAPStorage.account(for: kept.id))
        var environment = fixture.environment
        environment.platform.secrets = secrets
        let engine = BridgeEngine(environment: environment, tuning: .testing)   // stopped: identities come from the store
        #expect(engine.configurations.map(\.id) == [kept.id, removed.id])
        secrets.armed.set(true)
        let refresh = Task { @MainActor in await engine.refreshStatus() }
        #expect(await fixture.until { secrets.holding.value })
        let removal = Task { @MainActor in await engine.removeCamera(id: removed.id) }
        #expect(await fixture.waitFor { !engine.configurations.contains { $0.id == removed.id } })
        try await Task.sleep(for: .milliseconds(300))   // the removal deletes what it can meanwhile
        secrets.release()
        await refresh.value
        await removal.value

        #expect(try base.read(account: removedAccount) == nil, "the removed camera's identity is not created again")
        #expect(!engine.cameras.contains { $0.id == removed.id })
        #expect(engine.cameras.map(\.id) == [kept.id])
        await fixture.tearDown()
    }

    /// Review finding (W4 round 3): a status refresh that read the sensors bridge's status just before the last camera
    /// was removed published it afterwards; with the bridge gone nothing replaced it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aRefreshUnderWayWhenTheLastCameraIsRemovedLeavesNoSensorsBridge() async throws {
        let hold = Box(false)
        let held = Box(false)
        var tuning = EngineTuning.testing
        tuning.afterSensorsBridgeStatus = {
            guard hold.value else { return }
            held.set(true)
            while hold.value { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Gate")
        try await engine.addCamera(camera, password: nil)
        await engine.start()
        #expect(await fixture.waitFor { engine.sensorsBridge != nil })
        hold.set(true)
        #expect(await fixture.waitFor { held.value }, "the status loop read the bridge's status and waits")
        await engine.removeCamera(id: camera.id)
        #expect(engine.sensorsBridge == nil && engine.bridge == nil)
        hold.set(false)
        try await Task.sleep(for: .milliseconds(300))   // the held refresh finishes
        #expect(engine.sensorsBridge == nil, "the stopped bridge's status is not published again")
        await fixture.tearDown()
    }
}
#endif
