import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation

// The second tier: the HomeKit optimizer behind a confirmation, for cameras on a smart codec (`POST /cameras/:id/optimize`, `.../optimize/undo`).

extension WebApp {
    // MARK: Optimize (R11, R12; the second tier)

    private struct OptimizeRequest: Decodable {
        var confirm: Bool?
    }

    private struct OptimizeResource: Encodable {
        struct Applied: Encodable {
            var id: String
            var title: String
        }

        struct Failed: Encodable {
            var id: String
            var reason: String
        }

        var applied: [Applied]
        var failed: [Failed]
        var canUndo: Bool
        var mayNeedRecordingReEnabled: Bool
        var scoreBefore: Int
        var scoreAfter: Int

        init(_ result: HomeKitOptimizationResult) {
            let titles = Dictionary((result.before.checks + result.after.checks).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            applied = result.appliedFixes.map { Applied(id: $0, title: titles[$0] ?? $0) }
            failed = result.failedFixes.map { Failed(id: $0.checkID, reason: Redact.string($0.reason)) }
            canUndo = result.canUndo
            mayNeedRecordingReEnabled = result.mayNeedRecordingReEnabled
            scoreBefore = result.before.score
            scoreAfter = result.after.score
        }
    }

    /// `POST /cameras/:id/optimize { confirm: true }`: the HomeKit optimizer (20 to 40 s; it holds the engine's operations lock), one at a time
    /// per camera. The page never retries it.
    func optimizeCamera(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        let sentence = "Confirm that the camera’s video settings may be changed."
        guard !ctx.request.body.isEmpty else { throw APIError.badRequest(sentence, field: "confirm") }
        guard try decode(OptimizeRequest.self, from: ctx).confirm == true else { throw APIError.badRequest(sentence, field: "confirm") }
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        guard archiveState.beginOptimizing(id) else {
            throw APIError.conflict("optimize_busy", "This camera’s video settings are already being changed. Wait for that to finish.")
        }
        defer { archiveState.endOptimizing(id) }
        log.notice("optimizing a camera for HomeKit was requested from the web interface")
        do {
            return .json(OptimizeResource(try await backend.optimizeForHomeKit(cameraID: id)))
        } catch EngineError.unknownCamera {
            throw APIError.notFound("This camera was removed.")
        } catch {
            log.warning("optimizing a camera failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "optimize_failed", message: Self.optimizeSentence(error))
        }
    }

    /// `POST /cameras/:id/optimize/undo`: puts back what the last optimize changed. The body is not read.
    func undoOptimization(_ ctx: RequestContext) async throws -> HTTPResponse {
        let id = try ctx.uuid("id")
        guard await backend.overview().configurations.contains(where: { $0.id == id }) else { throw APIError.notFound("There is no camera with this identifier.") }
        do {
            try await backend.undoHomeKitOptimization(cameraID: id)
        } catch EngineError.unknownCamera {
            throw APIError.notFound("This camera was removed.")
        } catch EngineError.cameraNotRunning {
            throw APIError(status: 422, code: "optimize_failed", message: "There is nothing to undo for this camera.")
        } catch {
            log.warning("undoing an optimization failed: \(ErrorText.logDescription(error))")
            throw APIError(status: 422, code: "optimize_failed", message: Self.optimizeSentence(error))
        }
        return .empty()
    }

    /// What the person reads when the camera would not take the change: the methods that were tried and why each failed.
    private static func optimizeSentence(_ error: any Error) -> String {
        if let refused = error as? CameraConfigError { return "The camera didn’t accept the change: \(Redact.string(refused.summary))." }
        return ErrorText.describe(error)
    }
}
