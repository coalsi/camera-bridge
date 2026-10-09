import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore

// The API's route table. Contract: docs/linux/ARCHITECTURE.md ("Web API").

extension WebApp {
    static let routes: [Route] = [
        // Session
        Route("GET", "status", .open) { app, ctx in try await app.status(ctx) },
        Route("GET", "health", .open) { app, _ in await app.health() },
        Route("GET", "session", .open) { app, ctx in await app.sessionInfo(ctx) },
        Route("POST", "auth/setup", .open, takesBody: true) { app, ctx in try await app.setup(ctx) },
        Route("POST", "auth/login", .open, takesBody: true) { app, ctx in try await app.login(ctx) },
        Route("POST", "auth/logout") { app, ctx in await app.logout(ctx) },
        Route("POST", "auth/password", takesBody: true) { app, ctx in try await app.changePassword(ctx) },
        // Cameras
        Route("GET", "camera-types") { app, _ in await app.cameraTypes() },
        Route("GET", "cameras") { app, _ in await app.listCameras() },
        Route("POST", "cameras", takesBody: true) { app, ctx in try await app.addCamera(ctx) },
        Route("GET", "cameras/:id") { app, ctx in try await app.getCamera(ctx) },
        Route("PATCH", "cameras/:id", takesBody: true) { app, ctx in try await app.patchCamera(ctx) },
        Route("DELETE", "cameras/:id") { app, ctx in try await app.deleteCamera(ctx) },
        Route("GET", "cameras/:id/snapshot") { app, ctx in try await app.snapshot(ctx) },
        Route("GET", "cameras/:id/live") { app, ctx in try await app.live(ctx) },
        Route("GET", "cameras/:id/pairing") { app, ctx in try await app.pairing(ctx) },
        Route("POST", "cameras/:id/reset-pairing") { app, ctx in try await app.resetPairing(ctx) },
        Route("POST", "cameras/:id/test-motion") { app, ctx in try await app.testMotion(ctx) },
        Route("POST", "discover") { app, _ in await app.discover() },
        Route("POST", "probe", takesBody: true) { app, ctx in try await app.probe(ctx) },
        Route("POST", "integrations/unifi/cameras", takesBody: true) { app, ctx in try await app.unifiCameras(ctx) },
        Route("POST", "integrations/nest/authorize", takesBody: true) { app, ctx in try await app.nestAuthorize(ctx) },
        Route("POST", "integrations/nest/connect", takesBody: true) { app, ctx in try await app.nestConnect(ctx) },
        Route("GET", "sensors-bridge") { app, _ in await app.sensorsBridge() },
        Route("POST", "sensors-bridge/reset-pairing") { app, _ in try await app.resetSensorsBridgePairing() },
        // Bridge
        Route("GET", "settings") { app, _ in await app.getSettings() },
        Route("PATCH", "settings", takesBody: true) { app, ctx in try await app.patchSettings(ctx) },
        Route("POST", "bridge/pause") { app, _ in await app.pauseBridge() },
        Route("POST", "bridge/resume") { app, _ in await app.resumeBridge() },
        Route("GET", "logs") { app, ctx in app.logLines(ctx) },
        Route("GET", "diagnostics") { app, _ in await app.diagnostics() },
        Route("GET", "events") { app, ctx in try await app.events(ctx) },
        // System
        Route("GET", "system") { app, _ in await app.systemInfo() },
        Route("POST", "system/update", takesBody: true) { app, ctx in try await app.systemUpdate(ctx) },
        Route("POST", "system/reboot", takesBody: true) { app, ctx in try await app.systemReboot(ctx) },
        Route("GET", "system/disks") { app, _ in try await app.systemDisks() },
        Route("POST", "system/install", takesBody: true) { app, ctx in try await app.systemInstall(ctx) },
        Route("POST", "system/poweroff", takesBody: true) { app, ctx in try await app.systemPowerOff(ctx) },
        Route("POST", "system/ssh", takesBody: true) { app, ctx in try await app.systemSSH(ctx) },
        Route("POST", "system/auto-update", takesBody: true) { app, ctx in try await app.systemAutomaticUpdates(ctx) },
        Route("POST", "system/factory-reset", takesBody: true) { app, ctx in try await app.systemFactoryReset(ctx) },
    ]

    // MARK: Status and session

    private struct PublicStatus: Encodable {
        var product: String
        var version: String
        var name: String
        var setupRequired: Bool
        var authenticated: Bool
    }

    private struct CameraCounts: Encodable {
        var total: Int
        var online: Int
        var paired: Int
    }

    private struct SensorsBridgeSummary: Encodable {
        var paired: Bool
        var accessoryCount: Int
    }

    private struct SystemSummary: Encodable {
        var mode: String
        var hostname: String?
        var updateAvailable: Bool
        var updateState: String?
        var latestVersion: String?
    }

    private struct FullStatus: Encodable {
        var product: String
        var version: String
        var build: String
        var name: String
        var setupRequired: Bool
        var authenticated: Bool
        var state: String
        var stateText: String
        var uptimeSeconds: Int
        var cameras: CameraCounts
        var localNetwork: String
        var notices: [NoticeResource]
        var configurationRecovered: Bool
        var streamingHelperInstalled: Bool
        var sensorsBridge: SensorsBridgeSummary?
        var system: SystemSummary
    }

    func status(_ ctx: RequestContext) async throws -> HTTPResponse {
        let configured = await auth.isConfigured
        let name = await auth.bridgeName
        guard ctx.session != nil else {
            return .json(PublicStatus(product: configuration.product, version: configuration.version, name: name, setupRequired: !configured, authenticated: false))
        }
        let overview = await backend.overview()
        let info = await system.info()
        let paired = overview.cameras.filter(\.isPaired).count
        return .json(FullStatus(
            product: configuration.product, version: configuration.version, build: configuration.build, name: name, setupRequired: false,
            authenticated: true, state: StatusText.engineStateName(overview.state), stateText: StatusText.engineState(overview.state),
            uptimeSeconds: Int(Date().timeIntervalSince(launched)),
            cameras: CameraCounts(total: overview.configurations.count, online: overview.cameras.filter { $0.connection == .online }.count, paired: paired),
            localNetwork: "\(overview.localNetworkAccess)", notices: NoticeResource.resources(for: overview.networkNotices),
            configurationRecovered: overview.configurationRecovered, streamingHelperInstalled: overview.streamingHelperInstalled,
            sensorsBridge: overview.sensorsBridge.map { SensorsBridgeSummary(paired: $0.isPaired, accessoryCount: $0.accessoryCount) },
            system: SystemSummary(mode: info.mode, hostname: info.hostname, updateAvailable: info.update?.available ?? false,
                                  updateState: info.update?.state, latestVersion: info.update?.latest)))
    }

    /// For the update check after a restart and for monitoring: 200 while the bridge runs (or is paused on purpose), 503 otherwise.
    func health() async -> HTTPResponse {
        let overview = await backend.overview()
        let healthy: Bool
        switch overview.state {
        case .running, .paused: healthy = true
        default: healthy = false
        }
        struct Health: Encodable {
            var ok: Bool
            var state: String
        }
        return .json(Health(ok: healthy, state: StatusText.engineStateName(overview.state)), status: healthy ? 200 : 503)
    }

    func sessionInfo(_ ctx: RequestContext) async -> HTTPResponse {
        struct Info: Encodable {
            var authenticated: Bool
            var setupRequired: Bool
            var setupTokenRequired: Bool
            var bridgeName: String
            var csrfToken: String?
        }
        return .json(Info(authenticated: ctx.session != nil, setupRequired: !(await auth.isConfigured), setupTokenRequired: configuration.setupToken != nil,
                          bridgeName: await auth.bridgeName, csrfToken: ctx.session?.csrfToken))
    }

    // MARK: Authentication

    private struct Credentials: Decodable {
        var password: String
        var bridgeName: String?
        var setupToken: String?
    }

    private struct SignedIn: Encodable {
        var csrfToken: String
        var bridgeName: String
    }

    func authError(_ failure: AuthStore.Failure) -> APIError {
        switch failure {
        case .alreadyConfigured: .conflict("already_configured", "A password is already set. Sign in instead.")
        case .notConfigured: APIError(status: 409, code: "setup_required", message: "Set the administrator password first.")
        case .passwordTooShort: APIError.badRequest("Use at least \(AuthStore.passwordLength.lowerBound) characters.", field: "password")
        case .passwordTooLong: APIError.badRequest("Use at most \(AuthStore.passwordLength.upperBound) characters.", field: "password")
        case .wrongPassword: APIError(status: 401, code: "wrong_password", message: "That password isn’t right.", field: "password")
        case .storageFailed: APIError(status: 500, code: "storage", message: "The password couldn’t be saved. The disk may be full or read-only.")
        }
    }

    private func tooManyAttempts(_ seconds: Int) -> APIError {
        APIError(status: 429, code: "too_many_attempts", message: "Too many wrong tries. Wait \(seconds) second\(seconds == 1 ? "" : "s") and try again.",
                 headers: [("Retry-After", String(seconds))])
    }

    func setup(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(Credentials.self, from: ctx)
        if await auth.isConfigured { throw authError(.alreadyConfigured) }
        if let expected = configuration.setupToken {
            if let wait = await auth.loginDelay(address: ctx.request.remoteAddress) { throw tooManyAttempts(wait) }
            guard Secrets.constantTimeEqual(body.setupToken ?? "", expected) else {
                await auth.recordLogin(address: ctx.request.remoteAddress, success: false)
                throw APIError(status: 403, code: "setup_token", message: "That setup code isn’t right.", field: "setupToken")
            }
        }
        do {
            try await auth.configure(password: body.password, bridgeName: body.bridgeName)
        } catch let failure as AuthStore.Failure {
            throw authError(failure)
        }
        log.notice("the administrator password was set")
        return try await startSession(status: 201)
    }

    func login(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(Credentials.self, from: ctx)
        guard await auth.isConfigured else { throw authError(.notConfigured) }
        let address = ctx.request.remoteAddress
        if let wait = await auth.loginDelay(address: address) { throw tooManyAttempts(wait) }
        guard await auth.verify(body.password) else {
            await auth.recordLogin(address: address, success: false)
            throw authError(.wrongPassword)
        }
        await auth.recordLogin(address: address, success: true)
        return try await startSession(status: 200)
    }

    private func startSession(status: Int) async throws -> HTTPResponse {
        let created: (token: String, session: AuthStore.Session)
        do {
            created = try await auth.createSession()
        } catch let failure as AuthStore.Failure {
            throw authError(failure)
        }
        var response = HTTPResponse.json(SignedIn(csrfToken: created.session.csrfToken, bridgeName: await auth.bridgeName), status: status)
        response.headers.add("Set-Cookie", sessionCookie(token: created.token, secure: false))
        return response
    }

    func logout(_ ctx: RequestContext) async -> HTTPResponse {
        if let token = ctx.sessionToken { await auth.endSession(token: token) }
        var response = HTTPResponse.empty()
        response.headers.add("Set-Cookie", Self.clearedCookie())
        return response
    }

    private struct PasswordChange: Decodable {
        var current: String
        var new: String
    }

    func changePassword(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(PasswordChange.self, from: ctx)
        let address = ctx.request.remoteAddress
        if let wait = await auth.loginDelay(address: address) { throw tooManyAttempts(wait) }
        do {
            try await auth.changePassword(current: body.current, new: body.new, keeping: ctx.session?.id)
        } catch let failure as AuthStore.Failure {
            if failure == .wrongPassword {
                await auth.recordLogin(address: address, success: false)
                throw APIError(status: 401, code: "wrong_password", message: "The current password isn’t right.", field: "current")
            }
            throw authError(failure)
        }
        await auth.recordLogin(address: address, success: true)
        log.notice("the administrator password was changed; other browsers were signed out")
        return .empty()
    }

    // MARK: Camera types

    func cameraTypes() async -> HTTPResponse {
        struct GroupInfo: Encodable {
            var id: String
            var title: String
            var footer: String?
        }
        struct Types: Encodable {
            var groups: [GroupInfo]
            var types: [CameraTypeSpec]
            var streamingHelperInstalled: Bool
        }
        let overview = await backend.overview()
        let types = CameraTypeCatalog.all.filter { configuration.offersDemoCamera || $0.id != "demo" }
        let groups = CameraTypeSpec.Group.allCases.filter { group in types.contains { $0.group == group } }
            .map { GroupInfo(id: $0.rawValue, title: $0.title, footer: $0.footer) }
        return .json(Types(groups: groups, types: types, streamingHelperInstalled: overview.streamingHelperInstalled))
    }

    // MARK: Cameras

    func listCameras() async -> HTTPResponse {
        struct List: Encodable { var cameras: [CameraResource] }
        return .json(List(cameras: await backend.overview().cameraResources()))
    }

    func getCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard let camera = await backend.overview().cameraResource(id: id) else { throw APIError.notFound("There is no camera with this identifier.") }
        return .json(camera)
    }

    func deleteCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        await backend.removeCamera(id: id)
        return .empty()
    }

    func addCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(SetupRequest.self, from: ctx)
        let overview = await backend.overview()
        let prepared = try CameraSetup.prepare(body, helperInstalled: overview.streamingHelperInstalled, nest: nestSignIn(named: body.nestSession))
        let result: CameraProbeResult
        do {
            result = try await CameraSetup.probe(prepared, backend: backend)
        } catch let problem as SetupProblem {
            throw APIError.badRequest(problem.message, field: problem.field)
        } catch {
            log.notice("checking \(prepared.endpoint.host) failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "probe_failed", message: ErrorText.describe(error))
        }
        let configuration = try CameraSetup.makeConfiguration(prepared: prepared, result: result, request: body)
        do {
            try await backend.addCamera(configuration, password: prepared.secret)
        } catch EngineError.duplicateCamera {
            throw APIError.conflict("duplicate", ErrorText.describe(EngineError.duplicateCamera))
        } catch {
            log.warning("adding \(configuration.name) failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "add_failed", message: ErrorText.describe(error))
        }
        if let nest = body.nestSession { nestSignIns.withLock { _ = $0.removeValue(forKey: nest) } }
        guard let camera = await backend.overview().cameraResource(id: configuration.id) else {
            throw APIError(status: 500, code: "internal", message: "The camera was added but could not be read back.")
        }
        return .json(camera, status: 201)
    }

    // MARK: Camera changes

    private struct EndpointPatch: Decodable {
        var host: String?
        var httpPort: Int?
        var rtspPort: Int?
        var onvifPort: Int?
        var useHTTPS: Bool?
    }

    private struct OverlayPatch: Decodable {
        var enabled: Bool?
        var position: OverlayPosition?
        var showCameraName: Bool?
        var showDate: Bool?
        var showSeconds: Bool?
        var use24Hour: Bool?
        var size: OverlaySize?
    }

    private struct CameraPatch: Decodable {
        var name: String?
        var isEnabled: Bool?
        var username: String?
        var password: String?
        var endpoint: EndpointPatch?
        var mainStreamURL: String?
        var subStreamURL: String?
        var motionSource: MotionSource?
        var motionSensitivity: Double?
        var motionHoldSeconds: Int?
        var sensors: [String: Bool]?
        var audioEnabled: Bool?
        var twoWayAudio: Bool?
        var liveStreamMode: LiveStreamMode?
        var liveQualityMode: LiveQualityMode?
        var liveMaxBitrateOverride: MaxBitrateOverride?
        var recordingStreamMode: RecordingStreamMode?
        var recordingQualityMode: RecordingQualityMode?
        var timestampOverlay: OverlayPatch?
    }

    func patchCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let patch = try decode(CameraPatch.self, from: ctx)
        guard var camera = await backend.overview().configurations.first(where: { $0.id == id }) else {
            throw APIError.notFound("There is no camera with this identifier.")
        }
        if let name = patch.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw APIError.badRequest("Give the camera a name.", field: "name") }
            camera.name = String(trimmed.prefix(60))
        }
        if let value = patch.isEnabled { camera.isEnabled = value }
        if let value = patch.username { camera.username = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let endpoint = patch.endpoint {
            if let host = endpoint.host {
                guard let input = HostInput(host) else {
                    throw APIError.badRequest("Enter an IP address or host name, like 192.0.2.20 or camera.local.", field: "endpoint.host")
                }
                camera.endpoint.host = input.host
            }
            for (value, field) in [(endpoint.httpPort, "httpPort"), (endpoint.rtspPort, "rtspPort"), (endpoint.onvifPort, "onvifPort")] {
                if let value, !(1...65_535).contains(value) { throw APIError.badRequest("Ports must be between 1 and 65535.", field: "endpoint.\(field)") }
            }
            if let value = endpoint.httpPort { camera.endpoint.httpPort = value }
            if let value = endpoint.rtspPort { camera.endpoint.rtspPort = value }
            if let value = endpoint.onvifPort { camera.endpoint.onvifPort = value }
            if let value = endpoint.useHTTPS { camera.endpoint.useHTTPS = value }
        }
        for (text, field, keyPath) in [(patch.mainStreamURL, "mainStreamURL", \CameraConfiguration.mainStreamURL),
                                       (patch.subStreamURL, "subStreamURL", \CameraConfiguration.subStreamURL)] {
            guard let text else { continue }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                camera[keyPath: keyPath] = nil
            } else if let url = CameraSetup.streamURL(text) {
                camera[keyPath: keyPath] = url.removingUserInfo
            } else {
                throw APIError.badRequest(CameraSetup.isRTSPOverTLS(text) ? CameraSetup.rtspOverTLSUnsupported : "Enter a stream URL starting with rtsp://.", field: field)
            }
        }
        if let value = patch.motionSource, value != camera.motionSource {
            if value == .cameraEvents, let capabilities = camera.capabilities, !capabilities.events.contains(.motion) {
                throw APIError.badRequest("This camera doesn’t report motion itself. Choose built-in motion detection or the webhook.", field: "motionSource")
            }
            camera.motionSource = value
            if camera.capabilities != nil {   // a sensor the new source doesn't offer is turned off with it
                camera.sensors = SensorCatalog.filtered(camera.sensors, by: camera.capabilities, motionSource: value)
            }
        }
        if let value = patch.motionSensitivity {
            guard value.isFinite, (0...1).contains(value) else { throw APIError.badRequest("Sensitivity is between 0 and 1.", field: "motionSensitivity") }
            camera.motionSensitivity = value
        }
        if let value = patch.motionHoldSeconds {
            guard (1...3_600).contains(value) else { throw APIError.badRequest("Motion stays on for 1 to 3600 seconds.", field: "motionHoldSeconds") }
            camera.motionHoldSeconds = value
        }
        if let sensors = patch.sensors {
            let known = Dictionary(uniqueKeysWithValues: SensorCatalog.all.map { ($0.id, $0.path) })
            for (key, value) in sensors {
                guard let path = known[key] else { throw APIError.badRequest("There is no sensor called “\(key.prefix(30))”.", field: "sensors") }
                camera.sensors[keyPath: path] = value
            }
            if camera.capabilities != nil {
                camera.sensors = SensorCatalog.filtered(camera.sensors, by: camera.capabilities, motionSource: camera.motionSource)
            }
        }
        if let value = patch.audioEnabled { camera.audioEnabled = value }
        if let value = patch.twoWayAudio {
            if value, let capabilities = camera.capabilities, !capabilities.twoWayAudio {
                throw APIError.badRequest("This camera doesn’t support two-way audio.", field: "twoWayAudio")
            }
            camera.twoWayAudio = value
        }
        if let value = patch.liveStreamMode { camera.liveStreamMode = value }
        if let value = patch.liveQualityMode { camera.liveQualityMode = value }
        if let value = patch.liveMaxBitrateOverride { camera.liveMaxBitrateOverride = value }
        if let value = patch.recordingStreamMode { camera.recordingStreamMode = value }
        if let value = patch.recordingQualityMode { camera.recordingQualityMode = value }
        if let overlay = patch.timestampOverlay {
            if let value = overlay.enabled { camera.timestampOverlay.enabled = value }
            if let value = overlay.position { camera.timestampOverlay.position = value }
            if let value = overlay.showCameraName { camera.timestampOverlay.showCameraName = value }
            if let value = overlay.showDate { camera.timestampOverlay.showDate = value }
            if let value = overlay.showSeconds { camera.timestampOverlay.showSeconds = value }
            if let value = overlay.use24Hour { camera.timestampOverlay.use24Hour = value }
            if let value = overlay.size { camera.timestampOverlay.size = value }
        }
        let password = patch.password.flatMap { $0.isEmpty ? nil : $0 }
        do {
            try await backend.updateCamera(camera, password: password)
        } catch EngineError.unknownCamera {
            throw APIError.notFound("This camera was removed.")
        } catch {
            log.warning("changing \(camera.name) failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "update_failed", message: ErrorText.describe(error))
        }
        guard let updated = await backend.overview().cameraResource(id: id) else { throw APIError.notFound("This camera was removed.") }
        return .json(updated)
    }

    // MARK: Snapshot and live preview

    func snapshot(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        guard let jpeg = await backend.snapshotJPEG(cameraID: id) else {
            throw APIError(status: 503, code: "no_picture", message: "The camera has no picture yet.", headers: [("Retry-After", "5")])
        }
        var response = HTTPResponse(status: 200, contentType: "image/jpeg", data: jpeg)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// `multipart/x-mixed-replace` JPEGs: a quick look from the browser (Apple Home does the real viewing). A new picture every
    /// `liveFrameInterval`, for at most `liveLifetime`; the page starts it again while it is open.
    func live(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        guard takeLiveSlot() else {
            throw APIError(status: 429, code: "too_many_streams", message: "Too many live previews are open. Close one and try again.", headers: [("Retry-After", "5")])
        }
        let (backend, interval, lifetime) = (backend, configuration.liveFrameInterval, configuration.liveLifetime)
        let boundary = "cbframe"
        var headers = HTTPHeaders()
        headers["Cache-Control"] = "no-store"
        return .stream(contentType: "multipart/x-mixed-replace; boundary=\(boundary)", headers: headers) { [self] stream in
            defer { releaseLiveSlot() }
            let deadline = ContinuousClock.now + lifetime
            var waitingSince: ContinuousClock.Instant?
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let started = ContinuousClock.now
                if let jpeg = await backend.snapshotJPEG(cameraID: id) {
                    waitingSince = nil
                    var part = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
                    part.append(jpeg)
                    part.append(contentsOf: [0x0D, 0x0A])
                    try await stream.write(part)
                } else {
                    // No picture (camera offline, still starting): keep trying for a while, then give up.
                    waitingSince = waitingSince ?? started
                    if started - (waitingSince ?? started) > .seconds(30) { return }
                }
                let remaining = interval - (ContinuousClock.now - started)
                try await Task.sleep(for: max(remaining, .milliseconds(50)))
            }
        }
    }

    // MARK: Pairing

    func pairing(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let overview = await backend.overview()
        guard let camera = overview.configurations.first(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        let status = overview.cameras.first { $0.id == id }
        var resource = PairingResource(accessoryName: camera.name, paired: status?.isPaired ?? false, setupCode: nil, setupURI: nil, qrSVG: nil,
                                       blocker: nil, blockerMessage: nil, blockerAction: nil)
        if resource.paired { return .json(resource) }
        if let blocker = PairingBlocker.current(state: overview.state, isEnabled: camera.isEnabled, hapPort: status?.hapPort) {
            resource.blocker = blocker.rawValue
            resource.blockerMessage = blocker.message
            resource.blockerAction = blocker.action
        } else if let status, !status.setupURI.isEmpty {
            resource.setupCode = StatusText.setupCode(status.setupCode)
            resource.setupURI = status.setupURI
            resource.qrSVG = (try? QRCode(text: status.setupURI))?.svg()
        } else {
            resource.blocker = "waiting"
            resource.blockerMessage = "Waiting for the bridge to publish this accessory…"
        }
        return .json(resource)
    }

    func resetPairing(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        do {
            try await backend.resetPairing(cameraID: id)
        } catch {
            throw APIError(status: 422, code: "reset_failed", message: ErrorText.describe(error))
        }
        return .empty()
    }

    func testMotion(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let overview = await backend.overview()
        guard let camera = overview.configurations.first(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        let status = overview.cameras.first { $0.id == id }
        if let blocker = PairingBlocker.current(state: overview.state, isEnabled: camera.isEnabled, hapPort: status?.hapPort) {
            let reason: String
            switch blocker {
            case .cameraDisabled: reason = "This camera is turned off, so a motion event can’t reach the Home app."
            case .bridgePaused: reason = "The bridge is paused, so a motion event can’t reach the Home app."
            case .bridgeNotRunning: reason = "The bridge isn’t running, so a motion event can’t reach the Home app."
            case .bridgeStarting: reason = "The bridge is starting."
            case .accessoryNotRunning: reason = "This camera’s accessory isn’t running, so a motion event can’t reach the Home app."
            }
            throw APIError.conflict("not_published", reason)
        }
        await backend.triggerTestMotion(cameraID: id)
        return .empty()
    }

    // MARK: Finding and checking cameras

    func discover() async -> HTTPResponse {
        struct Found: Encodable { var cameras: [DiscoveredResource] }
        let configurations = await backend.overview().configurations
        var unique: [DiscoveredCamera] = []
        var indexByHost: [String: Int] = [:]
        for camera in await backend.discoverCameras() {
            guard let index = indexByHost[camera.host] else {
                indexByHost[camera.host] = unique.count
                unique.append(camera)
                continue
            }
            if unique[index].name == nil { unique[index].name = camera.name }
            if unique[index].hardware == nil { unique[index].hardware = camera.hardware }
            unique[index].xAddrs += camera.xAddrs.filter { !unique[index].xAddrs.contains($0) }
        }
        return .json(Found(cameras: unique.map { DiscoveredResource($0, configurations: configurations) }))
    }

    private struct StreamResource: Encodable {
        var summary: String
        var codec: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var audio: String?

        init(_ info: StreamInfo) {
            summary = StatusText.stream(info)
            codec = info.videoCodec.map(StatusText.videoCodec)
            width = info.width
            height = info.height
            fps = info.fps.flatMap { $0.isFinite ? $0 : nil }
            audio = info.audioCodec.map(StatusText.audioCodec)
        }
    }

    private struct MotionChoice: Encodable {
        var id: String
        var title: String
        var detail: String
    }

    private struct ProbeResource: Encodable {
        var ok = true
        var vendor: String
        var vendorName: String
        var manufacturer: String
        var model: String
        var serialNumber: String
        var firmware: String
        var mainStream: StreamResource?
        var subStream: StreamResource?
        var capabilities: CameraCapabilities
        var onvifPort: Int?
        var suggestedName: String
        var suggestedKind: CameraKind
        var suggestedMotionSource: MotionSource
        var motionSources: [MotionChoice]
        var sensorsByMotionSource: [String: [SensorCatalog.Sensor]]
        var hasCameraAudio: Bool
        var canUseTwoWayAudio: Bool
        var ringsThroughWebhook: Bool
        var alreadyAdded: AlreadyAdded?
    }

    private struct AlreadyAdded: Encodable {
        var id: UUID
        var name: String
    }

    private struct ProbeFailure: Encodable {
        var ok = false
        var error: String
    }

    func probe(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(SetupRequest.self, from: ctx)
        let overview = await backend.overview()
        let prepared = try CameraSetup.prepare(body, helperInstalled: overview.streamingHelperInstalled, nest: nestSignIn(named: body.nestSession))
        let result: CameraProbeResult
        do {
            result = try await CameraSetup.probe(prepared, backend: backend)
        } catch let problem as SetupProblem {
            throw APIError.badRequest(problem.message, field: problem.field)
        } catch is CancellationError {
            throw APIError(status: 499, code: "cancelled", message: "The check was cancelled.")
        } catch {
            log.notice("checking \(prepared.endpoint.host) failed: \(ErrorText.logDescription(error))")
            return .json(ProbeFailure(error: ErrorText.describe(error)))
        }
        let defaults = CameraSetup.Defaults(result: result, discoveredName: nil)
        let sources = CameraSetup.availableMotionSources(result.capabilities)
        var candidate = CameraConfiguration(name: defaults.name, kind: defaults.kind, vendor: result.vendor, endpoint: prepared.endpoint, username: prepared.username)
        candidate.mainStreamURL = (result.mainStream?.url ?? prepared.mainStreamURL)?.removingUserInfo
        candidate.serialNumber = result.serialNumber
        let existing = CameraSetup.alreadyAdded(candidate, in: overview.configurations)
        return .json(ProbeResource(
            vendor: result.vendor.rawValue, vendorName: StatusText.vendor(result.vendor), manufacturer: result.manufacturer, model: result.model,
            serialNumber: result.serialNumber, firmware: result.firmware, mainStream: result.mainStream.map(StreamResource.init),
            subStream: result.subStream.map(StreamResource.init), capabilities: result.capabilities, onvifPort: result.onvifPort,
            suggestedName: defaults.name, suggestedKind: defaults.kind, suggestedMotionSource: defaults.motionSource,
            motionSources: sources.map { MotionChoice(id: $0.rawValue, title: StatusText.motionSource($0), detail: StatusText.motionSourceDetail($0)) },
            sensorsByMotionSource: Dictionary(uniqueKeysWithValues: MotionSource.allCases.map {
                ($0.rawValue, SensorCatalog.available(in: result.capabilities, motionSource: $0))
            }),
            hasCameraAudio: result.mainStream.map { $0.audioCodec != nil } ?? true, canUseTwoWayAudio: result.capabilities.twoWayAudio,
            ringsThroughWebhook: defaults.kind == .doorbell && !result.capabilities.isDoorbell,
            alreadyAdded: existing.map { AlreadyAdded(id: $0.id, name: $0.name) }))
    }

    // MARK: Integrations

    private struct ConsoleRequest: Decodable {
        var host: String
        var httpPort: Int?
        var useHTTPS: Bool?
        var apiKey: String
    }

    func unifiCameras(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Item: Encodable {
            var id: String
            var name: String
            var model: String
            var connected: Bool
            var doorbell: Bool
        }
        struct List: Encodable { var cameras: [Item] }
        let body = try decode(ConsoleRequest.self, from: ctx)
        guard let input = HostInput(body.host) else { throw APIError.badRequest("Enter the console’s address, like 192.0.2.1.", field: "host") }
        let key = body.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.badRequest("Paste the API key from UniFi Protect.", field: "apiKey") }
        let secure = body.useHTTPS ?? (input.scheme != "http")
        let port = input.port ?? body.httpPort ?? (secure ? 443 : 80)
        guard (1...65_535).contains(port) else { throw APIError.badRequest("Ports must be between 1 and 65535.", field: "httpPort") }
        do {
            let cameras = try await backend.unifiProtectCameras(endpoint: CameraEndpoint(host: input.host, httpPort: port, rtspPort: 7441, useHTTPS: secure), apiKey: key)
            return .json(List(cameras: cameras.map { Item(id: $0.id, name: $0.name, model: $0.model, connected: $0.isConnected, doorbell: $0.isDoorbell) }))
        } catch {
            log.notice("listing the Protect cameras failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "console_failed", message: ErrorText.describe(error))
        }
    }

    private struct NestAuthorizeRequest: Decodable {
        var projectID: String
        var clientID: String
    }

    func nestAuthorize(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Link: Encodable { var url: String }
        let body = try decode(NestAuthorizeRequest.self, from: ctx)
        do {
            return .json(Link(url: try NestDeviceAccess.authorizationURL(projectID: body.projectID, clientID: body.clientID).absoluteString))
        } catch {
            throw APIError.badRequest(ErrorText.describe(error))
        }
    }

    private struct NestConnectRequest: Decodable {
        var projectID: String
        var clientID: String
        var clientSecret: String
        var code: String
    }

    func nestConnect(_ ctx: RequestContext) async throws -> HTTPResponse {
        struct Item: Encodable {
            var id: String
            var name: String
            var doorbell: Bool
            var transport: String
        }
        struct Connected: Encodable {
            var session: String
            var cameras: [Item]
        }
        let body = try decode(NestConnectRequest.self, from: ctx)
        guard let code = NestDeviceAccess.code(from: body.code) else {
            throw APIError.badRequest("Paste the code from the page Google showed (or that page’s address).", field: "code")
        }
        let access = NestDeviceAccess()
        do {
            let tokens = try await access.exchange(code: code, clientID: body.clientID, clientSecret: body.clientSecret)
            let cameras = try await access.cameras(projectID: body.projectID, accessToken: tokens.accessToken)
            guard !cameras.isEmpty else {
                throw APIError.conflict("no_cameras", "Google lists no cameras or doorbells for this project. Check that your home’s devices are linked to it.")
            }
            let id = Secrets.randomToken()
            nestSignIns.withLock { sessions in
                sessions = sessions.filter { Date().timeIntervalSince($0.value.created) < 900 }
                sessions[id] = NestSignIn(projectID: body.projectID.trimmingCharacters(in: .whitespaces), clientID: body.clientID.trimmingCharacters(in: .whitespaces),
                                          clientSecret: body.clientSecret.trimmingCharacters(in: .whitespaces), refreshToken: tokens.refreshToken,
                                          cameras: cameras, created: Date())
            }
            return .json(Connected(session: id, cameras: cameras.map { Item(id: $0.deviceID, name: $0.name, doorbell: $0.isDoorbell, transport: $0.protocolName) }))
        } catch let error as APIError {
            throw error
        } catch {
            log.notice("connecting to Google failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "nest_failed", message: ErrorText.describe(error))
        }
    }

    func nestSignIn(named id: String?) -> NestSignIn? {
        guard let id else { return nil }
        return nestSignIns.withLock { sessions in
            guard let sign = sessions[id], Date().timeIntervalSince(sign.created) < 900 else { return nil }
            return sign
        }
    }

    // MARK: Sensors bridge

    func sensorsBridge() async -> HTTPResponse {
        struct Bridge: Encodable {
            var available: Bool
            var paired: Bool
            var accessoryCount: Int
            var setupCode: String?
            var setupURI: String?
            var qrSVG: String?
            var message: String?
            var cameras: [CameraSensors]
        }
        let overview = await backend.overview()
        let rows = overview.configurations.compactMap { camera -> CameraSensors? in
            let names = (overview.sensorsBridge?.publishedSensors[camera.id] ?? []).map { "\($0)" }
            return names.isEmpty ? nil : CameraSensors(id: camera.id, name: camera.name, sensors: names)
        }
        var message: String?
        if overview.configurations.isEmpty {
            message = "It starts when you add a camera. Until then, Camera Bridge publishes nothing on your network."
        } else {
            switch overview.state {
            case .paused: message = "The bridge is paused. Resume it to use the sensors bridge."
            case .stopped, .failed: message = "The bridge isn’t running. Start it to use the sensors bridge."
            case .starting: message = "The bridge is starting."
            case .running: message = overview.sensorsBridge == nil ? "It isn’t running. The log shows why." : nil
            }
        }
        guard message == nil, let bridge = overview.sensorsBridge else {
            return .json(Bridge(available: false, paired: false, accessoryCount: 0, setupCode: nil, setupURI: nil, qrSVG: nil, message: message, cameras: []))
        }
        return .json(Bridge(available: true, paired: bridge.isPaired, accessoryCount: bridge.accessoryCount,
                            setupCode: bridge.isPaired ? nil : StatusText.setupCode(bridge.setupCode), setupURI: bridge.isPaired ? nil : bridge.setupURI,
                            qrSVG: bridge.isPaired ? nil : (try? QRCode(text: bridge.setupURI))?.svg(), message: nil, cameras: rows))
    }

    private struct CameraSensors: Encodable {
        var id: UUID
        var name: String
        var sensors: [String]
    }

    func resetSensorsBridgePairing() async throws -> HTTPResponse {
        do {
            try await backend.resetSensorsBridgePairing()
        } catch {
            throw APIError(status: 422, code: "reset_failed", message: ErrorText.describe(error))
        }
        return .empty()
    }
}
