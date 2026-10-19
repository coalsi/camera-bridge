import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// What is recorded, per camera, how busy it was and what happened (`GET /nvr/cameras`, `GET /nvr/activity`, `GET /nvr/events`).

extension WebApp {
    // MARK: Catalog and activity (R5, R6)

    private struct ExtentResource: Encodable {
        var id: UUID
        var oldest: Int64
        var newest: Int64
        var typicalGOP: OrNull<Double>
    }

    func nvrCameras() async throws -> HTTPResponse {
        struct Catalog: Encodable {
            var serverTime: Int64
            var catalogVersion: Int
            var cameras: [ExtentResource]
        }
        let archive = try readyArchive()
        let version = archive.catalogVersion
        let overview = await backend.overview()
        let cameras = overview.configurations.compactMap { camera in
            archive.extent(camera: camera.id).map {
                ExtentResource(id: camera.id, oldest: Self.milliseconds($0.oldest), newest: Self.milliseconds($0.newest),
                               typicalGOP: OrNull($0.typicalGOP.flatMap { $0.isFinite ? $0 : nil }))
            }
        }
        return .json(Catalog(serverTime: Self.milliseconds(Date()), catalogVersion: version, cameras: cameras))
    }

    private struct CameraActivity: Encodable {
        var typical: OrNull<Double>
        var complete: Bool
        var coverage: [Int]
        var level: [Double]
    }

    func nvrActivity(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Answer: Encodable {
            var from: Int64
            var binMs: Int64
            var bins: Int64
            var serverTime: Int64
            var catalogVersion: Int
            var byCamera: [String: CameraActivity]
        }
        let request = ctx.request
        // 1. Validate.
        let cameras = try queryCameras(request)
        let from = try queryTime("from", in: request)
        let binMs = try queryInteger("binMs", in: request, range: 1_000...86_400_000, sentence: "“binMs” is 1000 to 86400000.")
        let bins = try queryInteger("bins", in: request, range: 1...2_000, sentence: "“bins” is 1 to 2000.")
        guard bins * binMs <= 31 * 86_400_000 else { throw APIError.badRequest("Ask for at most 31 days at a time.", field: "bins") }
        let start = from / binMs * binMs
        return try await withArchiveSlot(ctx) { archive in
            let range = Self.date(milliseconds: start)..<Self.date(milliseconds: start + bins * binMs)
            let results = await Self.activities(of: cameras, in: archive, range: range, binCount: Int(bins))
            var byCamera: [String: CameraActivity] = [:]
            for (id, activity) in results {
                var coverage = activity.bins.map { Int((($0.coverage.isFinite ? min(max($0.coverage, 0), 1) : 0) * 100).rounded()) }
                var level = activity.bins.map { $0.level.isFinite ? max(0, $0.level) : 0 }
                coverage = Array(coverage.prefix(Int(bins))) + Array(repeating: 0, count: max(0, Int(bins) - coverage.count))
                level = Array(level.prefix(Int(bins))) + Array(repeating: 0, count: max(0, Int(bins) - level.count))
                byCamera[id.uuidString] = CameraActivity(typical: OrNull(activity.typical.flatMap { $0.isFinite ? $0 : nil }), complete: activity.isComplete,
                                                         coverage: coverage, level: level)
            }
            return .json(Answer(from: start, binMs: binMs, bins: bins, serverTime: Self.milliseconds(Date()), catalogVersion: archive.catalogVersion,
                                byCamera: byCamera))
        }
    }

    /// `cameras`: 1 to 16 camera identifiers separated by commas, the same one again (in either letter case) counted once.
    private func queryCameras(_ request: HTTPRequest) throws -> [UUID] {
        let ids = (request.queryValue("cameras") ?? "").split(separator: ",", omittingEmptySubsequences: false).map { UUID(uuidString: String($0)) }
        var cameras: [UUID] = []
        for id in ids {
            guard let id else { throw APIError.badRequest("“cameras” lists camera identifiers separated by commas.", field: "cameras") }
            if !cameras.contains(id) { cameras.append(id) }
        }
        guard (1...16).contains(cameras.count) else { throw APIError.badRequest("Ask for 1 to 16 cameras at a time.", field: "cameras") }
        return cameras
    }

    // MARK: Events

    /// The most events one answer carries, and how many when `limit` is not given.
    static let maximumEventsPerAnswer: Int64 = 1_000
    static let defaultEventsPerAnswer: Int64 = 200

    private struct EventResource: Encodable {
        var id: String
        var cameraID: UUID
        var kind: String
        var start: Int64
        var end: OrNull<Int64>
        var recorded: Bool
        var description: OrNull<DescriptionResource>
    }

    /// What an AI service said it saw: the sentence, what sort of thing, how much to care. Not the model or the time.
    private struct DescriptionResource: Encodable {
        var summary: String
        var kind: EventDescription.Kind
        var concern: EventDescription.Concern
    }

    /// `GET nvr/events?from=ms&to=ms&cameras=<id,…>&limit=n`: the events of those cameras that began in `from..<to` (at most 31 days), newest
    /// first, at most `limit` (1 to 1000, 200 when absent); `more` says older ones in the range were left out (ask again with `to` = the oldest
    /// `start`). A page never splits a millisecond, so that next page loses none: the events of the oldest start are all in this page or all in
    /// the next, and when more than `limit` began in that one millisecond and nothing newer, the page holds them all. 503 `archive_unavailable`
    /// (with `Retry-After`) while the recordings load or their folder is missing: never an empty answer then. Names, times and, for an event
    /// an AI service described, its sentence (`description`: summary, kind and concern; null until it is written): no address, path,
    /// credential or picture.
    func nvrEvents(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Answer: Encodable {
            var from: Int64
            var to: Int64
            var serverTime: Int64
            var more: Bool
            var events: [EventResource]
        }
        let request = ctx.request
        let cameras = try queryCameras(request)
        let from = try queryTime("from", in: request)
        let to = try queryTime("to", in: request)
        guard to > from else { throw APIError.badRequest("“to” comes after “from”.", field: "to") }
        guard to - from <= 31 * 86_400_000 else { throw APIError.badRequest("Ask for at most 31 days at a time.", field: "to") }
        let limit = try queryInteger("limit", in: request, range: 1...Self.maximumEventsPerAnswer, fallback: Self.defaultEventsPerAnswer,
                                     sentence: "“limit” is 1 to \(Self.maximumEventsPerAnswer).")
        return try await withArchiveSlot(ctx) { archive in
            let page: ArchiveEventPage
            do {
                page = try await archive.events(cameras: cameras, range: Self.date(milliseconds: from)..<Self.date(milliseconds: to), limit: Int(limit))
            } catch {
                throw Self.archiveAPIError(error)
            }
            let events = page.events.map { event in
                EventResource(id: event.id, cameraID: event.camera, kind: event.kind, start: Self.milliseconds(event.start),
                              end: OrNull(event.end.map(Self.milliseconds)), recorded: event.recorded,
                              description: OrNull(event.description.map { DescriptionResource(summary: $0.summary, kind: $0.kind, concern: $0.concern) }))
            }
            return .json(Answer(from: from, to: to, serverTime: Self.milliseconds(Date()), more: page.isTruncated, events: events))
        }
    }

    /// `archive.activity` for each camera, at most 4 at a time.
    private static func activities(of cameras: [UUID], in archive: any ArchiveReading, range: Range<Date>, binCount: Int) async -> [UUID: ArchiveActivity] {
        await withTaskGroup(of: (UUID, ArchiveActivity).self) { group in
            var remaining = cameras.makeIterator()
            func startNext() {
                guard let id = remaining.next() else { return }
                group.addTask { (id, await archive.activity(camera: id, range: range, binCount: binCount)) }
            }
            for _ in 0..<4 { startNext() }
            var results: [UUID: ArchiveActivity] = [:]
            while let (id, activity) = await group.next() {
                results[id] = activity
                startNext()
            }
            return results
        }
    }
}
