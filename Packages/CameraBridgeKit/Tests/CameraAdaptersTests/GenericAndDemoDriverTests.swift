import BridgeSupport
import Foundation
import MediaCore
import RTSP
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct GenericRTSPDriverTests {
    private let main = URL(string: "rtsp://192.0.2.50:554/stream1")!
    private let sub = URL(string: "rtsp://192.0.2.50:554/stream2")!

    @Test func probeFillsStreamInfoFromRTSPConnect() async throws {
        let info = RTSPSessionInfo(tracks: [], videoFormat: VideoFormat(codec: .h264, width: 1920, height: 1080, parameterSets: []),
                                   audioFormat: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let credentials = HTTPCredentials(username: "viewer", password: "pw")
        let driver = GenericRTSPDriver(endpoint: CameraEndpoint(host: "192.0.2.50"), credentials: credentials, mainStreamURL: main,
                                       subStreamURL: sub, rtspFactory: factory.factory)
        let result = try await driver.probe()
        #expect(result.vendor == .rtsp)
        #expect(result.mainStream == StreamInfo(url: main, videoCodec: .h264, width: 1920, height: 1080, audioCodec: .pcmu, audioSampleRate: 8000,
                                                audioChannels: 1))
        #expect(result.subStream?.url == sub)
        #expect(result.capabilities.events.isEmpty)
        #expect(!result.capabilities.snapshotAPI && !result.capabilities.twoWayAudio)
        #expect(factory.configurations.value.map(\.url) == [main, sub])
        #expect(factory.configurations.value.allSatisfy { $0.credentials == credentials && !$0.requestBackchannel })
        #expect(factory.session.calls.value.filter { $0 == "close" }.count == 2)
        #expect(driver.makeEventSource() == nil)
        #expect(try await driver.snapshot() == nil)
        #expect(driver.makeTalkbackSink() == nil)
    }

    @Test func credentialsInTheURLNeverReachStreamInfo() async throws {
        let factory = FakeRTSPFactory(FakeRTSPSession(info: RTSPSessionInfo(tracks: [])))
        let driver = GenericRTSPDriver(endpoint: CameraEndpoint(host: "192.0.2.50"), credentials: nil,
                                       mainStreamURL: URL(string: "rtsp://user:secret@192.0.2.50/live"), subStreamURL: nil, rtspFactory: factory.factory)
        let result = try await driver.probe()
        #expect(result.mainStream?.url.absoluteString == "rtsp://192.0.2.50/live")
        #expect(factory.configurations.value.first?.url.absoluteString == "rtsp://192.0.2.50/live")
    }

    @Test func failuresPropagateForMainButNotSub() async throws {
        let failing = FakeRTSPFactory(FakeRTSPSession(info: nil, error: RTSPError.unauthorized))
        let driver = GenericRTSPDriver(endpoint: CameraEndpoint(host: "192.0.2.50"), credentials: nil, mainStreamURL: main, subStreamURL: nil,
                                       rtspFactory: failing.factory)
        await #expect(throws: RTSPError.unauthorized) { try await driver.probe() }
        let noURL = GenericRTSPDriver(endpoint: CameraEndpoint(host: "192.0.2.50"), credentials: nil, mainStreamURL: nil, subStreamURL: nil,
                                      rtspFactory: failing.factory)
        await #expect(throws: CameraAdapterError.self) { try await noURL.probe() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DemoDriverTests {
    @Test func probeDescribesTheDemoCamera() async throws {
        let result = try await DemoCameraDriver().probe()
        #expect(result.vendor == .demo)
        #expect(result.capabilities.events == [.motion])
        #expect(result.mainStream?.videoCodec == .h264)
        #expect(try await DemoCameraDriver().snapshot() == nil)
    }

    @Test func timerDrivesMotion() async throws {
        let driver = DemoCameraDriver(firstMotionAfter: .milliseconds(50), period: .milliseconds(300), duration: .milliseconds(100))
        let source = try #require(driver.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.filter { $0 == .motion(false) }.count >= 2 })
        await source.stop()
        let events = recorder.values
        #expect(events.first == .eventChannel(connected: true))
        #expect(Array(events.dropFirst().prefix(4)) == [.motion(true), .motion(false), .motion(true), .motion(false)])
    }

    @Test func defaultsAreSixtySecondsForTen() {
        let driver = DemoCameraDriver()
        #expect(driver.period == .seconds(60))
        #expect(driver.duration == .seconds(10))
    }
}

@Suite struct CameraDriversFactoryTests {
    @Test func makeReturnsTheVendorDriver() {
        let endpoint = CameraEndpoint(host: "192.0.2.10")
        let url = URL(string: "rtsp://192.0.2.10/live")
        for vendor in CameraVendor.allCases {
            let driver = CameraDrivers.make(vendor: vendor, endpoint: endpoint, credentials: nil, mainStreamURL: url, subStreamURL: nil,
                                            transport: UnusedTransport())
            #expect(driver.vendor == vendor)
        }
        #expect(CameraDrivers.make(vendor: .hikvision, endpoint: endpoint, credentials: nil, mainStreamURL: nil, subStreamURL: nil,
                                   transport: UnusedTransport()) is HikvisionDriver)
        #expect(CameraDrivers.make(vendor: .rtsp, endpoint: endpoint, credentials: nil, mainStreamURL: url, subStreamURL: nil,
                                   transport: UnusedTransport()).makeEventSource() == nil)
    }
}
