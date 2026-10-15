import BridgeSupport
import FMP4
import Foundation
import MediaCore
import TestSupport
import Testing

/// A file as the recorder writes it: the init segment, then one stored fragment (`prft` + `moof` + `mdat`) after another.
struct ArchiveMediaFile {
    var initSegment: Data
    var fragments: [Data]
    var frameCount: Int

    /// The file as a player would see it: the init segment followed by the fragments, as they are.
    var bytes: Data { fragments.reduce(into: initSegment) { $0.append($1) } }
}

/// Streams and files for the ArchiveMedia tests (task T03). Structure tests use synthetic pictures (any platform, no tools); the decode tests use
/// pictures ffmpeg encoded, or the private Tapo capture when it is present.
enum ArchiveMediaFixtures {
    // MARK: Parameter sets

    /// The SPS and PPS of the repo capture `Tools/captures/tapo.h264`: H.264 Main, level 5.0, 2688 x 1520 (the codec string is avc1.4d0032).
    static let tapoSPS = hex("674d00328a8a5015005fd36400000fa00002710010")
    static let tapoPPS = hex("68ee3c80")
    /// A small H.264 High stream (libx264, 640 x 360) and a small HEVC Main stream (640 x 360): FMP4Tests' golden parameter sets.
    static let smallSPS = hex("6764001eacb201405ff2e022000003000200000300781e2c5c90")
    static let smallPPS = hex("68ebc3cb22c0")
    static let hevcVPS = hex("40010c01ffff016000000300b0000003000003003f1b0240")
    static let hevcSPS = hex("420101016000000300b0000003000003003fa005020171f2e206ee45914bff2e7f13fac05a8101010040")
    static let hevcPPS = hex("4401c072f05324")

    static func hex(_ text: String) -> Data { Data(hex: text) ?? Data() }

    static var tapoFormat: VideoFormat { VideoFormat.h264(sps: tapoSPS, pps: tapoPPS)! }
    static var smallH264Format: VideoFormat { VideoFormat.h264(sps: smallSPS, pps: smallPPS)! }
    static var hevcFormat: VideoFormat { VideoFormat.hevc(vps: hevcVPS, sps: hevcSPS, pps: hevcPPS)! }
    static let aac = AudioFormat.aacLC(sampleRate: 48_000, channels: 1)

    // MARK: Synthetic pictures

    /// `count` pictures of `format` at `ticks` (90 kHz) apart in decode order, a keyframe at 0 and then every `keyEvery`. The NAL units start with the
    /// header byte of their type and have recognisable bodies; the muxer looks at nothing else. `compositionOffset` gives `pts - dts` of picture `i`;
    /// `keySize` and `deltaSize` are the approximate sizes in bytes of a keyframe and of the other pictures.
    static func syntheticFrames(_ format: VideoFormat, count: Int, keyEvery: Int, ticks: Int64 = 3_600, keySize: Int = 300, deltaSize: Int = 40,
                                compositionOffset: (Int) -> Int64 = { _ in 0 }) -> [EncodedVideoFrame] {
        (0..<count).map { index in
            let key = index % keyEvery == 0
            let header: [UInt8] = switch format.codec {
            case .h264: [key ? 0x65 : 0x41]
            case .hevc: key ? [0x26, 0x01] : [0x02, 0x01]
            }
            let size = key ? keySize + index % 11 : deltaSize + index % 13
            let body = size > 4_096 ? Data(repeating: UInt8(truncatingIfNeeded: index), count: size) : Data((0..<size).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0 &* 7) })
            let nalUnits = [Data(header) + body.prefix(12), Data(header) + body.dropFirst(12)]
            let dts = Int64(index) * ticks
            return EncodedVideoFrame(format: format, nalUnits: nalUnits, isKeyframe: key,
                                     pts: MediaTime(value: dts + compositionOffset(index), timescale: 90_000),
                                     dts: compositionOffset(index) == 0 ? nil : MediaTime(value: dts, timescale: 90_000),
                                     wallClock: Date(timeIntervalSince1970: 1_800_000_000 + Double(dts) / 90_000))
        }
    }

    /// AAC-LC access units of 1024 samples covering `seconds`, from time 0.
    static func syntheticAudio(seconds: Double, format: AudioFormat = aac) -> [EncodedAudioFrame] {
        (0..<Int(seconds * Double(format.sampleRate) / 1024)).map { index in
            EncodedAudioFrame(format: format, data: Data((0..<20).map { UInt8(truncatingIfNeeded: 0xA0 &+ index &+ $0) }),
                              pts: MediaTime(value: Int64(index) * 1024, timescale: Int32(format.sampleRate)), sampleCount: 1024,
                              wallClock: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 1024 / Double(format.sampleRate)))
        }
    }

    // MARK: Files

    /// What the recorder writes (Mac spec 4.2): a fragment at every keyframe and after `cutEvery` pictures without one (the next piece of a long group
    /// of pictures is a continuation fragment), `prft` before every `moof`, each fragment's last picture lasting until the next fragment's first.
    /// `audio` is distributed by time; a muxer without `audioFormat` is video only.
    static func mux(_ frames: [EncodedVideoFrame], audio: [EncodedAudioFrame] = [], audioFormat: AudioFormat? = nil, cutEvery: Int = 62) throws -> ArchiveMediaFile {
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: frames[0].format, audio: audioFormat, writeProducerReferenceTime: true))
        var starts: [Int] = []
        var sinceStart = 0
        for (index, frame) in frames.enumerated() {
            if index == 0 || frame.isKeyframe || sinceStart >= cutEvery {
                starts.append(index)
                sinceStart = 0
            }
            sinceStart += 1
        }
        func seconds(_ frame: EncodedVideoFrame) -> Double { Double((frame.dts ?? frame.pts).converted(to: 90_000).value) / 90_000 }
        var fragments: [Data] = []
        for (position, start) in starts.enumerated() {
            let next = position + 1 < starts.count ? starts[position + 1] : nil
            let slice = Array(frames[start..<(next ?? frames.count)])
            let from = position == 0 ? -1 : seconds(frames[start])
            let until = next.map { seconds(frames[$0]) } ?? .infinity
            let sound = audioFormat == nil ? [] : audio.filter { Double($0.pts.value) / Double($0.pts.timescale) >= from && Double($0.pts.value) / Double($0.pts.timescale) < until }
            fragments.append(try muxer.fragment(video: slice, audio: sound, nextDecodeTime: next.map { frames[$0].dts ?? frames[$0].pts },
                                                continuation: !slice[0].isKeyframe))
        }
        return ArchiveMediaFile(initSegment: muxer.initializationSegment(), fragments: fragments, frameCount: frames.count)
    }
}

/// Byte-level helpers for the ArchiveMedia tests: find boxes in a file and change single fields.
enum ArchiveMediaBytes {
    /// Every box of `data`, depth first, with its slash-separated path (`moof/traf/trun`).
    static func boxes(in data: Data) throws -> [(path: String, box: MP4Box)] {
        func walk(_ boxes: [MP4Box], prefix: String) -> [(String, MP4Box)] {
            boxes.flatMap { [(prefix + $0.type, $0)] + walk($0.children, prefix: prefix + $0.type + "/") }
        }
        return walk(try MP4BoxReader.parse(data), prefix: "")
    }

    static func boxes(in data: Data, at path: String) throws -> [MP4Box] {
        try boxes(in: data).filter { $0.path == path }.map(\.box)
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32BE(UInt32(8 + payload.count))
        writer.write(Data(type.utf8))
        writer.write(payload)
        return writer.data
    }

    static func patching(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
        var copy = data
        copy.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        return copy
    }

    static func u32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[data.startIndex + offset + $1]) }
    }

    /// The trun of the traf with `trackID` (1 video, 2 sound) in a fragment.
    static func trun(in fragment: Data, track trackID: UInt32) throws -> MP4Box {
        let trafs = try boxes(in: fragment, at: "moof/traf")
        let traf = try #require(trafs.first { traf in
            traf.children.first { $0.type == "tfhd" }.map { readU32(fragment, at: $0.payloadOffset + 4) == trackID } ?? false
        })
        return try #require(traf.children.first { $0.type == "trun" })
    }

    /// `trun` fields by byte position in the payload: version 0, flags 1...3, sample_count 4, data_offset 8.
    static func settingTrunFlags(_ fragment: Data, track: UInt32, flags: UInt32, version: UInt8 = 0) throws -> Data {
        patching(fragment, at: try trun(in: fragment, track: track).payloadOffset, [version] + Array(u32(flags).dropFirst()))
    }

    static func settingTrunField(_ fragment: Data, track: UInt32, at position: Int, to value: UInt32) throws -> Data {
        patching(fragment, at: try trun(in: fragment, track: track).payloadOffset + position, u32(value))
    }

    /// What a correct `videoSegment` result must satisfy whatever the input was: a `moof` and an `mdat`, one video traf, the data offset at the first
    /// video byte and the sample sizes adding up to the `mdat`.
    static func isConsistentSegment(_ segment: Data) -> Bool {
        guard let boxes = try? MP4BoxReader.parse(segment), boxes.map(\.type) == ["moof", "mdat"], boxes[0].children.map(\.type) == ["mfhd", "traf"],
              let trun = boxes[0].children[1].children.last, trun.type == "trun" else { return false }
        guard trun.payloadSize >= 12 else { return false }
        let count = Int(readU32(segment, at: trun.payloadOffset + 4))
        let entry = readU32(segment, at: trun.payloadOffset) & 0x00FF_FFFF == 0xF01 ? 16 : 12
        guard count <= trun.payloadSize / entry, trun.payloadSize == 12 + count * entry,
              Int(Int32(bitPattern: readU32(segment, at: trun.payloadOffset + 8))) == boxes[0].size + 8 else { return false }
        let total = (0..<count).reduce(0) { $0 + Int(readU32(segment, at: trun.payloadOffset + 12 + $1 * entry + 4)) }
        return total == boxes[1].payloadSize && boxes[1].offset == boxes[0].size
    }
}
