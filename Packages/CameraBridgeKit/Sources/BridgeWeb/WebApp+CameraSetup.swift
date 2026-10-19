import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// "Set up for Camera Bridge" (docs/superpowers/specs/2026-10-16-camera-setup-design.md): the preview, the run and the restore of one camera,
// and "Restart the camera now" for a camera that took a change "after it restarts".

extension WebApp {
    static let cameraSetupRoutes: [Route] = [
        Route("GET", "cameras/:id/setup") { app, ctx in try await app.cameraSetupPreview(ctx) },
        Route("POST", "cameras/:id/setup", takesBody: true) { app, ctx in try await app.applyCameraSetup(ctx) },
        Route("POST", "cameras/:id/setup/restore", takesBody: true) { app, ctx in try await app.restoreCameraSetup(ctx) },
    ]

    private struct CameraSetupRequest: Decodable {
        var confirm: Bool?
        /// "Fix its address so the DNS stays", the person's choice in the preview (off unless sent).
        var fixAddress: Bool?
        /// With the choice: the camera's address as the preview showed it (`address`, `subnetMask`, `gateway`).
        var keeps: CameraAddressing?
    }

    /// `GET cameras/:id/setup`: reads the camera and answers what the setup would change, step by step. Changes nothing.
    func cameraSetupPreview(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try await knownCamera(ctx)
        do {
            return .json(try await backend.cameraSetupPreview(cameraID: id))
        } catch {
            throw Self.cameraSetupError(error, code: "camera_setup_unavailable")
        }
    }

    /// `POST cameras/:id/setup {confirm: true}`: applies the setup (it holds the engine's operations lock, up to a minute). Never automatic: the
    /// page sends it when the person presses the button, and never retries it. With `fixAddress: true` ("Fix its address so the DNS stays",
    /// off unless sent) it also needs `keeps`, the camera's address as the preview showed it: the engine fixes only that one.
    func applyCameraSetup(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try await knownCamera(ctx)
        let sentence = "Confirm that the camera’s settings may be changed."
        guard !ctx.request.body.isEmpty else { throw APIError.badRequest(sentence, field: "confirm") }
        let request = try decode(CameraSetupRequest.self, from: ctx)
        guard request.confirm == true else { throw APIError.badRequest(sentence, field: "confirm") }
        let fixAddress = request.fixAddress == true
        if fixAddress, request.keeps == nil {
            throw APIError.badRequest("Say which address the camera keeps: the one the preview showed.", field: "keeps")
        }
        let options = CameraSetupOptions(fixAddress: fixAddress, shownAddress: fixAddress ? request.keeps : nil)
        guard archiveState.beginOptimizing(id) else {
            throw APIError.conflict("camera_setup_busy", "This camera’s settings are already being changed. Wait for that to finish.")
        }
        defer { archiveState.endOptimizing(id) }
        log.notice("setting a camera up for Camera Bridge was requested from the web interface\(fixAddress ? ", with its address fixed as it is" : "")")
        do {
            return .json(try await backend.applyCameraSetup(cameraID: id, options: options))
        } catch {
            log.warning("setting a camera up failed: \(ErrorText.logDescription(error))")
            throw Self.cameraSetupError(error, code: "camera_setup_failed")
        }
    }

    /// `POST cameras/:id/setup/restore {confirm: true}`: writes back every setting the setup saved.
    func restoreCameraSetup(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try await knownCamera(ctx)
        guard !ctx.request.body.isEmpty, try decode(CameraSetupRequest.self, from: ctx).confirm == true else {
            throw APIError.badRequest("Confirm that the camera’s original settings may be written back.", field: "confirm")
        }
        guard archiveState.beginOptimizing(id) else {
            throw APIError.conflict("camera_setup_busy", "This camera’s settings are already being changed. Wait for that to finish.")
        }
        defer { archiveState.endOptimizing(id) }
        log.notice("restoring a camera's original settings was requested from the web interface")
        do {
            return .json(try await backend.restoreCameraSetup(cameraID: id))
        } catch {
            log.warning("restoring a camera's settings failed: \(ErrorText.logDescription(error))")
            throw Self.cameraSetupError(error, code: "camera_setup_failed")
        }
    }

    /// `POST cameras/:id/restart` ("Restart the camera now", the page confirms first): restarts the camera, only while it waits for a restart
    /// to apply a change it took (`BridgeEngine.offersCameraRestart`); 409 `camera_restart_not_needed` otherwise, so a page left open can't
    /// restart it at will, and `camera_setup_busy` while its settings are being changed. 204 once the camera took it: it is off the network
    /// for about a minute. Never retried.
    func restartCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try await knownCamera(ctx)
        guard let camera = await backend.overview().configurations.first(where: { $0.id == id }), BridgeEngine.offersCameraRestart(camera) else {
            throw Self.restartNotNeeded
        }
        guard archiveState.beginOptimizing(id) else {
            throw APIError.conflict("camera_setup_busy", "This camera’s settings are already being changed. Wait for that to finish.")
        }
        defer { archiveState.endOptimizing(id) }
        log.notice("restarting a camera was requested from the web interface")
        do {
            try await backend.restartCamera(cameraID: id)
        } catch is CameraRestartNotNeeded {
            throw Self.restartNotNeeded
        } catch {
            log.warning("restarting a camera failed: \(ErrorText.logDescription(error))")
            throw Self.cameraSetupError(error, code: "camera_restart_failed")
        }
        return .empty()
    }

    private static let restartNotNeeded = APIError.conflict("camera_restart_not_needed", CameraRestartNotNeeded().description)

    private func knownCamera(_ ctx: RequestContext) async throws -> UUID {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        return id
    }

    private static func cameraSetupError(_ error: any Error, code: String) -> APIError {
        switch error {
        case EngineError.unknownCamera: return APIError.notFound("This camera was removed.")
        case EngineError.cameraNotRunning: return APIError(status: 422, code: code, message: "This bridge can’t change camera settings.")
        case EngineError.invalidSettings(let reason): return APIError(status: 422, code: code, message: ErrorText.sentence(reason))
        default: return APIError(status: 422, code: code, message: ErrorText.describe(error))
        }
    }
}
