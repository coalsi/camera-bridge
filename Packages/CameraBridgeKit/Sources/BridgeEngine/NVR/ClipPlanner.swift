import FMP4
import Foundation
import Synchronization

/// The dry run of an export (export-clip spec 3.3). From a camera, a start and an end it reads the initialization segment of every file in the
/// range once and the header of every fragment in it (`ArchiveReadPart.header`: `prft` + `moof` + the 8-byte `mdat` header, a few hundred
/// bytes), never a picture, and works out everything `ClipWriter` needs: the clip's parts, the sample tables of each (`ClipPartTables`), the
/// gaps that are frozen or skipped, and the exact size of each part.
///
/// The rules, in the order the code applies them:
/// 1. The range is clamped to the camera's `extent`; less than a second of it is `nothingRecorded`, an archive that is still loading `notReady`.
/// 2. The clip begins at the first sample of the fragment that holds the governing key picture of the fragment that contains the start (or of
///    the first fragment after it when the start falls in a gap): a group of pictures never spans files, so `backToKey` fragments back.
/// 3. Fragments are walked with `fragment(startingAfter:)` while they start before the end. The last sample of the clip is the last one in
///    decode order whose presentation time (the viewer's: the fragment's start plus the durations before the sample plus its composition
///    offset) is before the end; the last copy is a prefix of its fragment's pictures.
/// 4. Between two consecutive fragments the wall-clock difference decides: under `limits.continuity` either way the media simply continues;
///    from there to `limits.maxHold` the previous sample is lengthened by the gap (the picture freezes); beyond that the gap is skipped and
///    reported; an overlap of `limits.continuity` or more trims the earlier fragment where the later one starts.
/// 5. A file whose initialization segment differs from the part's ends the part and starts the next one.
/// 6. Composition offsets that are all equal in a part are subtracted; offsets that vary are kept.
/// 7. More than `limits.maxSecondsPerCamera` seconds of media is `tooLong`; the sizes `sizing` gives, added up, above `limits.maxTotalBytes` are
///    `tooLarge`.
/// 8. `ArchiveError`s become `ClipError`s; the reads run at `.utility` priority and stop at the first read after the caller cancels.
/// 9. Sound (the recordings' AAC) goes with the pictures: each fragment's sound is placed where the fragment's own timing puts it against its first
///    picture, and lined up again at every fragment (a frozen or skipped gap lengthens the sound sample before it, sound that would overlap is
///    dropped), so it never drifts. It starts at the first picture or later (an empty edit) and ends with the last picture.
package struct ClipPlanner: Sendable {
    private let archive: any ArchiveReading
    private let limits: ClipLimits
    private let sizing: @Sendable (ClipPartTables) throws -> Int64

    /// `sizing` gives the exact size in bytes of the file `ClipWriter` writes for a part (`ClipSizing.totalBytes(of:)`); tests pass their own.
    package init(archive: any ArchiveReading, limits: ClipLimits, sizing: @escaping @Sendable (ClipPartTables) throws -> Int64) {
        self.archive = archive
        self.limits = limits
        self.sizing = sizing
    }

    /// Throws only `ClipError`.
    ///
    /// The work runs in a task of its own at `.utility` priority, so that a person who is watching is served first. Its result comes back through a
    /// continuation and not through `await task.value`: a task that is awaited by a higher-priority one is raised to that priority (Swift's priority
    /// escalation), which would put the reads at the priority of the screen or the request that asked.
    package func plan(_ request: ClipRequest) async throws -> ClipPlan {
        if Task.isCancelled { throw ClipError.cancelled }
        let work = RunningWork()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClipPlan, any Error>) in
                work.start(Task.detached(priority: .utility) {
                    do {
                        continuation.resume(returning: try await self.run(request))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                })
            }
        } onCancel: {
            work.cancel()
        }
    }

    /// The task that does a plan, and whether the caller has cancelled it before it existed.
    private final class RunningWork: Sendable {
        private let state = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

        func start(_ task: Task<Void, Never>) {
            let cancelled = state.withLock { state -> Bool in
                state.task = task
                return state.cancelled
            }
            if cancelled { task.cancel() }
        }

        func cancel() {
            let task = state.withLock { state -> Task<Void, Never>? in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    /// Shorter than this is not a clip.
    private static let minimumMicros: Int64 = 1_000_000

    private func run(_ request: ClipRequest) async throws -> ClipPlan {
        // 1. The range.
        guard archive.isReady else { throw ClipError.notReady }
        guard let extent = archive.extent(camera: request.camera) else { throw ClipError.nothingRecorded }
        let from = max(ArchiveTime.micros(request.start), ArchiveTime.micros(extent.oldest))
        let until = min(ArchiveTime.micros(request.end), ArchiveTime.micros(extent.newest))
        guard until - from >= Self.minimumMicros else { throw ClipError.nothingRecorded }

        // 2. The first fragment and the one that holds its key picture.
        let fromDate = Date(timeIntervalSince1970: Double(from) / 1_000_000)
        var first = await archive.fragment(camera: request.camera, containing: fromDate)
        if first == nil, let later = await archive.fragment(camera: request.camera, startingAfter: fromDate), ArchiveTime.micros(later.start) < until {
            first = later
        }
        guard var key = first else { throw ClipError.nothingRecorded }
        if key.backToKey > 0 {
            let id = ArchiveIdentity.fragmentID(fileKey: key.fileKey, index: max(0, key.index - key.backToKey))
            guard let found = await archive.fragment(camera: request.camera, id: id) else { throw ClipError.driveGone }
            key = found
        }

        // 3. The walk.
        var reader = FragmentReader(archive: archive)
        var previous = try await reader.load(key)
        var assembly = Assembly(limits: limits, first: previous)
        while let next = await archive.fragment(camera: request.camera, startingAfter: previous.fragment.start), ArchiveTime.micros(next.start) < until {
            let loaded = try await reader.load(next)
            try assembly.join(previous, to: loaded)
            previous = loaded
        }
        try assembly.finish(previous, before: until)
        return try build(request, assembly, from: from)
    }

    // MARK: Reading

    /// A fragment as the planner needs it: where it is, the initialization segment of its file and the video samples its header lists.
    private struct Loaded {
        var fragment: ArchiveFragment
        var initialization: Data
        var info: FMP4InitInfo
        var samples: [TrackSample]
        var media: FragmentMedia
    }

    /// The decode times and the sound of a fragment: its video `tfdt` (90 kHz), its sound samples, their `tfdt` (the sound's timescale) and where
    /// their bytes start in the fragment's `.fragment` read.
    private struct FragmentMedia {
        var videoBase: UInt64
        var sound: [TrackSample] = []
        var soundBase: UInt64 = 0
        var soundOffset: Int = 0
    }

    /// Reads and parses; remembers the initialization segment of each file (one read per file). Every failure leaves it as a `ClipError`.
    private struct FragmentReader {
        let archive: any ArchiveReading
        private var inits: [String: (data: Data, info: FMP4InitInfo)] = [:]
        private var reads = 0

        init(archive: any ArchiveReading) {
            self.archive = archive
        }

        mutating func load(_ fragment: ArchiveFragment) async throws -> Loaded {
            do {
                let file = try await initialization(of: fragment)
                let header = try await read(fragment, .header)
                let (samples, media) = try Self.samples(of: header, in: fragment, info: file.info)
                return Loaded(fragment: fragment, initialization: file.data, info: file.info, samples: samples, media: media)
            } catch {
                throw clipError(error, at: fragment)
            }
        }

        private mutating func initialization(of fragment: ArchiveFragment) async throws -> (data: Data, info: FMP4InitInfo) {
            if let known = inits[fragment.fileKey] { return known }
            let data = try await read(fragment, .initialization)
            let info = try FMP4InitReader.parse(data)
            // Every duration in the tables is a tick of 90 kHz.
            guard info.videoTimescale == ArchiveConstants.videoTimescale else { throw FMP4Error.invalidTimescale(info.videoTimescale) }
            let file = (data: Data(data.prefix(info.byteCount)), info: info)
            inits[fragment.fileKey] = file
            return file
        }

        /// Counts the read; none starts once the caller has cancelled.
        private mutating func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
            if Task.isCancelled { throw ClipError.cancelled }
            reads += 1
            return try await archive.read(fragment, part)
        }

        /// A drive that does not answer the very first read is gone; the same answer later in the range is a recording that cannot be read there.
        private func clipError(_ error: any Error, at fragment: ArchiveFragment) -> ClipError {
            switch error {
            case let error as ClipError: error
            case is CancellationError: .cancelled
            case ArchiveError.fileGone, ArchiveError.timedOut: reads <= 1 ? .driveGone : .damaged(at: fragment.start)
            default: .damaged(at: fragment.start)
            }
        }

        /// The video samples of a header read: `[prft] moof [mdat header]`, cut by the size fields of its boxes, and its sound.
        static func samples(of header: Data, in fragment: ArchiveFragment, info: FMP4InitInfo) throws -> ([TrackSample], FragmentMedia) {
            func box(at offset: Int) throws -> (size: Int, type: String) {
                guard offset >= 0, offset <= header.count - 8 else { throw FMP4Error.malformedBox(offset: offset, reason: "truncated box header") }
                var size = 0
                for index in 0..<4 { size = size << 8 | Int(header[header.startIndex + offset + index]) }
                let type = String(decoding: header[header.startIndex + offset + 4..<header.startIndex + offset + 8], as: UTF8.self)
                return (size, type)
            }
            var position = 0
            var current = try box(at: 0)
            if current.type == "prft" {
                guard current.size >= 8 else { throw FMP4Error.malformedBox(offset: 0, reason: "prft size") }
                position = current.size
                current = try box(at: position)
            }
            guard current.type == "moof", current.size >= 8, current.size <= header.count - position - 8 else {
                throw FMP4Error.malformedBox(offset: position, reason: "no moof where the header says")
            }
            let moof = header.subdata(in: header.startIndex + position..<header.startIndex + position + current.size)
            let mdat = try box(at: position + current.size)
            guard mdat.type == "mdat", mdat.size >= 8 else { throw FMP4Error.malformedBox(offset: position + current.size, reason: "no mdat header after the moof") }
            let parsed = try MovieFragmentReader.parse(moof: moof, mdatPayloadSize: mdat.size - 8)
            guard let video = parsed.tracks.first(where: { $0.trackID == info.videoTrackID }), !video.samples.isEmpty else {
                throw FMP4Error.malformedBox(offset: position, reason: "no video samples")
            }
            // The copies start at `headerLength` and take the video bytes in a row: the index must agree with the header about where the video starts
            // and the fragment the index describes must be long enough to hold it.
            let videoBytes = video.samples.reduce(0) { $0 + Int($1.size) }
            guard position + video.dataOffset == fragment.headerLength, fragment.headerLength + videoBytes <= fragment.byteLength else {
                throw FMP4Error.malformedBox(offset: position, reason: "the video samples are not where the index says")
            }
            var media = FragmentMedia(videoBase: video.baseDecodeTime)
            // Sound the clip can carry: the AAC track the recorder writes, its bytes inside the fragment. Anything else leaves the clip silent there.
            if info.audio?.codec == .aac, let trackID = info.audioTrackID, let sound = parsed.tracks.first(where: { $0.trackID == trackID }), !sound.samples.isEmpty {
                let soundBytes = sound.samples.reduce(0) { $0 + Int($1.size) }
                let start = position + sound.dataOffset
                if start >= fragment.headerLength, start + soundBytes <= fragment.byteLength {
                    media.sound = sound.samples
                    media.soundBase = sound.baseDecodeTime
                    media.soundOffset = start
                }
            }
            return (video.samples, media)
        }
    }

    // MARK: Assembling

    /// One output file in the making.
    private struct PartBuilder {
        var initialization: Data
        var width: Int
        var height: Int
        var samples: [ClipSample] = []
        var copies: [ClipCopy] = []
        /// Wall-clock time in 90 kHz ticks since 1970 of the first picture and of the end of the last one.
        var startTicks: Int64 = 0
        var endTicks: Int64 = 0
        /// The part's pictures so far, in 90 kHz ticks of the clip (holds included).
        var videoTicks: Int64 = 0
        /// The sound so far, in ticks of its timescale on the clip's time line.
        var soundSamples: [ClipSoundSample] = []
        var soundCopies: [ClipCopy] = []
        var soundFollows: [Int] = []
        var soundLead: Int64?
        var soundEnd: Int64 = 0
        let soundScale: Int64

        init(_ loaded: Loaded) {
            initialization = loaded.initialization
            width = loaded.info.video.width
            height = loaded.info.video.height
            soundScale = loaded.info.audio?.codec == .aac ? Int64(max(1, loaded.info.audio?.sampleRate ?? 0)) : 0
        }

        var sound: ClipSoundTables? {
            guard let soundLead, !soundSamples.isEmpty, soundScale > 0, let scale = UInt32(exactly: soundScale) else { return nil }
            return ClipSoundTables(samples: soundSamples, copies: soundCopies, follows: soundFollows, leadTicks: soundLead, timescale: scale)
        }

        /// Adds the sound of `loaded` that plays with its first `keptVideo` ticks of pictures, which start at `videoStart` on the clip's time line.
        mutating func addSound(_ loaded: Loaded, videoStart: Int64, keptVideo: Int64) {
            let scale = soundScale
            let media = loaded.media
            guard scale > 0, !media.sound.isEmpty, !copies.isEmpty else { return }
            // Where the fragment's own timing puts its first sound sample against its first picture, then on the clip's time line.
            let offset = Int64(media.soundBase) - Int64(media.videoBase) * scale / 90_000
            let firstStart = videoStart * scale / 90_000 + offset
            let end = (videoStart + keptVideo) * scale / 90_000
            var index = 0
            var start = firstStart
            var skipped = 0
            if soundLead == nil {
                while index < media.sound.count, start < 0 { start += Int64(media.sound[index].duration); skipped += Int(media.sound[index].size); index += 1 }
            } else {
                var delta = start - soundEnd
                while delta < 0, index < media.sound.count, delta + Int64(media.sound[index].duration) <= 0 {
                    delta += Int64(media.sound[index].duration)
                    start += Int64(media.sound[index].duration)
                    skipped += Int(media.sound[index].size)
                    index += 1
                }
                if let last = soundSamples.indices.last {
                    let lengthened = Int64(soundSamples[last].duration) + delta
                    if delta != 0, lengthened > 0, let fits = UInt32(exactly: lengthened) { soundSamples[last].duration = fits; start = soundEnd + delta }
                    else if delta < 0 { start = soundEnd }
                }
            }
            var kept: [ClipSoundSample] = []
            var bytes = 0
            var cursor = start
            while index < media.sound.count, cursor < end {
                let sample = media.sound[index]
                kept.append(ClipSoundSample(size: sample.size, duration: sample.duration))
                bytes += Int(sample.size)
                cursor += Int64(sample.duration)
                index += 1
            }
            guard !kept.isEmpty, bytes > 0 else { return }
            if soundLead == nil { soundLead = max(0, start); soundEnd = max(0, start) } else { soundEnd = start }
            soundCopies.append(ClipCopy(fragment: loaded.fragment, skipBytes: media.soundOffset + skipped, length: bytes,
                                        firstSample: soundSamples.count, sampleCount: kept.count))
            soundFollows.append(copies.count - 1)
            soundSamples += kept
            soundEnd += kept.reduce(Int64(0)) { $0 + Int64($1.duration) }
        }
    }

    /// The parts, the gaps and the running totals; fragments are added in time order.
    private struct Assembly {
        private let continuity: Int64
        private let maxHold: Int64
        private let maxTicks: Int64
        private let maxSeconds: Int
        private(set) var parts: [PartBuilder]
        private(set) var gaps: [ClipGap] = []
        private(set) var soundOmitted = false
        /// Ticks of media in the parts so far, holds included.
        private var ticks: Int64 = 0

        init(limits: ClipLimits, first: Loaded) {
            continuity = Self.micros(limits.continuity)
            maxHold = Self.micros(limits.maxHold)
            let (product, overflow) = Int64(limits.maxSecondsPerCamera).multipliedReportingOverflow(by: 90_000)
            maxTicks = overflow ? .max : max(0, product)
            maxSeconds = limits.maxSecondsPerCamera
            parts = [PartBuilder(first)]
            soundOmitted = first.info.audio != nil
        }

        private static func micros(_ seconds: TimeInterval) -> Int64 {
            Int64((seconds * 1_000_000).rounded())
        }

        /// The boundary between `previous` (not yet added) and `next`, which follows it in the walk.
        mutating func join(_ previous: Loaded, to next: Loaded) throws {
            let gap = ArchiveTime.micros(next.fragment.start) - ArchiveTime.micros(previous.fragment.end)     // microseconds; negative: an overlap
            let overlap = gap <= -continuity
            add(previous, keeping: overlap ? Self.count(of: previous, before: ArchiveTime.micros(next.fragment.start)) : previous.samples.count)
            soundOmitted = soundOmitted || next.info.audio != nil
            let sameFile = next.initialization == parts[parts.count - 1].initialization
            if gap >= continuity {
                var held = false
                if sameFile && gap <= maxHold { held = hold(gap) }
                gaps.append(ClipGap(from: previous.fragment.end, to: next.fragment.start, held: held))
            }
            if !sameFile { parts.append(PartBuilder(next)) }
            try checkLength()
        }

        /// Lengthens the last picture by `gap` microseconds; false when it would not fit its 32 bits.
        private mutating func hold(_ gap: Int64) -> Bool {
            let extra = gap * 9 / 100                                                  // microseconds to 90 kHz ticks
            let index = parts.count - 1
            guard let last = parts[index].samples.last, let lengthened = UInt32(exactly: Int64(last.duration) + extra) else { return false }
            parts[index].samples[parts[index].samples.count - 1].duration = lengthened
            parts[index].endTicks += extra
            parts[index].videoTicks += extra
            ticks += extra
            return true
        }

        /// The last fragment of the walk, cut where the clip ends (`end`, microseconds).
        mutating func finish(_ last: Loaded, before end: Int64) throws {
            add(last, keeping: Self.count(of: last, before: end))
            try checkLength()
            guard parts.contains(where: { !$0.samples.isEmpty }) else { throw ClipError.nothingRecorded }
        }

        private mutating func add(_ loaded: Loaded, keeping count: Int) {
            guard count > 0 else { return }
            let kept = loaded.samples.prefix(count)
            let start = ArchiveTime.ms(loaded.fragment.start) * 90
            let duration = kept.reduce(Int64(0)) { $0 + Int64($1.duration) }
            let index = parts.count - 1
            if parts[index].samples.isEmpty { parts[index].startTicks = start }
            parts[index].copies.append(ClipCopy(fragment: loaded.fragment, skipBytes: loaded.fragment.headerLength, length: kept.reduce(0) { $0 + Int($1.size) },
                                                firstSample: parts[index].samples.count, sampleCount: count))
            parts[index].samples += kept.map { ClipSample(size: $0.size, duration: $0.duration, compositionOffset: $0.compositionOffset, isSync: $0.isSync) }
            parts[index].endTicks = start + duration
            let videoStart = parts[index].videoTicks
            parts[index].videoTicks += duration
            parts[index].addSound(loaded, videoStart: videoStart, keptVideo: duration)
            ticks += duration
        }

        private func checkLength() throws {
            if ticks > maxTicks { throw ClipError.tooLong(maxSeconds: maxSeconds) }
        }

        /// How many of the first samples of `loaded` the clip keeps when it stops before `cutoff` (microseconds): up to the last one, in decode order,
        /// whose presentation time is before it. Presentation is the viewer's: the fragment's start plus the durations before the sample plus its
        /// composition offset, all in 90 kHz ticks (one tick is 100/9 microseconds, so the comparison is made in ninths of a microsecond).
        static func count(of loaded: Loaded, before cutoff: Int64) -> Int {
            let origin = ArchiveTime.ms(loaded.fragment.start) * 90
            var decode: Int64 = 0
            var count = 0
            for (index, sample) in loaded.samples.enumerated() {
                if (origin + decode + Int64(sample.compositionOffset)) * 100 < cutoff * 9 { count = index + 1 }
                decode += Int64(sample.duration)
            }
            return count
        }
    }

    // MARK: Building the plan

    private func build(_ request: ClipRequest, _ assembly: Assembly, from: Int64) throws -> ClipPlan {
        let built = assembly.parts.filter { !$0.samples.isEmpty }
        var parts: [ClipPart] = []
        var tables: [ClipPartTables] = []
        var total: Int64 = 0
        for (offset, part) in built.enumerated() {
            let start = Date(timeIntervalSince1970: Double(part.startTicks) / 90_000)
            let end = Date(timeIntervalSince1970: Double(part.endTicks) / 90_000)
            let table = ClipPartTables(initialization: part.initialization, samples: Self.withoutSharedOffset(part.samples), copies: part.copies,
                                       wallStart: start, width: part.width, height: part.height, sound: part.sound)
            let bytes: Int64
            do {
                bytes = try sizing(table)
            } catch let error as ClipError {
                throw error
            } catch is CancellationError {
                throw ClipError.cancelled
            } catch {
                throw ClipError.damaged(at: start)
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow, sum <= limits.maxTotalBytes else { throw ClipError.tooLarge(maxBytes: limits.maxTotalBytes) }
            total = sum
            let leadIn = Double(max(0, from - part.startTicks * 100 / 9)) / 1_000_000
            parts.append(ClipPart(index: offset + 1, count: built.count, start: start, end: end, leadIn: leadIn, byteCount: bytes,
                                  sampleCount: part.samples.count,
                                  fileName: ClipFileName.part(cameraName: request.cameraName, start: start, end: end, partIndex: offset + 1,
                                                              partCount: built.count, timeZone: request.timeZone)))
            tables.append(table)
        }
        // Sound is omitted only when the recordings had some and no part could carry it.
        let omitted = assembly.soundOmitted && built.allSatisfy { $0.sound == nil }
        return ClipPlan(request: request, parts: parts, gaps: assembly.gaps, soundOmitted: omitted, tables: tables)
    }

    /// Offsets that are all equal become none: the part's pictures are shown from its start instead of that long after it. Offsets that differ
    /// are the camera's reordering and are kept.
    private static func withoutSharedOffset(_ samples: [ClipSample]) -> [ClipSample] {
        guard let shared = samples.first?.compositionOffset, shared != 0, samples.allSatisfy({ $0.compositionOffset == shared }) else { return samples }
        return samples.map { sample in
            var sample = sample
            sample.compositionOffset = 0
            return sample
        }
    }
}
