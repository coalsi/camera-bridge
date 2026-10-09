import BridgeSupport
import CameraAdapters
import Foundation
import HAPCore
import Testing
@testable import BridgeEngine

/// `BridgeEngine.preview()` (task W1-8): static sample data for SwiftUI previews and the app's `-previewEngine YES` mode.
@MainActor @Suite struct BridgeEnginePreviewTests {
    @Test func previewShowsARunningBridgeWithSampleCameras() {
        let engine = BridgeEngine.preview()
        #expect(engine.state == .running)
        #expect(engine.localNetworkAccess == .granted)
        #expect(engine.cameras.count >= 4)
        #expect(Set(engine.cameras.map(\.kind)) == [.camera, .doorbell])
        #expect(Set(engine.cameras.map(\.id)).count == engine.cameras.count)
    }

    @Test func previewCoversEveryConnectionHealthTheUIRenders() {
        let states = BridgeEngine.preview().cameras.map(\.connection)
        #expect(states.contains(.online))
        #expect(states.contains(.connecting))
        #expect(states.contains(.disabled))
        #expect(states.contains { if case .offline = $0 { true } else { false } })
        let cameras = BridgeEngine.preview().cameras
        #expect(cameras.contains { $0.isPaired } && cameras.contains { !$0.isPaired })
        #expect(cameras.contains { $0.recordingNow && $0.motionActive })
        #expect(cameras.contains { $0.lastError != nil })
    }

    @Test func everyCameraHasAMatchingConfigurationWithoutCredentials() throws {
        let engine = BridgeEngine.preview()
        #expect(engine.configurations.count == engine.cameras.count)
        for status in engine.cameras {
            let config = try #require(engine.configurations.first { $0.id == status.id })
            #expect(config.name == status.name && config.kind == status.kind && config.vendor == status.vendor)
            #expect(config.isEnabled == (status.connection != .disabled))
            #expect(config.capabilities != nil)
            for url in [config.mainStreamURL, config.subStreamURL].compactMap({ $0 }) {
                #expect(url.user == nil && url.password == nil)
            }
            // Documentation addresses (RFC 5737) so nothing can ever reach a real device on anyone's network.
            #expect(config.vendor == .demo || config.endpoint.host.hasPrefix("192.0.2."))
        }
    }

    @Test func setupCodesAndURIsAreValidHAPPayloads() throws {
        let engine = BridgeEngine.preview()
        for status in engine.cameras {
            let code = try #require(SetupCode(status.setupCode))
            #expect(status.setupCode == code.formatted)
            #expect(!code.isTrivial)
            #expect(status.setupURI.hasPrefix("X-HM://"))
            let category: AccessoryCategory = status.kind == .doorbell ? .videoDoorbell : .ipCamera
            let setupID = String(status.setupURI.suffix(4))
            #expect(status.setupURI == SetupPayload.uri(code: code, setupID: setupID, category: category))
        }
        let bridge = try #require(engine.sensorsBridge)
        let bridgeCode = try #require(SetupCode(bridge.setupCode))
        #expect(bridge.setupURI == SetupPayload.uri(code: bridgeCode, setupID: String(bridge.setupURI.suffix(4)), category: .bridge))
        #expect(bridge.accessoryCount > 0)
    }

    /// Setup URIs computed independently (base-36 of category << 31 | IP flag << 28 | code, then the setup ID), not with
    /// `SetupPayload.uri`: Driveway 482-17-935 camera (17) CB1D, Front Door 631-58-204 doorbell (18) CB2F, sensors
    /// bridge 146-83-529 bridge (2) CBSB.
    @Test func setupURIsMatchIndependentGoldens() throws {
        let engine = BridgeEngine.preview()
        let byName = Dictionary(uniqueKeysWithValues: engine.cameras.map { ($0.name, $0) })
        #expect(byName["Driveway"]?.setupCode == "482-17-935")
        #expect(byName["Driveway"]?.setupURI == "X-HM://00GWZZG3ZCB1D")
        #expect(byName["Front Door"]?.setupCode == "631-58-204")
        #expect(byName["Front Door"]?.setupURI == "X-HM://00HWRFP30CB2F")
        let bridge = try #require(engine.sensorsBridge)
        #expect(bridge.setupCode == "146-83-529" && bridge.setupURI == "X-HM://0023PO9ZDCBSB")
    }

    @Test func sampleLogsAreOrderedNewestLastAndMentionCameras() {
        let logs = BridgeEngine.preview().recentLogs
        #expect(!logs.isEmpty && logs.count <= 1_000)
        #expect(logs.map(\.date) == logs.map(\.date).sorted())
        #expect(logs.contains { $0.cameraID != nil } && logs.contains { $0.cameraID == nil })
        #expect(Set(logs.map(\.level)).count >= 3)
        // The camera detail's Recent Events list shows a camera's "Events" entries.
        #expect(logs.contains { $0.category == "Events" && $0.cameraID == PreviewData.drivewayID })
    }

    @Test func sampleSettingsEnableTheWebhookWithAFixedToken() {
        let settings = BridgeEngine.preview().settings
        #expect(settings.webhookEnabled)
        #expect(settings.webhookToken.count == 32 && settings.webhookToken.allSatisfy(\.isHexDigit))
    }

    @Test func previewDataIsDeterministic() {
        let a = BridgeEngine.preview(), b = BridgeEngine.preview()
        #expect(a !== b)
        #expect(a.cameras.map(\.id) == b.cameras.map(\.id))
        #expect(a.cameras.map(\.setupCode) == b.cameras.map(\.setupCode))
        #expect(a.configurations == b.configurations)
        #expect(a.settings == b.settings)
    }

    @Test func previewEnvironmentCannotTouchTheNetwork() async {
        let engine = BridgeEngine.preview()
        #expect(engine.environment.loopbackOnly && !engine.environment.advertise)
        #expect(engine.environment.platform.advertiser is NullServiceAdvertiser)
        await #expect(throws: TransportError.self) {
            _ = try await engine.environment.platform.transport.connect(host: "192.0.2.10", port: 80, timeout: .seconds(1))
        }
    }
}
