import BridgeSupport
import BridgeEngine
import Foundation
import MediaCore

// Saving a clip from the browser (export-clip design, section 6): what a clip of one camera would be (`GET /nvr/cameras/:id/clip-plan`) and the
// clip itself as one MP4 download (`GET /nvr/cameras/:id/clip`). The planning and the writing are `ClipExporter`'s; this only parses the request,
// holds an archive slot for as long as a download runs and turns the engine's errors into sentences.

extension WebApp {
    private struct PartResource: Encodable {
        var index: Int
        var start: Int64
        var end: Int64
        var leadInMs: Int64
        var bytes: Int64
        var samples: Int
        var fileName: String
    }

    private struct GapResource: Encodable {
        var from: Int64
        var to: Int64
        var held: Bool
    }

    private struct PlanResource: Encodable {
        var camera: String
        var cameraName: String
        var parts: [PartResource]
        var gaps: [GapResource]
        var soundOmitted: Bool
        var bytes: Int64
        var durationMs: Int64
    }

    /// The sentences of the web page for what can go wrong with a clip (the Mac app says the same ones).
    static func clipAPIError(_ error: any Error) -> APIError {
        switch error {
        case let error as APIError: return error
        case let error as ClipError:
            switch error {
            case .nothingRecorded:
                return APIError(status: 404, code: "gap", message: "Nothing was recorded in this time.")
            case .notReady:
                return APIError(status: 503, code: "archive_unavailable", message: "The recordings are still loading. Try again in a moment.", headers: [("Retry-After", "2")])
            case .driveGone:
                return APIError(status: 502, code: "unreadable", message: "The recordings drive isn’t answering.")
            case .damaged:
                return APIError(status: 502, code: "unreadable", message: "Part of this recording can’t be read, so the clip can’t be saved.")
            case .tooLong(let seconds):
                return APIError(status: 422, code: "too_long", message: "A clip can be at most \(seconds / 3_600) hours for each camera. Choose a shorter time.")
            case .tooLarge(let bytes):
                return APIError(status: 422, code: "too_large", message: "A clip can be at most \(bytes >> 30) GiB. Choose a shorter time or fewer cameras.")
            case .cancelled:
                return APIError(status: 503, code: "archive_unavailable", message: "The request was cancelled.")
            case .sink:
                return APIError(status: 502, code: "unreadable", message: "The clip couldn’t be sent.")
            }
        default:
            return archiveAPIError(error)
        }
    }

    /// The camera, the range and the person's time zone (an IANA name; the file names are written in it) of a clip request.
    private func clipRequest(_ ctx: RequestContext) async throws -> ClipRequest {
        let id = try ctx.uuid("id")
        let from = try queryTime("from", in: ctx.request)
        let to = try queryTime("to", in: ctx.request)
        guard to > from else { throw APIError.badRequest("The clip must end after it starts.", field: "to") }
        var zone = TimeZone(identifier: "UTC") ?? .gmt
        if let name = ctx.request.queryValue("tz"), !name.isEmpty {
            guard name.utf8.count <= 64, let found = TimeZone(identifier: name) else { throw APIError.badRequest("That isn’t a time zone.", field: "tz") }
            zone = found
        }
        let overview = await backend.overview()
        guard let camera = overview.cameras.first(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        return ClipRequest(camera: id, cameraName: camera.name, start: Self.date(milliseconds: from), end: Self.date(milliseconds: to), timeZone: zone)
    }

    func nvrClipPlan(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let request = try await clipRequest(ctx)
        return try await withArchiveSlot(ctx) { archive in
            do {
                let plan = try await ClipExporter(archive: archive).plan(request)
                return .json(PlanResource(camera: request.camera.uuidString, cameraName: request.cameraName,
                                          parts: plan.parts.map { PartResource(index: $0.index, start: Self.milliseconds($0.start), end: Self.milliseconds($0.end),
                                                                               leadInMs: Int64(($0.leadIn * 1_000).rounded()), bytes: $0.byteCount, samples: $0.sampleCount, fileName: $0.fileName) },
                                          gaps: plan.gaps.map { GapResource(from: Self.milliseconds($0.from), to: Self.milliseconds($0.to), held: $0.held) },
                                          soundOmitted: plan.soundOmitted, bytes: plan.byteCount, durationMs: Int64((plan.duration * 1_000).rounded())))
            } catch {
                throw Self.clipAPIError(error)
            }
        }
    }

    /// The bytes of one part, written to the connection as the writer produces them (chunked: the size is in the plan, not in a header).
    func nvrClip(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let request = try await clipRequest(ctx)
        let part = Int(try queryInteger("part", in: ctx.request, range: 1...64, fallback: 1, sentence: "Give “part” as the number of the part."))
        let speed = try Self.timelapseSpeed(ctx.request.queryValue("speed"))
        let archive = try readyArchive()
        let address = ctx.request.remoteAddress
        guard takeArchiveSlot(address: address) else {
            throw APIError(status: 429, code: "busy", message: "The bridge is busy with other recordings. Try again in a moment.", headers: [("Retry-After", "1")])
        }
        let exporter = ClipExporter(archive: archive)
        let plan: ClipPlan
        do {
            plan = try await exporter.plan(request)
        } catch {
            releaseArchiveSlot(address: address)
            throw Self.clipAPIError(error)
        }
        guard plan.parts.indices.contains(part - 1) else {
            releaseArchiveSlot(address: address)
            throw APIError.notFound("The clip has no part \(part).")
        }
        // Re-encoded for the bridge's label (name, date and time) burned in, and for the camera's picture correction when the person asked for
        // the clip straightened and the correction is on; otherwise the recording's bytes as they are.
        let labels = ctx.request.queryValue("labels") == "1"
        var correction: PictureCorrection?
        if ctx.request.queryValue("straighten") == "1",
           let configured = await backend.overview().configurations.first(where: { $0.id == request.camera })?.pictureCorrection, !configured.isOff {
            correction = configured
        }
        if labels || correction != nil || speed != nil {
            return try await processedClip(plan: plan, part: part, exporter: exporter, cameraID: request.camera, name: request.cameraName, labels: labels,
                                           correction: correction, speed: speed, release: { [self] in releaseArchiveSlot(address: address) })
        }
        let name = plan.parts[part - 1].fileName
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        headers["Content-Disposition"] = Self.attachment(name)
        log.notice("a clip of \(request.cameraName) is being sent")
        return HTTPResponse.stream(contentType: "video/mp4", headers: headers) { stream in
            defer { self.releaseArchiveSlot(address: address) }
            do {
                try await exporter.export(plan, part: part, to: StreamClipSink(stream: stream)) { _ in }
            } catch {
                self.log.warning("sending a clip failed: \(String(describing: error))")
            }
        }
    }

    /// The speeds a time-lapse clip can be saved at (`speed` on the clip route): the Monitor's time-lapse speeds.
    static let timelapseSpeeds = [30, 60, 120, 300]

    /// The `speed` of a clip request: nil without one (the clip as recorded), else one of `timelapseSpeeds`.
    static func timelapseSpeed(_ text: String?) throws -> Int? {
        guard let text else { return nil }
        guard let value = Int(text), timelapseSpeeds.contains(value) else {
            throw APIError.badRequest("Give “speed” as 30, 60, 120 or 300.", field: "speed")
        }
        return value
    }

    /// A time-lapse clip's file name: the clip's own with " time-lapse 60x" before the extension.
    static func timelapseFileName(_ name: String, speed: Int) -> String {
        let suffix = " time-lapse \(speed)x"
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name + suffix }
        return String(name[..<dot]) + suffix + String(name[dot...])
    }

    /// `attachment; filename="…"; filename*=UTF-8''…` with the name made safe for a header (no quotes, no control characters, no slashes).
    static func attachment(_ name: String) -> String {
        let plain = String(name.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\"" || scalar == "\\" || scalar == "/" || scalar.value > 0x7E) ? "_" : Character(scalar)
        })
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? plain
        return "attachment; filename=\"\(plain)\"; filename*=UTF-8''\(encoded)"
    }
}

/// Where the clip writer's bytes go: the response.
private struct StreamClipSink: ClipSink {
    let stream: ResponseStream

    func write(_ bytes: Data) async throws { try await stream.write(bytes) }
}
