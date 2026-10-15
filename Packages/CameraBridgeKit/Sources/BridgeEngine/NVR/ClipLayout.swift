import FMP4
import Foundation

/// The bytes of a clip's file that come before the pictures, and its exact size (export-clip spec 4): `ftyp`, then `moov` complete with every sample
/// table, then the header of the `mdat` that holds the pictures. The planner has all the tables before the first picture is read, so this is known
/// before anything is written; `ClipWriter` writes the three, then copies the pictures untouched.
package struct ClipLayout: Sendable, Equatable {
    package let ftyp: Data
    package let moov: Data
    /// 8 bytes, or 16 (size 1 and a 64-bit size) when the pictures are 4 GiB or more.
    package let mdatHeader: Data
    /// The bytes of all the pictures: the sum of the sample sizes.
    package let payloadBytes: Int64
    /// Whether the chunk offsets are 64-bit (`co64`): when any chunk starts at 4 GiB or later.
    package let usesLongOffsets: Bool
    /// The file has a sound track (`ClipPartTables.sound`).
    package let hasSound: Bool

    package var totalBytes: Int64 { Int64(ftyp.count + moov.count + mdatHeader.count) + payloadBytes }

    /// Unix seconds to MP4 seconds (since 1904-01-01).
    static let epochDelta: Int64 = 2_082_844_800
    static let movieTimescale: UInt32 = 1000

    /// Throws `ClipError.damaged(at: tables.wallStart)` when the initialization segment has no video track, when there are no samples, or when the
    /// copies do not add up to the samples (a plan that could not be written).
    package static func make(_ tables: ClipPartTables) throws -> ClipLayout {
        let damaged = ClipError.damaged(at: tables.wallStart)
        guard !tables.samples.isEmpty, !tables.copies.isEmpty else { throw damaged }
        var payload: Int64 = 0
        for sample in tables.samples { payload += Int64(sample.size) }
        guard payload == tables.copies.reduce(Int64(0), { $0 + Int64($1.length) }),
              tables.copies.reduce(0, { $0 + $1.sampleCount }) == tables.samples.count else { throw damaged }

        let source = try SourceTrack(tables.initialization, damaged: damaged)
        var duration: UInt64 = 0
        for sample in tables.samples { duration += UInt64(sample.duration) }
        // The sound: its samples add up to its copies, and each copy follows a picture copy.
        var soundSource: SoundTrack?
        if let sound = tables.sound {
            var bytes: Int64 = 0
            for sample in sound.samples { bytes += Int64(sample.size) }
            guard !sound.samples.isEmpty, sound.copies.count == sound.follows.count, sound.timescale > 0,
                  bytes == sound.copies.reduce(Int64(0), { $0 + Int64($1.length) }),
                  sound.copies.reduce(0, { $0 + $1.sampleCount }) == sound.samples.count,
                  sound.follows.allSatisfy({ tables.copies.indices.contains($0) }), sound.leadTicks >= 0 else { throw damaged }
            soundSource = try SoundTrack(tables.initialization, damaged: damaged)
            payload += bytes
        }

        var ftyp = ClipBoxBuilder(capacity: 32)
        ftyp.box("ftyp") { box in
            box.fourCC("isom")
            box.u32(512)
            for brand in ["isom", "iso2", "avc1", "mp41"] { box.fourCC(brand) }
        }
        let mdatHeader = Self.mdatHeader(payload: payload)
        let prefix = Int64(ftyp.count) + Int64(mdatHeader.count)

        // The moov's size does not depend on the offsets' values, only on their width: build it with 32-bit offsets and, if the last chunk starts
        // beyond 4 GiB, again with 64-bit ones (which only moves the chunks further).
        var longOffsets = false
        var moov = try Self.moov(tables, source: source, sound: soundSource, duration: duration, prefix: prefix, longOffsets: false)
        if moov.lastChunkOffset > Int64(UInt32.max) {
            longOffsets = true
            moov = try Self.moov(tables, source: source, sound: soundSource, duration: duration, prefix: prefix, longOffsets: true)
        }
        return ClipLayout(ftyp: ftyp.data, moov: moov.data, mdatHeader: mdatHeader, payloadBytes: payload, usesLongOffsets: longOffsets,
                          hasSound: soundSource != nil)
    }

    static func mdatHeader(payload: Int64) -> Data {
        var header = ClipBoxBuilder(capacity: 16)
        if payload + 8 < Int64(1) << 32 {
            header.u32(UInt32(payload + 8))
            header.fourCC("mdat")
        } else {
            header.u32(1)
            header.fourCC("mdat")
            header.u64(UInt64(payload + 16))
        }
        return header.data
    }

    // MARK: The video track of the initialization segment

    /// What the clip takes from the recorder's initialization segment: the boxes it copies byte for byte and the media timescale.
    struct SourceTrack {
        var handler: Data
        var videoHeader: Data
        var dataInformation: Data
        var sampleDescription: Data
        var timescale: UInt32

        init(_ initialization: Data, damaged: ClipError) throws {
            guard let boxes = try? MP4BoxReader.parse(initialization), let moov = boxes.first(where: { $0.type == "moov" }) else { throw damaged }
            let tracks = moov.children(ofType: "trak")
            func isVideo(_ track: MP4Box) -> Bool {
                guard let handler = track.descendant(atPath: "mdia/hdlr"), handler.size >= 20 else { return false }
                let at = handler.payloadOffset + 8      // version and flags, pre_defined
                return initialization.count >= at + 4 && initialization[initialization.startIndex + at ..< initialization.startIndex + at + 4] == Data("vide".utf8)
            }
            guard let track = tracks.first(where: isVideo),
                  let handler = track.descendant(atPath: "mdia/hdlr"), let header = track.descendant(atPath: "mdia/minf/vmhd"),
                  let dinf = track.descendant(atPath: "mdia/minf/dinf"), let stsd = track.descendant(atPath: "mdia/minf/stbl/stsd"),
                  let mdhd = track.descendant(atPath: "mdia/mdhd") else { throw damaged }
            func slice(_ box: MP4Box) -> Data {
                initialization.subdata(in: initialization.startIndex + box.offset ..< initialization.startIndex + box.offset + box.size)
            }
            self.handler = slice(handler)
            videoHeader = slice(header)
            dataInformation = slice(dinf)
            sampleDescription = slice(stsd)
            let version = initialization[initialization.startIndex + mdhd.payloadOffset]
            let at = initialization.startIndex + mdhd.payloadOffset + 4 + (version == 1 ? 16 : 8)
            guard initialization.count >= at - initialization.startIndex + 4 else { throw damaged }
            let scale = initialization[at ..< at + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard scale > 0 else { throw damaged }
            timescale = scale
        }
    }

    /// What the clip takes from the sound track of the initialization segment: `hdlr`, `smhd`, `dinf` and `stsd`, copied byte for byte.
    struct SoundTrack {
        var handler: Data
        var soundHeader: Data
        var dataInformation: Data
        var sampleDescription: Data

        init(_ initialization: Data, damaged: ClipError) throws {
            guard let boxes = try? MP4BoxReader.parse(initialization), let moov = boxes.first(where: { $0.type == "moov" }) else { throw damaged }
            func isSound(_ track: MP4Box) -> Bool {
                guard let handler = track.descendant(atPath: "mdia/hdlr"), handler.size >= 20 else { return false }
                let at = handler.payloadOffset + 8
                return initialization.count >= at + 4 && initialization[initialization.startIndex + at ..< initialization.startIndex + at + 4] == Data("soun".utf8)
            }
            guard let track = moov.children(ofType: "trak").first(where: isSound),
                  let handler = track.descendant(atPath: "mdia/hdlr"), let header = track.descendant(atPath: "mdia/minf/smhd"),
                  let dinf = track.descendant(atPath: "mdia/minf/dinf"), let stsd = track.descendant(atPath: "mdia/minf/stbl/stsd") else { throw damaged }
            func slice(_ box: MP4Box) -> Data {
                initialization.subdata(in: initialization.startIndex + box.offset ..< initialization.startIndex + box.offset + box.size)
            }
            self.handler = slice(handler)
            soundHeader = slice(header)
            dataInformation = slice(dinf)
            sampleDescription = slice(stsd)
        }
    }

    // MARK: moov

    private struct BuiltMoov {
        var data: Data
        var lastChunkOffset: Int64
    }

    private static func moov(_ tables: ClipPartTables, source: SourceTrack, sound soundSource: SoundTrack?, duration: UInt64, prefix: Int64,
                             longOffsets: Bool) throws -> BuiltMoov {
        let created = UInt32(clamping: max(0, Int64(tables.wallStart.timeIntervalSince1970) + epochDelta))
        let videoDuration = UInt32(clamping: (duration * UInt64(movieTimescale) + UInt64(source.timescale) / 2) / UInt64(source.timescale))
        let samples = tables.samples
        let sound = soundSource == nil ? nil : tables.sound
        let soundSamples = sound?.samples ?? []
        let soundScale = UInt64(sound?.timescale ?? 1)
        let soundDuration = soundSamples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
        let toMovie = { (ticks: UInt64) in UInt32(clamping: (ticks * UInt64(movieTimescale) + soundScale / 2) / soundScale) }
        let leadMovie = toMovie(UInt64(sound?.leadTicks ?? 0))
        let soundMovie = toMovie(soundDuration)
        let movieDuration = max(videoDuration, sound == nil ? 0 : leadMovie &+ soundMovie)

        // The chunk offsets, once the size of the moov is known: one chunk per source fragment, and its sound (if any) right after it.
        var lastOffset: Int64 = 0
        func offsets(moovSize: Int64) -> (video: [Int64], sound: [Int64]) {
            var position = prefix + moovSize
            var video: [Int64] = []
            var audio: [Int64] = []
            video.reserveCapacity(tables.copies.count)
            var soundIndex = 0
            for (index, copy) in tables.copies.enumerated() {
                video.append(position); lastOffset = position; position += Int64(copy.length)
                while let sound, soundIndex < sound.copies.count, sound.follows[soundIndex] == index {
                    audio.append(position); lastOffset = position; position += Int64(sound.copies[soundIndex].length)
                    soundIndex += 1
                }
            }
            return (video, audio)
        }

        func writeOffsets(_ stbl: inout ClipBoxBuilder, _ chunkOffsets: [Int64]) {
            if longOffsets {
                stbl.fullBox("co64", version: 0, flags: 0) { box in
                    box.u32(UInt32(chunkOffsets.count))
                    for offset in chunkOffsets { box.u64(UInt64(offset)) }
                }
            } else {
                stbl.fullBox("stco", version: 0, flags: 0) { box in
                    box.u32(UInt32(chunkOffsets.count))
                    for offset in chunkOffsets { box.u32(UInt32(truncatingIfNeeded: offset)) }
                }
            }
        }

        func writeChunks(_ stbl: inout ClipBoxBuilder, _ counts: [Int]) {
            var entries: [(first: UInt32, perChunk: UInt32)] = []
            for (index, count) in counts.enumerated() where entries.last?.perChunk != UInt32(count) {
                entries.append((UInt32(index + 1), UInt32(count)))
            }
            stbl.fullBox("stsc", version: 0, flags: 0) { box in
                box.u32(UInt32(entries.count))
                for entry in entries { box.u32(entry.first); box.u32(entry.perChunk); box.u32(1) }
            }
        }

        func build(_ chunkOffsets: (video: [Int64], sound: [Int64])) -> Data {
            var moov = ClipBoxBuilder(capacity: 1_024 + samples.count * 12 + soundSamples.count * 8)
            moov.box("moov") { moov in
                moov.fullBox("mvhd", version: 0, flags: 0) { box in
                    box.u32(created); box.u32(created); box.u32(movieTimescale); box.u32(movieDuration)
                    box.u32(0x0001_0000); box.u16(0x0100); box.zeros(10)
                    box.identityMatrix(); box.zeros(24); box.u32(sound == nil ? 2 : 3)
                }
                moov.box("trak") { trak in
                    trak.fullBox("tkhd", version: 0, flags: 3) { box in
                        box.u32(created); box.u32(created); box.u32(1); box.u32(0); box.u32(videoDuration)
                        box.zeros(8); box.u16(0); box.u16(0); box.u16(0); box.u16(0)
                        box.identityMatrix(); box.u32(UInt32(clamping: tables.width) << 16); box.u32(UInt32(clamping: tables.height) << 16)
                    }
                    trak.box("mdia") { mdia in
                        mdia.fullBox("mdhd", version: 0, flags: 0) { box in
                            box.u32(created); box.u32(created); box.u32(source.timescale); box.u32(UInt32(clamping: duration))
                            box.u16(0x55C4); box.u16(0)
                        }
                        mdia.append(source.handler)
                        mdia.box("minf") { minf in
                            minf.append(source.videoHeader)
                            minf.append(source.dataInformation)
                            minf.box("stbl") { stbl in
                                stbl.append(source.sampleDescription)
                                writeTimeToSample(&stbl)
                                writeCompositionOffsets(&stbl)
                                writeSyncSamples(&stbl)
                                writeChunks(&stbl, tables.copies.map(\.sampleCount))
                                stbl.fullBox("stsz", version: 0, flags: 0) { box in
                                    box.u32(0); box.u32(UInt32(samples.count))
                                    for sample in samples { box.u32(sample.size) }
                                }
                                writeOffsets(&stbl, chunkOffsets.video)
                            }
                        }
                    }
                }
                if let sound, let soundSource {
                    moov.box("trak") { trak in
                        trak.fullBox("tkhd", version: 0, flags: 3) { box in
                            box.u32(created); box.u32(created); box.u32(2); box.u32(0); box.u32(leadMovie &+ soundMovie)
                            box.zeros(8); box.u16(0); box.u16(0); box.u16(0x0100); box.u16(0)
                            box.identityMatrix(); box.u32(0); box.u32(0)
                        }
                        // The sound begins `leadTicks` after the first picture: an empty edit, then the whole of the sound.
                        if sound.leadTicks > 0 {
                            trak.box("edts") { edts in
                                edts.fullBox("elst", version: 0, flags: 0) { box in
                                    box.u32(2)
                                    box.u32(leadMovie); box.u32(UInt32.max); box.u32(0x0001_0000)
                                    box.u32(soundMovie); box.u32(0); box.u32(0x0001_0000)
                                }
                            }
                        }
                        trak.box("mdia") { mdia in
                            mdia.fullBox("mdhd", version: 0, flags: 0) { box in
                                box.u32(created); box.u32(created); box.u32(sound.timescale); box.u32(UInt32(clamping: soundDuration))
                                box.u16(0x55C4); box.u16(0)
                            }
                            mdia.append(soundSource.handler)
                            mdia.box("minf") { minf in
                                minf.append(soundSource.soundHeader)
                                minf.append(soundSource.dataInformation)
                                minf.box("stbl") { stbl in
                                    stbl.append(soundSource.sampleDescription)
                                    var runs: [(count: UInt32, delta: UInt32)] = []
                                    for sample in soundSamples {
                                        if let last = runs.last, last.delta == sample.duration { runs[runs.count - 1].count += 1 } else { runs.append((1, sample.duration)) }
                                    }
                                    stbl.fullBox("stts", version: 0, flags: 0) { box in
                                        box.u32(UInt32(runs.count))
                                        for run in runs { box.u32(run.count); box.u32(run.delta) }
                                    }
                                    writeChunks(&stbl, sound.copies.map(\.sampleCount))
                                    stbl.fullBox("stsz", version: 0, flags: 0) { box in
                                        box.u32(0); box.u32(UInt32(soundSamples.count))
                                        for sample in soundSamples { box.u32(sample.size) }
                                    }
                                    writeOffsets(&stbl, chunkOffsets.sound)
                                }
                            }
                        }
                    }
                }
            }
            return moov.data
        }

        func writeTimeToSample(_ stbl: inout ClipBoxBuilder) {
            var runs: [(count: UInt32, delta: UInt32)] = []
            for sample in samples {
                if let last = runs.last, last.delta == sample.duration { runs[runs.count - 1].count += 1 } else { runs.append((1, sample.duration)) }
            }
            stbl.fullBox("stts", version: 0, flags: 0) { box in
                box.u32(UInt32(runs.count))
                for run in runs { box.u32(run.count); box.u32(run.delta) }
            }
        }

        func writeCompositionOffsets(_ stbl: inout ClipBoxBuilder) {
            guard samples.contains(where: { $0.compositionOffset != 0 }) else { return }
            var runs: [(count: UInt32, offset: Int32)] = []
            for sample in samples {
                if let last = runs.last, last.offset == sample.compositionOffset { runs[runs.count - 1].count += 1 } else { runs.append((1, sample.compositionOffset)) }
            }
            let negative = samples.contains { $0.compositionOffset < 0 }
            stbl.fullBox("ctts", version: negative ? 1 : 0, flags: 0) { box in
                box.u32(UInt32(runs.count))
                for run in runs { box.u32(run.count); box.i32(run.offset) }
            }
        }

        func writeSyncSamples(_ stbl: inout ClipBoxBuilder) {
            guard samples.contains(where: { !$0.isSync }) else { return }
            let sync = samples.indices.filter { samples[$0].isSync }
            stbl.fullBox("stss", version: 0, flags: 0) { box in
                box.u32(UInt32(sync.count))
                for index in sync { box.u32(UInt32(index + 1)) }
            }
        }

        let first = build(offsets(moovSize: 0))
        let final = build(offsets(moovSize: Int64(first.count)))
        return BuiltMoov(data: final, lastChunkOffset: lastOffset)
    }
}

/// The size of a clip's file, for the planner (`ClipPlanner(archive:limits:sizing:)`).
package enum ClipSizing {
    @Sendable package static func totalBytes(of tables: ClipPartTables) throws -> Int64 { try ClipLayout.make(tables).totalBytes }
}
