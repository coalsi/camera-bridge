import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// "Set up for Camera Bridge" (docs/superpowers/specs/2026-10-16-camera-setup-design.md): the preview, the run and the restore of one camera.

extension WebApp {
    static let cameraSetupRoutes: [Route] = [
        Route("GET", "cameras/:id/setup") { app, ctx in try await app.cameraSetupPreview(ctx) },
        Route("POST", "cameras/:id/setup", takesBody: true) { app, ctx in try await app.applyCameraSetup(ctx) },
        Route("POST", "cameras/:id/setup/restore", takesBody: true) { app, ctx in try await app.restoreCameraSetup(ctx) },
    ]

    private struct CameraSetupRequest: Decodable {
        var confirm: Bool?
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
    /// page sends it when the person presses the button, and never retries it.
    func applyCameraSetup(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try await knownCamera(ctx)
        let sentence = "Confirm that the camera’s settings may be changed."
        guard !ctx.request.body.isEmpty, try decode(CameraSetupRequest.self, from: ctx).confirm == true else {
            throw APIError.badRequest(sentence, field: "confirm")
        }
        guard archiveState.beginOptimizing(id) else {
            throw APIError.conflict("camera_setup_busy", "This camera’s settings are already being changed. Wait for that to finish.")
        }
        defer { archiveState.endOptimizing(id) }
        log.notice("setting a camera up for Camera Bridge was requested from the web interface")
        do {
            return .json(try await backend.applyCameraSetup(cameraID: id))
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
