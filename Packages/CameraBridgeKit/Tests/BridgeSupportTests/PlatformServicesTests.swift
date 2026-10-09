import Foundation
import Testing
@testable import BridgeSupport

@Suite struct PlatformServicesTests {
    @Test func inMemorySecretStoreReadsWritesAndDeletes() throws {
        let store = InMemorySecretStore()
        #expect(try store.read(account: "camera.1") == nil)
        try store.write(Data("pa55".utf8), account: "camera.1")
        try store.write(Data("other".utf8), account: "camera.2")
        #expect(try store.read(account: "camera.1") == Data("pa55".utf8))
        try store.write(Data("new".utf8), account: "camera.1")
        #expect(try store.read(account: "camera.1") == Data("new".utf8))
        try store.write(nil, account: "camera.1")
        #expect(try store.read(account: "camera.1") == nil)
        try store.write(nil, account: "missing")   // deleting a missing item is fine
        #expect(try store.read(account: "camera.2") == Data("other".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func nullAdvertiserAcceptsUpdatesAndFinishesOnCancel() async throws {
        let service = try await NullServiceAdvertiser().advertise(
            ServiceAdvertisement(name: "Test", type: "_cbtest._tcp", port: 1234, txt: ["c#": "1"]))
        try await service.updateTXT(["c#": "2"])
        let failures = service.failures
        service.cancel()
        service.cancel()   // idempotent
        var count = 0
        for await _ in failures { count += 1 }
        #expect(count == 0)
    }

    @Test(.timeLimit(.minutes(1))) func nullNetworkChangeMonitorNeverReportsChanges() async {
        var count = 0
        for await _ in NullNetworkChangeMonitor().changes { count += 1 }
        #expect(count == 0)
    }

    @Test func platformServicesHoldsInjectedServices() throws {
        let secrets = InMemorySecretStore()
        var services = PlatformServices(transport: FailingTransport(), advertiser: NullServiceAdvertiser(), secrets: secrets,
                                        networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager())
        services.power.beginBackgroundActivity(reason: "test")
        services.power.setKeepSystemAwake(true, reason: "test")
        try services.secrets.write(Data([1]), account: "a")
        #expect(try secrets.read(account: "a") == Data([1]))
        services.secrets = InMemorySecretStore()
        #expect(try services.secrets.read(account: "a") == nil)
        #expect(services.transport is FailingTransport)
    }

    @Test func advertisementAndErrorsAreValueTypes() {
        var ad = ServiceAdvertisement(name: "A", type: "_hap._tcp", port: 1, txt: ["sf": "1"])
        let copy = ad
        ad.txt["sf"] = "0"
        #expect(copy.txt["sf"] == "1" && ad != copy)
        #expect(TransportError.failed("x") == .failed("x") && TransportError.failed("x") != .closed)
    }
}

private final class FailingTransport: NetworkTransport {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.failed("unavailable") }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { throw TransportError.failed("unavailable") }
}
