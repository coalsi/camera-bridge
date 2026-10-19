import BridgeEngine
import CameraAdapters
import Foundation

/// Webhook helpers for Settings: token generation, port validation and an example request.
enum WebhookSettings {
    enum PortValidation: Equatable {
        case valid(UInt16)
        case invalid(String)
    }

    /// Environment variable name used in the example command, so the token itself never appears on screen.
    static let tokenPlaceholder = "$CAMERABRIDGE_TOKEN"

    /// 32 lowercase hex digits (128 random bits), the same shape as `BridgeSettings()`'s default token.
    static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let byte = UInt8.random(in: 0...255, using: &generator)
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    static func validatePort(_ text: String, settings: BridgeSettings, cameraPorts: [UInt16]) -> PortValidation {
        let rangeMessage = String(localized: "Use a port from 1024 to 65535.")
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1_024...65_535).contains(value) else {
            return .invalid(rangeMessage)
        }
        let port = UInt16(value)
        if port == settings.sensorsBridgePort {
            return .invalid(String(localized: "Port \(String(port)) is used by the sensors bridge."))
        }
        if cameraPorts.contains(port) {
            return .invalid(String(localized: "Port \(String(port)) is used by a camera."))
        }
        return .valid(port)
    }

    /// Stands for a camera's ID in the Settings example (each camera's page lists its own URLs).
    static let cameraIDPlaceholder = "<camera ID>"

    /// `cameraID` nil: `cameraIDPlaceholder`.
    static func exampleURL(host: String, port: UInt16, cameraID: UUID?, event: String) -> String {
        "http://\(host):\(port)/cameras/\(cameraID?.uuidString ?? cameraIDPlaceholder)/\(event)"
    }

    /// `curl -X POST -H "Authorization: Bearer $CAMERABRIDGE_TOKEN" http://…` — never includes the real token.
    static func exampleCommand(host: String, settings: BridgeSettings, cameraID: UUID?, event: String) -> String {
        "curl -X POST -H \"Authorization: Bearer \(tokenPlaceholder)\" "
            + exampleURL(host: host, port: settings.webhookPort, cameraID: cameraID, event: event)
    }

    /// One event a camera can receive through the webhook, and its URL.
    struct EventURL: Equatable, Identifiable {
        var event: String
        var url: String
        var id: String { event }
    }

    /// The webhook URLs of one camera (`POST /cameras/<id>/<event>`): its doorbell first (doorbells; the webhook rings any
    /// doorbell, also one that reports no button of its own), then motion and the detections. The webhook takes them
    /// whatever the camera's motion source; detections become sensors as the camera's Sensors section says.
    static func cameraURLs(host: String, port: UInt16, cameraID: UUID, kind: CameraKind) -> [EventURL] {
        let events = (kind == .doorbell ? ["doorbell"] : []) + ["motion", "motion/stop", "person", "vehicle", "animal", "package"]
        return events.map { EventURL(event: $0, url: exampleURL(host: host, port: port, cameraID: cameraID, event: $0)) }
    }

    /// Whether events of `camera` come only through the webhook: its motion source is the webhook, or it is a doorbell
    /// whose camera reports no button of its own (every Hikvision doorbell, plain RTSP), which rings only through it.
    static func dependsOnWebhook(_ camera: CameraConfiguration) -> Bool {
        camera.motionSource == .webhook || (camera.kind == .doorbell && camera.capabilities?.isDoorbell != true)
    }

    /// The camera page's notice next to its webhook URLs while the webhook isn't listening (`problem`: the engine's
    /// `webhookProblem`): what is lost for a camera that depends on the webhook, else that nothing reaches it.
    static func cameraNotice(problem: String, for camera: CameraConfiguration) -> String {
        guard dependsOnWebhook(camera) else {
            return String(localized: "\(problem) Events sent to these URLs are lost until it listens.")
        }
        if camera.kind == .doorbell, camera.capabilities?.isDoorbell != true {
            return String(localized: "\(problem) This doorbell rings only through the webhook, so its rings are lost until it listens.")
        }
        return String(localized: "\(problem) This camera’s motion comes from the webhook, so its motion and detections are lost until it listens.")
    }

    /// The name of a webhook event on screen.
    static func eventTitle(_ event: String) -> String {
        switch event {
        case "doorbell": String(localized: "Doorbell Ring")
        case "motion": String(localized: "Motion")
        case "motion/stop": String(localized: "Motion Ended")
        case "person": String(localized: "Person")
        case "vehicle": String(localized: "Vehicle")
        case "animal": String(localized: "Animal")
        case "package": String(localized: "Package")
        default: event
        }
    }

    /// All but the last four characters replaced with bullets.
    static func masked(_ token: String) -> String {
        guard token.count > 4 else { return String(repeating: "•", count: token.count) }
        return String(repeating: "•", count: token.count - 4) + token.suffix(4)
    }

    /// This Mac's name for example URLs ("Studio-Mac.local"), read once.
    static let localHostName = currentHostName()

    /// The kernel host name (`gethostname`), which needs no lookup. Not `ProcessInfo.hostName`: that resolves the
    /// name through DNS/mDNS and can block the calling thread for seconds.
    static func currentHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bonjourHostName(String(decoding: bytes, as: UTF8.self))
    }

    /// A bare name gets `.local`; a name that already has a domain is kept.
    static func bonjourHostName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "localhost" }
        return trimmed.contains(".") ? trimmed : trimmed + ".local"
    }
}
