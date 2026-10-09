import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// Small runtime building blocks: stream addresses, status summaries, power policy, log collection and the
/// concurrency helpers the engine relies on.
@Suite(.timeLimit(.minutes(1))) struct RuntimeSupportTests {
    @Test func vendorStreamDefaults() {
        let hikvision = CameraConfiguration(name: "Drive", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.21", rtspPort: 8554),
                                            username: "admin")
        let urls = StreamSources.urls(for: hikvision)
        #expect(urls.main?.absoluteString == "rtsp://192.0.2.21:8554/ISAPI/Streaming/channels/101")
        #expect(urls.sub?.absoluteString == "rtsp://192.0.2.21:8554/ISAPI/Streaming/channels/102")
        let reolink = CameraConfiguration(name: "Door", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.22"), username: "admin")
        #expect(StreamSources.urls(for: reolink).main?.absoluteString == "rtsp://192.0.2.22:554/h264Preview_01_main")
        #expect(StreamSources.urls(for: reolink).sub?.absoluteString == "rtsp://192.0.2.22:554/h264Preview_01_sub")
        // A configured main stream is used as is, without a guessed sub stream.
        var custom = hikvision
        custom.mainStreamURL = URL(string: "rtsp://192.0.2.21/custom")
        #expect(StreamSources.urls(for: custom) == StreamSources.URLs(main: URL(string: "rtsp://192.0.2.21/custom"), sub: nil))
        // ONVIF and plain RTSP have no defaults.
        let onvif = CameraConfiguration(name: "Garage", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.23"), username: "")
        #expect(StreamSources.urls(for: onvif) == StreamSources.URLs(main: nil, sub: nil))
        #expect(StreamSources.rtspURL(CameraEndpoint(host: "fd00::5", rtspPort: 554), path: "/s")?.absoluteString == "rtsp://[fd00::5]:554/s")
    }

    @Test func httpFLVFallbackOnlyForReolink() {
        let credentials = HTTPCredentials(username: "admin", password: "p&ss")
        let reolink = CameraConfiguration(name: "Door", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.22"), username: "admin")
        let fallback = StreamSources.reolinkFLV(camera: reolink, credentials: credentials, main: true, displayName: "Door")
        #expect(fallback?.label == "HTTP-FLV")
        var hikvision = reolink
        hikvision.vendor = .hikvision
        #expect(StreamSources.reolinkFLV(camera: hikvision, credentials: credentials, main: true, displayName: "Door") == nil)
    }

    @Test func videoSummary() {
        let format = VideoFormat(codec: .h264, width: 1920, height: 1080, parameterSets: [])
        #expect(StreamSources.summary(format, frameRate: 19.7) == "H.264 1920×1080 · 20 fps")
        #expect(StreamSources.summary(format, frameRate: nil) == "H.264 1920×1080")
        #expect(StreamSources.summary(VideoFormat(codec: .hevc, width: 2560, height: 1440, parameterSets: []), frameRate: .nan) == "H.265 2560×1440")
        #expect(StreamSources.summary(nil, frameRate: 20) == nil)
        #expect(CameraRuntime.isLoopback("127.0.0.1") && CameraRuntime.isLoopback("::1") && CameraRuntime.isLoopback("LOCALHOST"))
        #expect(!CameraRuntime.isLoopback("192.0.2.1"))
    }

    @Test func powerPolicyCallsThePlatformOnTransitionsOnly() {
        let platform = RecordingPowerManager()
        let power = PowerController(power: platform)
        power.bridgeStarted(keepAwake: false)
        power.setKeepAwake(false)
        power.setKeepAwake(true)
        power.setKeepAwake(true)
        power.bridgeStopped()
        power.bridgeStopped()
        power.bridgeStarted(keepAwake: true)
        #expect(platform.keepAwakeCalls.value == [false, true, false, true])
        #expect(platform.backgroundActivities.value == [PowerController.activityReason, PowerController.activityReason])
    }

    /// Review finding (W4): the background activity (no App Nap) was held for the life of the process, also while the
    /// bridge was paused or stopped.
    @Test func stoppingTheBridgeEndsTheBackgroundActivity() {
        let platform = RecordingPowerManager()
        let power = PowerController(power: platform)
        power.bridgeStarted(keepAwake: false)
        #expect(platform.endedActivities.value == 0)
        power.bridgeStopped()
        #expect(platform.endedActivities.value == 1)
        power.bridgeStarted(keepAwake: true)
        power.bridgeStopped()
        #expect(platform.endedActivities.value == 2)
        #expect(platform.keepAwakeCalls.value == [false, true, false])
    }

    @Test func logCollectorKeepsTheNewestThousand() {
        let signal = ChangeSignal()
        let collector = LogCollector(signal: signal)
        for index in 0..<1_005 { collector.record(LogEntry(level: .info, category: "t", message: "\(index)")) }
        let drained = collector.drain()
        #expect(drained.count == 1_000 && drained.first?.message == "5" && drained.last?.message == "1004")
        #expect(collector.drain().isEmpty)
    }

    // `withDeadline` and the FIFO lock (`AsyncSerialLock`) are BridgeSupport's: Tests/BridgeSupportTests/ConcurrencyTests.

    @Test(.timeLimit(.minutes(1))) func changeSignalCoalescesAndTimesOut() async {
        let signal = ChangeSignal()
        signal.notify()
        signal.notify()
        let started = ContinuousClock.now
        await signal.wait(timeout: .seconds(5))   // pending: returns at once
        #expect(ContinuousClock.now - started < .seconds(1))
        await signal.wait(timeout: .milliseconds(100))   // nothing pending: times out
        #expect(ContinuousClock.now - started >= .milliseconds(100))
        let waiter = Task { await signal.wait(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        signal.notify()
        await waiter.value
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @MainActor @Test func probeUsesTheDriverOfTheGivenVendor() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #if canImport(Darwin)
        let engine = BridgeEngine(environment: .testing(directory: directory.url), tuning: .standard)
        let result = try await engine.probeCamera(vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "", password: "",
                                                  mainStreamURL: nil, subStreamURL: nil)
        #expect(result.vendor == .demo && result.mainStream?.width == 1920)
        #endif
    }
}
