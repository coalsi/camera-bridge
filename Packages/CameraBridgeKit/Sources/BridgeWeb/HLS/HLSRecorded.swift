import BridgeEngine
import Foundation

/// What a recorded ticket plays: the fragments of a range, grouped into segments once when the ticket is minted and kept with it. A segment keeps
/// only its file, the index of its first fragment, how many follow and its length and size (48 bytes), never the fragments themselves: they
/// are found again by id when a file is served. At most `WebApp.hlsMostPlannedFragments` (8,000) fragments, so a plan is under 1 MiB (`estimatedBytes`).
struct HLSRecordedPlan: Sendable, Equatable {
    /// One recording file in the range: the file and the index of a fragment of it that its init segment is read through, and what its picture and
    /// sound are.
    struct File: Sendable, Equatable {
        var fileKey: String
        var index: Int
        var mime: String
        var width: Int
        var height: Int
        /// The file's sound goes out with its fragments: it has some, and the camera's "Camera audio" switch was on when the ticket was minted.
        var keepSound: Bool
    }

    /// A key fragment and the continuation fragments after it, joined into one segment. `file` is the index of its file in `files`, which is also
    /// the number of its `init-<n>.mp4`.
    struct Segment: Sendable, Equatable {
        /// The fragments are `first`, `first + 1`, ... `first + count - 1` of the file.
        var first: Int
        var count: Int
        var file: Int
        var duration: Double
        var startsDiscontinuity: Bool
        /// The fragments' bytes without their `prft`.
        var bytes: Int
    }

    var files: [File]
    var segments: [Segment]

    /// A count of the memory the plan holds, from the sizes of its parts.
    var estimatedBytes: Int {
        segments.count * MemoryLayout<Segment>.stride + files.reduce(0) { $0 + MemoryLayout<File>.stride + $1.fileKey.utf8.count + $1.mime.utf8.count }
    }

    var width: Int { files.first?.width ?? 0 }
    var height: Int { files.first?.height ?? 0 }

    /// The picture's codec from the first file, and the sound's when any file keeps it.
    var codecs: String {
        let mime = files.first?.mime ?? ""
        var codecs = mime.split(separator: "\"").dropFirst().first.map(String.init) ?? "avc1.640028"
        if files.contains(where: \.keepSound), !codecs.contains("mp4a") { codecs += ",mp4a.40.2" }
        return codecs
    }

    /// Bits a second the largest segment needs: its bytes over its duration.
    var bandwidth: Int {
        let largest = segments.max { $0.bytes < $1.bytes }
        guard let largest, largest.duration > 0 else { return 1 }
        return max(1, Int((Double(largest.bytes) * 8 / largest.duration).rounded(.up)))
    }

    var master: String { HLSPlaylist.master(codecs: codecs, width: width, height: height, bandwidth: bandwidth) }

    var media: String {
        HLSPlaylist.recorded(segments.enumerated().map {
            RecordedSegment(number: $0.offset, initNumber: $0.element.file, duration: $0.element.duration, startsDiscontinuity: $0.element.startsDiscontinuity)
        })
    }
}

extension WebApp {
    /// The most fragments one plan walks: a range that holds more is refused as too long (two hours at one fragment a second is 7,200).
    static let hlsMostPlannedFragments = 8_000
    /// The most bytes one segment is built from (a group of pictures that is minutes long is not sent).
    static let hlsLargestRecordedSegment = 64 * 1_048_576

    private static let mpegURL = "application/vnd.apple.mpegurl"

    /// Walks `camera`'s fragments from the key fragment at or before `from` up to the fragment that holds `to`, once, and groups them. No bytes are
    /// kept: the fragments only, and each file's mime and size from its init segment (one read per file).
    func planRecording(camera: UUID, from: Int64, to: Int64, keepSound: Bool, largestSegment: Int = WebApp.hlsLargestRecordedSegment,
                       archive: any ArchiveReading) async throws -> HLSRecordedPlan {
        let (start, end) = (Self.date(milliseconds: from), Self.date(milliseconds: to))
        var first = await archive.fragment(camera: camera, containing: start)
        if first == nil { first = await archive.fragment(camera: camera, startingAfter: start) }
        guard let found = first, found.start < end else {
            throw APIError(status: 404, code: "gap", message: "Nothing was recorded then.")
        }
        // The start steps back to the key fragment, as the clip planner does.
        var current = found
        if found.backToKey > 0 { current = try await fragmentOrGone(camera: camera, fileKey: found.fileKey, index: found.index - found.backToKey, archive: archive) }

        var files: [HLSRecordedPlan.File] = []
        var segments: [HLSRecordedPlan.Segment] = []
        var open: HLSRecordedPlan.Segment?
        var firstOfOpen: ArchiveFragment?, last: ArchiveFragment?
        var summed = 0.0
        func close() {
            guard var segment = open else { return }
            // From the first fragment's media time to the last one's end, so a gap inside a file is part of the time the playlist counts.
            let ticks = (last.map { $0.mediaStart + Self.ticks(of: $0) } ?? 0) - (firstOfOpen?.mediaStart ?? 0)
            segment.duration = ticks > 0 ? Double(ticks) / Double(ArchiveConstants.videoTimescale) : summed
            last = nil
            firstOfOpen = nil
            summed = 0
            segments.append(segment)
            open = nil
        }

        var walked = 0
        while true {
            walked += 1
            guard walked <= Self.hlsMostPlannedFragments else { throw Self.rangeTooLong }
            let bytes = max(0, current.byteLength - Self.producerReferenceTimeBytes)
            if current.hasKeyframe {
                close()
                var startsDiscontinuity = false
                if files.last?.fileKey != current.fileKey {
                    files.append(try await describeFile(of: current, keepSound: keepSound, archive: archive))
                    startsDiscontinuity = !segments.isEmpty
                }
                open = HLSRecordedPlan.Segment(first: current.index, count: 1, file: files.count - 1, duration: 0, startsDiscontinuity: startsDiscontinuity, bytes: bytes)
                (firstOfOpen, last, summed) = (current, current, current.duration)
            } else if let previous = last, previous.fileKey == current.fileKey, previous.index + 1 == current.index {
                open?.count += 1
                open?.bytes += bytes
                (last, summed) = (current, summed + current.duration)
            }   // a continuation fragment whose key fragment is not part of the plan cannot start a segment: it is left out
            // A segment the box would always refuse to send is refused now, not advertised.
            if let size = open?.bytes, size > largestSegment { throw Self.rangeTooLong }
            guard let next = await archive.fragment(camera: camera, startingAfter: current.start), next.start > current.start, next.start < end else { break }
            current = next
        }
        close()
        guard !segments.isEmpty else { throw APIError(status: 404, code: "gap", message: "Nothing was recorded then.") }
        return HLSRecordedPlan(files: files, segments: segments)
    }

    private static let rangeTooLong = APIError(status: 400, code: "range_too_long",
                                               message: "Ask for a shorter time: at most 2 hours, and fewer when the camera sends a key frame more than once a second.", field: "to")

    private static func ticks(of fragment: ArchiveFragment) -> Int64 {
        Int64((fragment.duration * Double(ArchiveConstants.videoTimescale)).rounded())
    }

    private func describeFile(of fragment: ArchiveFragment, keepSound: Bool, archive: any ArchiveReading) async throws -> HLSRecordedPlan.File {
        let video = try await readInit(of: fragment, archive: archive)
        return HLSRecordedPlan.File(fileKey: fragment.fileKey, index: fragment.index, mime: video.mime, width: video.width, height: video.height, keepSound: keepSound && video.hadAudio)
    }

    // MARK: Files

    /// A file of a recorded ticket. The playlists are written from the plan; an init segment or a segment reads the archive and takes an archive slot
    /// for it, as `fragments` does. Every answer is `no-store`, and the camera is the ticket's alone: nothing in the address names one.
    func hlsRecordedFile(_ file: HLSFile, plan: HLSRecordedPlan, camera: UUID, ctx: RequestContext) async -> HTTPResponse {
        // HEAD would run the whole read and then cut the body: a recorded init or segment refuses it (`refuseHEAD`), the playlists cost nothing.
        switch file {
        case .initSegment, .segment:
            if ctx.request.method == "HEAD" { return Self.hlsHeadRefused() }
        case .master, .media:
            break
        }
        switch file {
        case .master:
            return Self.hlsAnswer(Data(plan.master.utf8), contentType: Self.mpegURL)
        case .media:
            return Self.hlsAnswer(Data(plan.media.utf8), contentType: Self.mpegURL)
        case .initSegment(let number):
            guard plan.files.indices.contains(number) else { return Self.hlsNotFound() }
            return await hlsRead(ctx, contentType: "video/mp4") { archive in try await self.recordedInit(plan.files[number], camera: camera, archive: archive) }
        case .segment(let number):
            guard plan.segments.indices.contains(number) else { return Self.hlsNotFound() }
            let segment = plan.segments[number]
            return await hlsRead(ctx, contentType: "video/iso.segment") { archive in
                try await self.recordedSegment(segment, fileKey: plan.files[segment.file].fileKey, camera: camera, keepSound: plan.files[segment.file].keepSound, archive: archive)
            }
        }
    }

    private func hlsRead(_ ctx: RequestContext, contentType: String, _ work: (any ArchiveReading) async throws -> Data) async -> HTTPResponse {
        do {
            let data = try await withArchiveSlot(ctx, work)
            return Self.hlsAnswer(data, contentType: contentType)
        } catch {
            var response = HTTPResponse.error(Self.archiveAPIError(error))
            response.headers["Cache-Control"] = "no-store"
            return response
        }
    }

    /// The file's init segment: whole, sound track included, when its sound goes out; else the picture's track alone.
    private func recordedInit(_ file: HLSRecordedPlan.File, camera: UUID, archive: any ArchiveReading) async throws -> Data {
        let fragment = try await fragmentOrGone(camera: camera, fileKey: file.fileKey, index: file.index, archive: archive)
        do {
            let stored = try await archive.read(fragment, .initialization)
            return file.keepSound ? stored : try ArchiveMedia.videoInit(stored).data
        } catch {
            throw mediaFailure(error, fileKey: file.fileKey)
        }
    }

    /// The segment's fragments, each as `moof` + `mdat`, one after the other. With sound they are as stored but for the `prft`; without, the picture
    /// alone (`segment(of:)`).
    private func recordedSegment(_ segment: HLSRecordedPlan.Segment, fileKey: String, camera: UUID, keepSound: Bool, archive: any ArchiveReading) async throws -> Data {
        guard segment.bytes <= Self.hlsLargestRecordedSegment else {
            throw APIError(status: 502, code: "unreadable", message: "This part of the recording is too large to send.")
        }
        var out = Data()
        out.reserveCapacity(segment.bytes)
        for index in segment.first..<(segment.first + segment.count) {
            let fragment = try await fragmentOrGone(camera: camera, fileKey: fileKey, index: index, archive: archive)
            if keepSound {
                do {
                    out.append(try ArchiveMedia.segmentWithSound(try await archive.read(fragment, .fragment)))
                } catch {
                    throw mediaFailure(error, fileKey: fragment.fileKey)
                }
            } else {
                out.append(try await self.segment(of: fragment, archive: archive))
            }
        }
        return out
    }
}
