import BridgeEngine
import BridgeSupport
import Foundation

// "Keep this": stretches of recordings the person keeps from retention (`KeptRecording`).
//
// - `GET nvr/kept`: `{"kept": [{"id", "cameraID", "cameraName", "from", "to", "note", "created", "bytes", "hasVideo"}]}`, newest first; times in
//   Unix epoch milliseconds.
// - `POST nvr/kept` `{"cameraID", "from", "to", "note"?}`: 201 with the kept stretch; 400 for a range that is not one, longer than a day or
//   with no recording, 409 when there are already 200 or they would take more than a quarter of the room for recordings.
// - `DELETE nvr/kept/:kid`: 204; 404 for one that is not there.
extension WebApp {
    struct KeptResource: Encodable {
        var id: String
        var cameraID: UUID
        var cameraName: String
        var from: Int64
        var to: Int64
        var note: String
        var created: Int64
        var bytes: UInt64
        var hasVideo: Bool
    }

    private struct KeptList: Encodable {
        var kept: [KeptResource]
    }

    private struct KeepRequest: Decodable {
        var cameraID: UUID
        var from: Int64
        var to: Int64
        var note: String?
    }

    func nvrKept() async throws -> HTTPResponse {
        let archive = try readyArchive()
        let names = Dictionary(await backend.overview().configurations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return .json(KeptList(kept: await archive.keptRecordings().map { Self.keptResource($0, names: names) }))
    }

    func keepRecording(_ ctx: RequestContext) async throws -> HTTPResponse {
        let request = try decode(KeepRequest.self, from: ctx)
        let range = Self.earliestTime...Self.latestTime
        guard range.contains(request.from), range.contains(request.to), request.to > request.from else {
            throw APIError.badRequest(KeptRecordingError.badRange.errorDescription ?? "", field: "from")
        }
        let overview = await backend.overview()
        guard let camera = overview.configurations.first(where: { $0.id == request.cameraID }) else {
            throw APIError(status: 404, code: "not_found", message: "That camera isn’t on this bridge.")
        }
        let archive = try readyArchive()
        do {
            let kept = try await archive.keep(camera: camera.id, start: Date(timeIntervalSince1970: Double(request.from) / 1_000),
                                              end: Date(timeIntervalSince1970: Double(request.to) / 1_000), note: request.note ?? "")
            log.notice("a stretch of \(camera.name)'s recording is kept")
            return .json(Self.keptResource(kept, names: [camera.id: camera.name]), status: 201)
        } catch let error as KeptRecordingError {
            throw Self.apiError(error)
        }
    }

    func forgetKeptRecording(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard let id = ctx.params["kid"], (1...32).contains(id.utf8.count), id.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw APIError(status: 404, code: "not_found", message: KeptRecordingError.unknown.errorDescription ?? "")
        }
        do {
            try await readyArchive().forgetKept(id: id)
            return HTTPResponse(status: 204)
        } catch let error as KeptRecordingError {
            throw Self.apiError(error)
        }
    }

    static func keptResource(_ status: KeptRecordingStatus, names: [UUID: String]) -> KeptResource {
        KeptResource(id: status.kept.id, cameraID: status.kept.camera, cameraName: names[status.kept.camera] ?? "A removed camera",
                     from: Int64((status.kept.start.timeIntervalSince1970 * 1_000).rounded()), to: Int64((status.kept.end.timeIntervalSince1970 * 1_000).rounded()),
                     note: status.kept.note, created: Int64((status.kept.created.timeIntervalSince1970 * 1_000).rounded()), bytes: status.bytes,
                     hasVideo: status.hasVideo)
    }

    static func apiError(_ error: KeptRecordingError) -> APIError {
        let message = error.errorDescription ?? "That couldn’t be done."
        switch error {
        case .badRange, .tooLong, .nothingRecorded: return APIError.badRequest(message, field: "from")
        case .tooMany, .noRoom: return APIError(status: 409, code: "conflict", message: message)
        case .unknown: return APIError(status: 404, code: "not_found", message: message)
        case .noFolder, .loading: return APIError(status: 503, code: "archive_unavailable", message: message, headers: [("Retry-After", "2")])
        case .notSaved: return APIError(status: 500, code: "internal", message: message)
        }
    }
}
