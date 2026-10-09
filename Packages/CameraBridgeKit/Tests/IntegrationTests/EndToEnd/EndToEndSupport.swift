#if os(macOS)
#if canImport(AVFoundation)
import AVFoundation
#endif
import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import MediaCore
import PlatformApple
import RTP
import Synchronization
import Testing
import TestSupport
@testable import BridgeEngine

// Fixtures for the end-to-end scenarios of plan task W3-2: a real `BridgeEngine` on `BridgeEnvironment.testing`
// (loopback only, in-memory secrets, never a real Bonjour advertiser), driven from outside by TestSupport's HAP
// controller, SRTP receiver and HDS client, with independent checks (setup payload, ISO BMFF box walk, AVFoundation,
// and the opt-in Node / ffmpeg oracles).

/// Parent of every end-to-end suite. They run one at a time: each runs an engine with VideoToolbox encoders in real
/// time, and side by side the frame-rate checks would measure the machine instead of the bridge.
@Suite(.serialized) struct EndToEndTests {}

// MARK: - Concurrency helpers


// MARK: - The engine under test

/// An engine on `BridgeEnvironment.testing` in a fresh data directory. HAP ports start at a random base in
/// 22000–28000 (away from Scrypted, Homebridge and the ephemeral range); the sensors bridge and the webhook take
/// ephemeral ports. `advertiser` replaces the null advertiser with one that only records (never Bonjour).
@MainActor
final class EndToEndEngine {
    let directory: URL
    let environment: BridgeEnvironment
    let engine: BridgeEngine
    let advertiser: RecordingAdvertiser?

    init(tuning: EngineTuning = .standard, advertiser: RecordingAdvertiser? = nil,
         configure: (inout BridgeSettings) -> Void = { _ in }) async throws {
        directory = try TestSupportModule.makeTemporaryDirectory(prefix: "cb-e2e")
        var environment = BridgeEnvironment.testing(directory: directory)
        if let advertiser {
            environment.platform.advertiser = advertiser
            environment.advertise = true
        }
        self.environment = environment
        self.advertiser = advertiser
        engine = BridgeEngine(environment: environment, tuning: tuning)
        var settings = engine.settings
        settings.basePort = UInt16.random(in: 22_000...28_000)
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        configure(&settings)
        try await engine.updateSettings(settings)
    }

    static func demoCamera(name: String, kind: CameraKind = .camera) -> CameraConfiguration {
        CameraConfiguration(name: name, kind: kind, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
    }

    func status(_ id: UUID) -> CameraStatus? { engine.cameras.first { $0.id == id } }

    /// Waits until the camera is online with its HAP server listening and a setup code; returns that status.
    func waitUntilServing(_ id: UUID, timeout: Duration = .seconds(20)) async throws -> CameraStatus {
        let ready = await eventually(timeout: timeout) {
            guard let status = status(id) else { return false }
            return status.connection == .online && status.hapPort != nil && status.setupCode.count == 10
        }
        let status = try #require(status(id), "camera \(id) has no status")
        try #require(ready, "camera not serving: \(status.connection), port \(String(describing: status.hapPort)), \(status.lastError ?? "no error")")
        return status
    }

    /// Pairs a fresh controller with the camera's accessory (pair-setup + pair-verify on loopback).
    func pair(_ id: UUID) async throws -> HAPTestController {
        let status = try await waitUntilServing(id)
        return try await HAPTestController.paired(port: try #require(status.hapPort), setupCode: status.setupCode)
    }

    func tearDown() async {
        await engine.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

extension EngineTuning {
    /// Small demo streams for scenarios that do not look at the picture.
    static var smallDemo: EngineTuning {
        var tuning = EngineTuning.standard
        tuning.demoMain = DemoStream(width: 640, height: 360, fps: 15, keyframeInterval: .seconds(1))
        tuning.demoSub = DemoStream(width: 320, height: 180, fps: 10, keyframeInterval: .seconds(1))
        return tuning
    }
}

// MARK: - Recording advertiser (never Bonjour)

/// A `ServiceAdvertiser` that only records what the HAP servers would announce (registration and every TXT update).
final class RecordingAdvertiser: ServiceAdvertiser {
    struct Record: Sendable, Equatable {
        var name: String
        var type: String
        var port: UInt16
        var txt: [String: String]
    }

    /// Every registration and TXT update, in order.
    let history = Box<[Record]>([])

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        let record = Record(name: advertisement.name, type: advertisement.type, port: advertisement.port, txt: advertisement.txt)
        history.update { $0.append(record) }
        return RecordedService(record: record, history: history)
    }

    /// The TXT records announced for the service on `port`, oldest first.
    func txtHistory(port: UInt16) -> [[String: String]] {
        history.value.filter { $0.port == port }.map(\.txt)
    }

    /// The `sf` (status flags: 1 = unpaired) values announced for `port`, consecutive duplicates collapsed.
    func statusFlags(port: UInt16) -> [String] {
        txtHistory(port: port).compactMap { $0["sf"] }.reduce(into: []) { result, flag in
            if result.last != flag { result.append(flag) }
        }
    }
}

private final class RecordedService: AdvertisedService {
    private let record: RecordingAdvertiser.Record
    private let history: Box<[RecordingAdvertiser.Record]>
    private let failureStream = AsyncStream<TransportError>.makeStream()

    init(record: RecordingAdvertiser.Record, history: Box<[RecordingAdvertiser.Record]>) {
        self.record = record
        self.history = history
    }

    var failures: AsyncStream<TransportError> { failureStream.stream }

    func updateTXT(_ txt: [String: String]) async throws {
        var updated = record
        updated.txt = txt
        history.update { $0.append(updated) }
    }

    func cancel() { failureStream.continuation.finish() }

    deinit { failureStream.continuation.finish() }
}

// MARK: - Setup payload (independent decoder)

/// The 9-character base-36 payload of an `X-HM://` setup URI, decoded the way HAP-NodeJS `Accessory.setupURI` encodes
/// it: low 32 bits = setup code | flags << 27 | (category & 1) << 31, high bits = category >> 1.
struct SetupURIPayload: Equatable {
    var category: Int
    var setupCode: String
    var flags: Int
    var setupID: String

    init(_ uri: String) throws {
        let prefix = "X-HM://"
        try #require(uri.hasPrefix(prefix) && uri.count == prefix.count + 13, "not a setup URI: \(uri)")
        let body = uri.dropFirst(prefix.count)
        var value: UInt64 = 0
        for character in body.prefix(9) {
            let digit = try #require(character.isASCII ? Int(String(character), radix: 36) : nil, "bad base-36 digit in \(uri)")
            value = value * 36 + UInt64(digit)
        }
        category = Int(value >> 31)
        flags = Int((value >> 27) & 0xF)
        let code = value & 0x7FF_FFFF
        let digits = String(code)
        setupCode = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        setupID = String(body.suffix(4))
    }

    /// IP transport flag (HAP-NodeJS: `1 << 28`).
    var supportsIP: Bool { flags & 0x2 != 0 }
}

// MARK: - ISO BMFF (independent box walk, ISO/IEC 14496-12)

struct ISOBox: Sendable {
    var type: String
    var offset: Int
    var size: Int
    var headerSize: Int
    var children: [ISOBox]

    var payload: Range<Int> { (offset + headerSize)..<(offset + size) }

    func child(_ type: String) -> ISOBox? { children.first { $0.type == type } }
    func children(_ type: String) -> [ISOBox] { children.filter { $0.type == type } }

    /// The first box along `path` ("mdia/minf/stbl") below this one.
    func find(_ path: String) -> ISOBox? {
        var box: ISOBox? = self
        for component in path.split(separator: "/") { box = box?.child(String(component)) }
        return box
    }
}

enum ISOBoxError: Error, CustomStringConvertible {
    case truncated(String)
    case malformed(String)

    var description: String {
        switch self {
        case .truncated(let what): "truncated: \(what)"
        case .malformed(let what): "malformed: \(what)"
        }
    }
}

/// Big-endian reads with bounds checks.
struct BytesReader {
    let bytes: [UInt8]

    func u8(_ at: Int) throws -> UInt8 {
        guard at >= 0, at < bytes.count else { throw ISOBoxError.truncated("byte \(at) of \(bytes.count)") }
        return bytes[at]
    }

    func u16(_ at: Int) throws -> UInt16 { UInt16(try u8(at)) << 8 | UInt16(try u8(at + 1)) }

    func u32(_ at: Int) throws -> UInt32 { UInt32(try u16(at)) << 16 | UInt32(try u16(at + 2)) }

    func u64(_ at: Int) throws -> UInt64 { UInt64(try u32(at)) << 32 | UInt64(try u32(at + 4)) }

    func fourCC(_ at: Int) throws -> String {
        String(decoding: try (0..<4).map { try u8(at + $0) }, as: UTF8.self)
    }
}

enum ISOBoxWalk {
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf", "dinf", "edts", "udta"]

    static func boxes(_ bytes: [UInt8], in range: Range<Int>? = nil) throws -> [ISOBox] {
        let reader = BytesReader(bytes: bytes)
        let range = range ?? 0..<bytes.count
        var boxes: [ISOBox] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else { throw ISOBoxError.truncated("box header at \(offset)") }
            var size = Int(try reader.u32(offset))
            let type = try reader.fourCC(offset + 4)
            var header = 8
            if size == 1 {
                size = Int(try reader.u64(offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { throw ISOBoxError.malformed("\(type) of \(size) bytes at \(offset)") }
            var box = ISOBox(type: type, offset: offset, size: size, headerSize: header, children: [])
            if containers.contains(type) { box.children = try Self.boxes(bytes, in: box.payload) }
            boxes.append(box)
            offset += size
        }
        return boxes
    }
}

/// What an HKSV initialization segment (ftyp + moov) declares.
struct InitSegmentInfo {
    struct Track {
        var id: UInt32
        var handler: String
        var timescale: UInt32
        var sampleEntry: String
        var width = 0
        var height = 0
        var avcProfile: UInt8?
        var avcLevel: UInt8?
        var nalLengthSize = 4
        var sampleRate: Int?
        var channels: Int?
    }

    var topLevel: [String]
    var majorBrand: String
    var tracks: [Track]
    var hasMovieExtends: Bool

    var video: Track? { tracks.first { $0.handler == "vide" } }
    var audio: Track? { tracks.first { $0.handler == "soun" } }

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        let reader = BytesReader(bytes: bytes)
        let boxes = try ISOBoxWalk.boxes(bytes)
        topLevel = boxes.map(\.type)
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }), let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw ISOBoxError.malformed("no ftyp/moov: \(topLevel)")
        }
        majorBrand = try reader.fourCC(ftyp.payload.lowerBound)
        hasMovieExtends = moov.child("mvex")?.child("trex") != nil
        tracks = try moov.children("trak").map { trak in
            guard let tkhd = trak.child("tkhd"), let mdhd = trak.find("mdia/mdhd"), let hdlr = trak.find("mdia/hdlr"),
                  let stsd = trak.find("mdia/minf/stbl/stsd") else {
                throw ISOBoxError.malformed("trak without tkhd/mdhd/hdlr/stsd")
            }
            let tkhdVersion = try reader.u8(tkhd.payload.lowerBound)
            let trackID = try reader.u32(tkhd.payload.lowerBound + (tkhdVersion == 1 ? 20 : 12))
            let mdhdVersion = try reader.u8(mdhd.payload.lowerBound)
            let timescale = try reader.u32(mdhd.payload.lowerBound + (mdhdVersion == 1 ? 20 : 12))
            let handler = try reader.fourCC(hdlr.payload.lowerBound + 8)
            // stsd: full box header, entry count, then sample entries (boxes).
            let entryStart = stsd.payload.lowerBound + 8
            guard entryStart + 8 <= stsd.payload.upperBound else { throw ISOBoxError.truncated("stsd") }
            let entrySize = Int(try reader.u32(entryStart))
            let entryType = try reader.fourCC(entryStart + 4)
            var track = Track(id: trackID, handler: handler, timescale: timescale, sampleEntry: entryType)
            if entryType == "avc1" || entryType == "avc3" {
                track.width = Int(try reader.u16(entryStart + 8 + 24))
                track.height = Int(try reader.u16(entryStart + 8 + 26))
                let inner = try ISOBoxWalk.boxes(bytes, in: (entryStart + 8 + 78)..<(entryStart + entrySize))
                if let avcC = inner.first(where: { $0.type == "avcC" }) {
                    track.avcProfile = try reader.u8(avcC.payload.lowerBound + 1)
                    track.avcLevel = try reader.u8(avcC.payload.lowerBound + 3)
                    track.nalLengthSize = Int(try reader.u8(avcC.payload.lowerBound + 4) & 0x03) + 1
                }
            } else if entryType == "mp4a" {
                track.channels = Int(try reader.u16(entryStart + 8 + 16))
                track.sampleRate = Int(try reader.u32(entryStart + 8 + 24) >> 16)
            }
            return track
        }
    }
}

/// One `moof` + `mdat` fragment: per-track runs with their samples (tfhd defaults applied).
struct FragmentInfo {
    struct Run {
        var trackID: UInt32
        var baseDecodeTime: UInt64
        var defaultBaseIsMoof: Bool
        var durations: [UInt32]
        var sizes: [UInt32]
        var flags: [UInt32]
        /// Absolute offset of the first sample's data in the fragment.
        var dataOffset: Int

        var totalDuration: UInt64 { durations.reduce(0) { $0 + UInt64($1) } }
        var sampleCount: Int { sizes.count }
    }

    var topLevel: [String]
    var sequenceNumber: UInt32
    var runs: [Run]
    let bytes: [UInt8]

    func run(track: UInt32) -> Run? { runs.first { $0.trackID == track } }

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        let reader = BytesReader(bytes: bytes)
        let boxes = try ISOBoxWalk.boxes(bytes)
        topLevel = boxes.map(\.type)
        guard let moof = boxes.first(where: { $0.type == "moof" }), boxes.contains(where: { $0.type == "mdat" }) else {
            throw ISOBoxError.malformed("no moof/mdat: \(topLevel)")
        }
        guard let mfhd = moof.child("mfhd") else { throw ISOBoxError.malformed("moof without mfhd") }
        sequenceNumber = try reader.u32(mfhd.payload.lowerBound + 4)
        runs = try moof.children("traf").map { traf in
            guard let tfhd = traf.child("tfhd"), let tfdt = traf.child("tfdt"), let trun = traf.child("trun") else {
                throw ISOBoxError.malformed("traf without tfhd/tfdt/trun")
            }
            guard traf.children("trun").count == 1 else { throw ISOBoxError.malformed("more than one trun in a traf") }
            var cursor = tfhd.payload.lowerBound
            let tfhdFlags = try reader.u32(cursor) & 0xFF_FFFF
            let trackID = try reader.u32(cursor + 4)
            cursor += 8
            if tfhdFlags & 0x01 != 0 { cursor += 8 }   // base_data_offset
            if tfhdFlags & 0x02 != 0 { cursor += 4 }   // sample_description_index
            var defaultDuration: UInt32?, defaultSize: UInt32?, defaultFlags: UInt32?
            if tfhdFlags & 0x08 != 0 { defaultDuration = try reader.u32(cursor); cursor += 4 }
            if tfhdFlags & 0x10 != 0 { defaultSize = try reader.u32(cursor); cursor += 4 }
            if tfhdFlags & 0x20 != 0 { defaultFlags = try reader.u32(cursor) }
            let tfdtVersion = try reader.u8(tfdt.payload.lowerBound)
            let base = tfdtVersion == 1 ? try reader.u64(tfdt.payload.lowerBound + 4) : UInt64(try reader.u32(tfdt.payload.lowerBound + 4))

            cursor = trun.payload.lowerBound
            let trunFlags = try reader.u32(cursor) & 0xFF_FFFF
            let count = Int(try reader.u32(cursor + 4))
            cursor += 8
            var dataOffset = 0
            if trunFlags & 0x01 != 0 { dataOffset = Int(Int32(bitPattern: try reader.u32(cursor))); cursor += 4 }
            var firstFlags: UInt32?
            if trunFlags & 0x04 != 0 { firstFlags = try reader.u32(cursor); cursor += 4 }
            var durations: [UInt32] = [], sizes: [UInt32] = [], flags: [UInt32] = []
            for index in 0..<count {
                var duration = defaultDuration, size = defaultSize, sampleFlags = index == 0 ? (firstFlags ?? defaultFlags) : defaultFlags
                if trunFlags & 0x100 != 0 { duration = try reader.u32(cursor); cursor += 4 }
                if trunFlags & 0x200 != 0 { size = try reader.u32(cursor); cursor += 4 }
                if trunFlags & 0x400 != 0 { sampleFlags = try reader.u32(cursor); cursor += 4 }
                if trunFlags & 0x800 != 0 { cursor += 4 }
                guard let duration, let size else { throw ISOBoxError.malformed("sample \(index) of track \(trackID) without duration or size") }
                durations.append(duration)
                sizes.append(size)
                flags.append(sampleFlags ?? 0)
            }
            return Run(trackID: trackID, baseDecodeTime: base, defaultBaseIsMoof: tfhdFlags & 0x02_0000 != 0, durations: durations, sizes: sizes,
                       flags: flags, dataOffset: moof.offset + dataOffset)
        }
    }

    /// The NAL unit types (H.264 `nal_unit_type`) of `track`'s sample `index` (length-prefixed NAL units).
    func nalTypes(track: UInt32, sample index: Int, nalLengthSize: Int) throws -> [UInt8] {
        guard let run = run(track: track), index < run.sampleCount else { throw ISOBoxError.malformed("no sample \(index) in track \(track)") }
        let start = run.dataOffset + run.sizes.prefix(index).reduce(0) { $0 + Int($1) }
        let end = start + Int(run.sizes[index])
        guard start >= 0, end <= bytes.count else { throw ISOBoxError.truncated("sample data \(start)..<\(end) of \(bytes.count)") }
        let reader = BytesReader(bytes: bytes)
        var types: [UInt8] = []
        var cursor = start
        while cursor < end {
            var length = 0
            for byte in 0..<nalLengthSize { length = length << 8 | Int(try reader.u8(cursor + byte)) }
            cursor += nalLengthSize
            guard length > 0, cursor + length <= end else { throw ISOBoxError.malformed("NAL unit length \(length) at \(cursor)") }
            types.append(try reader.u8(cursor) & 0x1F)
            cursor += length
        }
        return types
    }
}

/// Checks every HKSV recording rule a hub depends on (research brief §3.9, integration brief §5.6) and returns the parsed
/// segments: init first (ftyp + moov with mvex), one video track (+ AAC-LC audio iff `audio`), fragments as single
/// moof + mdat with consecutive sequence numbers, default-base-is-moof, the video run starting with an IDR sample
/// (sync flags) whose NAL units include an IDR slice, sync flags on exactly the IDR samples, at most
/// `maximumFragmentSeconds` each, decode times that continue exactly from fragment to fragment (video from 0), and
/// audio samples in every fragment, contiguous and starting within 0.2 s of the fragment's video.
@discardableResult
func checkRecording(_ capture: RecordingCapture, audio: Bool, maximumFragmentSeconds: Double = 4.2,
                    sourceLocation: SourceLocation = #_sourceLocation) throws -> (initialization: InitSegmentInfo, fragments: [FragmentInfo]) {
    let initialization = try InitSegmentInfo(try #require(capture.initialization, "no mediaInitialization packet", sourceLocation: sourceLocation))
    #expect(initialization.topLevel == ["ftyp", "moov"], sourceLocation: sourceLocation)
    #expect(initialization.hasMovieExtends, "moov without mvex/trex", sourceLocation: sourceLocation)
    let video = try #require(initialization.video, "no video track", sourceLocation: sourceLocation)
    #expect(video.sampleEntry == "avc1" && video.timescale == 90_000, "video \(video.sampleEntry) at \(video.timescale)", sourceLocation: sourceLocation)
    if audio {
        let track = try #require(initialization.audio, "RecordingAudioActive but no audio track", sourceLocation: sourceLocation)
        #expect(track.sampleEntry == "mp4a" && track.sampleRate == 32_000 && track.channels == 1,
                "audio \(track.sampleEntry) \(String(describing: track.sampleRate)) Hz × \(String(describing: track.channels))", sourceLocation: sourceLocation)
        #expect(initialization.tracks.count == 2, sourceLocation: sourceLocation)
    } else {
        #expect(initialization.audio == nil && initialization.tracks.count == 1, "RecordingAudioActive off but tracks \(initialization.tracks.map(\.handler))",
                sourceLocation: sourceLocation)
    }
    var fragments: [FragmentInfo] = []
    var nextDecodeTime: UInt64 = 0
    var nextAudioDecodeTime: UInt64?
    for (index, data) in capture.fragments.enumerated() {
        let fragment = try FragmentInfo(data)
        fragments.append(fragment)
        #expect(fragment.topLevel.filter { $0 != "prft" } == ["moof", "mdat"], "fragment \(index): \(fragment.topLevel)", sourceLocation: sourceLocation)
        #expect(fragment.sequenceNumber == UInt32(index + 1), "fragment \(index) has sequence \(fragment.sequenceNumber)", sourceLocation: sourceLocation)
        let run = try #require(fragment.run(track: video.id), "fragment \(index) has no video", sourceLocation: sourceLocation)
        #expect(run.defaultBaseIsMoof, "fragment \(index): tfhd without default-base-is-moof", sourceLocation: sourceLocation)
        #expect(run.flags.first == 0x0200_0000, "fragment \(index) starts with sample flags \(String(describing: run.flags.first))", sourceLocation: sourceLocation)
        #expect(try fragment.nalTypes(track: video.id, sample: 0, nalLengthSize: video.nalLengthSize).contains(5),
                "fragment \(index) does not start with an IDR", sourceLocation: sourceLocation)
        // Sync samples (0x02000000) are exactly the IDR samples; every other sample is flagged non-sync.
        for (sample, flags) in run.flags.enumerated() {
            let isIDR = try fragment.nalTypes(track: video.id, sample: sample, nalLengthSize: video.nalLengthSize).contains(5)
            #expect(isIDR ? flags == 0x0200_0000 : flags & 0x0001_0000 != 0, "fragment \(index) sample \(sample): flags \(flags), IDR \(isIDR)",
                    sourceLocation: sourceLocation)
        }
        let seconds = Double(run.totalDuration) / Double(video.timescale)
        #expect(seconds > 0 && seconds <= maximumFragmentSeconds, "fragment \(index) lasts \(seconds) s", sourceLocation: sourceLocation)
        #expect(run.baseDecodeTime == nextDecodeTime, "fragment \(index) starts at \(run.baseDecodeTime), expected \(nextDecodeTime)",
                sourceLocation: sourceLocation)
        nextDecodeTime = run.baseDecodeTime + run.totalDuration
        if audio, let track = initialization.audio {
            let audioRun = fragment.run(track: track.id)
            #expect((audioRun?.sampleCount ?? 0) > 0, "fragment \(index) has no audio samples", sourceLocation: sourceLocation)
            if let audioRun {
                // Audio continues without gaps or overlaps and stays with the picture.
                if let expected = nextAudioDecodeTime {
                    #expect(audioRun.baseDecodeTime == expected, "fragment \(index) audio starts at \(audioRun.baseDecodeTime), expected \(expected)",
                            sourceLocation: sourceLocation)
                }
                nextAudioDecodeTime = audioRun.baseDecodeTime + audioRun.totalDuration
                let drift = Double(audioRun.baseDecodeTime) / Double(track.timescale) - Double(run.baseDecodeTime) / Double(video.timescale)
                #expect(abs(drift) < 0.2, "fragment \(index): audio starts \(drift) s from the video", sourceLocation: sourceLocation)
            }
        } else {
            #expect(fragment.runs.count == 1, "fragment \(index) has \(fragment.runs.count) tracks", sourceLocation: sourceLocation)
        }
    }
    return (initialization, fragments)
}

// MARK: - Keyframe oracle (ffprobe packet flags)

/// Where an independent demuxer must report keyframes in a recording's video, one entry per sample in decode order: true
/// exactly for the samples whose NAL units include an IDR slice (read from the bitstream, not from the trun sample flags
/// the in-house box walk interprets), and the index of each fragment's first sample, where a keyframe is mandatory. IDR
/// samples after a fragment's first are keyframes too: a 4 s fragment of 2 s GOPs holds two.
struct ExpectedKeyframes: Equatable {
    var keyframes: [Bool]
    var fragmentStarts: [Int]

    init(keyframes: [Bool], fragmentStarts: [Int]) {
        self.keyframes = keyframes
        self.fragmentStarts = fragmentStarts
    }

    init(fragments: [FragmentInfo], video: InitSegmentInfo.Track) throws {
        keyframes = []
        fragmentStarts = []
        for (index, fragment) in fragments.enumerated() {
            guard let run = fragment.run(track: video.id), run.sampleCount > 0 else { throw ISOBoxError.malformed("fragment \(index) has no video") }
            fragmentStarts.append(keyframes.count)
            for sample in 0..<run.sampleCount {
                keyframes.append(try fragment.nalTypes(track: video.id, sample: sample, nalLengthSize: video.nalLengthSize).contains(5))
            }
        }
    }
}

/// Compares ffprobe's video packet flags (`-select_streams v -show_entries packet=flags -of csv=p=0`: one line per packet
/// in decode order, "K__" for a keyframe, which ffmpeg's mov demuxer derives from the trun sample flags on its own) with
/// `expected`. Returns one message per disagreement: a packet count other than the sample count, a fragment that does not
/// start with a keyframe, an IDR sample that is not a keyframe, a keyframe that is not an IDR sample. Empty when they agree.
func keyframeMismatches(ffprobeFlags flags: [String], expected: ExpectedKeyframes) -> [String] {
    var mismatches: [String] = []
    if flags.count != expected.keyframes.count {
        mismatches.append("ffprobe reports \(flags.count) video packets for \(expected.keyframes.count) samples")
    }
    let fragmentStartingAt = Dictionary(expected.fragmentStarts.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    for (packet, (line, isIDR)) in zip(flags, expected.keyframes).enumerated() {
        let isKeyframe = line.hasPrefix("K")
        if let fragment = fragmentStartingAt[packet], !isKeyframe {
            mismatches.append("fragment \(fragment) starts at packet \(packet) without a keyframe (flags \(line))")
        } else if isKeyframe != isIDR {
            let found = isKeyframe ? "keyframe" : "no keyframe", sample = isIDR ? "an IDR" : "not an IDR"
            mismatches.append("packet \(packet): ffprobe says \(found), the sample is \(sample) (flags \(line))")
        }
    }
    return mismatches
}

// MARK: - AVFoundation read-back

/// What AVFoundation decodes from a file.
struct PlaybackReport: Sendable {
    var duration: Double
    var videoTrackCount: Int
    var audioTrackCount: Int
    var decodedVideoFrames = 0
    var decodedAudioSamples = 0
    /// The largest magnitude of the decoded audio (16-bit samples): about 0 for silence.
    var audioPeak = 0
    var videoReaderCompleted = false
    var audioReaderCompleted = false
}

#if canImport(AVFoundation)
/// Decodes every video frame (to pixel buffers) and every audio sample (to LPCM) of `url` with `AVAssetReader`.
func decodeWithAVFoundation(_ url: URL) async throws -> PlaybackReport {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    var report = PlaybackReport(duration: duration, videoTrackCount: videoTracks.count, audioTrackCount: audioTracks.count)
    report.audioReaderCompleted = audioTracks.isEmpty
    if let track = videoTracks.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let sample = output.copyNextSampleBuffer() {
            report.decodedVideoFrames += CMSampleBufferGetImageBuffer(sample) != nil ? 1 : 0
        }
        report.videoReaderCompleted = reader.status == .completed
    }
    if let track = audioTracks.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                                                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                                                             AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let buffer = output.copyNextSampleBuffer() {
            let (count, peak): (Int, Int) = {
                var peak = 0
                if let block = CMSampleBufferGetDataBuffer(buffer) {
                    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                    if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr {
                        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                            peak = max(peak, abs(Int(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))))
                        }
                    }
                }
                return (CMSampleBufferGetNumSamples(buffer), peak)
            }()
            report.decodedAudioSamples += count
            report.audioPeak = max(report.audioPeak, peak)
        }
        report.audioReaderCompleted = reader.status == .completed
    }
    return report
}
#endif

// MARK: - Live stream helpers

/// Decodes received access units with VideoToolbox (through `AppleMediaCodecs`): the size of every decoded picture.
func decodeLiveFrames(_ frames: [ReceivedVideoFrame]) async throws -> [(width: Int, height: Int)] {
    var decoder: (any VideoDecoding)?
    var format: VideoFormat?
    var sizes: [(width: Int, height: Int)] = []
    defer { decoder?.invalidate() }
    guard let base = frames.first?.rtpTimestamp else { return [] }
    for frame in frames where frame.isComplete {
        if let sps = frame.sps, let pps = frame.pps, let parsed = VideoFormat.h264(sps: sps, pps: pps), parsed != format {
            decoder?.invalidate()
            format = parsed
            decoder = try AppleMediaCodecs().makeVideoDecoder(format: parsed)
        }
        guard let format, let decoder else { continue }
        if let decoded = try await decoder.decode(frame.encodedFrame(format: format, baseTimestamp: base)) { sizes.append((decoded.width, decoded.height)) }
    }
    return sizes
}

/// Width and height from a baseline/progressive JPEG's SOF segment (ITU-T T.81 §B.2.2), after checking SOI.
func jpegSize(_ data: Data) throws -> (width: Int, height: Int) {
    let reader = BytesReader(bytes: [UInt8](data))
    guard try reader.u16(0) == 0xFFD8 else { throw ISOBoxError.malformed("no JPEG SOI") }
    var offset = 2
    while offset + 4 <= reader.bytes.count {
        guard try reader.u8(offset) == 0xFF else { throw ISOBoxError.malformed("JPEG marker expected at \(offset)") }
        let marker = try reader.u8(offset + 1)
        let length = Int(try reader.u16(offset + 2))
        if (0xC0...0xC3).contains(marker) {
            return (Int(try reader.u16(offset + 7)), Int(try reader.u16(offset + 5)))
        }
        offset += 2 + length
    }
    throw ISOBoxError.truncated("no JPEG SOF segment")
}

/// True when nothing holds the UDP `port` on `host` any more (our bind succeeds; UDPSocket never sets SO_REUSEADDR).
func udpPortIsFree(_ port: UInt16, host: String = "127.0.0.1") -> Bool {
    guard let socket = try? UDPSocket.bind(host: host, port: port) else { return false }
    socket.close()
    return true
}

/// A free even/odd UDP port pair on 127.0.0.1 (ffmpeg may bind RTP + 1 for RTCP).
func freeUDPPortPair() throws -> UInt16 {
    for _ in 0..<50 {
        let probe = try UDPSocket.bind(host: "127.0.0.1")
        let port = probe.localPort & ~1
        probe.close()
        guard port > 1024, port < 65_532 else { continue }
        guard let rtp = try? UDPSocket.bind(host: "127.0.0.1", port: port) else { continue }
        guard let rtcp = try? UDPSocket.bind(host: "127.0.0.1", port: port + 1) else { rtp.close(); continue }
        rtp.close()
        rtcp.close()
        return port
    }
    throw UDPSocketError.invalidAddress("no free UDP port pair on 127.0.0.1")
}

// MARK: - External tools (opt-in oracles)

enum ExternalTool {
    /// The repository root (`Interop/`, `Packages/`), from this file's location.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../..").standardizedFileURL
    }

    /// `environmentKey` if set, else the first executable of `candidates`.
    static func find(environmentKey: String, candidates: [String]) -> URL? {
        let paths = [ProcessInfo.processInfo.environment[environmentKey]].compactMap { $0 } + candidates
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var node: URL? { find(environmentKey: "CB_NODE", candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]) }
    static var ffmpeg: URL? { find(environmentKey: "CB_FFMPEG", candidates: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) }
    static var ffprobe: URL? { find(environmentKey: "CB_FFPROBE", candidates: ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) }
}

struct ToolResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String
    var timedOut: Bool
    var output: String { String(decoding: stdout, as: UTF8.self) }
}

/// A started external process with its output drained concurrently (a chatty tool never blocks on a full pipe).
struct RunningTool: Sendable {
    let process: Process
    let stdout: Task<Data, Never>
    let stderr: Task<Data, Never>

    static func start(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) throws -> RunningTool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdoutHandle = out.fileHandleForReading, stderrHandle = err.fileHandleForReading
        return RunningTool(process: process, stdout: Task.detached { stdoutHandle.readDataToEndOfFile() },
                           stderr: Task.detached { stderrHandle.readDataToEndOfFile() })
    }

    /// Waits for the exit; after `timeout` the process is terminated (a hung tool never outlives the test).
    func finish(timeout: Duration) async -> ToolResult {
        let exited = await eventually(timeout: timeout) { !process.isRunning }
        if !exited { process.terminate() }
        process.waitUntilExit()
        let out = await stdout.value
        let err = String(decoding: await stderr.value, as: UTF8.self)
        return ToolResult(status: process.terminationStatus, stdout: out, stderr: err, timedOut: !exited)
    }

    static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil, timeout: Duration) async throws -> ToolResult {
        try await start(executable, arguments, currentDirectory: currentDirectory).finish(timeout: timeout)
    }
}

// MARK: - A web server that knows no camera API

/// Answers every HTTP request with 404 and closes (an ONVIF camera whose SOAP endpoints are unreachable), so a driver's
/// probes and event channel fail fast on loopback without touching any other service.
final class NotFoundHTTPServer: Sendable {
    private let listener: any TCPListener
    private let task: Task<Void, Never>
    /// Requests answered so far.
    let requests: Box<Int>

    var port: UInt16 { listener.port }

    init(transport: any NetworkTransport) async throws {
        let listener = try await transport.listen(port: 0, loopbackOnly: true)
        self.listener = listener
        let requests = Box(0)
        self.requests = requests
        task = Task {
            await withDiscardingTaskGroup { group in
                for await connection in listener.connections {
                    group.addTask {
                        var received = Data()
                        while received.range(of: Data("\r\n\r\n".utf8)) == nil, received.count < 65_536 {
                            guard let chunk = try? await connection.receive(maximumLength: 4_096) else { break }
                            received.append(chunk)
                        }
                        requests.update { $0 += 1 }
                        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        try? await connection.send(Data(response.utf8))
                        connection.close()
                    }
                }
            }
        }
    }

    func stop() {
        listener.close()
        task.cancel()
    }
}
#endif
