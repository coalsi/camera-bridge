import BridgeEngine
import FMP4
import Foundation
import MediaCore
import Synchronization

// An archive for the NVR route tests: the files are real (the bytes `FMP4Muxer` writes for the recorder: an init segment, then `prft` + `moof`
// + `mdat` fragments), described by the `ArchiveFragment`s the store would answer. Behaviour the tests need to provoke (not ready, a read that
// stays in flight, a damaged or vanished fragment) is switched on the object.

/// Holds work in flight: `wait()` suspends the caller (no thread is blocked) until `open()`; `waiting` counts the suspended callers.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    var waiting: Int { state.withLock { $0.waiters.count } }
}

/// One recorded file: its init segment, and for each fragment the stored bytes (`prft` + `moof` + `mdat`) and what the store would say about it.
struct ArchiveFixtureFile: Sendable {
    var camera: UUID
    var segment: String
    var initData: Data
    var fragments: [ArchiveFragment]
    /// Stored bytes of each fragment, parallel to `fragments`.
    var stored: [Data]
    /// The video samples' bytes of each fragment (what a video-only answer holds in its `mdat`).
    var videoBytes: [Int]
    var hasAudio: Bool

    var fileKey: String { ArchiveIdentity.fileKey(forSegment: segment) }
}

enum ArchiveFixture {
    /// A 640x360 High@3.0 H.264 stream's parameter sets (`avc1.64001e`), as the FMP4 tests use.
    static let format: VideoFormat = {
        let sps = bytes("6764001eacb201405ff2e022000003000200000300781e2c5c90"), pps = bytes("68ebc3cb22c0")
        return VideoFormat.h264(sps: sps, pps: pps)!
    }()

    static let mimeOfTheStream = "video/mp4; codecs=\"avc1.64001e\""
    static let audioFormat = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)

    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() { data.append(UInt8(String([high, low]), radix: 16) ?? 0) }
        return data
    }

    /// A file of `fragments` fragments of `framesPerFragment` frames, `frameTicks` 90 kHz ticks apart (3,600 is 25 fps; 3,003 is 30000/1001), starting at
    /// `startMs` (the file's anchor). A group of pictures is `gopFragments` fragments long: the first fragment of each group starts with a keyframe, the
    /// others are continuation fragments (`backToKey` counts back to the keyframe's).
    static func file(camera: UUID, segment: String, startMs: Double, fragments count: Int, framesPerFragment: Int = 25, frameTicks: Int64 = 3_600,
                     gopFragments: Int = 1, audio: Bool = false) throws -> ArchiveFixtureFile {
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: audio ? audioFormat : nil, writeProducerReferenceTime: true))
        let anchor = Date(timeIntervalSince1970: startMs / 1000)
        var result = ArchiveFixtureFile(camera: camera, segment: segment, initData: muxer.initializationSegment(), fragments: [], stored: [], videoBytes: [], hasAudio: audio)
        func frame(_ number: Int) -> EncodedVideoFrame {
            let isKey = (number / framesPerFragment) % gopFragments == 0 && number % framesPerFragment == 0
            let header: UInt8 = isKey ? 0x65 : 0x41
            let units = [Data([header] + (0..<(isKey ? 200 : 40)).map { UInt8(truncatingIfNeeded: number &* 7 &+ $0) })]
            return EncodedVideoFrame(format: format, nalUnits: units, isKeyframe: isKey, pts: MediaTime(value: Int64(number) * frameTicks, timescale: 90_000),
                                     dts: nil, wallClock: anchor.addingTimeInterval(Double(Int64(number) * frameTicks) / 90_000))
        }
        for index in 0..<count {
            let numbers = (index * framesPerFragment)..<((index + 1) * framesPerFragment)
            let frames = numbers.map(frame)
            let mediaStart = Int64(index * framesPerFragment) * frameTicks
            let ticks = Int64(framesPerFragment) * frameTicks
            var audioFrames: [EncodedAudioFrame] = []
            if audio {
                // AAC frames of 1,024 samples at 16 kHz that start inside this fragment's time span.
                let first = Int((Double(mediaStart) / 90_000 * 16_000 / 1_024).rounded(.up)), last = Int((Double(mediaStart + ticks) / 90_000 * 16_000 / 1_024).rounded(.up))
                audioFrames = (first..<last).map { n in
                    EncodedAudioFrame(format: audioFormat, data: Data(repeating: UInt8(truncatingIfNeeded: n), count: 21), pts: MediaTime(value: Int64(n) * 1_024, timescale: 16_000),
                                      sampleCount: 1_024, wallClock: anchor.addingTimeInterval(Double(n) * 1_024 / 16_000))
                }
            }
            let isContinuation = index % gopFragments != 0
            let next = (index + 1 < count) ? MediaTime(value: Int64((index + 1) * framesPerFragment) * frameTicks, timescale: 90_000) : nil
            let data = try muxer.fragment(video: frames, audio: audioFrames, nextDecodeTime: next, continuation: isContinuation)
            let groupStart = index - index % gopFragments
            result.stored.append(data)
            result.videoBytes.append(frames.reduce(0) { $0 + 4 + $1.nalUnits.reduce(0) { $0 + $1.count } })
            result.fragments.append(ArchiveFragment(
                camera: camera, segment: segment, index: index, start: anchor.addingTimeInterval(Double(mediaStart) / 90_000), duration: Double(ticks) / 90_000,
                mediaStart: mediaStart, hasKeyframe: !isContinuation, gopStart: anchor.addingTimeInterval(Double(Int64(groupStart * framesPerFragment) * frameTicks) / 90_000),
                backToKey: index - groupStart, byteLength: data.count))
            // Where the video begins: after the `prft`, the `moof` and the 8-byte `mdat` header (what a clip skips).
            if let mdat = try MP4BoxReader.parse(data).first(where: { $0.type == "mdat" }) { result.fragments[result.fragments.count - 1].headerLength = mdat.payloadOffset }
        }
        return result
    }
}

/// An `ArchiveReading` over fixture files, with switches for the situations the routes must survive.
final class FakeArchiveReading: ArchiveReading {
    private struct State {
        var files: [ArchiveFixtureFile] = []
        var ready = true
        var version = 1
        var typicalGOP: TimeInterval?
        var removed: Set<String> = []
        var failures: [String: ArchiveError] = [:]
        var corrupted: Set<String> = []
        var readGate: AsyncGate?
        var activityDelay: Duration = .zero
        var activityProvider: (@Sendable (UUID, Range<Date>, Int) -> ArchiveActivity)?
        var reads: [(id: String, part: ArchiveReadPart)] = []
        var readsInFlight = 0
        var mostReadsInFlight = 0
        var activitiesInFlight = 0
        var mostActivitiesInFlight = 0
        var activityCalls: [(camera: UUID, range: Range<Date>, binCount: Int)] = []
    }

    private let state = Mutex(State())

    init(_ files: [ArchiveFixtureFile] = []) {
        state.withLock { $0.files = files }
    }

    // MARK: Switches and counters

    var files: [ArchiveFixtureFile] {
        get { state.withLock { $0.files } }
        set { state.withLock { $0.files = newValue } }
    }

    func setReady(_ ready: Bool) { state.withLock { $0.ready = ready } }
    func setTypicalGOP(_ value: TimeInterval?) { state.withLock { $0.typicalGOP = value } }
    func setReadGate(_ gate: AsyncGate?) { state.withLock { $0.readGate = gate } }
    func setActivityDelay(_ delay: Duration) { state.withLock { $0.activityDelay = delay } }
    func setActivityProvider(_ provider: (@Sendable (UUID, Range<Date>, Int) -> ArchiveActivity)?) { state.withLock { $0.activityProvider = provider } }
    func bumpCatalogVersion() { state.withLock { $0.version += 1 } }

    /// Retention removed this fragment: lookups by id answer nil and reads fail with `fileGone`.
    func remove(_ id: String) { state.withLock { _ = $0.removed.insert(id) } }
    func fail(_ id: String, with error: ArchiveError) { state.withLock { $0.failures[id] = error } }
    /// Reads of this fragment return its bytes cut in half (a damaged file).
    func corrupt(_ id: String) { state.withLock { _ = $0.corrupted.insert(id) } }

    var reads: [(id: String, part: ArchiveReadPart)] { state.withLock { $0.reads } }
    var mostReadsInFlight: Int { state.withLock { $0.mostReadsInFlight } }
    var readsInFlight: Int { state.withLock { $0.readsInFlight } }
    var mostActivitiesInFlight: Int { state.withLock { $0.mostActivitiesInFlight } }
    var activityCalls: [(camera: UUID, range: Range<Date>, binCount: Int)] { state.withLock { $0.activityCalls } }

    // MARK: ArchiveReading

    var isReady: Bool { state.withLock { $0.ready } }
    var catalogVersion: Int { state.withLock { $0.version } }

    private func all(_ camera: UUID, _ state: State) -> [ArchiveFragment] {
        state.files.filter { $0.camera == camera }.flatMap(\.fragments).filter { !state.removed.contains($0.id) }
    }

    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? {
        state.withLock { state in all(camera, state).filter { $0.start <= time && time < $0.end }.max { $0.start < $1.start } }
    }

    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? {
        state.withLock { state in all(camera, state).filter { $0.start > time }.min { $0.start < $1.start } }
    }

    func fragment(camera: UUID, id: String) async -> ArchiveFragment? {
        state.withLock { state in all(camera, state).first { $0.id == id } }
    }

    func extent(camera: UUID) -> ArchiveExtent? {
        state.withLock { state in
            let fragments = all(camera, state)
            guard let oldest = fragments.map(\.start).min(), let newest = fragments.map(\.end).max() else { return nil }
            return ArchiveExtent(oldest: oldest, newest: newest, typicalGOP: state.typicalGOP)
        }
    }

    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
        let (delay, provider) = state.withLock { state -> (Duration, (@Sendable (UUID, Range<Date>, Int) -> ArchiveActivity)?) in
            state.activityCalls.append((camera, range, binCount))
            state.activitiesInFlight += 1
            state.mostActivitiesInFlight = max(state.mostActivitiesInFlight, state.activitiesInFlight)
            return (state.activityDelay, state.activityProvider)
        }
        defer { state.withLock { $0.activitiesInFlight -= 1 } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let provider { return provider(camera, range, binCount) }
        let width = range.upperBound.timeIntervalSince(range.lowerBound) / Double(binCount)
        let fragments = state.withLock { all(camera, $0) }
        let bins = (0..<binCount).map { index -> ArchiveActivity.Bin in
            let start = range.lowerBound.addingTimeInterval(Double(index) * width), end = start.addingTimeInterval(width)
            let covered = fragments.reduce(0.0) { $0 + max(0, min($1.end, end).timeIntervalSince(max($1.start, start))) }
            return ArchiveActivity.Bin(coverage: min(1, covered / width), level: covered > 0 ? 1_000 : 0, peak: covered > 0 ? 2_000 : 0)
        }
        return ArchiveActivity(start: range.lowerBound, binDuration: width, bins: bins, typical: 1_000, isComplete: true)
    }

    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        let gate = state.withLock { state -> AsyncGate? in
            state.reads.append((fragment.id, part))
            state.readsInFlight += 1
            state.mostReadsInFlight = max(state.mostReadsInFlight, state.readsInFlight)
            return state.readGate
        }
        defer { state.withLock { $0.readsInFlight -= 1 } }
        if let gate { await gate.wait() }
        let (file, failure, removed, damaged) = state.withLock { state in
            (state.files.first { $0.segment == fragment.segment }, state.failures[fragment.id], state.removed.contains(fragment.id), state.corrupted.contains(fragment.id))
        }
        if let failure { throw failure }
        guard let file, !removed, fragment.index < file.stored.count else { throw ArchiveError.fileGone }
        switch part {
        case .initialization: return damaged ? file.initData.prefix(file.initData.count / 2) : file.initData
        case .fragment: return damaged ? file.stored[fragment.index].prefix(file.stored[fragment.index].count / 2) : file.stored[fragment.index]
        case .keyframe:
            guard fragment.hasKeyframe else { throw ArchiveError.noKeyframe }
            return file.stored[fragment.index]
        case .header:
            // `prft` + `moof` + the `mdat` header: everything before the first byte of the `mdat` payload, where the video begins.
            let stored = file.stored[fragment.index]
            guard let mdat = try MP4BoxReader.parse(stored).first(where: { $0.type == "mdat" }) else { throw ArchiveError.unreadable("The fixture fragment has no mdat.") }
            let header = stored.prefix(mdat.payloadOffset)
            return damaged ? header.prefix(header.count / 2) : header
        }
    }
}
