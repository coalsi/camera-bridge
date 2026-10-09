import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import RTSP

/// An accessory's Apple Home setup code (`XXX-XX-XXX`) and `X-HM://` setup URI.
struct PairingCode: Equatable {
    var setupCode: String
    var setupURI: String
}

/// What the Add Camera wizard needs from the bridge. `AppModel` implements it (engine in live mode, fixtures in
/// preview mode); tests use a fake.
protocol CameraSetupService: AnyObject {
    /// The engine's current answer about Local Network access (the Discover page shows a denial).
    var localNetworkAccess: LocalNetworkAccess { get }
    /// The cameras already configured: the wizard points out a camera it would add a second time.
    var configuredCameras: [CameraConfiguration] { get }
    func discoverCameras() async -> [DiscoveredCamera]
    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                     mainStreamURL: URL?, subStreamURL: URL?) async throws -> CameraProbeResult
    /// The check of a camera behind a service (`CameraVendor.go2rtc`, `.unifi`): `secret` is the service's token, API key or source address.
    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult
    /// A UniFi Protect console's cameras, from its official API with `apiKey`.
    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera]
    /// Whether the go2rtc streaming helper is part of this copy of the app (cloud cameras and Protect's RTSPS need it).
    var isStreamingHelperInstalled: Bool { get }
    /// Starts go2rtc's own sign-in pages on this Mac and returns the address to open; they close with `endIntegrationSignIn()`.
    func beginIntegrationSignIn() async throws -> URL
    func endIntegrationSignIn() async
    /// Google's Device Access sign-in steps (replaceable in tests).
    var nestAccess: NestDeviceAccess { get }
    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws
    /// The added camera's code once the engine publishes it.
    func pairingCode(for cameraID: UUID) -> PairingCode?
}

extension CameraSetupService {
    var nestAccess: NestDeviceAccess { NestDeviceAccess() }
}

/// Readable messages for errors shown in alerts and inline. Every error the engine and the camera adapters throw has
/// its own sentence; an error nobody mapped reads `unexpected` on screen, and `logDescription` (the Swift type and case)
/// goes to the log instead. The text goes on screen, so it is redacted like the log (`Redact.string`: URL user info,
/// password-like parameters): an engine or adapter error may quote a camera URL.
///
/// Network, stream, camera API and storage errors are worded once, by the engine (`BridgeEngine.readableReason`, which
/// its state strings and a camera's offline reason use too): the app makes a sentence of that reason and adds what to
/// do. `TransportError.failed`'s own text (POSIX and URLError codes) never reaches the screen, only the log.
/// `EngineError`, which the engine's operations throw at the app, has the app's sentences.
enum ErrorText {
    static let unexpected = String(localized: "Something unexpected went wrong. The log in Settings has the details.")

    static func describe(_ error: any Error) -> String {
        Redact.string(readable(error))
    }

    /// For the log: the Swift type and case of a plain Swift error ("CameraAdapterError.httpStatus(503)", or
    /// "EngineError: <description>" for one with its own description), else its description. Redacted.
    static func logDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == String(reflecting: type(of: error)) else { return Redact.string(String(describing: error)) }
        let typeName = String(describing: type(of: error))
        // Through `Any`: `any Error` → `CustomStringConvertible` is folded to "always succeeds" (every error bridges to an
        // NSError, which has a description), though at run time the cast asks the error's own type, as intended here.
        if let described = (error as Any) as? any CustomStringConvertible { return Redact.string("\(typeName): \(described.description)") }
        return Redact.string("\(typeName).\(String(describing: error))")
    }

    private static func readable(_ error: any Error) -> String {
        switch error {
        case let engine as EngineError: engine.readable
        case is TransportError, is CameraAdapterError, is RTSPError, is ConfigurationStoreError, is PortAllocationError,
             is CredentialStoreError, is HTTPClientError, is CancellationError:
            [sentence(BridgeEngine.readableReason(error)), advice(for: error)].compactMap { $0 }.joined(separator: " ")
        case let localized as any LocalizedError:
            localized.errorDescription ?? error.localizedDescription
        default:
            // A plain Swift error has no readable Cocoa description ("The operation couldn’t be completed…"), and its
            // case name means nothing to the person: say so plainly (the log gets `logDescription`).
            (error as NSError).domain == String(reflecting: type(of: error)) ? unexpected : error.localizedDescription
        }
    }

    /// The engine's reason phrase ("the connection timed out") as a sentence ("The connection timed out.").
    static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        let text = first.uppercased() + reason.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    /// What the person can do about an error the engine words, where the app knows.
    private static func advice(for error: any Error) -> String? {
        switch error {
        case TransportError.localNetworkDenied:
            return String(localized: "Allow Camera Bridge in System Settings › Privacy & Security › Local Network.")
        case TransportError.failed:
            // The platform's text (POSIX, URLError -1003 for a name that doesn't resolve, …) is in the log.
            return String(localized: "Check the camera’s address and that it is on your network. The log in Settings has the details.")
        case CameraAdapterError.httpStatus, CameraAdapterError.invalidResponse, is HTTPClientError:
            return String(localized: "Check the camera type and ports.")
        case RTSPError.notFound:
            return String(localized: "Check the stream URL.")
        case RTSPError.unsupportedCodec:
            return String(localized: "Choose H.264 or HEVC in the camera’s settings.")
        case ConfigurationStoreError.unsupportedSchemaVersion:
            return String(localized: "Update Camera Bridge to use it.")
        case ConfigurationStoreError.corrupt:
            return String(localized: "The log in Settings has the details.")
        case is CredentialStoreError:
            return String(localized: "Enter it again with the camera’s Change Password button.")
        default:
            return nil
        }
    }
}

private extension EngineError {
    var readable: String {
        switch self {
        case .unknownCamera: String(localized: "This camera was removed.")
        case .duplicateCamera: String(localized: "This camera has already been added.")
        case .cameraNotRunning: String(localized: "The camera isn’t running.")
        case .invalidSettings(let reason): String(localized: "These settings can’t be used: \(reason).")
        case .configurationUnavailable: String(localized: "Camera Bridge couldn’t read its configuration. The log in Settings has the details.")
        case .noCameraAPI(let host):
            String(localized: "No Hikvision, Reolink or ONVIF interface answered at \(host). Check the address and ports (turn on Use HTTPS if the camera only answers HTTPS), or go back and choose Camera Type › RTSP URL.")
        }
    }
}
