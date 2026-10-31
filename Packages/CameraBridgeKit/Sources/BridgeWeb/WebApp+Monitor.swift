import BridgeEngine
import Foundation

// Monitoring from Home Assistant, Uptime Kuma and the like: `GET /api/v1/monitor`, read-only, behind a long random token from Settings
// (`PATCH settings {monitorEnabled, regenerateMonitorToken}`; `GET settings` shows it as `monitorToken`). The token goes in a header,
// `Authorization: Bearer <token>`, never in the address (a URL ends up in logs and histories): a request with `token=` in its query is
// refused even when the token is right. No session is needed and a session alone is not enough. Off (no token): 403 `monitor_off`;
// no token or a wrong one: 401 `monitor_token`.
//
// The answer, every key always there (null when unknown):
//   { time, version, state, cameras: [{ id, name, enabled, online, connection, recording, recordingState, lastSegment }],
//     recordings: { state, freeBytes, totalBytes, floorBytes } | null, archive: { state, freeBytes, totalBytes } | null,
//     update: { state, available, current, latest } | null, signIn: { failedLastHour, failedLastDay, lockedAddresses, everyoneWaits } }
// `recording` is true while the camera's recording is on and writing; `lastSegment` is the end of its newest recorded piece. `recordings.state`
// is `ok`, or why recording is paused (`no_folder`, `low_space`, …); `archive.state` is the archive drive's (`connected`, `notConnected`, …).
extension WebApp {
    static let monitorRoutes: [Route] = [
        Route("GET", "monitor", .open) { app, ctx in try await app.monitor(ctx) },
    ]

    private struct MonitorCamera: Encodable {
        var id: UUID
        var name: String
        var enabled: Bool
        var online: Bool
        var connection: String
        var recording: Bool
        var recordingState: String
        var lastSegment: Date?

        private enum CodingKeys: String, CodingKey { case id, name, enabled, online, connection, recording, recordingState, lastSegment }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(online, forKey: .online)
            try container.encode(connection, forKey: .connection)
            try container.encode(recording, forKey: .recording)
            try container.encode(recordingState, forKey: .recordingState)
            try container.encode(lastSegment, forKey: .lastSegment)
        }
    }

    private struct MonitorDrive: Encodable {
        var state: String
        var freeBytes: UInt64
        var totalBytes: UInt64
        var floorBytes: UInt64?
    }

    private struct MonitorUpdate: Encodable {
        var state: String
        var available: Bool
        var current: String
        var latest: String?

        private enum CodingKeys: String, CodingKey { case state, available, current, latest }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(available, forKey: .available)
            try container.encode(current, forKey: .current)
            try container.encode(latest, forKey: .latest)
        }
    }

    private struct MonitorSignIn: Encodable {
        var failedLastHour: Int
        var failedLastDay: Int
        var lockedAddresses: Int
        var everyoneWaits: Bool
    }

    private struct MonitorAnswer: Encodable {
        var time: Date
        var version: String
        var state: String
        var cameras: [MonitorCamera]
        var recordings: MonitorDrive?
        var archive: MonitorDrive?
        var update: MonitorUpdate?
        var signIn: MonitorSignIn

        private enum CodingKeys: String, CodingKey { case time, version, state, cameras, recordings, archive, update, signIn }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .time)
            try container.encode(version, forKey: .version)
            try container.encode(state, forKey: .state)
            try container.encode(cameras, forKey: .cameras)
            try container.encode(recordings, forKey: .recordings)
            try container.encode(archive, forKey: .archive)
            try container.encode(update, forKey: .update)
            try container.encode(signIn, forKey: .signIn)
        }
    }

    func monitor(_ ctx: RequestContext) async throws -> HTTPResponse {
        let request = ctx.request
        if request.query.contains(where: { ["token", "access_token", "monitorToken"].contains($0.name) }) {
            throw APIError.badRequest("Send the token in the Authorization header (Bearer), never in the address.", field: "token")
        }
        guard await auth.monitorToken != nil else {
            throw APIError(status: 403, code: "monitor_off", message: "Monitoring is off. Turn it on in Settings to get a token.")
        }
        let header = request.headers["Authorization"] ?? ""
        let presented = header.lowercased().hasPrefix("bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        guard await auth.isMonitorToken(presented) else {
            throw APIError(status: 401, code: "monitor_token", message: "Send the monitoring token from Settings as Authorization: Bearer <token>.",
                           headers: [("WWW-Authenticate", "Bearer")])
        }
        let overview = await backend.overview()
        let archive = backend.archive
        let cameras = overview.configurations.map { configuration -> MonitorCamera in
            let status = overview.cameras.first { $0.id == configuration.id }
            let nvr = status.map { NVRStatusResource($0.nvr) }
            return MonitorCamera(id: configuration.id, name: configuration.name, enabled: configuration.isEnabled, online: status?.connection == .online,
                                 connection: status.map { StatusText.connectionName($0.connection) } ?? "unknown",
                                 recording: nvr?.state == "recording", recordingState: nvr?.state ?? "off",
                                 lastSegment: archive?.extent(camera: configuration.id)?.newest)
        }
        let storage = overview.nvrStorage
        let pause: ArchivePause? = overview.settings.nvrFolder == nil ? .noFolder : storage?.pause
        let recordings = storage.map { MonitorDrive(state: pause?.code ?? "ok", freeBytes: $0.freeBytes, totalBytes: $0.totalBytes, floorBytes: $0.floorBytes) }
        let drive = storage?.archive.map { MonitorDrive(state: $0.state.rawValue, freeBytes: $0.freeBytes, totalBytes: $0.totalBytes, floorBytes: $0.floorBytes) }
        let update = await system.info().update.map { MonitorUpdate(state: $0.state, available: $0.available, current: $0.current, latest: $0.latest) }
        let counts = await auth.signInCounts()
        return .json(MonitorAnswer(time: Date(), version: configuration.version, state: StatusText.engineStateName(overview.state), cameras: cameras,
                                   recordings: recordings, archive: drive, update: update,
                                   signIn: MonitorSignIn(failedLastHour: counts.lastHour, failedLastDay: counts.lastDay, lockedAddresses: counts.lockedAddresses,
                                                         everyoneWaits: counts.everyoneWaits)))
    }
}
