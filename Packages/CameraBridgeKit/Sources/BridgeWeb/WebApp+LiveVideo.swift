import BridgeEngine
import BridgeSupport
import Foundation
import MediaCore
import Synchronization

// Live video for the page: `GET /api/v1/live?cameras=<id>,<id>…&stream=sub|main|automatic[&width=<px>][&audio=<id>,…]`. One long response carries
// every asked camera's live H.264/HEVC as fragmented MP4 (no video transcoding; the cameras named in `audio` also carry their sound as AAC-LC, unless
// the camera's "Camera audio" switch is off), so a wall of cameras needs one of the browser's ~6 connections to the
// bridge instead of one each. The page appends the pieces to a Media Source Extensions buffer per camera (linux/web/js/live/mux.js). An Apple
// TV watches through it with its key (`Route.Access.viewer`); a TV removed while it watches loses the stream within `viewerRecheckInterval`.
//
// The body is a sequence of messages: a 6-byte header (type: UInt8, camera: UInt8 = its index in `cameras`, length: UInt32 big-endian) and the
// payload. Types:
//   1 meta     JSON {"mime", "width", "height", "stream"}: a new init segment follows; everything after it belongs to it (a new decoder)
//   2 init     the init segment (ftyp + moov)
//   3 delta    one frame (moof + mdat) that depends on earlier ones
//   4 keyframe one keyframe (moof + mdat): a reader that fell behind may restart here
//   5 status   JSON {"state": "waiting" | "unavailable", "message"}: no picture from this camera for now; the server keeps trying
// A camera whose pieces back up (a slow network) skips to its next keyframe with a new init, so a reader never decodes a delta without its keyframe.
extension WebApp {
    enum LiveMessage: UInt8 {
        case meta = 1, initialization = 2, delta = 3, keyframe = 4, status = 5
    }

    /// The most cameras one live request may carry.
    static let maximumLiveCameras = 32
    /// Bytes queued for the browser beyond which a camera skips to its next keyframe (the network is slower than the cameras).
    static let liveBacklogLimit = 24 << 20
    /// The shortest wait between two looks at whether an Apple TV that watches live is still added. A `WebConfiguration.viewerRecheckInterval`
    /// below it counts as this long, so a zero or tiny setting cannot turn the look into a loop that never sleeps.
    static let minimumViewerRecheck = Duration.milliseconds(100)

    /// How long a TV's live view waits between two looks at whether the TV is still added: the configured interval, but at least `minimumViewerRecheck`.
    static func viewerRecheckWait(_ configured: Duration) -> Duration {
        max(configured, minimumViewerRecheck)
    }

    static func liveFrame(_ type: LiveMessage, camera: Int, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 6)
        out.append(type.rawValue)
        out.append(UInt8(truncatingIfNeeded: camera))
        let length = UInt32(payload.count)
        out.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        out.append(payload)
        return out
    }

    static func liveJSON(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    func liveVideo(_ ctx: RequestContext) async throws -> HTTPResponse {
        let text = ctx.request.queryValue("cameras") ?? ""
        let ids = text.split(separator: ",").compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !ids.isEmpty, ids.count <= Self.maximumLiveCameras, Set(ids).count == ids.count else {
            throw APIError.badRequest("Name 1 to \(Self.maximumLiveCameras) different cameras in cameras=.", field: "cameras")
        }
        let configurations = await backend.overview().configurations
        let known = Set(configurations.map(\.id))
        guard ids.allSatisfy(known.contains) else { throw APIError.notFound("There is no camera with this identifier.") }
        let streamText = ctx.request.queryValue("stream") ?? "sub"
        guard let stream = LiveVideoStream(rawValue: streamText) else {
            throw APIError.badRequest("stream must be sub, main or automatic.", field: "stream")
        }
        let width = ctx.request.queryValue("width").flatMap(Int.init).map { min(max($0, 64), 8192) }
        // Sound costs a converter per camera (G.711 to AAC), so only the cameras the page plays aloud carry it. And never a camera whose "Camera audio"
        // switch is off, however the request lists it: the page does not ask for those, but an Apple TV's key opens this route too, and the switch is
        // the owner's word on whether a camera is heard. Such a camera is sent without sound; that is no error.
        let asked = Set((ctx.request.queryValue("audio") ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) })
        let audible = asked.intersection(configurations.filter(\.audioEnabled).map(\.id))
        guard takeLiveSlot() else {
            throw APIError(status: 429, code: "too_many_streams", message: "Too many live views are open. Close one and try again.", headers: [("Retry-After", "5")])
        }
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        let backend = backend
        // An Apple TV's view (its key opened the route): the TV is looked for in the list while it watches.
        let (auth, viewer, recheck) = (auth, ctx.viewer?.id, Self.viewerRecheckWait(configuration.viewerRecheckInterval))
        let release = ReleaseOnce { [self] in releaseLiveSlot() }
        var answer = HTTPResponse.stream(contentType: "application/octet-stream", headers: headers) { response in
            defer { release() }
            let (outbox, sender) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            let queued = Mutex(0)
            let send: @Sendable (Data) -> Void = { data in
                queued.withLock { $0 += data.count }
                sender.yield(data)
            }
            let backlogged: @Sendable () -> Bool = { queued.withLock { $0 } > Self.liveBacklogLimit }
            try await withThrowingTaskGroup(of: Void.self) { group in
                // The writer: one chunk per message, in order. It ends when the browser goes away (the write throws or the task is cancelled).
                group.addTask {
                    for await data in outbox {
                        try Task.checkCancellation()
                        try await response.write(data)
                        queued.withLock { $0 -= data.count }
                    }
                }
                for (index, id) in ids.enumerated() {
                    group.addTask {
                        await Self.pumpLiveCamera(id: id, index: index, stream: stream, width: width, audio: audible.contains(id), backend: backend, send: send,
                                              backlogged: backlogged)
                    }
                }
                // A TV removed while it watches: its key is refused from then on, and its view ends within `viewerRecheckInterval`, as when
                // the writer stops.
                if let viewer {
                    group.addTask {
                        while !Task.isCancelled, await auth.isViewerListed(viewer) {
                            try? await Task.sleep(for: recheck)
                        }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
                sender.finish()
            }
        }
        answer.onDiscard = { release() }
        return answer
    }

    /// One camera of a live request, until the request ends: subscribes, remuxes and sends; says when there is no picture and tries again.
    static func pumpLiveCamera(id: UUID, index: Int, stream: LiveVideoStream, width: Int?, audio: Bool = false, backend: any BridgeBackend,
                               send: @escaping @Sendable (Data) -> Void, backlogged: @escaping @Sendable () -> Bool) async {
        var announcedWaiting = false
        while !Task.isCancelled {
            let subscription: LiveVideoSubscription
            do {
                subscription = try await backend.liveVideo(cameraID: id, stream: stream, displayWidth: width, audio: audio)
            } catch {
                if !announcedWaiting {
                    announcedWaiting = true
                    let message = (error as? EngineError)?.description ?? "The camera is not running."
                    send(liveFrame(.status, camera: index, payload: liveJSON(["state": "unavailable", "message": message])))
                }
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            announcedWaiting = false
            var remuxer = LiveMP4Remuxer(audio: audio)
            var skipping = false
            await withTaskCancellationHandler {
                for await sample in subscription.samples {
                    if Task.isCancelled { break }
                    let frame: EncodedVideoFrame
                    switch sample {
                    case .audio(let sound): remuxer.push(audio: sound); continue
                    case .video(let video): frame = video
                    }
                    if skipping {
                        guard frame.isKeyframe, !backlogged() else { continue }
                        skipping = false
                        remuxer.restart()
                    }
                    let parts: [LiveMP4Remuxer.Part]
                    do { parts = try remuxer.push(frame) } catch { remuxer.restart(); continue }
                    for part in parts {
                        if backlogged() { skipping = true; remuxer.restart(); break }
                        switch part {
                        case .initialization(let data, let mime, let width, let height):
                            send(liveFrame(.meta, camera: index, payload: liveJSON(["mime": mime, "width": width, "height": height,
                                                                                    "stream": subscription.stream.rawValue])))
                            send(liveFrame(.initialization, camera: index, payload: data))
                        case .media(let data, let keyframe):
                            send(liveFrame(keyframe ? .keyframe : .delta, camera: index, payload: data))
                        }
                    }
                }
            } onCancel: {
                subscription.cancel()
            }
            subscription.cancel()
            if Task.isCancelled { return }
            // The subscription ended (the camera restarted or was reconfigured): say so, then subscribe again.
            send(liveFrame(.status, camera: index, payload: liveJSON(["state": "waiting", "message": "Reconnecting to the camera…"])))
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
