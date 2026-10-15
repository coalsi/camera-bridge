import FMP4
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// One fragment of a fixture file. The defaults are what the recorder writes for the owner's Hikvision cameras: 50 pictures 4,500 ticks (50 ms)
/// apart, 2.5 s. A key picture is 104 bytes (100 and the 4-byte length prefix), any other picture 44.
struct PlannerFixtureFragment: Sendable {
    var frames = 50
    /// Ticks (90 kHz) between two pictures: 4,500 is 20 pictures a second, 7,200 is 12.5.
    var ticks: Int64 = 4_500
    /// False makes a continuation fragment: the middle of a long group of pictures.
    var startsOnKey = true
    var keyBytes = 100
    var deltaBytes = 40
    /// `pts - dts` of picture `i` in ticks.
    var compositionOffset: @Sendable (Int) -> Int64 = { _ in 0 }

    /// The 2.5 s of 20 pictures a second that start a group of pictures / continue one.
    static let key = PlannerFixtureFragment()
    static let continuation = PlannerFixtureFragment(startsOnKey: false)
}

/// A file as the recorder writes it, described by what the planner is meant to see.
struct PlannerFixtureFile: Sendable {
    /// The file's name inside the day folder: "13-00-00".
    var name = "13-00-00"
    /// The file's anchor, Unix epoch milliseconds.
    var startMs = PlannerFixture.t0
    /// Six fragments of 2.5 s (15 s); the third and fourth continue the group of pictures of the second (`backToKey` 0, 0, 1, 2, 0, 0).
    var fragments: [PlannerFixtureFragment] = [.key, .key, .continuation, .continuation, .key, .key]
    var format = ArchiveMediaFixtures.smallH264Format
    var audio = false
    var videoTimescale: Int32 = 90_000
    /// Added to the `headerLength` and to the `length` the index records for every fragment (an index that disagrees with the file).
    var headerLengthShift = 0
    var lengthShift = 0
}

enum PlannerFixture {
    static let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// The anchor of the first file of every test, Unix epoch milliseconds.
    static let t0: Int64 = 1_760_101_200_000

    /// The time `offsetMs` milliseconds after `t0`.
    static func at(_ offsetMs: Int64) -> Date { ArchiveTime.date(ms: t0 + offsetMs) }

    /// Whole milliseconds since `t0` of a date.
    static func offset(_ date: Date) -> Int64 { ArchiveTime.ms(date) - t0 }

    static func request(_ fromMs: Int64, _ toMs: Int64, camera: UUID = PlannerFixture.camera) -> ClipRequest {
        ClipRequest(camera: camera, cameraName: "Driveway", start: at(fromMs), end: at(toMs), timeZone: TimeZone(identifier: "UTC")!)
    }

    /// The size a part is said to have: the bytes its copies take plus 100.
    static let sizing: @Sendable (ClipPartTables) throws -> Int64 = { tables in Int64(tables.copies.reduce(0) { $0 + $1.length }) + 100 }

    static func planner(_ archive: PlannerFixtureArchive, limits: ClipLimits = .standard,
                        sizing: @escaping @Sendable (ClipPartTables) throws -> Int64 = PlannerFixture.sizing) -> ClipPlanner {
        ClipPlanner(archive: archive, limits: limits, sizing: sizing)
    }
}

/// An `ArchiveReading` over fixture files whose lookups are the store's own (`CatalogState`: a later file wins an overlap, fragments abut inside a
/// file) and whose bytes are the ones `FMP4Muxer` writes. Every read is recorded; a test can fail a read, make it wait, or damage its bytes.
final class PlannerFixtureArchive: ArchiveReading, Sendable {
    struct Read: Sendable, Equatable {
        var fragment: String
        var part: ArchiveReadPart
        var priority: TaskPriority
    }

    /// What `add` made of a file.
    struct Built: Sendable {
        var file: PlannerFixtureFile
        var segment: String
        var fileKey: String
        var initData: Data
        /// `prft` + `moof` + `mdat` of each fragment, as the muxer wrote them.
        var fragments: [Data]
        var records: [CBIndexFragmentRecord]

        func id(_ index: Int) -> String { ArchiveIdentity.fragmentID(fileKey: fileKey, index: index) }
    }

    /// Runs at the start of every read, with its number (the first read of the archive is 1). It may throw, wait, or cancel the task it runs in.
    typealias Hook = @Sendable (_ number: Int, _ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Void
    /// Changes the bytes a read returns.
    typealias Tamper = @Sendable (_ fragment: ArchiveFragment, _ part: ArchiveReadPart, _ data: Data) -> Data

    private struct Stored: Sendable {
        var initData: Data
        var fragments: [Data]
        var headerLengths: [Int]
    }

    private struct State: Sendable {
        var catalog = CatalogState()
        var stored: [String: Stored] = [:]
        var ready = true
        /// Ids that `fragment(camera:id:)` no longer finds (retention took them).
        var hidden: Set<String> = []
        var reads: [Read] = []
        var hook: Hook?
        var tamper: Tamper?
    }

    private let state = Mutex(State())

    var isReady: Bool { state.withLock { $0.ready } }
    var catalogVersion: Int { 1 }
    var reads: [Read] { state.withLock { $0.reads } }

    func setReady(_ ready: Bool) { state.withLock { $0.ready = ready } }
    /// Lookups by id stop finding this fragment (the other lookups still do).
    func hide(_ id: String) { state.withLock { _ = $0.hidden.insert(id) } }
    func setHook(_ hook: Hook?) { state.withLock { $0.hook = hook } }
    func setTamper(_ tamper: Tamper?) { state.withLock { $0.tamper = tamper } }

    /// The reads of one kind, in order.
    func reads(of part: ArchiveReadPart) -> [String] { reads.filter { $0.part == part }.map(\.fragment) }

    // MARK: Files

    @discardableResult
    func add(_ file: PlannerFixtureFile, camera: UUID = PlannerFixture.camera) throws -> Built {
        let audioFormat = AudioFormat.aacLC(sampleRate: 16_000, channels: 1)
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: file.format, audio: file.audio ? audioFormat : nil,
                                                                   videoTimescale: file.videoTimescale, writeProducerReferenceTime: true))
        let initData = muxer.initializationSegment()
        var size = initData.count
        var fragments: [Data] = []
        var records: [CBIndexFragmentRecord] = []
        var headerLengths: [Int] = []
        var ticks: Int64 = 0
        for (position, fragment) in file.fragments.enumerated() {
            let wall = Date(timeIntervalSince1970: Double(file.startMs + (ticks + 45) / 90) / 1_000)
            let frames = (0..<fragment.frames).map { index -> EncodedVideoFrame in
                let isKey = index == 0 && fragment.startsOnKey
                let decode = ticks + Int64(index) * fragment.ticks
                let offset = fragment.compositionOffset(index)
                return EncodedVideoFrame(format: file.format, nalUnits: [Self.nal(isKey: isKey, bytes: isKey ? fragment.keyBytes : fragment.deltaBytes, seed: decode)],
                                         isKeyframe: isKey, pts: MediaTime(value: decode + offset, timescale: 90_000),
                                         dts: offset == 0 ? nil : MediaTime(value: decode, timescale: 90_000),
                                         wallClock: wall.addingTimeInterval(Double(index) * Double(fragment.ticks) / 90_000))
            }
            let next = ticks + Int64(fragment.frames) * fragment.ticks
            // Sound on the same clock: 1024-sample frames at 16 kHz.
            var audio: [EncodedAudioFrame] = []
            if file.audio {
                let from = Int((ticks * 16_000 / 90_000 + 1_023) / 1_024), to = Int((next * 16_000 / 90_000 + 1_023) / 1_024)
                audio = (from..<to).map { index in
                    EncodedAudioFrame(format: audioFormat, data: Data(repeating: UInt8(truncatingIfNeeded: index), count: 20),
                                      pts: MediaTime(value: Int64(index) * 1_024, timescale: 16_000), sampleCount: 1_024, wallClock: wall)
                }
            }
            let data = try muxer.fragment(video: frames, audio: audio, nextDecodeTime: position + 1 < file.fragments.count ? MediaTime(value: next, timescale: 90_000) : nil,
                                          continuation: !fragment.startsOnKey)
            let measurement = try FragmentIndexer.measure(data)
            var record = try FragmentIndexer.record(measurement, offset: UInt64(size), firstMediaTime: 0, previousBackToKey: records.last.map { Int($0.backToKey) })
            record.headerLength = UInt32(Int(record.headerLength) + file.headerLengthShift)
            record.length = UInt32(Int(record.length) + file.lengthShift)
            records.append(record)
            headerLengths.append(measurement.headerLength)
            fragments.append(data)
            size += data.count
            ticks = next
        }
        return register(file, camera: camera, initData: initData, fragments: fragments, records: records, headerLengths: headerLengths, size: size)
    }

    /// A file made of bytes recorded for real: an initialization segment and `prft` + `moof` + `mdat` fragments in order (the opt-in real-data test).
    @discardableResult
    func addRecorded(initData: Data, fragments: [Data], name: String = "13-00-00", startMs: Int64 = PlannerFixture.t0, hasAudio: Bool = false,
                     camera: UUID = PlannerFixture.camera) throws -> Built {
        var records: [CBIndexFragmentRecord] = []
        var headerLengths: [Int] = []
        var size = initData.count
        for data in fragments {
            let measurement = try FragmentIndexer.measure(data)
            records.append(try FragmentIndexer.record(measurement, offset: UInt64(size), firstMediaTime: 0, previousBackToKey: records.last.map { Int($0.backToKey) }))
            headerLengths.append(measurement.headerLength)
            size += data.count
        }
        var file = PlannerFixtureFile()
        file.name = name
        file.startMs = startMs
        file.audio = hasAudio
        return register(file, camera: camera, initData: initData, fragments: fragments, records: records, headerLengths: headerLengths, size: size)
    }

    private func register(_ file: PlannerFixtureFile, camera: UUID, initData: Data, fragments: [Data], records: [CBIndexFragmentRecord],
                          headerLengths: [Int], size: Int) -> Built {
        let segment = ArchiveLayout.segment(cameraDirectory: camera.uuidString, dateDirectory: "2025-10-10", baseName: file.name)
        let catalogFile = CatalogFile(camera: camera, segment: segment, startMs: file.startMs, endMs: FragmentIndexer.endWallMs(startWallMs: file.startMs, records: records),
                                      initLength: UInt32(initData.count), flags: file.audio ? CBIndexFormat.flagHasAudio : 0, mp4Bytes: UInt64(size),
                                      sidecarBytes: 0, fragmentCount: records.count, rollups: [], isOpen: false)
        let built = Built(file: file, segment: segment, fileKey: ArchiveIdentity.fileKey(forSegment: segment), initData: initData, fragments: fragments, records: records)
        state.withLock { state in
            state.catalog.insert(catalogFile, table: records)
            state.stored[built.fileKey] = Stored(initData: initData, fragments: fragments, headerLengths: headerLengths)
        }
        return built
    }

    private static func nal(isKey: Bool, bytes: Int, seed: Int64) -> Data {
        var data = Data([isKey ? 0x65 : 0x41])
        for offset in 1..<max(2, bytes) { data.append(UInt8(truncatingIfNeeded: Int(truncatingIfNeeded: seed) &+ offset &* 31)) }
        return data
    }

    // MARK: ArchiveReading

    func activity(camera: UUID, range: Range<Date>, binCount: Int) async -> ArchiveActivity {
        ArchiveActivity(start: range.lowerBound, binDuration: 1, bins: [], typical: nil, isComplete: true)
    }

    func fragment(camera: UUID, containing time: Date) async -> ArchiveFragment? {
        let micros = ArchiveTime.micros(time)
        return state.withLock { state in
            guard state.ready, case .found(let fragment) = state.catalog.fragment(camera: camera, containingMicros: micros) else { return nil }
            return fragment
        }
    }

    func fragment(camera: UUID, startingAfter time: Date) async -> ArchiveFragment? {
        let micros = ArchiveTime.micros(time)
        return state.withLock { state in
            guard state.ready, case .found(let fragment) = state.catalog.fragment(camera: camera, startingAfterMicros: micros) else { return nil }
            return fragment
        }
    }

    func fragment(camera: UUID, id: String) async -> ArchiveFragment? {
        guard let parsed = ArchiveIdentity.parseFragmentID(id) else { return nil }
        return state.withLock { state in
            guard state.ready, !state.hidden.contains(id),
                  case .found(let fragment) = state.catalog.fragment(camera: camera, fileKey: parsed.fileKey, index: parsed.index) else { return nil }
            return fragment
        }
    }

    func extent(camera: UUID) -> ArchiveExtent? {
        state.withLock { state in state.ready ? state.catalog.extent(camera: camera, typicalGOP: nil) : nil }
    }

    func read(_ fragment: ArchiveFragment, _ part: ArchiveReadPart) async throws -> Data {
        let (number, hook, tamper, stored) = state.withLock { state -> (Int, Hook?, Tamper?, Stored?) in
            state.reads.append(Read(fragment: fragment.id, part: part, priority: Task.currentPriority))
            return (state.reads.count, state.hook, state.tamper, state.stored[fragment.fileKey])
        }
        if let hook { try await hook(number, fragment, part) }
        guard let stored, fragment.index >= 0, fragment.index < stored.fragments.count else { throw ArchiveError.fileGone }
        let data: Data
        switch part {
        case .initialization: data = stored.initData
        case .header: data = stored.fragments[fragment.index].prefix(stored.headerLengths[fragment.index])
        case .fragment: data = stored.fragments[fragment.index]
        case .keyframe: throw ArchiveError.unreadable("The fixture does not serve key pictures.")
        }
        return tamper?(fragment, part, data) ?? data
    }
}

/// Opens once; every `wait()` before and after returns then (the planner tests' own copy: the lifecycle tests' `Gate` is macOS only).
final class PlannerGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
