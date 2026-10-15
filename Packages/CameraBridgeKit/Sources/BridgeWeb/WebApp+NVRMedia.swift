import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// The recorded video for the browser's MediaSource: what to fetch for a time (`GET /nvr/cameras/:id/fragments`), the video-only fragments, the init
// segments and the key pictures (`.../fragments/:fid`, `.../init`, `GET /nvr/cameras/:id/keyframe`). With `?track=sound`, a fragment or init is the
// recording's sound alone (AAC-LC, `audio/mp4`), for the page's audio element that plays it beside the picture; 204 when that file has no sound.

extension WebApp {
    static let maximumLeadIn = 64

    // MARK: Fragments (R7)

    private struct PartResource: Encodable {
        var id: String
        var file: String
        var start: Int64
        var end: Int64
        var bytes: Int
        var key: Bool
    }

    private struct FileResource: Encodable {
        var mime: String
        var width: Int
        var height: Int
        var anchor: Double
        var initId: String
        var sound: Bool
    }

    private struct FoundPlan: Encodable {
        var serverTime: Int64
        var found = true
        var at: Int64
        var exact: Bool
        var targetIndex: Int
        var parts: [PartResource]
        var files: [String: FileResource]
    }

    private struct MissingPlan: Encodable {
        var serverTime: Int64
        var found = false
        var at: Int64
        var reason: String
        var next: OrNull<Int64>
        var newest: OrNull<Int64>
    }

    private struct MoreParts: Encodable {
        var serverTime: Int64
        var parts: [PartResource]
        var files: [String: FileResource]
    }

    /// The prefix a stored fragment starts with and a served one lacks (`prft`, version 1: 32 bytes).
    static let producerReferenceTimeBytes = 32

    func nvrFragments(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let request = ctx.request
        let hasAt = request.queryValue("at") != nil, hasAfter = request.queryValue("after") != nil
        guard hasAt != hasAfter else {
            throw APIError.badRequest("Give either “at” or “after”, not both and not neither.", field: hasAt ? "after" : "at")
        }
        if hasAt {
            let at = try queryTime("at", in: request)
            let ahead = Int(try queryInteger("ahead", in: request, range: 0...16, fallback: 2, sentence: "“ahead” is 0 to 16."))
            return try await withArchiveSlot(ctx) { archive in try await plan(camera: id, at: at, ahead: ahead, archive: archive) }
        }
        let after = try fragmentID(request.queryValue("after") ?? "", field: "after")
        let limit = Int(try queryInteger("limit", in: request, range: 1...64, fallback: 8, sentence: "“limit” is 1 to 64."))
        return try await withArchiveSlot(ctx) { archive in try await more(camera: id, after: after, limit: limit, archive: archive) }
    }

    private func plan(camera: UUID, at: Int64, ahead: Int, archive: any ArchiveReading) async throws -> HTTPResponse {
        let time = Self.date(milliseconds: at)
        let now = Self.milliseconds(Date())
        guard let target = await archive.fragment(camera: camera, containing: time) else {
            let extent = archive.extent(camera: camera)
            let reason: String
            var next: Int64?
            if let extent {
                if time < extent.oldest {
                    reason = "beforeStart"
                } else if time >= extent.newest {
                    reason = "afterEnd"
                } else {
                    reason = "gap"
                    next = await archive.fragment(camera: camera, startingAfter: time).map { Self.milliseconds($0.start) }
                }
            } else {
                reason = "empty"
            }
            return .json(MissingPlan(serverTime: now, at: at, reason: reason, next: OrNull(next), newest: OrNull(extent.map { Self.milliseconds($0.newest) })))
        }
        // The fragments from the keyframe's to the target's: a group of pictures never spans files.
        var key = target
        if target.backToKey > 0 {
            key = try await fragmentOrGone(camera: camera, fileKey: target.fileKey, index: target.index - target.backToKey, archive: archive)
        }
        var fragments = [key]
        var exact = true
        if target.index - key.index + 1 > Self.maximumLeadIn {
            exact = false   // a lead-in this long is not offered: the key picture only
        } else if target.index > key.index {
            for index in (key.index + 1)...target.index {
                fragments.append(try await fragmentOrGone(camera: camera, fileKey: target.fileKey, index: index, archive: archive))
            }
        }
        let targetIndex = exact ? target.index - key.index : 0
        if exact {
            var last = target
            for _ in 0..<ahead {
                guard let next = await archive.fragment(camera: camera, startingAfter: last.start), next.start > last.start else { break }
                fragments.append(next)
                last = next
            }
        }
        let described = try await describe(fragments, archive: archive)
        return .json(FoundPlan(serverTime: now, at: at, exact: exact, targetIndex: targetIndex, parts: described.parts, files: described.files))
    }

    private func more(camera: UUID, after: String, limit: Int, archive: any ArchiveReading) async throws -> HTTPResponse {
        guard var last = await archive.fragment(camera: camera, id: after) else { throw Self.archiveAPIError(ArchiveError.fileGone) }
        var fragments: [ArchiveFragment] = []
        while fragments.count < limit, let next = await archive.fragment(camera: camera, startingAfter: last.start), next.start > last.start {
            fragments.append(next)
            last = next
        }
        let described = try await describe(fragments, archive: archive)
        return .json(MoreParts(serverTime: Self.milliseconds(Date()), parts: described.parts, files: described.files))
    }

    private func fragmentOrGone(camera: UUID, fileKey: String, index: Int, archive: any ArchiveReading) async throws -> ArchiveFragment {
        guard index >= 0, let fragment = await archive.fragment(camera: camera, id: ArchiveIdentity.fragmentID(fileKey: fileKey, index: index)) else {
            throw Self.archiveAPIError(ArchiveError.fileGone)
        }
        return fragment
    }

    /// The file's start in epoch milliseconds minus its first fragment's media time: constant for a file (epoch ms = anchor + media seconds x 1000),
    /// rounded to a microsecond so the figures from two fragments of one file agree.
    static func anchor(of fragment: ArchiveFragment) -> Double {
        let value = fragment.start.timeIntervalSince1970 * 1000 - Double(fragment.mediaStart) / 90
        return (value * 1000).rounded() / 1000
    }

    private func part(_ fragment: ArchiveFragment, anchor: Double) -> PartResource {
        // Start and end come from the file's anchor and integer ticks, so consecutive parts of a file abut exactly.
        let ticks = Int64((fragment.duration * Double(ArchiveConstants.videoTimescale)).rounded())
        return PartResource(id: fragment.id, file: fragment.fileKey,
                            start: Int64((anchor + Double(fragment.mediaStart) / 90).rounded()),
                            end: Int64((anchor + Double(fragment.mediaStart + ticks) / 90).rounded()),
                            bytes: max(0, fragment.byteLength - Self.producerReferenceTimeBytes), key: fragment.hasKeyframe)
    }

    /// The parts for `fragments` (in order) and what the page needs to play each file: the mime, the picture size, the anchor, and the id of
    /// the first listed part of the file (`/init` of it answers the file's init segment).
    private func describe(_ fragments: [ArchiveFragment], archive: any ArchiveReading) async throws -> (parts: [PartResource], files: [String: FileResource]) {
        var parts: [PartResource] = []
        var files: [String: FileResource] = [:]
        for fragment in fragments {
            let info = try await fileInfo(for: fragment, archive: archive)
            parts.append(part(fragment, anchor: info.anchor))
            if files[fragment.fileKey] == nil {
                files[fragment.fileKey] = FileResource(mime: info.mime, width: info.width, height: info.height, anchor: info.anchor, initId: fragment.id, sound: info.sound)
            }
        }
        return (parts, files)
    }

    private func fileInfo(for fragment: ArchiveFragment, archive: any ArchiveReading) async throws -> FileInfoCache.Info {
        if let cached = archiveState.files.info(fileKey: fragment.fileKey, segment: fragment.segment) { return cached }
        return remember(try await readInit(of: fragment, archive: archive), for: fragment)
    }

    /// Keeps what the page needs to play `fragment`'s file; the anchor stays what it was when the file was first seen.
    @discardableResult
    private func remember(_ video: ArchiveMedia.VideoInit, for fragment: ArchiveFragment) -> FileInfoCache.Info {
        let anchor = archiveState.files.info(fileKey: fragment.fileKey, segment: fragment.segment)?.anchor ?? Self.anchor(of: fragment)
        let info = FileInfoCache.Info(segment: fragment.segment, mime: video.mime, width: video.width, height: video.height, sound: video.hadAudio, anchor: anchor)
        archiveState.files.store(info, fileKey: fragment.fileKey)
        return info
    }

    private func readInit(of fragment: ArchiveFragment, archive: any ArchiveReading) async throws -> ArchiveMedia.VideoInit {
        do {
            return try ArchiveMedia.videoInit(try await archive.read(fragment, .initialization))
        } catch {
            throw mediaFailure(error, fileKey: fragment.fileKey)
        }
    }

    // MARK: Media (R8 to R10)

    private func mp4(_ data: Data) throws -> HTTPResponse {
        guard data.count <= configuration.maximumSegmentBytes else {
            throw APIError(status: 502, code: "unreadable", message: "This part of the recording is too large to send.")
        }
        var response = HTTPResponse(status: 200, contentType: "video/mp4", data: data)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// The video-only bytes of `fragment`: `moof` + `mdat` without the `prft` and without any sound.
    private func segment(of fragment: ArchiveFragment, archive: any ArchiveReading) async throws -> Data {
        do {
            return try ArchiveMedia.videoSegment(try await archive.read(fragment, .fragment))
        } catch {
            throw mediaFailure(error, fileKey: fragment.fileKey)
        }
    }

    /// `?track=sound`: the sound alone; nothing else is a track this route serves.
    private func wantsSound(_ ctx: RequestContext) throws -> Bool {
        switch ctx.request.queryValue("track") {
        case nil, "video": return false
        case "sound": return true
        default: throw APIError.badRequest("track must be video or sound.", field: "track")
        }
    }

    /// The sound of `data` as an answer: `audio/mp4`, or 204 when there is none.
    private func sound(_ data: Data?) throws -> HTTPResponse {
        guard let data else {
            var empty = HTTPResponse(status: 204, contentType: "audio/mp4", data: Data())
            empty.headers["Cache-Control"] = "no-store"
            return empty
        }
        var response = try mp4(data)
        response.headers["Content-Type"] = "audio/mp4"
        return response
    }

    func nvrFragment(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let id = try ctx.uuid("id")
        let fid = try fragmentID(ctx.params["fid"] ?? "", field: "fid")
        let soundOnly = try wantsSound(ctx)
        return try await withArchiveSlot(ctx) { archive in
            guard let fragment = await archive.fragment(camera: id, id: fid) else { throw Self.archiveAPIError(ArchiveError.fileGone) }
            if soundOnly {
                do {
                    return try sound(try ArchiveMedia.soundSegment(try await archive.read(fragment, .fragment)))
                } catch let error as APIError {
                    throw error
                } catch {
                    throw mediaFailure(error, fileKey: fragment.fileKey)
                }
            }
            return try mp4(try await segment(of: fragment, archive: archive))
        }
    }

    func nvrFragmentInit(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let id = try ctx.uuid("id")
        let fid = try fragmentID(ctx.params["fid"] ?? "", field: "fid")
        let soundOnly = try wantsSound(ctx)
        return try await withArchiveSlot(ctx) { archive in
            guard let fragment = await archive.fragment(camera: id, id: fid) else { throw Self.archiveAPIError(ArchiveError.fileGone) }
            if soundOnly {
                do {
                    return try sound(try ArchiveMedia.soundInit(try await archive.read(fragment, .initialization)))
                } catch let error as APIError {
                    throw error
                } catch {
                    throw mediaFailure(error, fileKey: fragment.fileKey)
                }
            }
            let video = try await readInit(of: fragment, archive: archive)
            remember(video, for: fragment)
            return try mp4(video.data)
        }
    }

    /// What the page needs to play the key fragment `GET /keyframe` returns (`X-CB-Part`, ASCII JSON).
    private struct KeyPart: Encodable {
        var id: String
        var file: String
        var start: Int64
        var end: Int64
        var mime: String
        var width: Int
        var height: Int
        var anchor: Double
        var initId: String
    }

    func nvrKeyframe(_ ctx: RequestContext) async throws -> HTTPResponse {
        try refuseHEAD(ctx)
        let id = try ctx.uuid("id")
        let at = try queryTime("at", in: ctx.request)
        return try await withArchiveSlot(ctx) { archive in
            let time = Self.date(milliseconds: at)
            guard let target = await archive.fragment(camera: id, containing: time) else {
                var headers: [(String, String)] = []
                if let next = await archive.fragment(camera: id, startingAfter: time) { headers.append(("X-CB-Next", String(Self.milliseconds(next.start)))) }
                throw APIError(status: 404, code: "gap", message: "Nothing was recorded at that time.", headers: headers)
            }
            let key = target.backToKey == 0 ? target : try await fragmentOrGone(camera: id, fileKey: target.fileKey, index: target.index - target.backToKey, archive: archive)
            guard key.hasKeyframe else { throw APIError(status: 502, code: "unreadable", message: "This part of the recording can’t be read.") }
            let info = try await fileInfo(for: key, archive: archive)
            var response = try mp4(try await segment(of: key, archive: archive))
            let described = part(key, anchor: info.anchor)
            let header = KeyPart(id: key.id, file: key.fileKey, start: described.start, end: described.end, mime: info.mime, width: info.width, height: info.height,
                                 anchor: info.anchor, initId: key.id)
            response.headers["X-CB-Part"] = String(decoding: (try? JSONEncoder.iso.encode(header)) ?? Data(), as: UTF8.self)
            return response
        }
    }
}
