#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import HDS
import MediaCore
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// A controller that stops reading an HKSV recording must not let the producer queue fragments without limit (audit 3 B8): the
/// stream holds `RecordingProducer.queuedPacketLimit` packets, and a consumer that falls further behind ends it with one warning.
@Suite(.serialized) struct RuntimeRecordingBackpressureTests {
    @Test(.timeLimit(.minutes(2))) func aConsumerThatStopsReadingEndsTheStreamInsteadOfQueueingForever() async throws {
        let warnings = LiveLogCapture()
        defer { warnings.stop() }
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .milliseconds(500), audio: nil))
        #expect(await feeder.waitUntilReady())
        let log = Log(category: "RecordingBackpressureTest")
        let producer = RecordingProducer(streamID: 42, configuration: RecordingFixtures.configuration(width: 640, height: 360, prebufferMs: 0, fragmentMs: 500),
                                         audioActive: false, cameraAudioEnabled: false, hub: feeder.hub, codecs: AppleMediaCodecs(), timing: RecordingTiming(), log: log)
        let stream = producer.start()
        // Nobody reads: an init segment and about two fragments a second.
        #expect(await eventually(timeout: .seconds(10)) { await feeder.hub.subscriberCount == 1 }, "the producer subscribed")
        let ended = await eventually(timeout: .seconds(30)) { await feeder.hub.subscriberCount == 0 }
        #expect(ended, "the producer stopped on its own once the queue filled")
        // What was queued is intact and ends with the error: no packet was dropped from the middle.
        #expect(warnings.matching(category: "RecordingBackpressureTest", containing: "reads its fragments too slowly").count == 1)
        let (packets, error) = await collect(stream)
        #expect(packets.count == RecordingProducer.queuedPacketLimit, "\(packets.count) packets were waiting")
        #expect(error != nil)
        let initialization = try #require(packets.first).packet.data
        #expect(try initializationTracks(initialization).types == ["ftyp", "moov"])
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        var next: UInt64?
        for fragment in fragments {
            let video = try #require(fragment.video)
            if let next { #expect(video.baseDecodeTime == next, "the waiting fragments are contiguous") }
            next = video.baseDecodeTime + video.totalDuration
        }
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(2))) func aConsumerThatKeepsUpIsNeverCut() async throws {
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .milliseconds(500), audio: nil))
        #expect(await feeder.waitUntilReady())
        let producer = RecordingProducer(streamID: 43, configuration: RecordingFixtures.configuration(width: 640, height: 360, prebufferMs: 0, fragmentMs: 500),
                                         audioActive: false, cameraAudioEnabled: false, hub: feeder.hub, codecs: AppleMediaCodecs(), timing: RecordingTiming(),
                                         log: Log(category: "RecordingBackpressureTest"))
        let stream = producer.start()
        let (packets, error) = await collect(stream, limit: 3 * RecordingProducer.queuedPacketLimit)
        #expect(error == nil && packets.count == 3 * RecordingProducer.queuedPacketLimit, "\(packets.count) packets read")
        producer.cancel()
        await feeder.stop()
    }
}
#endif
