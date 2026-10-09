import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import RTSP

/// Readable messages for errors the page shows: every error the engine and the camera adapters throw has its own sentence (the
/// engine words them once, `BridgeEngine.readableReason`; this adds what to do), and an error nobody mapped reads `unexpected`
/// while its Swift type goes to the log. The text goes on screen, so it is redacted like the log (`Redact.string`: URL user
/// info, password-like parameters): an engine or adapter error may quote a camera URL.
enum ErrorText {
    static let unexpected = "Something unexpected went wrong. The log has the details."

    static func describe(_ error: any Error) -> String {
        Redact.string(readable(error))
    }

    /// For the log: the Swift type and case, redacted.
    static func logDescription(_ error: any Error) -> String {
        Redact.string(String(describing: type(of: error)) + ": " + String(describing: error))
    }

    private static func readable(_ error: any Error) -> String {
        switch error {
        case let engine as EngineError:
            return engine.readable
        case let integration as IntegrationError:
            return integration.message
        case is TransportError, is CameraAdapterError, is RTSPError, is ConfigurationStoreError, is PortAllocationError, is CredentialStoreError,
             is HTTPClientError, is CancellationError:
            return [sentence(BridgeEngine.readableReason(error)), advice(for: error)].compactMap { $0 }.joined(separator: " ")
        case let localized as any LocalizedError:
            return localized.errorDescription ?? unexpected
        default:
            return unexpected
        }
    }

    /// The engine's reason phrase ("the connection timed out") as a sentence ("The connection timed out.").
    static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        let text = first.uppercased() + reason.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    /// What the person can do about an error the engine words, where it is known.
    private static func advice(for error: any Error) -> String? {
        switch error {
        case TransportError.failed:
            return "Check the camera’s address and that it is on your network. The log has the details."
        case CameraAdapterError.httpStatus, CameraAdapterError.invalidResponse, is HTTPClientError:
            return "Check the camera type and ports."
        case RTSPError.notFound:
            return "Check the stream URL."
        case RTSPError.unsupportedCodec:
            return "Choose H.264 or HEVC in the camera’s settings."
        case ConfigurationStoreError.unsupportedSchemaVersion:
            return "Update Camera Bridge OS to use it."
        case ConfigurationStoreError.corrupt:
            return "The log has the details."
        case is CredentialStoreError:
            return "Enter it again with the camera’s password field."
        default:
            return nil
        }
    }
}

private extension EngineError {
    var readable: String {
        switch self {
        case .unknownCamera: "This camera was removed."
        case .duplicateCamera: "This camera has already been added."
        case .cameraNotRunning: "The camera isn’t running."
        case .invalidSettings(let reason): "These settings can’t be used: \(reason)."
        case .configurationUnavailable: "Camera Bridge couldn’t read its configuration. The log has the details."
        case .noCameraAPI(let host):
            "No Hikvision, Reolink or ONVIF interface answered at \(host). Check the address and ports (turn on Use HTTPS if the camera only answers HTTPS), or go back and choose Camera Type › RTSP URL."
        }
    }
}
