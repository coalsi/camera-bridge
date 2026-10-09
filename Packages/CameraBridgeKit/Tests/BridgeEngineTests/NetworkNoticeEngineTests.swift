#if canImport(Darwin)
import BridgeSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

/// The engine's network notices: this Mac's VPN found by the status loop (and gone again), a controller's notice with the
/// camera's name filled in, and the notice clearing an hour after it was last seen.
@Suite(.serialized) struct NetworkNoticeEngineTests {
    @MainActor @Test(.timeLimit(.minutes(1))) func theStatusLoopPublishesThisMacsVPNAndClearsItWhenItIsGone() async throws {
        let vpn = Box<MacVPNStatus?>(MacVPNStatus(interface: "utun4", address: "10.8.0.6", reason: .defaultRoute))
        var tuning = EngineTuning.testing
        tuning.macVPNProbe = { vpn.value }
        tuning.macVPNCheckInterval = .milliseconds(100)
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        await engine.start()
        #expect(await fixture.waitFor { engine.recentNetworkNotices.contains { $0.kind == .macOnVPN && $0.interfaceName == "utun4" } })
        #expect(engine.macVPN?.interface == "utun4")
        vpn.set(nil)
        #expect(await fixture.waitFor { engine.recentNetworkNotices.isEmpty && engine.macVPN == nil })
        await fixture.tearDown()
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func aControllerNoticeGetsTheCamerasNameAndExpires() async throws {
        var tuning = EngineTuning.testing
        tuning.macVPNProbe = { nil }
        let fixture = try await EngineFixture(tuning: tuning)
        let engine = fixture.engine
        let camera = EngineFixture.demoCamera(name: "Driveway")
        try await engine.addCamera(camera, password: nil)
        engine.recordNetworkNotice(NetworkNotice(kind: .controllerOnVPN, cameraID: camera.id, advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.20",
                                                 usedFallback: true))
        let notice = try #require(engine.recentNetworkNotices.first)
        #expect(notice.cameraName == "Driveway" && notice.usedFallback && notice.delivery == .pending)
        engine.recordNetworkNotice(NetworkNotice(kind: .controllerOnVPN, cameraID: camera.id, advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.20",
                                                 usedFallback: true, delivery: .reached))
        #expect(engine.recentNetworkNotices.count == 1 && engine.recentNetworkNotices[0].delivery == .reached)
        // Reported an hour and a minute ago: not shown at all.
        engine.recordNetworkNotice(NetworkNotice(kind: .controllerOnVPN, advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.99",
                                                 date: Date().addingTimeInterval(-3_660)))
        #expect(engine.recentNetworkNotices.map(\.peerAddress) == ["192.0.2.20"])
        await fixture.tearDown()
    }

    @MainActor @Test func thePreviewScenariosShowTheNotices() {
        let vpn = BridgeEngine.preview(scenario: .vpn)
        #expect(vpn.recentNetworkNotices.map(\.kind) == [.controllerOnVPN] && vpn.recentNetworkNotices[0].delivery == .reached)
        #expect(BridgeEngine.preview(scenario: .vpnFailed).recentNetworkNotices[0].delivery == .failed)
        let mac = BridgeEngine.preview(scenario: .macVPN)
        #expect(mac.macVPN?.interface == "utun4" && mac.recentNetworkNotices.map(\.kind) == [.macOnVPN])
        #expect(BridgeEngine.preview().recentNetworkNotices.isEmpty)
    }
}
#endif
