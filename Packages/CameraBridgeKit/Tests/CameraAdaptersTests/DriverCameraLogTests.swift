// Loopback mock cameras and a real loopback transport (PlatformApple): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import PlatformApple
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

/// Review finding (W4 round 4): the driver layer logged without the camera's ID (`CameraDrivers.make` took none), so
/// event channel failures, camera API warnings and two-way audio lines never reached the camera's log page, and named no
/// camera in Settings. Every line a driver's event source, camera API client, RTSP probe or talkback sink logs carries
/// the camera's ID.
@Suite(.timeLimit(.minutes(1))) struct DriverCameraLogTests {
    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }

        func tagged(_ cameraID: UUID, _ category: String, containing text: String) -> Bool {
            entries.value.contains { $0.cameraID == cameraID && $0.category == category && $0.message.contains(text) }
        }
    }

    private let credentials = HTTPCredentials(username: "admin", password: "secret")

    /// Runs `body` with a sink on the process-wide log hub (entries are told apart by their camera IDs).
    private func capturing(_ body: (Capture) async throws -> Void) async rethrows {
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        try await body(capture)
    }

    /// A loopback port nothing listens on.
    private func closedPort() async throws -> Int {
        let listener = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)
        let port = Int(listener.port)
        listener.close()
        return port
    }

    @Test(arguments: [CameraVendor.onvif, .reolink, .hikvision])
    func eventChannelFailuresNameTheCamera(vendor: CameraVendor) async throws {
        try await capturing { capture in
            let id = UUID()
            let port = try await closedPort()
            let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: port, onvifPort: port)
            let driver = CameraDrivers.make(vendor: vendor, endpoint: endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                            transport: AppleNetworkTransport(), cameraID: id)
            let source = try #require(driver.makeEventSource())
            _ = source.events()
            let category = vendor == .hikvision ? "hikvision-events" : "events"
            #expect(await eventually { capture.tagged(id, category, containing: "event channel failed") }, "\(vendor)")
            await source.stop()
        }
    }

    @Test func hikvisionTalkbackLinesNameTheCamera() async throws {
        try await capturing { capture in
            let camera = try await MockHikvisionCamera.start()
            defer { camera.stop() }
            let id = UUID()
            let driver = CameraDrivers.make(vendor: .hikvision, endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "pa55"),
                                            mainStreamURL: nil, subStreamURL: nil, transport: AppleNetworkTransport(), cameraID: id)
            let sink = try #require(driver.makeTalkbackSink())
            try await sink.open()
            await sink.close()
            #expect(capture.tagged(id, "talkback", containing: "two-way audio open on channel 1"))
        }
    }

    /// The RTSP probe's and the backchannel's sessions carry the camera's ID (their RTSP client logs with it), and so do
    /// the backchannel sink's own lines.
    @Test func backchannelSessionsAndLinesNameTheCamera() async throws {
        try await capturing { capture in
            let reolink = try await MockReolinkCamera.start()
            defer { reolink.stop() }
            let onvif = try await MockONVIFCamera.start()
            defer { onvif.stop() }
            for vendor in [CameraVendor.reolink, .onvif] {
                let id = UUID()
                let rtsp = FakeRTSPFactory {
                    FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: RTSPBackchannelTalkbackSink.defaultFormat))
                }
                let driver: any CameraDriver = vendor == .reolink
                    ? ReolinkDriver(endpoint: reolink.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                    transport: UnusedTransport(), rtspFactory: rtsp.factory, cameraID: id)
                    : ONVIFDriver(endpoint: onvif.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                  transport: UnusedTransport(), rtspFactory: rtsp.factory, cameraID: id)
                #expect(try await driver.probe().capabilities.twoWayAudio)
                let sink = try #require(driver.makeTalkbackSink())
                try await sink.open()
                await sink.close()
                let configurations = rtsp.configurations.value
                #expect(configurations.count == 2, "the probe's session and the sink's")
                #expect(configurations.allSatisfy { $0.cameraID == id }, "\(vendor)")
                #expect(capture.tagged(id, "talkback", containing: "backchannel open"), "\(vendor)")
                await driver.close()
            }
        }
    }

    @Test func cameraAPIWarningsNameTheCamera() async throws {
        try await capturing { capture in
            // Reolink: the session limit (no host, no camera name before).
            let reolink = try await MockReolinkCamera.start()
            defer { reolink.stop() }
            reolink.sessionLimit.set(true)
            let reolinkID = UUID()
            let driver = CameraDrivers.make(vendor: .reolink, endpoint: reolink.endpoint, credentials: credentials, mainStreamURL: nil,
                                            subStreamURL: nil, transport: UnusedTransport(), cameraID: reolinkID)
            await #expect(throws: CameraAdapterError.apiError(command: "Login", code: -5)) { _ = try await driver.snapshot() }
            #expect(capture.tagged(reolinkID, "reolink", containing: "maximum number of API sessions"))

            // ONVIF: the camera's clock.
            let onvif = try await MockONVIFCamera.start(clockOffset: 120)
            defer { onvif.stop() }
            let onvifID = UUID()
            let onvifDriver = ONVIFDriver(endpoint: onvif.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                          transport: UnusedTransport(), rtspFactory: FakeRTSPFactory(FakeRTSPSession(info: nil)).factory,
                                          cameraID: onvifID)
            _ = try await onvifDriver.probe()
            #expect(capture.tagged(onvifID, "onvif", containing: "camera clock differs"))
        }
    }

    /// The PullPoint loop's own lines (Renew faults) and the Reolink side channel's hint to turn ONVIF on.
    @Test func eventSourceLinesNameTheCamera() async throws {
        try await capturing { capture in
            let onvif = try await MockONVIFCamera.start()
            defer { onvif.stop() }
            onvif.renewFault.set("ActionNotSupported")
            var timing = ONVIFEventTiming()
            timing.pullTimeout = "PT1S"
            timing.renewInterval = .milliseconds(100)
            timing.minimumPullInterval = .milliseconds(20)
            let onvifID = UUID()
            let pullPoint = try #require(ONVIFDriver(endpoint: onvif.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                                     transport: UnusedTransport(), rtspFactory: FakeRTSPFactory(FakeRTSPSession(info: nil)).factory,
                                                     timing: timing, cameraID: onvifID).makeEventSource())
            _ = pullPoint.events()
            #expect(await eventually { capture.tagged(onvifID, "onvif-events", containing: "Renew not supported") })
            await pullPoint.stop()

            let reolink = try await MockReolinkCamera.start()
            defer { reolink.stop() }
            reolink.netPort.set(#"{"onvifEnable":0,"onvifPort":8000}"#)
            var reolinkTiming = ReolinkEventTiming()
            reolinkTiming.pollInterval = .milliseconds(30)
            let reolinkID = UUID()
            let polling = try #require(ReolinkDriver(endpoint: reolink.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                                     transport: UnusedTransport(), rtspFactory: FakeRTSPFactory(FakeRTSPSession(info: nil)).factory,
                                                     timing: reolinkTiming, cameraID: reolinkID).makeEventSource())
            _ = polling.events()
            #expect(await eventually { capture.tagged(reolinkID, "reolink-events", containing: "ONVIF is switched off") })
            await polling.stop()
        }
    }
}
#endif
