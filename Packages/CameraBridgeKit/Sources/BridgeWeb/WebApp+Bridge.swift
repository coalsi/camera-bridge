import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// Settings, the bridge's state, logs, diagnostics, the event stream and the system.

extension WebApp {
    // MARK: Settings

    func getSettings() async -> HTTPResponse {
        let overview = await backend.overview()
        return .json(SettingsResource(settings: overview.settings, bridgeName: await auth.bridgeName, webhookProblem: overview.webhookProblem))
    }

    private struct SettingsPatch: Decodable {
        var bridgeName: String?
        var basePort: Int?
        var sensorsBridgePort: Int?
        var webhookEnabled: Bool?
        var webhookPort: Int?
        var regenerateWebhookToken: Bool?
        var logLevel: String?
        var motionShadowTest: Bool?
    }

    func patchSettings(_ ctx: RequestContext) async throws -> HTTPResponse {
        let patch = try decode(SettingsPatch.self, from: ctx)
        for (value, field, allowZero) in [(patch.basePort, "basePort", false), (patch.sensorsBridgePort, "sensorsBridgePort", true),
                                          (patch.webhookPort, "webhookPort", true)] {
            guard let value else { continue }
            guard (allowZero && value == 0) || (1_024...65_535).contains(value) else {
                throw APIError.badRequest("Use a port between 1024 and 65535.", field: field)
            }
        }
        var level: LogLevel?
        if let name = patch.logLevel {
            guard let parsed = SettingsResource.level(named: name) else { throw APIError.badRequest("Choose a log level from debug to error.", field: "logLevel") }
            level = parsed
        }
        if let name = patch.bridgeName {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.badRequest("Give the bridge a name.", field: "bridgeName") }
            do {
                try await auth.setBridgeName(name)
            } catch let failure as AuthStore.Failure {
                throw authError(failure)
            }
        }
        let token = patch.regenerateWebhookToken == true ? Secrets.hex(Secrets.randomBytes(16)) : nil
        let (basePort, sensorsPort, webhookEnabled, webhookPort, shadow) = (patch.basePort, patch.sensorsBridgePort, patch.webhookEnabled, patch.webhookPort, patch.motionShadowTest)
        let newLevel = level
        do {
            try await backend.updateSettings { settings in
                if let basePort { settings.basePort = UInt16(basePort) }
                if let sensorsPort { settings.sensorsBridgePort = UInt16(sensorsPort) }
                if let webhookEnabled { settings.webhookEnabled = webhookEnabled }
                if let webhookPort { settings.webhookPort = UInt16(webhookPort) }
                if let token { settings.webhookToken = token }
                if let newLevel { settings.logLevel = newLevel }
                if let shadow { settings.motionShadowTest = shadow }
            }
        } catch {
            throw APIError(status: 422, code: "settings_failed", message: ErrorText.describe(error))
        }
        return await getSettings()
    }

    func pauseBridge() async -> HTTPResponse {
        await backend.pause()
        return .empty()
    }

    func resumeBridge() async -> HTTPResponse {
        await backend.resume()
        return .empty()
    }

    // MARK: Logs and diagnostics

    private struct LogList: Encodable {
        var lines: [LogLineResource]
    }

    /// `GET /logs?since=<ISO 8601>&limit=<1...1000>&level=<name>`: recent lines, oldest first; as server-sent events (`event: log`) when
    /// the client asks for `text/event-stream`: the newest lines first, then each new one as it is written.
    func logLines(_ ctx: RequestContext) -> HTTPResponse {
        let request = ctx.request
        let limit = min(max(Int(request.queryValue("limit") ?? "") ?? 200, 1), 1_000)
        let level = request.queryValue("level").flatMap(SettingsResource.level(named:)) ?? .info
        let since = request.queryValue("since").flatMap { ISO8601DateFormatter().date(from: $0) }
        if !request.acceptsEventStream {
            return .json(LogList(lines: logs.recent(limit: limit, since: since, level: level).map(LogLineResource.init)))
        }
        guard takeEventSlot() else {
            return .error(APIError(status: 429, code: "too_many_streams", message: "Too many pages are listening. Close one and try again.", headers: [("Retry-After", "5")]))
        }
        let logs = logs
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        headers["X-Accel-Buffering"] = "no"
        return .stream(contentType: "text/event-stream; charset=utf-8", headers: headers) { [self] stream in
            defer { releaseEventSlot() }
            let live = logs.subscribe()   // before the backlog, so nothing falls between the two
            try await stream.write("retry: 3000\n\n")
            var seen = Set<UUID>()
            for entry in logs.recent(limit: limit, since: since, level: level) {
                seen.insert(entry.id)
                try await stream.write(EventHub.event("log", LogLineResource(entry)).text)
            }
            for await entry in live where entry.level >= level && !seen.contains(entry.id) {
                try await stream.write(EventHub.event("log", LogLineResource(entry)).text)
            }
        }
    }

    func diagnostics() async -> HTTPResponse {
        let text = await backend.diagnosticsReport(context: configuration.diagnosticsContext(launched))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        var response = HTTPResponse.text(text)
        response.headers["Content-Disposition"] = "attachment; filename=\"CameraBridge-Diagnostics-\(stamp).txt\""
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    // MARK: Events

    /// Server-sent events: `bridge`, `camera`, `removed`, `motion`, `doorbell`, `notices` (see `EventHub`). The state as it is now
    /// comes first, so a page that reconnects catches up.
    func events(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard takeEventSlot() else {
            throw APIError(status: 429, code: "too_many_streams", message: "Too many pages are listening. Close one and try again.", headers: [("Retry-After", "5")])
        }
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        headers["X-Accel-Buffering"] = "no"
        let (backend, hub) = (backend, hub)
        return .stream(contentType: "text/event-stream; charset=utf-8", headers: headers) { [self] stream in
            defer { releaseEventSlot() }
            let live = hub.subscribe()
            try await stream.write("retry: 3000\n\n")
            for event in EventHub.snapshotEvents(await backend.overview()) { try await stream.write(event.text) }
            for await event in live { try await stream.write(event.text) }
        }
    }

    // MARK: System

    private func systemFailure(_ error: any Error) -> APIError {
        if let failure = error as? SystemError { return APIError.conflict("system_error", failure.message) }
        return APIError(status: 500, code: "system_error", message: "The system couldn’t do that. The log has the details.")
    }

    func systemInfo() async -> HTTPResponse {
        .json(await system.info())
    }

    private struct UpdateRequest: Decodable {
        var action: String
    }

    func systemUpdate(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(UpdateRequest.self, from: ctx)
        do {
            switch body.action {
            case "check": return .json(try await system.checkForUpdate())
            case "apply":
                log.notice("installing a system update")
                return .json(try await system.applyUpdate())
            default: throw APIError.badRequest("Choose “check” or “apply”.", field: "action")
            }
        } catch let error as APIError {
            throw error
        } catch {
            log.warning("system update failed: \(ErrorText.logDescription(error))")
            throw systemFailure(error)
        }
    }

    private struct Confirmation: Decodable {
        var confirm: Bool?
    }

    func systemReboot(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(Confirmation.self, from: ctx)
        guard body.confirm == true else { throw APIError.badRequest("Confirm that the bridge should restart.", field: "confirm") }
        do {
            log.notice("restart requested from the web interface")
            try await system.reboot()
        } catch {
            throw systemFailure(error)
        }
        return .empty(202)
    }

    func systemPowerOff(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(Confirmation.self, from: ctx)
        guard body.confirm == true else { throw APIError.badRequest("Confirm that the bridge should switch off.", field: "confirm") }
        do {
            log.notice("switching off requested from the web interface")
            try await system.powerOff()
        } catch {
            throw systemFailure(error)
        }
        return .empty(202)
    }

    func systemDisks() async throws -> HTTPResponse {
        struct Disks: Encodable { var disks: [InstallTarget] }
        do {
            return .json(Disks(disks: try await system.installTargets()))
        } catch {
            throw systemFailure(error)
        }
    }

    private struct InstallRequest: Decodable {
        var targetID: String?
        /// What the person typed: "ERASE ALL DATA ON <disk name>".
        var phrase: String?
        var copyData: Bool?
    }

    func systemInstall(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(InstallRequest.self, from: ctx)
        guard let target = body.targetID, !target.isEmpty else { throw APIError.badRequest("Choose the disk to install to.", field: "targetID") }
        guard let phrase = body.phrase, !phrase.isEmpty, phrase.utf8.count <= 200 else {
            throw APIError.badRequest("Type the sentence shown to confirm that the disk may be erased.", field: "phrase")
        }
        do {
            log.notice("install to a disk requested from the web interface")
            try await system.install(targetID: target, phrase: phrase, copyData: body.copyData ?? true)
        } catch {
            log.warning("install failed: \(ErrorText.logDescription(error))")
            throw systemFailure(error)
        }
        return .empty(202)
    }

    private struct SSHRequest: Decodable {
        var enabled: Bool?
        var authorizedKeys: String?
    }

    func systemSSH(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(SSHRequest.self, from: ctx)
        guard let enabled = body.enabled else { throw APIError.badRequest("Choose whether SSH is on or off.", field: "enabled") }
        var keys: [String] = []
        if enabled {
            do {
                keys = try SSHKeys.parse(body.authorizedKeys ?? "")
            } catch let error as SystemError {
                throw APIError.badRequest(error.message, field: "authorizedKeys")
            }
        }
        do {
            log.notice("SSH \(enabled ? "on" : "off") requested from the web interface")
            try await system.setSSH(enabled: enabled, authorizedKeys: keys)
        } catch {
            throw systemFailure(error)
        }
        return .json(await system.info())
    }

    private struct AutomaticUpdatesRequest: Decodable {
        var enabled: Bool?
    }

    func systemAutomaticUpdates(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(AutomaticUpdatesRequest.self, from: ctx)
        guard let enabled = body.enabled else { throw APIError.badRequest("Choose whether automatic updates are on or off.", field: "enabled") }
        do {
            try await system.setAutomaticUpdates(enabled)
        } catch {
            throw systemFailure(error)
        }
        return .json(await system.info())
    }

    private struct FactoryResetRequest: Decodable {
        var confirm: String?
    }

    func systemFactoryReset(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(FactoryResetRequest.self, from: ctx)
        guard body.confirm == "RESET" else { throw APIError.badRequest("Type RESET to confirm.", field: "confirm") }
        do {
            log.notice("factory reset requested from the web interface")
            try await system.factoryReset()
        } catch {
            throw systemFailure(error)
        }
        return .empty(202)
    }
}
