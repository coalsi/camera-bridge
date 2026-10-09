import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct Go2RTCDriverTests {
    private let ring = "ring:?camera_id=1&device_id=dev&refresh_token=RT-SECRET"
    private let info = RTSPSessionInfo(tracks: [], videoFormat: VideoFormat(codec: .h264, width: 1920, height: 1080, parameterSets: []),
                                       audioFormat: AudioFormat(codec: .opus, sampleRate: 48_000, channels: 2))

    private func driver(source: String?, provider: (any Go2RTCStreamProviding)? = FakeGo2RTCProvider(), factory: FakeRTSPFactory? = nil,
                        uuid: UUID? = UUID(), service: IntegrationService = .ring, details: [String: String] = [:]) -> Go2RTCDriver {
        Go2RTCDriver(cameraID: uuid, settings: IntegrationSettings(service: service, details: details),
                     credentials: source.map { HTTPCredentials(username: "", password: $0) }, provider: provider,
                     rtspFactory: (factory ?? FakeRTSPFactory(FakeRTSPSession(info: info))).factory, probeTimeout: .seconds(2))
    }

    @Test func probeAttachesTheSourceAndDescribesTheHelpersLocalRTSP() async throws {
        let provider = FakeGo2RTCProvider()
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let uuid = UUID()
        let result = try await driver(source: ring, provider: provider, factory: factory, uuid: uuid, details: [IntegrationSettings.Key.deviceName: "Front Door"]).probe()
        let attached = await provider.attached
        #expect(attached.count == 1 && attached[0].streamID == Go2RTCManager.streamName(for: uuid) && attached[0].source.url == ring)
        #expect(factory.configurations.value.map(\.url.absoluteString) == ["rtsp://127.0.0.1:8554/\(Go2RTCManager.streamName(for: uuid))"])
        #expect(factory.configurations.value[0].credentials == nil && factory.configurations.value[0].cameraID == uuid)
        #expect(result.vendor == .go2rtc && result.manufacturer == "Ring" && result.model == "Front Door")
        #expect(result.mainStream?.width == 1920 && result.mainStream?.videoCodec == .h264 && result.subStream == nil)
        #expect(result.capabilities == CameraCapabilities())   // no events, no snapshot API, no two-way audio: soft motion is the motion
        let expectedIdentity = Go2RTCDriver.identity(of: try Go2RTCSource(parsing: ring))
        #expect(result.serialNumber.hasPrefix("go2rtc-"))
        #expect(result.serialNumber == expectedIdentity)
        let everythingShown: String = [result.serialNumber, result.model, result.manufacturer, result.mainStream?.url.absoluteString ?? ""].joined(separator: " ")
        #expect(!everythingShown.contains("RT-SECRET"))
    }

    @Test func theSameSourceHasTheSameIdentityAndAnotherDoesNot() throws {
        let one = try Go2RTCSource(parsing: ring)
        let two = try Go2RTCSource(parsing: ring.replacingOccurrences(of: "camera_id=1", with: "camera_id=2"))
        #expect(Go2RTCDriver.identity(of: one) == Go2RTCDriver.identity(of: one))
        #expect(Go2RTCDriver.identity(of: one) != Go2RTCDriver.identity(of: two))
    }

    @Test func attachStreamsAndReleaseDoNotAskTheStreamForAnything() async throws {
        let provider = FakeGo2RTCProvider()
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let uuid = UUID()
        let go = driver(source: ring, provider: provider, factory: factory, uuid: uuid)
        let url = try await go.attachStreams()
        #expect(url.absoluteString == "rtsp://127.0.0.1:8554/\(Go2RTCManager.streamName(for: uuid))")
        #expect(factory.configurations.value.isEmpty, "no RTSP session: the helper would dial the service for it")
        await go.releaseStreams()
        await go.close()
        #expect(await provider.detached == [Go2RTCManager.streamName(for: uuid), Go2RTCManager.streamName(for: uuid)])
        // Usable again afterwards.
        _ = try await go.attachStreams()
        #expect(await provider.attached.count == 2)
    }

    @Test func noEventsNoSnapshotNoTalkback() async throws {
        let go = driver(source: ring)
        #expect(go.makeEventSource() == nil && go.makeTalkbackSink() == nil && go.vendor == .go2rtc)
        #expect(try await go.snapshot() == nil)
    }

    @Test func aMissingOrBrokenSourceIsExplained() async throws {
        for source in [nil, "", "exec:evil", "ring:?device_id=1"] as [String?] {
            do {
                _ = try await driver(source: source).probe()
                Issue.record("probe passed for \(String(describing: source))")
            } catch let error as IntegrationError {
                #expect(!error.message.contains("evil"))
            }
        }
        await #expect(throws: IntegrationError.self) { _ = try await driver(source: ring, provider: nil).probe() }
        await #expect(throws: IntegrationError.self) { _ = try await driver(source: ring, provider: nil).attachStreams() }
    }

    @Test func helperErrorsPassThrough() async throws {
        let provider = FakeGo2RTCProvider()
        await provider.setFailure(Go2RTCError.helperMissing)
        await #expect(throws: Go2RTCError.helperMissing) { _ = try await driver(source: ring, provider: provider).probe() }
        await provider.setFailure(Go2RTCError.notReady("no free port"))
        await #expect(throws: Go2RTCError.notReady("no free port")) { _ = try await driver(source: ring, provider: provider).attachStreams() }
    }

    @Test func failedStreamsSayWhatTheHelperSaidAndNeverASecret() async throws {
        let provider = FakeGo2RTCProvider()
        await provider.setProblems(["[streams] error=\"ring: authentication failed\" url=ring:?refresh_token=RT-SECRET"])
        for failure: any Error in [RTSPError.timeout, RTSPError.notFound, RTSPError.badStatus(500), TransportError.closed] {
            let factory = FakeRTSPFactory(FakeRTSPSession(info: nil, error: failure))
            do {
                _ = try await driver(source: ring, provider: provider, factory: factory).probe()
                Issue.record("probe passed")
            } catch let error as IntegrationError {
                #expect(error.message.contains("authentication failed"), "\(error.message)")
                #expect(!error.message.contains("RT-SECRET"))
            }
        }
        // Without a line from the helper the advice is generic but names the service.
        let quiet = FakeGo2RTCProvider()
        do {
            _ = try await driver(source: ring, provider: quiet, factory: FakeRTSPFactory(FakeRTSPSession(info: nil, error: RTSPError.timeout)), service: .ring).probe()
            Issue.record("probe passed")
        } catch let error as IntegrationError {
            #expect(error.message.contains("did not deliver video in time") && error.message.contains("Ring app"))
        }
        // Cancellation is not an explanation.
        let cancelled = FakeRTSPFactory(FakeRTSPSession(info: nil, error: CancellationError()))
        await #expect(throws: CancellationError.self) { _ = try await driver(source: ring, factory: cancelled).probe() }
    }

    @Test func theFactoryBuildsEachIntegrationVendor() {
        let endpoint = CameraEndpoint(host: "192.0.2.5")
        let transport = UnusedTransport()
        let provider = FakeGo2RTCProvider()
        func make(_ vendor: CameraVendor) -> any CameraDriver {
            CameraDrivers.make(vendor: vendor, endpoint: endpoint, credentials: nil, mainStreamURL: nil, subStreamURL: nil, transport: transport, cameraID: UUID(),
                               integration: IntegrationSettings(service: .ring), go2rtc: provider)
        }
        let go2rtc = make(.go2rtc), amcrest = make(.amcrest), doorbird = make(.doorbird), unifi = make(.unifi)
        #expect(go2rtc is Go2RTCDriver)
        #expect(amcrest is AmcrestDriver)
        #expect(doorbird is DoorBirdDriver)
        #expect(unifi is UnifiProtectDriver)
        #expect(go2rtc.vendor == .go2rtc)
        #expect(amcrest.vendor == .amcrest)
        #expect(doorbird.vendor == .doorbird)
        #expect(unifi.vendor == .unifi)
        #expect(go2rtc is any StreamHoldingDriver)
        #expect(unifi is any StreamHoldingDriver)
        #expect(!(amcrest is any StreamHoldingDriver))
    }

    @Test func vendorsRoundTripThroughJSON() throws {
        for vendor in CameraVendor.allCases {
            let data = try JSONEncoder().encode([vendor])
            #expect(try JSONDecoder().decode([CameraVendor].self, from: data) == [vendor])
        }
        #expect(CameraVendor.allCases.map(\.rawValue).contains("go2rtc") && CameraVendor.allCases.map(\.rawValue).contains("unifi"))
        let settings = IntegrationSettings(service: .unifiProtect, details: [IntegrationSettings.Key.protectCameraID: "abc"])
        #expect(try JSONDecoder().decode(IntegrationSettings.self, from: try JSONEncoder().encode(settings)) == settings)
    }
}
