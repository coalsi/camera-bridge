import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization

// The NVR's web API: where recordings are stored, the per-camera Record switch, the catalog and the activity waveform, and the video-only
// fragments the page plays through MediaSource. Contract: docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md, part C.
//
// Every route needs a session. A media route meets the gates of C.3 in this order, so a malformed request never uses a slot: it is validated,
// the backend must have an archive, the archive must be ready, and an admission slot must be free. Nothing here touches the disk on the
// cooperative pool: `ArchiveReading.read` runs on the store's own queue, and folder checks on the engine's probe queue.
//
// This file: the route table, admission, the gates, request parsing, the error mapping and the state the routes share. The routes themselves
// are in WebApp+NVRStorage.swift (storage and the Record switch), WebApp+NVRCatalog.swift (catalog and activity), WebApp+NVRMedia.swift
// (fragments, init segments and key pictures) and WebApp+NVROptimize.swift (the optimizer, second tier).

extension WebApp {
    static let archiveRoutes: [Route] = [
        Route("GET", "nvr/storage") { app, _ in await app.nvrStorage() },
        Route("GET", "nvr/storage/locations") { app, _ in await app.nvrLocations() },
        Route("PATCH", "nvr/storage", takesBody: true) { app, ctx in try await app.patchNVRStorage(ctx) },
        Route("PATCH", "cameras/:id/nvr", takesBody: true) { app, ctx in try await app.patchCameraNVR(ctx) },
        Route("GET", "nvr/cameras") { app, _ in try await app.nvrCameras() },
        Route("GET", "nvr/activity") { app, ctx in try await app.nvrActivity(ctx) },
        Route("GET", "nvr/cameras/:id/fragments") { app, ctx in try await app.nvrFragments(ctx) },
        Route("GET", "nvr/cameras/:id/fragments/:fid") { app, ctx in try await app.nvrFragment(ctx) },
        Route("GET", "nvr/cameras/:id/fragments/:fid/init") { app, ctx in try await app.nvrFragmentInit(ctx) },
        Route("GET", "nvr/cameras/:id/keyframe") { app, ctx in try await app.nvrKeyframe(ctx) },
        Route("GET", "nvr/cameras/:id/clip-plan") { app, ctx in try await app.nvrClipPlan(ctx) },
        Route("GET", "nvr/cameras/:id/clip") { app, ctx in try await app.nvrClip(ctx) },
        Route("POST", "cameras/:id/optimize", takesBody: true) { app, ctx in try await app.optimizeCamera(ctx) },
        Route("POST", "cameras/:id/optimize/undo", takesBody: true) { app, ctx in try await app.undoOptimization(ctx) },
    ]

    // MARK: Admission and gates

    /// One more archive request for `address`, unless 8 are running in all or 6 for this address (`WebConfiguration.maximumArchiveReads`):
    /// no queue and no wait, like `takeLiveSlot`. Every `true` is paired with `releaseArchiveSlot` in a `defer`.
    func takeArchiveSlot(address: String) -> Bool {
        archiveState.slots.withLock { slots in
            guard slots.total < configuration.maximumArchiveReads,
                  slots.perAddress[address, default: 0] < configuration.maximumArchiveReadsPerAddress else { return false }
            slots.total += 1
            slots.perAddress[address, default: 0] += 1
            return true
        }
    }

    func releaseArchiveSlot(address: String) {
        archiveState.slots.withLock { slots in
            slots.total = max(0, slots.total - 1)
            switch slots.perAddress[address] {
            case .none: break
            case .some(let count) where count <= 1: slots.perAddress[address] = nil
            case .some(let count): slots.perAddress[address] = count - 1
            }
        }
    }

    /// Archive requests running now (tests).
    var archiveSlotsInUse: Int { archiveState.slots.withLock { $0.total } }

    /// Gates 2 and 3 of C.3: the backend has an archive, and it has loaded its catalog.
    func readyArchive() throws -> any ArchiveReading {
        guard let archive = backend.archive else {
            throw APIError(status: 503, code: "archive_unavailable", message: "Recording isn’t available on this bridge.")
        }
        guard archive.isReady else {
            throw APIError(status: 503, code: "archive_unavailable", message: "The recordings are still loading. Try again in a moment.",
                           headers: [("Retry-After", "2")])
        }
        return archive
    }

    /// Gates 2 to 4 and 6 of C.3 around `work`: the archive must exist and be ready, a slot is taken for the request's address and released
    /// when `work` ends. The caller has validated the request already (gate 1).
    func withArchiveSlot<T>(_ ctx: RequestContext, _ work: (any ArchiveReading) async throws -> T) async throws -> T {
        let archive = try readyArchive()
        let address = ctx.request.remoteAddress
        guard takeArchiveSlot(address: address) else {
            throw APIError(status: 429, code: "busy", message: "The bridge is busy with other recordings. Try again in a moment.",
                           headers: [("Retry-After", "1")])
        }
        defer { releaseArchiveSlot(address: address) }
        return try await work(archive)
    }

    /// HEAD would run the whole read and then cut the body (`HTTPServer`): a media route refuses it.
    func refuseHEAD(_ ctx: RequestContext) throws {
        guard ctx.request.method != "HEAD" else {
            throw APIError(status: 405, code: "method_not_allowed", message: "That isn’t possible here.", headers: [("Allow", "GET")])
        }
    }

    // MARK: Request parsing

    static let earliestTime: Int64 = 978_307_200_000     // 2001-01-01
    static let latestTime: Int64 = 4_102_444_800_000     // 2100-01-01

    /// A query value of 1 to 15 decimal digits within `range`; a missing one is `fallback` when there is one.
    func queryInteger(_ name: String, in request: HTTPRequest, range: ClosedRange<Int64>, fallback: Int64? = nil, sentence: String) throws -> Int64 {
        guard let text = request.queryValue(name) else {
            if let fallback { return fallback }
            throw APIError.badRequest(sentence, field: name)
        }
        guard (1...15).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = Int64(text), range.contains(value) else {
            throw APIError.badRequest(sentence, field: name)
        }
        return value
    }

    func queryTime(_ name: String, in request: HTTPRequest) throws -> Int64 {
        try queryInteger(name, in: request, range: Self.earliestTime...Self.latestTime, sentence: "Give “\(name)” as a time in milliseconds since 1970.")
    }

    func fragmentID(_ text: String, field: String) throws -> String {
        guard ArchiveIdentity.parseFragmentID(text) != nil else { throw APIError.badRequest("That isn’t a recording part.", field: field) }
        return text
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// A folder path as the settings and the location list compare it: without trailing slashes.
    static func normalizedPath(_ path: String) -> String {
        var text = path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Errors

    /// Every archive failure as one API error: a removed file or part is gone, a drive that does not answer is slow, anything else about a
    /// fragment (a damaged one, an MP4 the browser view cannot be made from) is unreadable. The sentences name no path and no file.
    static func archiveAPIError(_ error: any Error) -> APIError {
        switch error {
        case let error as APIError:
            return error
        case ArchiveError.fileGone:
            return APIError(status: 410, code: "gone", message: "That part of the recording is no longer there.")
        case ArchiveError.timedOut, is DeadlineExceeded:
            return APIError(status: 504, code: "drive_slow", message: "The recordings drive isn’t answering.", headers: [("Retry-After", "2")])
        case is CancellationError:
            return APIError(status: 503, code: "archive_unavailable", message: "The request was cancelled.", headers: [("Retry-After", "2")])
        default:
            return APIError(status: 502, code: "unreadable", message: "This part of the recording can’t be read.")
        }
    }

    /// `archiveAPIError`, plus one log line per file the first time one of its parts cannot be read (the kind of failure, never its text).
    func mediaFailure(_ error: any Error, fileKey: String) -> APIError {
        let mapped = Self.archiveAPIError(error)
        if mapped.status == 502, archiveState.firstReport(of: fileKey) {
            log.warning("a recorded part of file \(fileKey) can’t be read (\(Redact.string(Self.failureKind(error))))")
        }
        return mapped
    }

    private static func failureKind(_ error: any Error) -> String {
        switch error {
        case ArchiveError.unreadable: "unreadable"
        case ArchiveError.noKeyframe: "no keyframe"
        case ArchiveMedia.Failure.malformed: "malformed"
        case ArchiveMedia.Failure.unsupported: "unsupported"
        default: String(describing: type(of: error))
        }
    }
}

// MARK: - Helpers

/// A value written as `null` when it is absent. Synthesized `Encodable` leaves a nil optional out; the contract's NVR answers have every key
/// present.
struct OrNull<Value: Encodable & Sendable>: Encodable, Sendable {
    var value: Value?

    init(_ value: Value?) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// What the NVR routes remember between requests (one per `WebApp`): the admission counters, what the page needs to play each file, the folder
/// checks in flight, the cameras being optimized and the files already reported as unreadable.
final class ArchiveWebState: Sendable {
    struct Slots {
        var total = 0
        var perAddress: [String: Int] = [:]
    }

    let slots = Mutex(Slots())
    let files = FileInfoCache()
    let folders = ArchiveFolderProbe()
    private let optimizing = Mutex(Set<UUID>())
    private let reported = Mutex(Set<String>())

    /// True for the first call per file (bounded: the set starts again after 256 files).
    func firstReport(of fileKey: String) -> Bool {
        reported.withLock { reported in
            if reported.count >= FileInfoCache.capacity { reported.removeAll() }
            return reported.insert(fileKey).inserted
        }
    }

    func beginOptimizing(_ id: UUID) -> Bool {
        optimizing.withLock { $0.insert(id).inserted }
    }

    func endOptimizing(_ id: UUID) {
        optimizing.withLock { _ = $0.remove(id) }
    }
}

/// What the page needs to play a file, cached per file key (256 entries, the least recently used goes first). The entry holds the segment path
/// it was made for, so a key that is somehow shared by two files never serves the wrong one.
final class FileInfoCache: Sendable {
    struct Info: Sendable, Equatable {
        var segment: String
        var mime: String
        var width: Int
        var height: Int
        var sound: Bool
        /// The file's start in epoch milliseconds minus its first fragment's media time (`WebApp.anchor(of:)`).
        var anchor: Double
    }

    static let capacity = 256

    private struct Entry: Sendable {
        var info: Info
        var used: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var clock: UInt64 = 0
    }

    private let state = Mutex(State())

    func info(fileKey: String, segment: String) -> Info? {
        state.withLock { state in
            guard var entry = state.entries[fileKey], entry.info.segment == segment else { return nil }
            state.clock += 1
            entry.used = state.clock
            state.entries[fileKey] = entry
            return entry.info
        }
    }

    func store(_ info: Info, fileKey: String) {
        state.withLock { state in
            state.clock += 1
            state.entries[fileKey] = Entry(info: info, used: state.clock)
            if state.entries.count > Self.capacity, let oldest = state.entries.min(by: { $0.value.used < $1.value.used })?.key {
                state.entries[oldest] = nil
            }
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
}

/// `backend.inspectArchiveFolder` for a listed location, with a deadline, one check at a time per path, and (for the chooser) the last answer
/// reused for a few seconds, so the page's polling cannot pile up probes on a slow drive.
final class ArchiveFolderProbe: Sendable {
    enum Outcome: Sendable, Equatable {
        case usable(ArchiveFolderReport)
        /// The sentence the person reads (`ArchiveFolderError.errorDescription`).
        case rejected(String)
        /// Nothing answered within the deadline.
        case unresponsive
    }

    private struct State {
        var recent: [String: (at: ContinuousClock.Instant, outcome: Outcome)] = [:]
        var running: [String: Task<Outcome, Never>] = [:]
    }

    private let state = Mutex(State())
    let deadline: Duration
    let reuse: Duration

    init(deadline: Duration = .seconds(8), reuse: Duration = .seconds(10)) {
        self.deadline = deadline
        self.reuse = reuse
    }

    func inspect(_ path: String, using backend: any BridgeBackend, reusing: Bool) async -> Outcome {
        enum Step { case answer(Outcome), wait(Task<Outcome, Never>) }
        let deadline = deadline
        let step = state.withLock { locked -> Step in
            if reusing, let hit = locked.recent[path], ContinuousClock.now - hit.at < reuse { return .answer(hit.outcome) }
            if let task = locked.running[path] { return .wait(task) }
            let task = Task { [self] in
                let outcome: Outcome
                do {
                    let report = try await withDeadline(deadline) { try await backend.inspectArchiveFolder(path) }
                    outcome = .usable(report)
                } catch is DeadlineExceeded {
                    outcome = .unresponsive
                } catch {
                    outcome = .rejected(ErrorText.describe(error))
                }
                self.state.withLock { locked in
                    locked.running[path] = nil
                    if case .unresponsive = outcome { locked.recent[path] = nil } else { locked.recent[path] = (ContinuousClock.now, outcome) }
                }
                return outcome
            }
            locked.running[path] = task
            return .wait(task)
        }
        switch step {
        case .answer(let outcome): return outcome
        case .wait(let task): return await task.value
        }
    }
}
