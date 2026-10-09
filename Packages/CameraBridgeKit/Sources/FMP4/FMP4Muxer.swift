import Foundation
import MediaCore

/// Fragmented-MP4 writer for HKSV recordings (research brief §3.9): one initialization segment, then one `moof`+`mdat`
/// per call to `fragment(_:)` / `fragment(video:audio:)`, laid out like ffmpeg's
/// `-movflags frag_keyframe+empty_moov+default_base_moof`.
///
/// Track 1 is video (`avc1`/`hvc1`, timescale `videoTimescale`), track 2 the optional AAC-LC audio (timescale = sample rate).
/// Timestamps of both tracks are rebased together so the first video frame of the first fragment decodes at 0; audio and
/// video pts must share one time origin (as `MediaHub` delivers them). A muxer serves exactly one recording: after a
/// source discontinuity or a parameter-set change, create a new one (and send its new initialization segment).
public struct FMP4Muxer: Sendable {
    /// What the last successful `fragment` call wrote and left out. FMP4 cannot log, so the caller reports these.
    public struct FragmentStatistics: Sendable, Equatable {
        public var videoSamples: Int
        public var audioSamples: Int
        /// Video frames without NAL units once the ones below were removed; skipped (the previous sample lasts longer).
        public var skippedVideoFrames: Int
        /// NAL units removed from video samples: empty ones, in-band copies of the sample entry's parameter sets, access
        /// unit delimiters, end of sequence / bitstream, filler data and H.264 SPS extensions.
        public var removedNALUnits: Int
        /// Audio frames before the recording's first video frame, or not after the last audio sample written.
        public var droppedAudioFrames: Int
        /// Audio frames more than `FMP4Muxer.audioHorizon` past the end of the fragment's video (a glitched or misaligned
        /// clock). They are dropped without moving the audio timeline, so later audio is not lost with them.
        public var outOfRangeAudioFrames: Int

        public init(videoSamples: Int = 0, audioSamples: Int = 0, skippedVideoFrames: Int = 0, removedNALUnits: Int = 0,
                    droppedAudioFrames: Int = 0, outOfRangeAudioFrames: Int = 0) {
            self.videoSamples = videoSamples
            self.audioSamples = audioSamples
            self.skippedVideoFrames = skippedVideoFrames
            self.removedNALUnits = removedNALUnits
            self.droppedAudioFrames = droppedAudioFrames
            self.outOfRangeAudioFrames = outOfRangeAudioFrames
        }
    }

    /// How far past the end of a fragment's video its audio may reach before it counts as out of range.
    public static let audioHorizon: Duration = .seconds(2)

    public let configuration: FMP4Configuration
    /// Statistics of the last fragment written (all zero before the first; unchanged by a call that throws).
    public private(set) var lastFragmentStatistics = FragmentStatistics()

    private let video: VideoTrack
    private let audio: AudioTrack?
    private let initSegment: Data
    /// The configured parameter sets without trailing zero bytes, as a set (order and duplicates do not matter).
    private let referenceParameterSets: Set<Data>
    private var state = State()

    private struct State: Sendable {
        var sequenceNumber: UInt32 = 0
        /// Source decode time (video ticks) that maps to 0, fixed by the first fragment.
        var videoOrigin: Int64?
        /// The same instant in audio ticks.
        var audioOrigin: Int64?
        /// Rebased decode time and duration of the last video sample written.
        var lastVideoDecodeTime: Int64?
        var lastVideoDuration: Int64?
        /// Rebased decode time of the last audio sample written.
        var lastAudioTime: Int64?
    }

    static let keyframeSampleFlags: UInt32 = 0x0200_0000       // sample_depends_on = 2 (I-frame)
    static let deltaSampleFlags: UInt32 = 0x0101_0000          // sample_depends_on = 1, sample_is_non_sync_sample
    static let audioSampleFlags: UInt32 = 0x0200_0000
    /// AAC-LC access unit length, used when a frame reports no sample count.
    static let aacFrameSamples: Int64 = 1_024

    /// NAL unit types kept out of samples. Parameter sets (H.264 SPS 7, PPS 8; HEVC VPS 32, SPS 33, PPS 34) live only in
    /// the sample entry (`hvc1` requires it), so an in-band copy must match one there; the others carry nothing a decoder
    /// needs from an MP4 sample (H.264 AUD 9, end of sequence 10, end of stream 11, filler 12, SPS extension 13 — alpha
    /// planes only; HEVC AUD 35, EOS 36, EOB 37, filler 38).
    static let h264ParameterSetTypes: Set<UInt8> = [7, 8]
    static let h264RemovedTypes: Set<UInt8> = [9, 10, 11, 12, 13]
    static let hevcParameterSetTypes: Set<UInt8> = [32, 33, 34]
    static let hevcRemovedTypes: Set<UInt8> = [35, 36, 37, 38]

    /// Validates the formats and builds the initialization segment. Throws `FMP4Error` for a missing/unparsable parameter
    /// set, an unusable picture size, a non-positive timescale, or audio other than AAC-LC (including an AudioSpecificConfig
    /// with another object type, or a sampling frequency different from the format's).
    public init(configuration: FMP4Configuration) throws {
        guard configuration.videoTimescale > 0 else { throw FMP4Error.invalidTimescale(configuration.videoTimescale) }
        let format = configuration.video
        var width = format.width
        var height = format.height
        let record: Data
        switch format.codec {
        case .h264:
            record = try AVCDecoderConfigurationRecord.make(parameterSets: format.parameterSets)
            if width <= 0 || height <= 0,
               let sps = format.parameterSets.first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }), let parsed = H264SPS.parse(sps) {
                (width, height) = (parsed.width, parsed.height)
            }
        case .hevc:
            record = try HEVCDecoderConfigurationRecord.make(parameterSets: format.parameterSets)
            if width <= 0 || height <= 0,
               let sps = format.parameterSets.first(where: { $0.count >= 2 && ($0[$0.startIndex] >> 1) & 0x3F == 33 }),
               let parsed = HEVCSPS.parse(sps) {
                (width, height) = (parsed.width, parsed.height)
            }
        }
        guard (1...0xFFFF).contains(width), (1...0xFFFF).contains(height) else {
            throw FMP4Error.invalidVideoDimensions(width: width, height: height)
        }
        let videoTrack = VideoTrack(codec: format.codec, width: width, height: height, timescale: configuration.videoTimescale,
                                    decoderConfiguration: record, sampleAspectRatio: format.sampleAspectRatio)

        var audioTrack: AudioTrack?
        if let audio = configuration.audio {
            guard audio.codec == .aac else { throw FMP4Error.unsupportedAudio("\(audio.codec.rawValue): only AAC-LC can be recorded") }
            guard audio.sampleRate > 0, audio.sampleRate <= Int(Int32.max), (1...8).contains(audio.channels) else {
                throw FMP4Error.unsupportedAudio("AAC with \(audio.sampleRate) Hz / \(audio.channels) channels")
            }
            let asc = audio.audioSpecificConfig.flatMap { $0.isEmpty ? nil : $0 }
                ?? AudioFormat.aacLC(sampleRate: audio.sampleRate, channels: audio.channels).audioSpecificConfig ?? Data()
            guard let config = AudioSpecificConfig(asc) else { throw FMP4Error.unsupportedAudio("unparsable AudioSpecificConfig") }
            guard config.objectType == AudioSpecificConfig.aacLC else {
                throw FMP4Error.unsupportedAudio("audio object type \(config.objectType): only AAC-LC (2) can be recorded")
            }
            guard config.sampleRate == audio.sampleRate else {
                throw FMP4Error.unsupportedAudio("AudioSpecificConfig at \(config.sampleRate) Hz, format at \(audio.sampleRate) Hz")
            }
            audioTrack = AudioTrack(sampleRate: audio.sampleRate, channels: audio.channels, audioSpecificConfig: asc, config: config)
        }

        self.configuration = configuration
        self.video = videoTrack
        self.audio = audioTrack
        self.initSegment = InitializationSegment.make(video: videoTrack, audio: audioTrack)
        self.referenceParameterSets = Set(Self.normalized(format.parameterSets))
    }

    /// ftyp + moov(mvhd, trak×n with avc1/hvc1 + avcC/hvcC, mp4a + esds, mvex/trex).
    public func initializationSegment() -> Data {
        initSegment
    }

    /// One moof (one traf per track, ONE trun per traf, tfhd default-base-is-moof) + mdat.
    /// video.first must be a keyframe. tfdt is rebased so the first fragment of this muxer starts at 0.
    ///
    /// Without a successor's decode time the last video sample repeats the previous duration; use `fragment(_:)` with
    /// `GOPFragmenter.pushGroups(_:)` so each fragment's tfdt equals the previous one plus its durations.
    public mutating func fragment(video frames: [EncodedVideoFrame], audio audioFrames: [EncodedAudioFrame]) throws -> Data {
        try fragment(video: frames, audio: audioFrames, nextDecodeTime: nil)
    }

    /// `fragment(video:audio:nextDecodeTime:)` for a `GOPFragmenter` group.
    public mutating func fragment(_ group: FragmentGroup) throws -> Data {
        try fragment(video: group.video, audio: group.audio, nextDecodeTime: group.nextDecodeTime)
    }

    /// One fragment, as `fragment(video:audio:)`.
    ///
    /// With `writeProducerReferenceTime` a 32-byte `prft` (version 1, flags 0, NTP time of the first sample's `wallClock`,
    /// media time = video tfdt) precedes the moof. `mdat` holds the video samples (4-byte length-prefixed NAL units)
    /// followed by the audio access units. Samples leave out in-band parameter sets identical to the sample entry's
    /// (a different one throws `.videoFormatChanged`), delimiters, end-of-sequence/stream and filler NAL units; frames
    /// left without NAL units are skipped (a fragment must still start with a non-empty keyframe).
    ///
    /// Each sample's duration is the distance to the next one. The last video sample ends at `nextDecodeTime` (the next
    /// fragment's first decode time) when that lies after it and within a 32-bit duration; otherwise it repeats the
    /// previous duration. The last audio sample lasts `sampleCount`. Audio before the recording's first video frame, not
    /// advancing past the last written audio sample, or more than `audioHorizon` past the end of this fragment's video is
    /// dropped (`lastFragmentStatistics` counts it); audio passed to a muxer without an audio track is ignored, and a
    /// fragment without audio samples has no audio traf. On a throw the muxer is unchanged.
    public mutating func fragment(video frames: [EncodedVideoFrame], audio audioFrames: [EncodedAudioFrame],
                                  nextDecodeTime: MediaTime?) throws -> Data {
        guard let firstFrame = frames.first else { throw FMP4Error.emptyFragment }
        guard firstFrame.isKeyframe else { throw FMP4Error.fragmentMustStartWithKeyframe }
        var statistics = FragmentStatistics()

        // Samples.
        var samples: [(frame: EncodedVideoFrame, units: [Data])] = []
        samples.reserveCapacity(frames.count)
        for frame in frames {
            try checkVideoFormat(frame.format)
            let units = try sampleUnits(of: frame, removed: &statistics.removedNALUnits)
            if units.isEmpty {
                statistics.skippedVideoFrames += 1
            } else {
                samples.append((frame, units))
            }
        }
        guard let first = samples.first?.frame else { throw FMP4Error.emptyFragment }
        guard first.isKeyframe else { throw FMP4Error.fragmentMustStartWithKeyframe }

        // Video timing.
        let timescale = video.timescale
        let decodeTimes = samples.map { ($0.frame.dts ?? $0.frame.pts).converted(to: timescale).value }
        let origin = state.videoOrigin ?? decodeTimes[0]
        let videoTimes = try decodeTimes.map { try Self.difference($0, origin, "video decode time") }
        guard videoTimes[0] >= 0 else { throw FMP4Error.nonMonotonicTimestamps("video starts before the recording's first frame") }
        if let last = state.lastVideoDecodeTime, videoTimes[0] <= last {
            throw FMP4Error.nonMonotonicTimestamps("fragment starts at or before a video sample already written")
        }
        for index in videoTimes.indices.dropFirst() where videoTimes[index] <= videoTimes[index - 1] {
            throw FMP4Error.nonMonotonicTimestamps("video decode times must increase (sample \(index))")
        }
        var videoDurations = zip(videoTimes.dropFirst(), videoTimes).map { $0 - $1 }
        let lastVideoTime = videoTimes[videoTimes.count - 1]
        if let next = nextDecodeTime.flatMap({ try? Self.difference($0.converted(to: timescale).value, origin, "") }),
           next > lastVideoTime, next - lastVideoTime <= Int64(UInt32.max) {
            videoDurations.append(next - lastVideoTime)
        } else {
            videoDurations.append(videoDurations.last ?? state.lastVideoDuration ?? max(1, Int64(timescale) / 30))
        }
        try Self.checkDurations(videoDurations, "video")
        let compositionOffsets = try zip(samples, decodeTimes).map { sample, decode in
            try Self.difference(sample.frame.pts.converted(to: timescale).value, decode, "composition offset")
        }
        let hasCompositionOffsets = compositionOffsets.contains { $0 != 0 }
        let signedOffsets = compositionOffsets.contains { $0 < 0 }
        let offsetRange = signedOffsets ? Int64(Int32.min)...Int64(Int32.max) : 0...Int64(UInt32.max)
        guard compositionOffsets.allSatisfy({ offsetRange.contains($0) }) else { throw FMP4Error.timestampOutOfRange("composition offset") }

        // Audio timing, on the same origin.
        var audioSamples: [(time: Int64, frame: EncodedAudioFrame)] = []
        var audioOrigin = state.audioOrigin
        if let track = audio {
            let trackOrigin = state.audioOrigin ?? MediaTime(value: origin, timescale: timescale).converted(to: track.timescale).value
            audioOrigin = trackOrigin
            // The end of this fragment's video in audio ticks, plus the horizon (saturating).
            let (videoEnd, endOverflow) = lastVideoTime.addingReportingOverflow(videoDurations[videoDurations.count - 1])
            let videoEndInAudioTicks = MediaTime(value: endOverflow ? .max : videoEnd, timescale: timescale).converted(to: track.timescale).value
            let horizon = Int64(track.sampleRate).multipliedReportingOverflow(by: Self.audioHorizon.components.seconds).partialValue
            let (latest, latestOverflow) = videoEndInAudioTicks.addingReportingOverflow(horizon)
            let latestAudioTime = latestOverflow ? Int64.max : latest
            var previous = state.lastAudioTime
            for frame in audioFrames {
                try checkAudioFormat(frame.format, of: track)
                guard let time = try? Self.difference(frame.pts.converted(to: track.timescale).value, trackOrigin, "audio time"),
                      time <= latestAudioTime else {
                    statistics.outOfRangeAudioFrames += 1                   // far ahead: a glitched or misaligned clock
                    continue
                }
                if time < 0 || previous.map({ time <= $0 }) == true {
                    statistics.droppedAudioFrames += 1                      // before the recording starts, duplicate or out of order
                    continue
                }
                audioSamples.append((time, frame))
                previous = time
            }
        }
        var audioDurations = zip(audioSamples.dropFirst(), audioSamples).map { $0.time - $1.time }
        if let last = audioSamples.last {
            audioDurations.append(last.frame.sampleCount > 0 ? Int64(last.frame.sampleCount) : Self.aacFrameSamples)
        }
        try Self.checkDurations(audioDurations, "audio")

        // Sizes.
        let videoSizes = samples.map { $0.units.reduce(0) { $0 + 4 + $1.count } }
        let videoBytes = videoSizes.reduce(0, +)
        let audioBytes = audioSamples.reduce(0) { $0 + $1.frame.data.count }
        let mediaBytes = videoBytes + audioBytes
        guard mediaBytes < Int(Int32.max) else { throw FMP4Error.fragmentTooLarge(mediaBytes) }

        let sequence = state.sequenceNumber &+ 1
        var writer = BoxWriter(capacity: 256 + 20 * (samples.count + audioSamples.count) + mediaBytes)
        if configuration.writeProducerReferenceTime {
            writer.fullBox("prft", version: 1, flags: 0) { w in                // flags MUST be 0 (tvOS 27 homed)
                w.u32(VideoTrack.trackID)
                w.u64(Self.ntpTimestamp(first.wallClock))
                w.u64(UInt64(videoTimes[0]))
            }
        }
        let moofStart = writer.count
        var videoOffsetField = 0
        var audioOffsetField: Int?
        writer.box("moof") { w in
            w.fullBox("mfhd", version: 0, flags: 0) { $0.u32(sequence) }
            w.box("traf") { w in
                w.fullBox("tfhd", version: 0, flags: 0x02_0000) { $0.u32(VideoTrack.trackID) }   // default-base-is-moof
                w.fullBox("tfdt", version: 1, flags: 0) { $0.u64(UInt64(videoTimes[0])) }
                // data-offset | sample-duration | sample-size | sample-flags (| sample-composition-time-offset)
                let flags: UInt32 = 0x00_0701 | (hasCompositionOffsets ? 0x00_0800 : 0)
                w.fullBox("trun", version: signedOffsets ? 1 : 0, flags: flags) { w in
                    w.u32(UInt32(samples.count))
                    videoOffsetField = w.count
                    w.i32(0)
                    for index in samples.indices {
                        w.u32(UInt32(videoDurations[index]))
                        w.u32(UInt32(videoSizes[index]))
                        w.u32(samples[index].frame.isKeyframe ? Self.keyframeSampleFlags : Self.deltaSampleFlags)
                        if hasCompositionOffsets { w.u32(UInt32(truncatingIfNeeded: compositionOffsets[index])) }
                    }
                }
            }
            if let firstAudio = audioSamples.first {
                w.box("traf") { w in
                    w.fullBox("tfhd", version: 0, flags: 0x02_0000) { $0.u32(AudioTrack.trackID) }
                    w.fullBox("tfdt", version: 1, flags: 0) { $0.u64(UInt64(firstAudio.time)) }
                    w.fullBox("trun", version: 0, flags: 0x00_0701) { w in
                        w.u32(UInt32(audioSamples.count))
                        audioOffsetField = w.count
                        w.i32(0)
                        for (index, sample) in audioSamples.enumerated() {
                            w.u32(UInt32(audioDurations[index]))
                            w.u32(UInt32(sample.frame.data.count))
                            w.u32(Self.audioSampleFlags)
                        }
                    }
                }
            }
        }
        let moofSize = writer.count - moofStart
        guard moofSize + 8 + mediaBytes <= Int(Int32.max) else { throw FMP4Error.fragmentTooLarge(moofSize + 8 + mediaBytes) }
        let videoDataOffset = moofSize + 8                                     // relative to the moof (default-base-is-moof)
        writer.patchU32(at: videoOffsetField, UInt32(videoDataOffset))
        if let audioOffsetField { writer.patchU32(at: audioOffsetField, UInt32(videoDataOffset + videoBytes)) }

        writer.u32(UInt32(8 + mediaBytes))
        writer.fourCC("mdat")
        for sample in samples {
            for nal in sample.units {
                writer.u32(UInt32(nal.count))
                writer.append(nal)
            }
        }
        for sample in audioSamples { writer.append(sample.frame.data) }

        state.sequenceNumber = sequence
        state.videoOrigin = origin
        state.audioOrigin = audioOrigin
        state.lastVideoDecodeTime = lastVideoTime
        state.lastVideoDuration = videoDurations.last
        if let lastAudio = audioSamples.last { state.lastAudioTime = lastAudio.time }
        statistics.videoSamples = samples.count
        statistics.audioSamples = audioSamples.count
        lastFragmentStatistics = statistics
        return writer.data
    }

    /// Whether frames of `format` fit the video track (same codec and parameter sets); `fragment` throws
    /// `.videoFormatChanged` for frames that do not.
    public func accepts(video format: VideoFormat) -> Bool {
        (try? checkVideoFormat(format)) != nil
    }

    /// Whether frames of `format` fit the audio track (false without one); `fragment` throws `.audioFormatChanged` for
    /// frames that do not.
    public func accepts(audio format: AudioFormat) -> Bool {
        guard let audio else { return false }
        return (try? checkAudioFormat(format, of: audio)) != nil
    }

    // MARK: - Helpers

    private func checkVideoFormat(_ format: VideoFormat) throws {
        guard format.codec == video.codec else { throw FMP4Error.videoFormatChanged }
        guard !format.parameterSets.isEmpty, format.parameterSets != configuration.video.parameterSets else { return }
        guard Set(Self.normalized(format.parameterSets)) == referenceParameterSets else { throw FMP4Error.videoFormatChanged }
    }

    /// Codec, rate and channels as configured; an AudioSpecificConfig, when the frame carries one, with the same object
    /// type, sampling frequency and channel configuration as the track's.
    private func checkAudioFormat(_ format: AudioFormat, of track: AudioTrack) throws {
        guard format.codec == .aac, format.sampleRate == track.sampleRate, format.channels == track.channels else {
            throw FMP4Error.audioFormatChanged
        }
        guard let asc = format.audioSpecificConfig, !asc.isEmpty, asc != track.audioSpecificConfig else { return }
        guard AudioSpecificConfig(asc) == track.config else { throw FMP4Error.audioFormatChanged }
    }

    /// The frame's NAL units that belong in its sample (see `h264ParameterSetTypes`); `removed` counts the others.
    /// An in-band parameter set that differs from the sample entry's throws `.videoFormatChanged`.
    private func sampleUnits(of frame: EncodedVideoFrame, removed: inout Int) throws -> [Data] {
        var kept: [Data]?                                                  // built only once a unit is removed
        for (index, unit) in frame.nalUnits.enumerated() {
            if try belongsInSample(unit) {
                kept?.append(unit)
            } else {
                removed += 1
                if kept == nil { kept = Array(frame.nalUnits[..<index]) }
            }
        }
        return kept ?? frame.nalUnits
    }

    private func belongsInSample(_ unit: Data) throws -> Bool {
        guard let header = unit.first else { return false }
        let type: UInt8
        let parameterSets: Set<UInt8>
        let removedTypes: Set<UInt8>
        switch video.codec {
        case .h264:
            (type, parameterSets, removedTypes) = (header & 0x1F, Self.h264ParameterSetTypes, Self.h264RemovedTypes)
        case .hevc:
            guard unit.count >= 2 else { return false }                    // shorter than the 2-byte NAL unit header
            (type, parameterSets, removedTypes) = ((header >> 1) & 0x3F, Self.hevcParameterSetTypes, Self.hevcRemovedTypes)
        }
        if parameterSets.contains(type) {
            guard referenceParameterSets.contains(Self.trimmed(unit)) else { throw FMP4Error.videoFormatChanged }
            return false
        }
        return !removedTypes.contains(type)
    }

    /// Parameter sets without trailing zero bytes (trailing_zero_8bits carry no information).
    private static func normalized(_ sets: [Data]) -> [Data] {
        sets.map(trimmed)
    }

    private static func trimmed(_ unit: Data) -> Data {
        var trimmed = unit
        while trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    private static func difference(_ lhs: Int64, _ rhs: Int64, _ what: String) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { throw FMP4Error.timestampOutOfRange(what) }
        return result
    }

    private static func checkDurations(_ durations: [Int64], _ track: String) throws {
        guard durations.allSatisfy({ (1...Int64(UInt32.max)).contains($0) }) else {
            throw FMP4Error.timestampOutOfRange("\(track) sample duration")
        }
    }

    /// 64-bit NTP timestamp (seconds since 1900 in the high word, era-relative; fraction in the low word).
    static func ntpTimestamp(_ date: Date) -> UInt64 {
        let unix = date.timeIntervalSince1970
        guard unix.isFinite, unix > -2_208_988_800, unix < 1e15 else { return 0 }
        let whole = unix.rounded(.down)
        let fraction = min((unix - whole) * 4_294_967_296, 4_294_967_295).rounded(.down)
        let seconds = UInt64(Int64(whole) + 2_208_988_800) & 0xFFFF_FFFF
        return seconds << 32 | UInt64(fraction)
    }
}
