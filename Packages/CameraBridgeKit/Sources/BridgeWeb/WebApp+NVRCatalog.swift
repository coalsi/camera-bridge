import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// What is recorded, per camera, and how busy it was (`GET /nvr/cameras`, `GET /nvr/activity`).

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
        let ids = (request.queryValue("cameras") ?? "").split(separator: ",", omittingEmptySubsequences: false).map { UUID(uuidString: String($0)) }
        var cameras: [UUID] = []
        for id in ids {
            guard let id else { throw APIError.badRequest("“cameras” lists camera identifiers separated by commas.", field: "cameras") }
            if !cameras.contains(id) { cameras.append(id) }
        }
        guard (1...16).contains(cameras.count) else { throw APIError.badRequest("Ask for 1 to 16 cameras at a time.", field: "cameras") }
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
