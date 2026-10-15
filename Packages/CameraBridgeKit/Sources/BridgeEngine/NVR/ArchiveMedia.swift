import BridgeSupport
import FMP4
import Foundation

/// MP4 surgery for the browser (addendum L5.2): the video-only view of a file that may also hold sound, and the codec string
/// `MediaSource.isTypeSupported` wants. Lives in BridgeEngine because BridgeWeb may not import FMP4; `package` access.
///
/// It reads only what `FMP4Muxer` writes (docs/superpowers/plans/2026-10-10-nvr/T03-archive-media.md): an initialization segment of `ftyp` and `moov`
/// (`mvhd`, a video `trak` with track id 1, an optional sound `trak` with track id 2, `mvex` with one `trex` per track), and fragments of an optional
/// `prft`, a `moof` (`mfhd`, a video `traf` and an optional sound `traf`, each `tfhd` + `tfdt` + one `trun`) and an `mdat` with the video samples first.
/// Anything else is `Failure.unsupported`; bytes that do not add up are `Failure.malformed`. Every function throws only `Failure`, never traps and
/// never allocates more than its input holds.
package enum ArchiveMedia {
    package struct VideoInit: Sendable, Equatable {
        /// `ftyp` + `moov` with the video track only (unchanged bytes when the file has no audio track).
        package var data: Data
        /// `video/mp4; codecs="avc1.4d0032"` (or `hvc1.…`).
        package var mime: String
        package var width: Int
        package var height: Int
        /// The original init segment had an audio track.
        package var hadAudio: Bool

        package init(data: Data, mime: String, width: Int, height: Int, hadAudio: Bool) {
            self.data = data
            self.mime = mime
            self.width = width
            self.height = height
            self.hadAudio = hadAudio
        }
    }

    package enum Failure: Error, Equatable, Sendable {
        /// Not an MP4 this recorder wrote, or a box that does not add up.
        case malformed(String)
        /// A codec, box or `trun` flag combination the recorder never writes.
        case unsupported(String)
    }

    /// The mime type of the file's video track from its init segment.
    package static func mime(forInit initData: Data) throws -> String {
        try InitSegment(initData).mime
    }

    /// The init segment without its audio track, with the mime, picture size and whether audio was dropped.
    package static func videoInit(_ initData: Data) throws -> VideoInit {
        let parsed = try InitSegment(initData)
        guard parsed.hasAudio else {
            return VideoInit(data: initData, mime: parsed.mime, width: parsed.width, height: parsed.height, hadAudio: false)
        }
        let source = Source(initData)
        var moov = ByteWriter()
        let mvhd = source.bytes(parsed.mvhd)
        if parsed.mvhd.headerSize == 8, mvhd.count == mvhdVersion0Size, mvhd[mvhd.startIndex + 8] == 0 {
            moov.write(mvhd.prefix(mvhdVersion0Size - 4))                    // the last field is next_track_ID: the video track's id + 1
            moov.writeUInt32BE(videoTrackID + 1)
        } else {
            moov.write(mvhd)
        }
        moov.write(source.bytes(parsed.video))
        let trex = source.bytes(parsed.videoTrex)
        moov.writeUInt32BE(UInt32(8 + trex.count))
        moov.write(Data("mvex".utf8))
        moov.write(trex)
        var out = ByteWriter()
        out.write(source.bytes(parsed.ftyp))
        out.writeUInt32BE(UInt32(8 + moov.data.count))
        out.write(Data("moov".utf8))
        out.write(moov.data)
        return VideoInit(data: out.data, mime: parsed.mime, width: parsed.width, height: parsed.height, hadAudio: true)
    }

    /// One stored fragment (`prft` + `moof` + `mdat`) as `moof` + `mdat` with the video samples only: no `prft`, no audio `traf`.
    package static func videoSegment(_ fragment: Data) throws -> Data {
        guard fragment.count <= Int(Int32.max) else { throw malformed("a fragment is under 2 GiB") }
        let source = Source(fragment)
        let boxes = try parseBoxes(fragment)
        let skipped = boxes.first?.type == "prft" ? 1 : 0                  // the prft goes by its box size, whatever it is
        guard boxes.count == skipped + 2, boxes[skipped].type == "moof", boxes[skipped + 1].type == "mdat" else {
            throw malformed("a fragment is an optional prft, a moof and an mdat")
        }
        let moof = boxes[skipped]
        let mdat = boxes[skipped + 1]

        var mfhd: MP4Box?
        var runs: [UInt32: TrackRun] = [:]
        for child in moof.children {
            switch child.type {
            case "mfhd" where mfhd == nil:
                mfhd = child
            case "traf":
                let run = try TrackRun(traf: child, source: source)
                guard runs[run.trackID] == nil else { throw malformed("a moof has two traf boxes for track \(run.trackID)") }
                runs[run.trackID] = run
            default:
                throw unsupported("a moof holds a '\(child.type)' box the recorder never writes")
            }
        }
        guard let mfhd, let video = runs[videoTrackID] else { throw malformed("a moof needs an mfhd and a video traf") }
        guard video.sampleCount > 0 else { throw malformed("the video traf has no samples") }
        guard moof.offset + video.dataOffset == mdat.payloadOffset else { throw unsupported("the video samples do not start the mdat") }
        let audio = runs[audioTrackID]
        if let audio {
            guard audio.dataOffset == video.dataOffset + video.sampleBytes else { throw unsupported("the sound samples do not follow the video samples") }
        }
        let sampleBytes = video.sampleBytes + (audio?.sampleBytes ?? 0)
        guard sampleBytes == mdat.payloadSize else {
            throw malformed("the samples add up to \(sampleBytes) bytes and the mdat holds \(mdat.payloadSize)")
        }
        guard audio != nil else {
            return fragment.subdata(in: fragment.startIndex + moof.offset..<fragment.endIndex)       // only the prft is dropped
        }

        let mfhdBytes = source.bytes(mfhd)
        let trafBytes = source.bytes(video.traf)
        let moofSize = 8 + mfhdBytes.count + trafBytes.count
        let dataOffset = moofSize + 8                                      // the new mdat starts right after the new moof
        guard dataOffset + video.sampleBytes <= Int(Int32.max) else { throw unsupported("a fragment of more than 2 GiB") }
        let offsetField = video.trun.payloadOffset + 8 - video.traf.offset  // where the trun's data_offset sits inside the traf
        var out = ByteWriter()
        out.writeUInt32BE(UInt32(moofSize))
        out.write(Data("moof".utf8))
        out.write(mfhdBytes)
        out.write(trafBytes.prefix(offsetField))
        out.writeUInt32BE(UInt32(dataOffset))
        out.write(trafBytes.dropFirst(offsetField + 4))
        out.writeUInt32BE(UInt32(8 + video.sampleBytes))
        out.write(Data("mdat".utf8))
        let mdatStart = fragment.startIndex + mdat.payloadOffset
        out.write(fragment[mdatStart..<mdatStart + video.sampleBytes])
        return out.data
    }

    // MARK: - Sound only

    /// The mime of the sound track: the recorder writes AAC-LC only.
    package static let soundMime = "audio/mp4; codecs=\"mp4a.40.2\""

    /// The init segment with the sound track only (`ftyp` + `moov` of `mvhd`, the sound `trak` and its `trex`), for an audio element that plays a
    /// recording's sound beside the picture. nil when the file has no sound.
    package static func soundInit(_ initData: Data) throws -> Data? {
        let parsed = try InitSegment(initData)
        guard let audio = parsed.audio, let trex = parsed.audioTrex else { return nil }
        let source = Source(initData)
        var moov = ByteWriter()
        moov.write(source.bytes(parsed.mvhd))
        moov.write(source.bytes(audio))
        let trexBytes = source.bytes(trex)
        moov.writeUInt32BE(UInt32(8 + trexBytes.count))
        moov.write(Data("mvex".utf8))
        moov.write(trexBytes)
        var out = ByteWriter()
        out.write(source.bytes(parsed.ftyp))
        out.writeUInt32BE(UInt32(8 + moov.data.count))
        out.write(Data("moov".utf8))
        out.write(moov.data)
        return out.data
    }

    /// One stored fragment as `moof` + `mdat` with the sound samples only. nil when the fragment holds no sound.
    package static func soundSegment(_ fragment: Data) throws -> Data? {
        guard fragment.count <= Int(Int32.max) else { throw malformed("a fragment is under 2 GiB") }
        let source = Source(fragment)
        let boxes = try parseBoxes(fragment)
        let skipped = boxes.first?.type == "prft" ? 1 : 0
        guard boxes.count == skipped + 2, boxes[skipped].type == "moof", boxes[skipped + 1].type == "mdat" else {
            throw malformed("a fragment is an optional prft, a moof and an mdat")
        }
        let moof = boxes[skipped]
        let mdat = boxes[skipped + 1]
        var mfhd: MP4Box?
        var runs: [UInt32: TrackRun] = [:]
        for child in moof.children {
            switch child.type {
            case "mfhd" where mfhd == nil: mfhd = child
            case "traf":
                let run = try TrackRun(traf: child, source: source)
                guard runs[run.trackID] == nil else { throw malformed("a moof has two traf boxes for track \(run.trackID)") }
                runs[run.trackID] = run
            default: throw unsupported("a moof holds a '\(child.type)' box the recorder never writes")
            }
        }
        guard let mfhd else { throw malformed("a moof needs an mfhd") }
        guard let audio = runs[audioTrackID], audio.sampleCount > 0 else { return nil }
        let start = moof.offset + audio.dataOffset
        guard start >= mdat.payloadOffset, start + audio.sampleBytes <= mdat.payloadOffset + mdat.payloadSize else {
            throw malformed("the sound samples lie outside the mdat")
        }
        let mfhdBytes = source.bytes(mfhd)
        let trafBytes = source.bytes(audio.traf)
        let moofSize = 8 + mfhdBytes.count + trafBytes.count
        let dataOffset = moofSize + 8
        let offsetField = audio.trun.payloadOffset + 8 - audio.traf.offset
        var out = ByteWriter()
        out.writeUInt32BE(UInt32(moofSize))
        out.write(Data("moof".utf8))
        out.write(mfhdBytes)
        out.write(trafBytes.prefix(offsetField))
        out.writeUInt32BE(UInt32(dataOffset))
        out.write(trafBytes.dropFirst(offsetField + 4))
        out.writeUInt32BE(UInt32(8 + audio.sampleBytes))
        out.write(Data("mdat".utf8))
        let begin = fragment.startIndex + start
        out.write(fragment[begin..<begin + audio.sampleBytes])
        return out.data
    }

    // MARK: - The recorder's layout

    /// `FMP4Muxer` writes the video track as track 1 and the optional sound track as track 2 (`VideoTrack.trackID`, `AudioTrack.trackID`, internal to FMP4).
    private static let videoTrackID: UInt32 = 1
    private static let audioTrackID: UInt32 = 2
    /// ftyp + moov of an H.264 file is under 1 KB and of an HEVC file under 2 KB; a megabyte is far beyond any real one.
    private static let maximumInitBytes = 1 << 20
    /// `mvhd` version 0: 8 header + 4 version/flags + 4 x 4 times and duration + rate 4 + volume 2 + 10 reserved + 36 matrix + 24 pre_defined + 4 next_track_ID.
    private static let mvhdVersion0Size = 108
    /// The `trun` flags the muxer writes: data offset, duration, size, flags (0x000701), plus composition offsets (0x000F01).
    private static let trunFlags: UInt32 = 0x00_0701
    private static let trunFlagsWithCompositionOffsets: UInt32 = 0x00_0F01
    /// `tfhd` as the muxer writes it: version 0, flags default-base-is-moof, and the track id.
    private static let tfhdVersionAndFlags: UInt32 = 0x0002_0000

    private static func malformed(_ message: String) -> Failure { .malformed(printable(message)) }
    private static func unsupported(_ message: String) -> Failure { .unsupported(printable(message)) }

    /// A message that is safe to log: printable ASCII only (a box type is four arbitrary bytes), at most 160 characters.
    private static func printable(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.prefix(160).map { (0x20..<0x7F).contains($0.value) ? $0 : "?" }))
    }

    /// `MP4BoxReader.parse` with its error mapped to `Failure`.
    private static func parseBoxes(_ data: Data) throws -> [MP4Box] {
        do {
            return try MP4BoxReader.parse(data)
        } catch FMP4Error.malformedBox(let offset, let reason) {
            throw malformed("box at offset \(offset): \(reason)")
        } catch {
            throw malformed("unreadable boxes")
        }
    }

    /// Runs `body` over the payload of `box` (after its header); a read past its end is `Failure.malformed`.
    private static func fields<T>(of box: MP4Box, in source: Source, _ body: (inout ByteReader) throws -> T) throws -> T {
        var reader = ByteReader(source.payload(box))
        do {
            return try body(&reader)
        } catch is ByteError {
            throw malformed("'\(box.type)' is shorter than its fields")
        }
    }

    /// The bytes of boxes the parser found in `data` (offsets are relative to `data.startIndex`, so slices work).
    private struct Source {
        let data: Data

        init(_ data: Data) { self.data = data }

        func bytes(_ box: MP4Box) -> Data { data[data.startIndex + box.offset..<data.startIndex + box.offset + box.size] }
        func payload(_ box: MP4Box) -> Data { data[data.startIndex + box.payloadOffset..<data.startIndex + box.offset + box.size] }
    }

    /// The init segment of a file this recorder wrote.
    private struct InitSegment {
        var ftyp: MP4Box
        var mvhd: MP4Box
        var video: MP4Box
        var hasAudio: Bool
        var audio: MP4Box?
        var videoTrex: MP4Box
        var audioTrex: MP4Box?
        var mime: String
        var width: Int
        var height: Int

        init(_ data: Data) throws {
            guard data.count <= ArchiveMedia.maximumInitBytes else { throw malformed("an initialization segment is under 1 MiB") }
            let source = Source(data)
            let boxes = try parseBoxes(data)
            guard boxes.count == 2, boxes[0].type == "ftyp", boxes[1].type == "moov" else {
                throw malformed("an initialization segment is an ftyp and a moov")
            }
            var mvhd: MP4Box?
            var mvex: MP4Box?
            var video: MP4Box?
            var audio: MP4Box?
            for child in boxes[1].children {
                switch child.type {
                case "mvhd" where mvhd == nil:
                    mvhd = child
                case "mvex" where mvex == nil:
                    mvex = child
                case "trak":
                    let id = try Self.trackID(of: child, in: source)
                    switch try Self.handlerType(of: child, in: source) {
                    case "vide":
                        guard video == nil else { throw unsupported("more than one video track") }
                        guard id == videoTrackID else { throw unsupported("video track id \(id) (the recorder writes \(videoTrackID))") }
                        video = child
                    case "soun":
                        guard audio == nil else { throw unsupported("more than one sound track") }
                        guard id == audioTrackID else { throw unsupported("sound track id \(id) (the recorder writes \(audioTrackID))") }
                        audio = child
                    default:
                        throw unsupported("a track that is neither video nor sound")
                    }
                default:
                    throw unsupported("a moov holds a '\(child.type)' box the recorder never writes")
                }
            }
            guard let mvhd, let mvex, let video else { throw malformed("a moov needs an mvhd, a video track and an mvex") }
            let trex = try mvex.children(ofType: "trex").first { try Self.trexTrackID($0, in: source) == videoTrackID }
            guard let trex else { throw malformed("the mvex has no trex for the video track") }

            let (mime, width, height) = try Self.describeVideo(video, in: source)
            self.ftyp = boxes[0]
            self.mvhd = mvhd
            self.video = video
            self.hasAudio = audio != nil
            self.audio = audio
            self.audioTrex = try mvex.children(ofType: "trex").first { try Self.trexTrackID($0, in: source) == audioTrackID }
            self.videoTrex = trex
            self.mime = mime
            self.width = width
            self.height = height
        }

        /// `tkhd` track_ID: after version (1), flags (3) and the creation and modification times (4 + 4, or 8 + 8 in version 1).
        private static func trackID(of trak: MP4Box, in source: Source) throws -> UInt32 {
            guard let tkhd = trak.child("tkhd") else { throw malformed("a trak has no tkhd") }
            return try fields(of: tkhd, in: source) { reader in
                let version = try reader.readUInt8()
                try reader.skip(version == 1 ? 19 : 11)
                return try reader.readUInt32BE()
            }
        }

        /// `hdlr` handler_type: after version and flags (4) and pre_defined (4).
        private static func handlerType(of trak: MP4Box, in source: Source) throws -> String {
            guard let hdlr = trak.descendant(atPath: "mdia/hdlr") else { throw malformed("a trak has no hdlr") }
            return try fields(of: hdlr, in: source) { reader in
                try reader.skip(8)
                return String(decoding: try reader.readBytes(4), as: UTF8.self)
            }
        }

        /// `trex` track_ID: after version and flags (4).
        private static func trexTrackID(_ trex: MP4Box, in source: Source) throws -> UInt32 {
            try fields(of: trex, in: source) { reader in
                try reader.skip(4)
                return try reader.readUInt32BE()
            }
        }

        /// The mime, width and height of the video sample entry (`avc1` with `avcC`, or `hvc1` with `hvcC`).
        private static func describeVideo(_ trak: MP4Box, in source: Source) throws -> (mime: String, width: Int, height: Int) {
            guard let stsd = trak.descendant(atPath: "mdia/minf/stbl/stsd"), stsd.children.count == 1, let entry = stsd.children.first else {
                throw malformed("the video track needs exactly one sample entry")
            }
            // VisualSampleEntry: 6 reserved, data_reference_index, pre_defined, reserved, 12 pre_defined, then width and height.
            let (width, height): (Int, Int) = try fields(of: entry, in: source) { reader in
                try reader.skip(24)
                return (Int(try reader.readUInt16BE()), Int(try reader.readUInt16BE()))
            }
            guard width > 0, height > 0 else { throw malformed("the video sample entry has no picture size") }
            switch entry.type {
            case "avc1":
                guard let avcC = entry.child("avcC") else { throw malformed("the avc1 sample entry has no avcC") }
                return (try avcMime(avcC, in: source), width, height)
            case "hvc1":
                guard let hvcC = entry.child("hvcC") else { throw malformed("the hvc1 sample entry has no hvcC") }
                return (try hevcMime(hvcC, in: source), width, height)
            default:
                throw unsupported("the video sample entry '\(entry.type)' (the recorder writes avc1 or hvc1)")
            }
        }

        /// `avc1.PPCCLL`: AVCProfileIndication, profile_compatibility and AVCLevelIndication, lowercase hexadecimal (RFC 6381).
        private static func avcMime(_ avcC: MP4Box, in source: Source) throws -> String {
            let (profile, compatibility, level): (UInt8, UInt8, UInt8) = try fields(of: avcC, in: source) { reader in
                guard try reader.readUInt8() == 1 else { throw malformed("the avcC is not version 1") }
                return (try reader.readUInt8(), try reader.readUInt8(), try reader.readUInt8())
            }
            return "video/mp4; codecs=\"avc1.\(hex(profile, upper: false))\(hex(compatibility, upper: false))\(hex(level, upper: false))\""
        }

        /// `hvc1.[A|B|C]profile.compatibility.[L|H]level[.constraint bytes]` (ISO/IEC 14496-15 Annex E.3): the profile space as a letter (none for 0), the
        /// profile as a decimal number, the 32 compatibility flags in reverse bit order as hexadecimal without leading zeros, the tier and level as `L93`
        /// or `H153`, then the six constraint bytes as two-digit hexadecimal separated by dots, trailing zero bytes left out.
        private static func hevcMime(_ hvcC: MP4Box, in source: Source) throws -> String {
            struct Record { var profileByte: UInt8; var compatibility: UInt32; var constraints: [UInt8]; var level: UInt8 }
            let record: Record = try fields(of: hvcC, in: source) { reader in
                guard reader.remaining >= 23, try reader.readUInt8() == 1 else { throw malformed("the hvcC is not a version 1 record") }
                return Record(profileByte: try reader.readUInt8(), compatibility: try reader.readUInt32BE(),
                              constraints: [UInt8](try reader.readBytes(6)), level: try reader.readUInt8())
            }
            var reversed: UInt32 = 0
            var flags = record.compatibility
            for _ in 0..<32 {
                reversed = reversed << 1 | flags & 1
                flags >>= 1
            }
            let space = record.profileByte >> 6
            let tier = record.profileByte & 0x20 != 0 ? "H" : "L"
            var codec = "hvc1."
            if space > 0 { codec += String(UnicodeScalar(UInt8(ascii: "A") + space - 1)) }
            codec += "\(record.profileByte & 0x1F).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(record.level)"
            var constraints = record.constraints[...]
            while constraints.last == 0 { constraints.removeLast() }
            for byte in constraints { codec += "." + hex(byte, upper: true) }
            return "video/mp4; codecs=\"\(codec)\""
        }

        private static func hex(_ byte: UInt8, upper: Bool) -> String {
            let digits = Array((upper ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
            return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]], as: UTF8.self)
        }
    }

    /// One `traf` of a fragment: its track, where its samples start (from the `moof`) and how many bytes they add up to.
    private struct TrackRun {
        var traf: MP4Box
        var trun: MP4Box
        var trackID: UInt32
        var sampleCount: Int
        var dataOffset: Int
        var sampleBytes: Int

        init(traf: MP4Box, source: Source) throws {
            guard traf.children.map(\.type) == ["tfhd", "tfdt", "trun"] else { throw unsupported("a traf is a tfhd, a tfdt and one trun") }
            let tfhd = traf.children[0]
            let trun = traf.children[2]
            guard tfhd.size == 16 else { throw unsupported("a tfhd with fields beyond the track id") }
            let trackID: UInt32 = try fields(of: tfhd, in: source) { reader in
                guard try reader.readUInt32BE() == tfhdVersionAndFlags else { throw unsupported("a tfhd that is not default-base-is-moof only") }
                return try reader.readUInt32BE()
            }
            guard trackID == videoTrackID || trackID == audioTrackID else { throw unsupported("a traf for track \(trackID)") }
            let isAudio = trackID == audioTrackID

            var sampleCount = 0
            var dataOffset = 0
            var sampleBytes = 0
            try fields(of: trun, in: source) { reader in
                let versionAndFlags = try reader.readUInt32BE()
                let version = versionAndFlags >> 24
                let flags = versionAndFlags & 0x00FF_FFFF
                let allowed = isAudio ? flags == trunFlags && version == 0
                                      : (flags == trunFlags || flags == trunFlagsWithCompositionOffsets) && version <= 1
                guard allowed else { throw unsupported("a trun with version \(version) and flags 0x\(String(flags, radix: 16))") }
                sampleCount = Int(try reader.readUInt32BE())
                dataOffset = Int(Int32(bitPattern: try reader.readUInt32BE()))
                let entryLength = flags == trunFlagsWithCompositionOffsets ? 16 : 12          // duration, size, flags (, composition offset)
                guard sampleCount <= reader.remaining / entryLength, sampleCount * entryLength == reader.remaining else {
                    throw malformed("a trun of \(sampleCount) samples does not fit its box")
                }
                for _ in 0..<sampleCount {
                    try reader.skip(4)
                    sampleBytes += Int(try reader.readUInt32BE())
                    try reader.skip(entryLength - 8)
                }
            }
            self.traf = traf
            self.trun = trun
            self.trackID = trackID
            self.sampleCount = sampleCount
            self.dataOffset = dataOffset
            self.sampleBytes = sampleBytes
        }
    }
}
