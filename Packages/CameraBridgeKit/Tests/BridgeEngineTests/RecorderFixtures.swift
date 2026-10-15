import CameraAdapters
import FMP4
import Foundation
import MediaCore
@testable import BridgeEngine

/// Synthetic frames on a clock the tests control. Frame `n` of a stream at `fps` decodes at `n / fps` and was captured at `base + n / fps`.
enum RecorderFixtures {
    /// 2001-09-09: further than a day from any date a test runs on, so `MediaHub.wallClockOffset` ignores the frames' wall clock (it is a lag
    /// against the real clock) and an anchor is always `wallClock` itself.
    static let base = Date(timeIntervalSince1970: 1_000_000_000)
    static let sps = Data(hex: "6764001eacb201405ff2e022000003000200000300781e2c5c90")!
    static let pps = Data(hex: "68ebc3cb22c0")!
    static let h264: VideoFormat = VideoFormat.h264(sps: sps, pps: pps)!
    static let otherH264: VideoFormat = {
        // The same stream with a different PPS: a parameter-set change the muxer cannot describe in the same init segment.
        VideoFormat.h264(sps: sps, pps: Data(hex: "68ebc3cb22c1")!)!
    }()
    static let aac32k = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)

    /// A frame with payload bytes that identify it (frame number and position), a big keyframe and small delta frames.
    static func video(_ number: Int, fps: Int = 30, gop: Int = 60, format: VideoFormat = h264, reordered: Bool = false, keyframe: Bool? = nil,
                      wallSkew: Double = 0, size: Int? = nil) -> EncodedVideoFrame {
        let isKey = keyframe ?? (number % gop == 0)
        let decode = Int64(number) * 90_000 / Int64(fps)
        let payload = size ?? (isKey ? 3_000 : 300)
        let header: UInt8 = isKey ? 0x65 : 0x41
        var nal = payload <= 4_096 ? Data([header] + (1..<payload).map { UInt8(truncatingIfNeeded: number &* 31 &+ $0) })
            : Data(repeating: UInt8(truncatingIfNeeded: number), count: payload)           // big pictures: fast to build, still told apart by their first bytes
        nal[0] = header
        let delay: Int64 = reordered ? 2 * 90_000 / Int64(fps) : 0
        return EncodedVideoFrame(format: format, nalUnits: [nal], isKeyframe: isKey, pts: MediaTime(value: decode + delay, timescale: 90_000),
                                 dts: reordered ? MediaTime(value: decode, timescale: 90_000) : nil,
                                 wallClock: base.addingTimeInterval(Double(number) / Double(fps) * (1 + wallSkew)))
    }

    static func videoFrames(_ range: Range<Int>, fps: Int = 30, gop: Int = 60, format: VideoFormat = h264, reordered: Bool = false, wallSkew: Double = 0) -> [EncodedVideoFrame] {
        range.map { video($0, fps: fps, gop: gop, format: format, reordered: reordered, wallSkew: wallSkew) }
    }

    static func audio(_ number: Int, format: AudioFormat = aac32k) -> EncodedAudioFrame {
        EncodedAudioFrame(format: format, data: Data((0..<24).map { UInt8(truncatingIfNeeded: number &* 7 &+ $0) }),
                          pts: MediaTime(value: Int64(number) * 1_024, timescale: Int32(format.sampleRate)), sampleCount: 1_024,
                          wallClock: base.addingTimeInterval(Double(number) * 1_024 / Double(format.sampleRate)))
    }

    /// Camera audio for the first `seconds` of a stream.
    static func audioFrames(seconds: Double, format: AudioFormat = aac32k) -> [EncodedAudioFrame] {
        (0..<Int(seconds * Double(format.sampleRate) / 1_024)).map { audio($0, format: format) }
    }

    static func camera(name: String = "Driveway", recordSound: Bool = false, audioEnabled: Bool = true) -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.10"), username: "admin")
        camera.nvrEnabled = true
        camera.nvrRecordSound = recordSound
        camera.audioEnabled = audioEnabled
        return camera
    }
}

extension RecorderFixtures {
    /// Video and audio in the order a camera would deliver them: by capture time, video first when equal.
    static func interleaved(_ video: [EncodedVideoFrame], _ audio: [EncodedAudioFrame]) -> [MediaSample] {
        let entries = video.map { (time: Double($0.pts.value) / 90_000, sample: MediaSample.video($0)) }
            + audio.map { (time: $0.pts.seconds, sample: MediaSample.audio($0)) }
        return entries.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element.sample)
    }

    /// A muxer with a key fragment of 10 frames, a continuation of 5 and a second key fragment, each with a `prft`.
    static func fragments(audio: Bool = false) throws -> [Data] {
        let format = h264
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: audio ? aac32k : nil, writeProducerReferenceTime: true))
        let frames = videoFrames(0..<30, gop: 15)
        let sound = audio ? audioFrames(seconds: 1) : []
        func next(_ index: Int) -> MediaTime { MediaTime(value: Int64(index) * 3_000, timescale: 90_000) }
        return [
            try muxer.fragment(video: Array(frames[0..<10]), audio: audio ? Array(sound.prefix(10)) : [], nextDecodeTime: next(10), continuation: false),
            try muxer.fragment(video: Array(frames[10..<15]), audio: [], nextDecodeTime: next(15), continuation: true),
            try muxer.fragment(video: Array(frames[15..<30]), audio: [], nextDecodeTime: nil, continuation: false),
        ]
    }
}
