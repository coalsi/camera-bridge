import BridgeSupport
import Foundation
import Synchronization

/// Keeps a camera keyframe request (`CameraDriver.requestKeyframe`) from ever costing a login or flooding a camera.
/// Hikvision cameras lock logins after a few failed attempts, so a request is one call per need:
///
/// - never within `spacing` of the previous one to the same camera (a live view asks at most every few seconds; a second
///   ask is dropped without sending anything);
/// - never again once the camera answered that it does not know the call (the next call would only be another request that
///   fails, and some firmware counts those);
/// - never while ONVIF logins to that camera are paused (`ONVIFLoginGuard`: after a rejected login or a lockout), and a
///   rejected login of its own pauses them, so nothing retries a wrong password;
/// - one request at a time per camera address, with the camera's other HTTP requests (`CameraHTTPGates`).
final class CameraKeyframeGuard: Sendable {
    enum Verdict: Equatable, Sendable {
        case allowed
        /// A request went out to this camera less than `spacing` ago.
        case tooSoon
        /// The camera has no such call.
        case unsupported
    }

    /// Between two requests to one camera.
    static let defaultSpacing: Duration = .seconds(10)
    static let shared = CameraKeyframeGuard()

    private let spacing: Duration

    init(spacing: Duration = CameraKeyframeGuard.defaultSpacing) {
        self.spacing = spacing
    }

    private struct Entry {
        var lastRequest: ContinuousClock.Instant?
        var unsupported = false
    }

    private let entries = Mutex<[String: Entry]>([:])

    /// Records the request when it is allowed. `key`: the camera and stream (`host:port/channel`).
    func permit(key: String, now: ContinuousClock.Instant = .now) -> Verdict {
        entries.withLock { entries in
            var entry = entries[key] ?? Entry()
            if entry.unsupported { return .unsupported }
            if let last = entry.lastRequest, now - last < spacing { return .tooSoon }
            entry.lastRequest = now
            entries[key] = entry
            return .allowed
        }
    }

    func markUnsupported(key: String) {
        entries.withLock { entries in
            var entry = entries[key] ?? Entry()
            entry.unsupported = true
            entries[key] = entry
        }
    }

    /// Forgets a camera (tests: a mock camera's ephemeral port must not stay marked for the next test that binds it).
    func forget(key: String) {
        entries.withLock { _ = $0.removeValue(forKey: key) }
    }
}

extension CameraDriver {
    /// The keyframe request every driver shares: refused up front while logins are paused or the request is too soon,
    /// otherwise `send` runs once (one at a time per camera address); a rejected login pauses every login to this camera for
    /// two minutes (`ONVIFLoginGuard`) and is never retried, and a camera that does not know the call is not asked again.
    /// `loginHost` is the key `ONVIFLoginGuard` uses for this camera ("host:port" of the API address).
    func guardedKeyframeRequest(endpoint: CameraEndpoint, key: String, loginHost: String, guardian: CameraKeyframeGuard,
                                send: @escaping @Sendable () async throws -> Void) async throws {
        if let until = ONVIFLoginGuard.shared.blockedUntil(host: loginHost) { throw CameraAdapterError.lockedOut(until: until) }
        switch guardian.permit(key: key) {
        case .allowed: break
        case .tooSoon: return
        case .unsupported: throw CameraAdapterError.unsupported("this camera has no keyframe request")
        }
        do {
            try await CameraHTTPGates.gate(for: endpoint).withLock { try await send() }
        } catch let error as CameraAdapterError {
            switch error {
            case .unauthorized:
                ONVIFLoginGuard.shared.recordRejection(host: loginHost)
            case .httpStatus(let status) where [404, 405, 501].contains(status):
                guardian.markUnsupported(key: key)
                throw CameraAdapterError.unsupported("this camera has no keyframe request (HTTP \(status))")
            case .soapFault(let fault) where fault.lowercased().contains("notsupported") || fault.lowercased().contains("actionnotsupported"):
                guardian.markUnsupported(key: key)
                throw CameraAdapterError.unsupported("this camera has no keyframe request (\(fault))")
            default:
                break
            }
            throw error
        }
    }
}
