#if canImport(Darwin)
import BridgeSupport
import FMP4
import Foundation
import HAPCamera
import HDS
import MediaCore
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// HKSV recording delegate (plan W3-1 item 5; research brief §3.9; integration brief §5.2–§5.3) on a real-time
/// VideoToolbox synthetic source through a `MediaHub`.
@Suite(.serialized) struct RuntimeRecordingTests {
    static let log = Log(category: "RecordingTest")

    static func handler(_ feeder: HubFeeder, audioEnabled: Bool = true, timing: RecordingTiming = RecordingTiming()) -> RecordingHandler {
        RecordingHandler(hub: feeder.hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: audioEnabled, timing: timing, log: log)
    }

    /// Checks the stream: init first, fragments start with an IDR, each at most `fragmentMs` plus one frame (15 fps
    /// sources), continuous tfdt.
    static func validate(_ packets: [ReceivedPacket], fragmentMs: Int, expectAudio: Bool) throws -> [FragmentInfo] {
        let initialization = try #require(packets.first).packet
        let (types, trackCount) = try initializationTracks(initialization.data)
        #expect(types == ["ftyp", "moov"])
        #expect(trackCount == (expectAudio ? 2 : 1))
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        var nextVideo: UInt64?
        var nextAudio: UInt64?
        for fragment in fragments {
            let video = try #require(fragment.video)
            #expect(video.flags.first == 0x0200_0000, "fragment starts with a sync sample")
            #expect(try fragment.firstVideoSampleNALTypes().contains(5), "first sample is an IDR")
            #expect(Double(video.totalDuration) / 90_000 <= Double(fragmentMs) / 1000 + 1.0 / 15 + 0.001)
            if let nextVideo { #expect(video.baseDecodeTime == nextVideo, "tfdt continues the previous fragment") }
            nextVideo = video.baseDecodeTime + video.totalDuration
            #expect((fragment.audio != nil) == expectAudio)
            if let audio = fragment.audio {
                if let nextAudio { #expect(audio.baseDecodeTime == nextAudio, "audio is contiguous") }
                nextAudio = audio.baseDecodeTime + audio.totalDuration
            }
        }
        #expect(fragments.first?.video?.baseDecodeTime == 0, "tfdt rebased to 0")
        return fragments
    }

    @Test(.timeLimit(.minutes(3))) func passthroughWithCameraAudio() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: .aac, audioRate: 32_000))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingActive(true)
        await handler.updateRecordingAudioActive(true)
        let stream = try await handler.recordingStream(streamID: 1)
        #expect(await handler.isRecording)
        let (packets, error) = await collect(stream, limit: 5)
        #expect(error == nil)
        #expect(packets.count == 5)
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: true)
        // Passthrough keeps the camera's 640×360 frames: the first sample holds the source's bytes (no SPS/PPS in band).
        #expect(fragments.allSatisfy { ($0.audio?.durations.count ?? 0) > 0 })
        #expect(packets.allSatisfy { !$0.packet.isLast })
        await handler.acknowledgeStream(streamID: 1)
        #expect(await !handler.isRecording)
        #expect(await eventually { await feeder.hub.subscriberCount == 0 })
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func transcodesWhenTheProfileDoesNotFitAndRecordsSilence() async throws {
        // The synthetic source is Main; a Baseline selection forces the transcoder. The camera has no audio.
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, profile: .baseline, level: .level3_1,
                                                                                   fragmentMs: 1000, bitrate: 500))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 7), limit: 4)
        #expect(error == nil)
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: true)
        // Silence covers the video: 32 kHz AAC frames of 1024 samples, as long as the video (within one frame).
        for fragment in fragments {
            let video = try #require(fragment.video), audio = try #require(fragment.audio)
            #expect(audio.durations.allSatisfy { $0 == 1024 })
            #expect(abs(Double(audio.totalDuration) / 32_000 - Double(video.totalDuration) / 90_000) < 0.07)
        }
        // The encoder's output is Baseline (profile_idc 66 in the avcC).
        let avcC = try #require(try MP4BoxReader.parse(packets[0].packet.data).first { $0.type == "moov" }?
            .descendant(atPath: "trak/mdia/minf/stbl/stsd"))
        let bytes = [UInt8](packets[0].packet.data.subdata(in: avcC.offset..<(avcC.offset + avcC.size)))
        let marker = try #require((0..<(bytes.count - 4)).first { bytes[$0] == 0x61 && bytes[$0 + 1] == 0x76 && bytes[$0 + 2] == 0x63 && bytes[$0 + 3] == 0x43 })
        #expect(bytes[marker + 5] == 66)
        await handler.closeRecordingStream(streamID: 7, reason: .normal)
        await feeder.stop()
    }

    /// Review finding (W4 round 3): Camera Audio off was only tested against sources without audio. With the camera's
    /// microphone on the stream, a recording with RecordingAudioActive carries silence, never its sound.
    @Test(.timeLimit(.minutes(3))) func cameraAudioOffRecordsSilenceNotTheCamerasSound() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: .aac, audioRate: 32_000))
        #expect(await feeder.waitUntilReady())
        #expect(await feeder.hub.audioFormat != nil, "the camera has audio")
        try await Task.sleep(for: .seconds(1))
        let handler = Self.handler(feeder, audioEnabled: false)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 30), limit: 4)
        #expect(error == nil)
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: true)
        let silent = Set(try AppleMediaCodecs().silentAACFrames(duration: .milliseconds(200), sampleRate: 32_000, channels: 1,
                                                                startPTS: MediaTime(value: 0, timescale: 32_000), wallClock: Date())
            .map { UInt32($0.data.count) })
        for fragment in fragments {
            let audio = try #require(fragment.audio)
            #expect(!audio.sizes.isEmpty && audio.sizes.allSatisfy(silent.contains), "audio sample sizes \(audio.sizes), silence is \(silent)")
        }
        await handler.closeRecordingStream(streamID: 30, reason: nil)
        await feeder.stop()
    }

    /// Review finding: the camera's audio stops across a reconnect (audio switched off on the camera, a fallback stream
    /// without audio). The recording must carry silent AAC (spec: silence when the camera has no audio), not an AAC
    /// track chosen from the audio format seen before the reconnect that never gets a sample.
    @Test(.timeLimit(.minutes(3))) func recordsSilenceWhenAReconnectedSourceHasNoAudio() async throws {
        let hub = MediaHub()
        let withAudio = HubFeeder(source: syntheticSource(audio: .aac, audioRate: 32_000), hub: hub)
        #expect(await withAudio.waitUntilReady())
        #expect(await hub.audioFormat != nil)
        await withAudio.stop()
        try await Task.sleep(for: .milliseconds(300))   // let a sample already in flight land first
        await hub.discontinuity()                       // what IngestSupervisor does after every connection
        let videoOnly = HubFeeder(source: syntheticSource(audio: nil), hub: hub)
        #expect(await videoOnly.waitUntilReady())
        try await Task.sleep(for: .seconds(1))
        let handler = Self.handler(videoOnly)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 8), limit: 4)
        #expect(error == nil)
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: true)
        #expect(fragments.allSatisfy { ($0.audio?.durations.count ?? 0) > 0 }, "every fragment carries silent AAC")
        await handler.closeRecordingStream(streamID: 8, reason: nil)
        await videoOnly.stop()
    }

    /// Review finding (integration brief §5.6): a camera sending B-frames must not pass through, even when its format
    /// fits the selection; the ingest's `StreamTraits` tell the producer.
    @Test(.timeLimit(.minutes(3))) func bFramesFromTheIngestForceTheTranscoder() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        let traits = StreamTraits()
        traits.observe(.video(EncodedVideoFrame(format: VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: []), nalUnits: [Data([0x01, 0xA0])],
                                                isKeyframe: false, pts: MediaTime(value: 0, timescale: 90_000), wallClock: Date())))
        #expect(traits.usesBFrames)
        // 1280×720 Main fits the 640×360 Main source: without the traits this passes through at 640×360.
        let handler = RecordingHandler(hub: feeder.hub, traits: traits, codecs: AppleMediaCodecs(), cameraAudioEnabled: false, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 1280, height: 720, fragmentMs: 1000))
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 3), limit: 2)
        #expect(error == nil)
        _ = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)
        #expect(try Self.sampleEntrySize(packets[0].packet.data) == (1280, 720), "transcoded to the selection")
        await handler.closeRecordingStream(streamID: 3, reason: .normal)
        await feeder.stop()
    }

    /// Review finding (B-frames; the test above fakes the traits on a source without B-frames): a real B-frame camera
    /// (VideoToolbox, decode times as FLV carries them) is transcoded, and the clip shows every picture once, in display
    /// order. Pictures used to be encoded in decode order, and FrameRateLimiter (with a frame rate measured on the
    /// reordered presentation times) dropped about half of them.
    @Test(.timeLimit(.minutes(3))) func bFrameCameraIsRecordedInDisplayOrder() async throws {
        let frames = try BFrameStream.encode(count: 250, keyframes: Set(stride(from: 25, to: 250, by: 25)))   // 10 s, IDR every 1 s
        try #require(BFrameStream.reorders(frames))
        let traits = StreamTraits()
        let feeder = HubFeeder(source: PacedFrameSource(frames: frames, fps: 25), traits: traits)
        #expect(await feeder.waitUntilReady())
        #expect(traits.usesBFrames, "the traits saw the camera's B-frames")
        // 640×360 Main fits the selection: only the B-frames force the transcoder.
        let handler = RecordingHandler(hub: feeder.hub, traits: traits, codecs: AppleMediaCodecs(), cameraAudioEnabled: false, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, fragmentMs: 1000))
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 5), limit: 4)
        await handler.closeRecordingStream(streamID: 5, reason: .normal)
        await feeder.stop()
        #expect(error == nil)
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)

        let format = try #require(avcCFormat(packets[0].packet.data))
        let decoder = try AppleMediaCodecs().makeVideoDecoder(format: format)
        defer { decoder.invalidate() }
        var shown: [Int] = []
        for fragment in fragments {
            for (index, sample) in try fragment.videoSamples().enumerated() {
                let frame = EncodedVideoFrame(format: format, nalUnits: NALUnits.splitLengthPrefixed(sample), isKeyframe: index == 0,
                                              pts: MediaTime(value: Int64(shown.count * 3_600), timescale: 90_000), wallClock: Date())
                let picture = try #require(try await decoder.decode(frame))
                shown.append(try #require(BFrameStream.index(of: picture)))
            }
        }
        #expect(shown.count >= 70, "\(shown.count) pictures in 3 fragments of 1 s at 25 fps")
        let steps = zip(shown.dropFirst(), shown).map { ($0 - $1 + 50) % 50 }
        #expect(steps.allSatisfy { $0 == 1 }, "\(shown)")
    }

    /// Width and height of the init segment's `avc1` sample entry (ISO/IEC 14496-12 VisualSampleEntry).
    static func sampleEntrySize(_ initialization: Data) throws -> (Int, Int) {
        let bytes = [UInt8](initialization)
        let marker = try #require((0..<(bytes.count - 4)).first { bytes[$0] == 0x61 && bytes[$0 + 1] == 0x76 && bytes[$0 + 2] == 0x63 && bytes[$0 + 3] == 0x31 })
        // type (4) + reserved (6) + data_reference_index (2) + pre_defined/reserved (16), then width and height.
        let offset = marker + 4 + 6 + 2 + 16
        try #require(offset + 4 <= bytes.count)
        return (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]), Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
    }

    @Test(.timeLimit(.minutes(3))) func noAudioTrackWhileRecordingAudioIsOff() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: .pcmu, audioRate: 8_000))
        #expect(await feeder.waitUntilReady())
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(false)
        let (packets, _) = await collect(try await handler.recordingStream(streamID: 2), limit: 3)
        _ = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)
        await handler.closeRecordingStream(streamID: 2, reason: nil)

        // PCMU camera audio is converted to AAC-LC 32 kHz when audio is on.
        await handler.updateRecordingAudioActive(true)
        let (converted, _) = await collect(try await handler.recordingStream(streamID: 3), limit: 4)
        let fragments = try Self.validate(converted, fragmentMs: 1000, expectAudio: true)
        #expect(fragments.dropFirst().allSatisfy { ($0.audio?.durations.count ?? 0) > 0 })
        await handler.closeRecordingStream(streamID: 3, reason: nil)
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func prebufferIsPacedAndStartsBeforeTheRequest() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        try await Task.sleep(for: .seconds(4))
        let handler = Self.handler(feeder)
        // 3 s prebuffer of 1 s fragments: three fragments are ready at once and must not burst.
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 3000, fragmentMs: 1000))
        let requested = ContinuousClock.now
        let (packets, _) = await collect(try await handler.recordingStream(streamID: 4), limit: 4)
        let fragmentTimes = packets.dropFirst().map(\.at)
        for (earlier, later) in zip(fragmentTimes, fragmentTimes.dropFirst()) {
            #expect(later - earlier >= .milliseconds(240), "≤ 1 fragment per 250 ms")
        }
        // The replayed fragments arrive well before real time would produce 3 s of video.
        #expect(try #require(fragmentTimes.last) - requested < .milliseconds(2_500))
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)
        // Review finding (W4): how much pre-request video arrives was never checked (a third of it passed every suite).
        // What arrives right away spans the prebuffer, less at most one GOP (0.5 s) where the replay starts.
        let immediate = zip(packets.dropFirst(), fragments).filter { $0.0.at - requested < .milliseconds(1_200) }
        let seconds = immediate.reduce(0.0) { $0 + Double($1.1.video?.totalDuration ?? 0) / 90_000 }
        #expect(seconds >= 2.5, "\(seconds) s of video arrived within 1.2 s of the request")
        await handler.closeRecordingStream(streamID: 4, reason: nil)
        await feeder.stop()
    }

    /// Review finding (W4): a passthrough recording ended with unexpectedFailure when the camera came back with other
    /// parameter sets (FMP4Muxer.videoFormatChanged), or other audio (audioFormatChanged), during the recording.
    @Test(.timeLimit(.minutes(3))) func aSourceFormatChangeEndsThePassthroughRecordingCleanly() async throws {
        let hub = MediaHub()
        let feeder = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: nil), hub: hub)
        #expect(await feeder.waitUntilReady())
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        let stream = try await handler.recordingStream(streamID: 8)
        let reader = Task { await collect(stream, limit: 40) }
        try await Task.sleep(for: .milliseconds(2_500))
        // The camera reconnects at another resolution (IngestSupervisor: discontinuity, then the new stream).
        await feeder.stop()
        await hub.discontinuity()
        let larger = HubFeeder(source: syntheticSource(width: 480, height: 270, audio: nil), hub: hub)
        let (packets, error) = await reader.value
        #expect(error == nil, "no unexpectedFailure: \(String(describing: error))")
        #expect(packets.count >= 3)
        #expect(packets.last?.packet.isLast == true, "what was open goes out as the last fragment")
        #expect(packets.dropLast().allSatisfy { !$0.packet.isLast })
        _ = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)
        // The hub's next stream starts over on the new format.
        let (next, nextError) = await collect(try await handler.recordingStream(streamID: 9), limit: 3)
        #expect(nextError == nil && next.count == 3)
        #expect(try Self.sampleEntrySize(try #require(next.first).packet.data) == (480, 270))
        await handler.closeRecordingStream(streamID: 9, reason: nil)
        await larger.stop()
    }

    @Test(.timeLimit(.minutes(3))) func cameraAudioOfAnotherFormatIsConvertedNotFatal() async throws {
        let hub = MediaHub()
        let feeder = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: .aac, audioRate: 32_000), hub: hub)
        #expect(await feeder.waitUntilReady())
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: true, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let stream = try await handler.recordingStream(streamID: 10)
        let reader = Task { await collect(stream, limit: 8) }
        try await Task.sleep(for: .milliseconds(2_000))
        // Same video, but the camera's audio comes back at 16 kHz.
        await feeder.stop()
        await hub.discontinuity()
        let changed = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: .aac, audioRate: 16_000), hub: hub)
        let (packets, error) = await reader.value
        #expect(error == nil, "no unexpectedFailure: \(String(describing: error))")
        #expect(packets.count == 8)
        // The 16 kHz audio is converted to the track's 32 kHz: every fragment keeps its audio.
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        #expect(fragments.allSatisfy { ($0.audio?.durations.count ?? 0) > 0 })
        await handler.closeRecordingStream(streamID: 10, reason: nil)
        await changed.stop()
    }

    /// `AppleMediaCodecs` that notes the input format of every audio transcoder asked for (and refuses to make one with
    /// `refuseAudio`).
    struct AudioNotingCodecs: MediaCodecs {
        let base = AppleMediaCodecs()
        let audioInputs = Box<[AudioFormat]>([])
        var refuseAudio = false
        func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { try base.makeVideoDecoder(format: format) }
        func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { try base.makeVideoEncoder(settings: settings) }
        func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { try base.makeVideoTranscoder(output: output) }
        func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding {
            audioInputs.update { $0.append(input) }
            if refuseAudio { throw MediaCodecError.unsupported("no converter for \(input.codec.rawValue)") }
            return try base.makeAudioTranscoder(input: input, output: output)
        }
        func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data {
            try base.jpeg(from: frame, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
        }
        func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { try base.resizeJPEG(jpeg, maxWidth: maxWidth, maxHeight: maxHeight) }
        func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
            try base.silentAACFrames(duration: duration, sampleRate: sampleRate, channels: channels, startPTS: startPTS, wallClock: wallClock)
        }
        func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration, audio: AudioCodec?,
                                 audioSampleRate: Int) -> any MediaSource {
            base.makeSyntheticSource(displayName: displayName, width: width, height: height, fps: fps, keyframeInterval: keyframeInterval,
                                     audio: audio, audioSampleRate: audioSampleRate)
        }
    }

    /// Review finding (W4 round 4): camera audio that cannot be converted when the recording starts falls back to a silent
    /// AAC track (the selection asked for audio); that branch never ran.
    @Test(.timeLimit(.minutes(2))) func cameraAudioThatCannotBeConvertedRecordsSilence() async throws {
        let feeder = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: .aac, audioRate: 16_000))
        #expect(await feeder.waitUntilReady())
        #expect(await feeder.hub.audioFormat?.sampleRate == 16_000, "the 32 kHz track needs a converter")
        var codecs = AudioNotingCodecs()
        codecs.refuseAudio = true
        let handler = RecordingHandler(hub: feeder.hub, codecs: codecs, cameraAudioEnabled: true, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 36), limit: 4)
        #expect(error == nil, "\(String(describing: error))")
        #expect(codecs.audioInputs.value.first?.sampleRate == 16_000, "the converter was asked for")
        let fragments = try Self.validate(packets, fragmentMs: 1000, expectAudio: true)
        #expect(fragments.allSatisfy { ($0.audio?.durations.count ?? 0) > 0 }, "silent AAC fills the audio track")
        await handler.closeRecordingStream(streamID: 36, reason: nil)
        await feeder.stop()
    }

    struct AudioChange: Sendable, CustomTestStringConvertible {
        var from: AudioCodec
        var fromRate: Int
        var to: AudioCodec
        var toRate: Int
        var testDescription: String { "\(from.rawValue) \(fromRate) Hz → \(to.rawValue) \(toRate) Hz" }
    }

    /// Transcoded → transcoded with another codec (AAC 16 kHz → G.711, G.711 → AAC 16 kHz, µ-law → A-law), and
    /// passthrough → transcoded (the track's AAC 32 kHz → G.711).
    static let audioChanges = [AudioChange(from: .aac, fromRate: 16_000, to: .pcmu, toRate: 8_000),
                               AudioChange(from: .pcmu, fromRate: 8_000, to: .aac, toRate: 16_000),
                               AudioChange(from: .pcmu, fromRate: 8_000, to: .pcma, toRate: 8_000),
                               AudioChange(from: .aac, fromRate: 32_000, to: .pcmu, toRate: 8_000)]

    /// Review finding (W4 round 2): a mid-recording change of the camera's audio was handled for AAC passthrough only.
    /// The transcoder kept decoding the new audio as the old codec (aborted: unexpectedFailure; or noise and gaps), and
    /// passthrough dropped any non-AAC audio for the rest of the recording.
    @Test(.timeLimit(.minutes(2)), arguments: audioChanges) func cameraAudioOfAnotherCodecKeepsTheRecordingsAudio(_ change: AudioChange) async throws {
        let hub = MediaHub()
        let codecs = AudioNotingCodecs()
        let feeder = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: change.from, audioRate: change.fromRate), hub: hub)
        #expect(await feeder.waitUntilReady())
        let handler = RecordingHandler(hub: hub, codecs: codecs, cameraAudioEnabled: true, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        await handler.updateRecordingAudioActive(true)
        let stream = try await handler.recordingStream(streamID: 12)
        let reader = Task { await collect(stream, limit: 9) }
        try await Task.sleep(for: .milliseconds(2_000))
        // Same video; the camera comes back with other audio.
        await feeder.stop()
        await hub.discontinuity()
        let changed = HubFeeder(source: syntheticSource(width: 320, height: 180, audio: change.to, audioRate: change.toRate), hub: hub)
        let (packets, error) = await reader.value
        #expect(error == nil, "no unexpectedFailure: \(String(describing: error))")
        #expect(packets.count == 9)
        // 1 s fragments of 32 kHz AAC carry about 31 frames; the old audio path left 0–6 after the change.
        let counts = try packets.dropFirst().map { try FragmentInfo($0.packet.data).audio?.durations.count ?? 0 }
        #expect(counts.allSatisfy { $0 >= 15 }, "audio frames per fragment: \(counts)")
        #expect(codecs.audioInputs.value.contains { $0.codec == change.to && $0.sampleRate == change.toRate },
                "the new audio is converted from its own format: \(codecs.audioInputs.value.map(\.codec))")
        await handler.closeRecordingStream(streamID: 12, reason: nil)
        await changed.stop()
    }

    /// Review finding (W4 round 2): a long-GOP (smart codec) camera whose GOP was not measured yet (one keyframe since
    /// the runtime started) passed through although the GOP already open was longer than the fragment: every fragment
    /// of the recording (up to 3 minutes) was a whole 10 s GOP. The open GOP's age now counts as a lower bound.
    @Test(.timeLimit(.minutes(2))) func aLongGOPNotMeasuredYetIsTranscodedOnceItOutgrewTheFragment() async throws {
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(10), audio: nil))
        #expect(await eventually(timeout: .seconds(10)) { await feeder.hub.lastKeyframe != nil })
        try await Task.sleep(for: .milliseconds(5_000))
        #expect(await feeder.hub.measuredGOPDuration == nil, "one keyframe so far")
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 4000, fragmentMs: 4000))
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 13), limit: 3)
        #expect(error == nil)
        #expect(packets.count == 3 && packets.allSatisfy { !$0.packet.isLast }, "transcoded from the start: the stream goes on")
        _ = try Self.validate(packets, fragmentMs: 4000, expectAudio: false)
        await handler.closeRecordingStream(streamID: 13, reason: nil)
        await feeder.stop()
    }

    /// Review finding (W4 round 2): passthrough was never reconsidered during a recording. A GOP that outgrows the
    /// fragment now ends the stream with what fits as the last fragment; the hub's next stream decides again.
    @Test(.timeLimit(.minutes(2))) func aPassthroughGOPThatOutgrowsTheFragmentEndsTheStream() async throws {
        let feeder = HubFeeder(source: syntheticSource(width: 640, height: 360, fps: 15, gop: .seconds(10), audio: nil))
        #expect(await eventually(timeout: .seconds(10)) { await feeder.hub.lastKeyframe != nil })
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 0, fragmentMs: 4000))
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 14), limit: 4)
        #expect(error == nil)
        #expect(packets.count >= 2 && packets.count < 4, "\(packets.count) packets")
        #expect(packets.last?.packet.isLast == true, "the stream ends with a last fragment")
        let fragments = try packets.dropFirst().map { try FragmentInfo($0.packet.data) }
        for fragment in fragments {
            let seconds = Double(try #require(fragment.video).totalDuration) / 90_000
            #expect(seconds <= 4.05 + 1.0 / 15 + 0.001, "a \(seconds) s fragment")
        }
        // The next stream knows the GOP outgrew the fragment: transcoded, fragments of the fragment length.
        let (next, nextError) = await collect(try await handler.recordingStream(streamID: 15), limit: 2)
        #expect(nextError == nil && next.count == 2)
        _ = try Self.validate(next, fragmentMs: 4000, expectAudio: false)
        await handler.closeRecordingStream(streamID: 15, reason: nil)
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(3))) func capMarksTheLastFragment() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        let handler = Self.handler(feeder, timing: RecordingTiming(maximumDuration: .seconds(2), fragmentPacing: .milliseconds(250)))
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 0, fragmentMs: 1000))
        let started = ContinuousClock.now
        let (packets, error) = await collect(try await handler.recordingStream(streamID: 5))
        #expect(error == nil)
        #expect(packets.last?.packet.isLast == true)
        #expect(packets.dropLast().allSatisfy { !$0.packet.isLast })
        #expect(ContinuousClock.now - started < .seconds(5))
        _ = try Self.validate(packets, fragmentMs: 1000, expectAudio: false)
        await handler.acknowledgeStream(streamID: 5)
        await feeder.stop()
    }

    #if os(macOS)
    /// Review finding (W4): passthrough fragments ran past fragmentLength when the camera's GOP length varied (the
    /// fragmenter merged GOPs on the guess that the next GOP is as long as the last one). A 50-frame-GOP camera drops from
    /// 25 to 12.5 fps (night mode: 2 s GOPs become 4 s), then reconnects 0.48 s into a GOP (the rebaser joins the new
    /// timeline, so that GOP is cut short), switches back to day mode, to night mode again, and finally comes back with
    /// other parameter sets, which ends the recording with what is open. Every GOP fits the 4 s fragment, so the camera
    /// passes through; every fragment must fit too, the last ones included. Before the fix: [4, 6, 4, 4.48, 4, 4, 4, 4.08] s.
    @Test(.timeLimit(.minutes(1))) func passthroughFragmentsStayWithinTheFragmentLengthWhenTheGOPVaries() async throws {
        let idr = try #require(try BFrameStream.encode(count: 1).first)
        func frame(_ time: Double, key: Bool, format: VideoFormat? = nil) -> MediaSample { Self.frame(like: idr, at: time, key: key, format: format) }
        let hub = MediaHub()
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false,
                                       timing: RecordingTiming(fragmentPacing: .zero), log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 0, fragmentMs: 4000))
        let stream = try await handler.recordingStream(streamID: 12)
        let reader = Task { await collect(stream) }
        #expect(await eventually { await hub.subscriberCount == 1 })
        // 25 fps until 6 s, then 12.5 fps; keyframes every 50 frames (0, 2, 4, 6, 10, 14 s); the camera drops at 14.48 s.
        for index in 0..<256 {
            await hub.ingest(frame(index < 150 ? Double(index) / 25 : 6 + Double(index - 150) / 12.5, key: index % 50 == 0))
        }
        // It reconnects with a new timeline: 12.5 fps, 4 s GOPs, which the recording continues at 14.48 s (keyframes at
        // 14.48, 18.48, 22.48, 26.48 s); then 25 fps (keyframe at 28.48 s), then 12.5 fps again until 30.48 s.
        await hub.discontinuity()
        for index in 0...150 { await hub.ingest(frame(100 + Double(index) / 12.5, key: index % 50 == 0)) }
        for index in 1...50 { await hub.ingest(frame(112 + Double(index) / 25, key: index == 50)) }
        for index in 1...25 { await hub.ingest(frame(114 + Double(index) / 12.5, key: false)) }
        // New parameter sets: the open fragment goes out and the stream ends. As one fragment it would be 4.08 s long.
        var changed = idr.format
        changed.parameterSets[changed.parameterSets.count - 1].append(0x01)
        await hub.ingest(frame(116.08, key: true, format: changed))

        let (packets, error) = await reader.value
        #expect(error == nil)
        #expect(packets.last?.packet.isLast == true && packets.dropLast().allSatisfy { !$0.packet.isLast })
        let infos = try Self.validate(packets, fragmentMs: 4000, expectAudio: false)
        let lengths = infos.map { Double($0.video?.totalDuration ?? 0) / 90_000 }
        #expect(lengths.allSatisfy { $0 <= 4.05 }, "fragment lengths \(lengths) s")
        #expect(lengths.map { ($0 * 100).rounded() / 100 } == [4, 2, 4, 4, 0.48, 4, 4, 4, 2, 2.08])
        // Passed through: every frame before the format change is there, as the camera sent it.
        #expect(infos.reduce(0) { $0 + ($1.video?.durations.count ?? 0) } == 256 + 151 + 75)
    }

    /// At the duration cap the fragment that goes out is the last one. A keyframe can close two (a GOP that turned out not
    /// to fit, then the fragment it starts): both go out, the second marked last, rather than the second being dropped.
    @Test(.timeLimit(.minutes(1))) func aKeyframeClosingTwoFragmentsAtTheCapSendsBoth() async throws {
        let idr = try #require(try BFrameStream.encode(count: 1).first)
        let hub = MediaHub()
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false,
                                       timing: RecordingTiming(maximumDuration: .zero, fragmentPacing: .zero), log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(prebufferMs: 0, fragmentMs: 4000))
        let stream = try await handler.recordingStream(streamID: 13)
        let reader = Task { await collect(stream) }
        #expect(await eventually { await hub.subscriberCount == 1 })
        // A 2 s GOP at 25 fps, the next at 12.5 fps until 4.0 s, then a keyframe at 4.08 s: [0, 2 s) and [2 s, 4.08 s).
        for index in 0...50 { await hub.ingest(Self.frame(like: idr, at: Double(index) / 25, key: index % 50 == 0)) }
        for index in 1...25 { await hub.ingest(Self.frame(like: idr, at: 2 + Double(index) * 0.08, key: false)) }
        await hub.ingest(Self.frame(like: idr, at: 4.08, key: true))
        let (packets, error) = await reader.value
        #expect(error == nil)
        #expect(packets.map(\.packet.isLast) == [false, false, true])
        let lengths = try Self.validate(packets, fragmentMs: 4000, expectAudio: false).map { Double($0.video?.totalDuration ?? 0) / 90_000 }
        #expect(lengths.map { ($0 * 100).rounded() / 100 } == [2, 2.08])
    }

    /// A 25 fps H.264 Main camera without B-frames (the B-frame stream through the transcoder), keyframes every second.
    static func pOnlyStream(count: Int) async throws -> [EncodedVideoFrame] {
        let source = try BFrameStream.encode(count: count, fps: 25, keyframes: Set(stride(from: 25, to: count, by: 25)))
        let converter = try AppleMediaCodecs().makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 25, bitrateKbps: 1500,
                                                                                               profile: .main, level: .level3_1,
                                                                                               keyframeInterval: .seconds(1), realtime: false))
        defer { converter.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in source { frames += try await converter.transcode(frame) }
        return frames
    }

    /// Review finding (W4 round 3): the transcoder's output frame rate was the hub's measured rate (a mean over the last
    /// 90 frames, rounded) at the start of the recording. A 25 fps camera that skipped two frames just before motion
    /// measured 24.4 and was recorded at 24 fps for the whole clip: a picture dropped (and the one before repeated)
    /// every second. Only the selected rate (30) limits the output now.
    @Test(.timeLimit(.minutes(2))) func aFrameRateMeasuredLowAtTheStartDropsNothingForTheWholeRecording() async throws {
        let frames = try await Self.pOnlyStream(count: 300)
        #expect(frames.count >= 290 && !BFrameStream.reorders(frames))
        let hub = MediaHub()
        // Two pictures missing just before the recording starts (a busy camera): the hub measures about 24.4 fps.
        let early = frames.prefix(88).enumerated().filter { $0.offset != 40 && $0.offset != 41 }.map(\.element)
        for frame in early { await hub.ingest(.video(frame)) }
        let measured = try #require(await hub.measuredFrameRate)
        #expect(measured < 24.5, "measured \(measured) fps")
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false,
                                       timing: RecordingTiming(fragmentPacing: .zero), log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, profile: .baseline, level: .level3_1,
                                                                                   prebufferMs: 4000, fragmentMs: 1000, bitrate: 500))
        let stream = try await handler.recordingStream(streamID: 21)
        let received = Box<[Data]>([])
        let reader = Task { for try await packet in stream { received.update { $0.append(packet.data) } } }
        #expect(await eventually(timeout: .seconds(10)) { !received.value.isEmpty }, "the recording chose its path (init segment sent)")
        for frame in frames.dropFirst(88) { await hub.ingest(.video(frame)) }
        func recorded() throws -> (samples: Int, seconds: Double) {
            let infos = try received.value.dropFirst().map { try FragmentInfo($0) }
            return (infos.reduce(0) { $0 + ($1.video?.durations.count ?? 0) },
                    Double(infos.reduce(UInt64(0)) { $0 + ($1.video?.totalDuration ?? 0) }) / 90_000)
        }
        #expect(await eventually(timeout: .seconds(20)) { ((try? recorded())?.seconds ?? 0) >= 9 })
        await handler.closeRecordingStream(streamID: 21, reason: nil)
        reader.cancel()
        let (samples, seconds) = try recorded()
        #expect(Double(samples) / seconds > 24.6, "\(samples) pictures in \(seconds) s")
    }

    /// Records `frames` (instantly) through a transcoded 640×360 Baseline selection with `codecs`; returns the packets
    /// received and how the stream ended (nil: still open when closed after `wanted` packets, or 20 s).
    static func transcodedRecording(of frames: [EncodedVideoFrame], codecs: WatchedTranscoderCodecs, wanted: Int,
                                    streamID: Int) async throws -> (packets: [Data], error: (any Error)?) {
        let hub = MediaHub()
        let handler = RecordingHandler(hub: hub, codecs: codecs, cameraAudioEnabled: false, timing: RecordingTiming(fragmentPacing: .zero),
                                       log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, profile: .baseline, level: .level3_1,
                                                                                   prebufferMs: 0, fragmentMs: 1000, bitrate: 500))
        let stream = try await handler.recordingStream(streamID: streamID)
        let received = Box<[Data]>([])
        let ended = Box<(any Error)??>(nil)
        let reader = Task {
            do {
                for try await packet in stream { received.update { $0.append(packet.data) } }
                ended.set(.some(nil))
            } catch {
                ended.set(.some(error))
            }
        }
        #expect(await eventually { await hub.subscriberCount == 1 })
        for frame in frames { await hub.ingest(.video(frame)) }
        _ = await eventually(timeout: .seconds(20)) { received.value.count >= wanted || ended.value != nil }
        await handler.closeRecordingStream(streamID: streamID, reason: nil)
        reader.cancel()
        return (received.value, ended.value ?? nil)
    }

    /// Review finding (W4 round 3): a keyframe the decoder rejected (a malformed IDR, a VideoToolbox hiccup) ended a
    /// transcoded recording with unexpectedFailure, where live view only drops that frame; the next IDR a second later
    /// decodes fine. The frame is dropped and the recording goes on.
    @Test(.timeLimit(.minutes(2))) func aKeyframeTheTranscoderRejectsCostsOneGOPNotTheRecording() async throws {
        let frames = try await Self.pOnlyStream(count: 200)   // 8 one-second GOPs
        let keyframes = Box(0)
        var codecs = WatchedTranscoderCodecs()
        codecs.fails = { frame in frame.isKeyframe && keyframes.update { $0 += 1; return $0 } == 3 }
        let (packets, error) = try await Self.transcodedRecording(of: frames, codecs: codecs, wanted: 6, streamID: 22)
        #expect(error == nil, "\(String(describing: error))")
        #expect(packets.count >= 6, "\(packets.count) packets: the recording goes on after the rejected keyframe")
        _ = try packets.dropFirst().map { try FragmentInfo($0) }
    }

    /// A transcoder that fails every frame from some point on still ends the stream (rather than recording nothing for
    /// up to 3 minutes): after a new transcoder failed too.
    @Test(.timeLimit(.minutes(2))) func aTranscoderThatKeepsFailingEndsTheRecording() async throws {
        let frames = try await Self.pOnlyStream(count: 200)
        let keyframes = Box(0)
        var codecs = WatchedTranscoderCodecs()
        codecs.fails = { frame in (frame.isKeyframe ? keyframes.update { $0 += 1; return $0 } : keyframes.value) >= 3 }
        let (packets, error) = try await Self.transcodedRecording(of: frames, codecs: codecs, wanted: 100, streamID: 23)
        #expect((error as? HDSProtocolReason) == .unexpectedFailure, "\(String(describing: error))")
        #expect(packets.count >= 2 && packets.count < 6)
        #expect(codecs.transcoders.value.count == 2, "the second failure in a row got a new transcoder")
    }

    /// Every fragment's video length (seconds) and whether the packets after the initialization segment were marked last.
    static func fragmentLengths(_ packets: [ReceivedPacket]) throws -> (lengths: [Double], last: [Bool]) {
        let fragments = Array(packets.dropFirst())
        let lengths = try fragments.map { Double(try #require(try FragmentInfo($0.packet.data).video).totalDuration) / 90_000 }
        return (lengths.map { ($0 * 1000).rounded() / 1000 }, fragments.map(\.packet.isLast))
    }

    /// Records `frames` (instantly, with `prebufferMs` = 0) with a 4 s fragment; returns what arrived until the stream
    /// ended or `wanted` packets came (then it is closed).
    static func gapRecording(_ frames: [MediaSample], configuration: CameraRecordingConfiguration, wanted: Int = 20,
                             streamID: Int) async throws -> (packets: [ReceivedPacket], error: (any Error)?, ended: Bool) {
        let hub = MediaHub()
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false, timing: RecordingTiming(fragmentPacing: .zero),
                                       log: Self.log)
        await handler.updateRecordingConfiguration(configuration)
        let stream = try await handler.recordingStream(streamID: streamID)
        let received = Box<[ReceivedPacket]>([])
        let outcome = Box<(any Error)??>(nil)
        let reader = Task {
            do {
                for try await packet in stream { received.update { $0.append(ReceivedPacket(packet: packet, at: .now)) } }
                outcome.set(.some(nil))
            } catch {
                outcome.set(.some(error))
            }
        }
        #expect(await eventually { await hub.subscriberCount == 1 })
        for frame in frames { await hub.ingest(frame) }
        _ = await eventually(timeout: .seconds(20)) { received.value.count >= wanted || outcome.value != nil }
        try await Task.sleep(for: .milliseconds(500))
        let ended = outcome.value != nil
        await handler.closeRecordingStream(streamID: streamID, reason: nil)
        reader.cancel()
        return (received.value, outcome.value ?? nil, ended)
    }

    /// Review finding (W4 round 4): only a passed-through delta frame past the fragment length ended the stream. Video
    /// that came back at a keyframe after a gap (a lost IDR: the depacketizer drops the whole GOP; a stall) closed the open
    /// fragment at that late keyframe, its last picture stretched over the gap: an 8 s fragment of a 4 s selection (HKSV:
    /// no longer than fragmentLength). What fits goes out and the stream ends, as for a GOP that outgrows the fragment.
    @Test(.timeLimit(.minutes(1))) func aLostIDRNeverStretchesAPassthroughFragmentPastItsLength() async throws {
        let idr = try #require(try BFrameStream.encode(count: 1).first)
        // 25 fps, 4 s GOPs; the IDR at 8 s is lost, and with it every frame up to the next one at 12 s.
        let frames = (0..<(25 * 20)).compactMap { index -> MediaSample? in
            let time = Double(index) / 25
            return time >= 8 && time < 12 ? nil : Self.frame(like: idr, at: time, key: index % 100 == 0)
        }
        let (packets, error, ended) = try await Self.gapRecording(frames, configuration: RecordingFixtures.configuration(prebufferMs: 0, fragmentMs: 4000),
                                                                  streamID: 31)
        #expect(error == nil)
        let (lengths, last) = try Self.fragmentLengths(packets)
        #expect(lengths.allSatisfy { $0 <= 4.05 + 0.04 }, "fragment lengths \(lengths) s")
        #expect(ended && last.last == true && last.dropLast().allSatisfy { !$0 }, "the stream ends with a last fragment: \(last)")
        #expect(lengths == [4, 4], "\(lengths)")
    }

    /// The same for a transcoded recording: a source gap (frames from 2 to 6 s missing in a 1 s-GOP camera) left one
    /// 4 s picture in a 6 s fragment.
    @Test(.timeLimit(.minutes(2))) func aSourceGapNeverStretchesATranscodedFragmentPastItsLength() async throws {
        let frames = try await Self.pOnlyStream(count: 300).filter { $0.pts.seconds < 2 || $0.pts.seconds >= 6 }
        let configuration = RecordingFixtures.configuration(width: 640, height: 360, profile: .baseline, level: .level3_1, prebufferMs: 0, fragmentMs: 4000,
                                                            bitrate: 500)
        let (packets, error, _) = try await Self.gapRecording(frames.map { .video($0) }, configuration: configuration, streamID: 32)
        #expect(error == nil)
        let (lengths, last) = try Self.fragmentLengths(packets)
        #expect(!lengths.isEmpty && lengths.allSatisfy { $0 <= 4.05 + 0.04 }, "fragment lengths \(lengths) s")
        #expect(last.last == true, "the stream ends at the gap: \(last)")
    }

    /// The round-3 recovery path on a long-GOP camera: a 10 s-GOP camera (transcoded for its GOP) whose keyframe at 10 s
    /// the decoder rejects records nothing until its next keyframe at 20 s. That gap made a 12 s fragment.
    @Test(.timeLimit(.minutes(2))) func aRejectedKeyframeOfALongGOPCameraNeverStretchesAFragmentPastItsLength() async throws {
        let frames = try await Self.longGOPStream(seconds: 30, gop: 10).map { frame -> MediaSample in
            var input = frame
            if frame.isKeyframe, abs(frame.pts.seconds - 10) < 0.001, let last = frame.nalUnits.last { input.nalUnits = [Data(last.prefix(12))] }
            return .video(input)
        }
        let configuration = RecordingFixtures.configuration(width: 640, height: 360, profile: .baseline, level: .level3_1, prebufferMs: 0, fragmentMs: 4000,
                                                            bitrate: 500)
        let (packets, error, _) = try await Self.gapRecording(frames, configuration: configuration, streamID: 33)
        #expect(error == nil)
        let (lengths, last) = try Self.fragmentLengths(packets)
        #expect(!lengths.isEmpty && lengths.allSatisfy { $0 <= 4.05 + 0.04 }, "fragment lengths \(lengths) s")
        #expect(last.last == true, "the stream ends at the gap: \(last)")
    }

    /// A 25 fps 640×360 H.264 Main camera without B-frames whose keyframes come every `gop` seconds.
    static func longGOPStream(seconds: Int, gop: Int) async throws -> [EncodedVideoFrame] {
        let count = seconds * 25
        let source = try BFrameStream.encode(count: count, fps: 25, keyframes: Set(stride(from: gop * 25, to: count, by: gop * 25)))
        let converter = try AppleMediaCodecs().makeVideoTranscoder(output: VideoEncoderSettings(width: 640, height: 360, fps: 25, bitrateKbps: 1500,
                                                                                               profile: .main, level: .level3_1,
                                                                                               keyframeInterval: .seconds(gop), realtime: false))
        defer { converter.invalidate() }
        var frames: [EncodedVideoFrame] = []
        for frame in source { frames += try await converter.transcode(frame) }
        return frames
    }

    /// Review finding (W4 round 4): the hub replays from the newest keyframe at least `prebufferLength` old, and a camera
    /// whose GOP is longer than the fragment (exactly the ones that are transcoded) has its keyframes up to a GOP apart: a
    /// 10 s-GOP camera sent 12 s and more of pre-event video for a 4 s prebuffer, in about a second (integration brief
    /// §5.3: yield from the newest fragment at or before now − prebufferLength; do not burst the whole buffer). The
    /// transcoded recording now starts with a keyframe at the requested prebuffer.
    @Test(.timeLimit(.minutes(2))) func aLongGOPCameraSendsThePrebufferItWasAskedForNotItsWholeGOP() async throws {
        // Keyframes at 0, 10 and 20 s; the recording is requested at 23 s (the hub holds all of it).
        let frames = try await Self.longGOPStream(seconds: 23, gop: 10)
        let hub = MediaHub()
        for frame in frames { await hub.ingest(.video(frame)) }
        #expect(try #require(await hub.measuredGOPDuration) > .seconds(9), "a 10 s GOP: transcoded")
        let handler = RecordingHandler(hub: hub, codecs: AppleMediaCodecs(), cameraAudioEnabled: false, log: Self.log)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(width: 640, height: 360, profile: .main, level: .level3_1,
                                                                                   prebufferMs: 4000, fragmentMs: 4000, bitrate: 1500))
        let stream = try await handler.recordingStream(streamID: 34)
        let received = Box<[Data]>([])
        let reader = Task { for try await packet in stream { received.update { $0.append(packet.data) } } }
        #expect(await eventually(timeout: .seconds(10)) { received.value.count >= 2 }, "the prebuffer arrives")
        try await Task.sleep(for: .seconds(2))   // everything the replay closes has gone out (≤ 1 fragment per 250 ms)
        await handler.closeRecordingStream(streamID: 34, reason: nil)
        reader.cancel()
        let seconds = try received.value.dropFirst().reduce(0.0) { $0 + Double(try #require(try FragmentInfo($1).video).totalDuration) / 90_000 }
        #expect(seconds > 0 && seconds <= 4 + 4 + 0.1, "\(seconds) s of pre-event video for a 4 s prebuffer")
    }

    /// A passthrough-ready frame at `time` s: the IDR's own bytes for a keyframe, a P slice otherwise.
    static func frame(like idr: EncodedVideoFrame, at time: Double, key: Bool, format: VideoFormat? = nil) -> MediaSample {
        .video(EncodedVideoFrame(format: format ?? idr.format, nalUnits: key ? idr.nalUnits : [Data([0x41, 0x9A, 0x00, 0x01, 0x02])],
                                 isKeyframe: key, pts: .seconds(time), wallClock: Date()))
    }
    #endif

    @Test(.timeLimit(.minutes(1))) func closeStopsTheProducerAtOnce() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        let handler = Self.handler(feeder)
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        let stream = try await handler.recordingStream(streamID: 6)
        let reader = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(1500))
        let closed = ContinuousClock.now
        await handler.closeRecordingStream(streamID: 6, reason: .cancelled)
        let (packets, _) = await reader.value
        #expect(ContinuousClock.now - closed < .seconds(2), "honours close well within 10 s")
        #expect(packets.count >= 2)
        #expect(await eventually { await feeder.hub.subscriberCount == 0 })
        await feeder.stop()
    }

    @Test(.timeLimit(.minutes(1))) func oneStreamPerCameraAndConfigurationRequired() async throws {
        let feeder = HubFeeder(source: syntheticSource(audio: nil))
        #expect(await feeder.waitUntilReady())
        let handler = Self.handler(feeder)
        await #expect(throws: HDSProtocolReason.invalidConfiguration) { _ = try await handler.recordingStream(streamID: 1) }
        await handler.updateRecordingConfiguration(RecordingFixtures.configuration(fragmentMs: 1000))
        let first = try await handler.recordingStream(streamID: 1)
        let firstReader = Task { await collect(first) }
        try await Task.sleep(for: .milliseconds(300))
        let second = try await handler.recordingStream(streamID: 2)
        // The replaced producer ends; the new one produces.
        _ = await firstReader.value
        let (packets, _) = await collect(second, limit: 2)
        #expect(packets.count == 2)
        await handler.closeRecordingStream(streamID: 1, reason: nil)   // stale id: ignored
        #expect(await handler.isRecording)
        await handler.closeRecordingStream(streamID: 2, reason: nil)
        #expect(await !handler.isRecording)
        await feeder.stop()
    }
}
#endif
