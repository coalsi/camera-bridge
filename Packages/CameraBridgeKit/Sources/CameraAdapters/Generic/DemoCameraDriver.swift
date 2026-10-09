import Foundation
import MediaCore

/// The built-in Demo camera (development and App Review): video comes from `MediaCodecs.makeSyntheticSource`
/// (BridgeEngine); events come from a timer — motion for `duration` every `period`, the first after `firstMotionAfter`.
final class DemoCameraDriver: CameraDriver, Sendable {
    let vendor: CameraVendor = .demo
    let firstMotionAfter: Duration
    let period: Duration
    let duration: Duration

    init(firstMotionAfter: Duration = .seconds(10), period: Duration = .seconds(60), duration: Duration = .seconds(10)) {
        self.firstMotionAfter = firstMotionAfter
        self.period = max(period, duration)
        self.duration = duration
    }

    func probe() async throws -> CameraProbeResult {
        let main = URL(string: "demo://camera/main").map {
            StreamInfo(url: $0, videoCodec: .h264, width: 1920, height: 1080, fps: 30, audioCodec: .aac, audioSampleRate: 32000, audioChannels: 1)
        }
        let sub = URL(string: "demo://camera/sub").map { StreamInfo(url: $0, videoCodec: .h264, width: 640, height: 360, fps: 30) }
        return CameraProbeResult(vendor: .demo, manufacturer: "CameraBridge", model: "Demo Camera", serialNumber: "DEMO-0001", firmware: "1.0",
                                 mainStream: main, subStream: sub, capabilities: CameraCapabilities(events: [.motion]))
    }

    func makeEventSource() -> (any CameraEventSource)? {
        let (first, period, duration) = (firstMotionAfter, period, duration)
        return SupervisedEventSource(label: "Demo") { context in
            context.connected()
            try await Task.sleep(for: first)
            while true {
                await context.apply([.activate(.motion, source: "demo", hold: nil)])
                try await Task.sleep(for: duration)
                await context.apply([.deactivate(.motion, source: "demo")])
                try await Task.sleep(for: period - duration)
            }
        }
    }

    func snapshot() async throws -> Data? { nil }

    func makeTalkbackSink() -> (any TalkbackSink)? { nil }
}
