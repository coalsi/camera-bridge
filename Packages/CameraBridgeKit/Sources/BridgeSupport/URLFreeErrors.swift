import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors without the request URL — the one copy (RTSP's HTTP-FLV source, CameraAdapters' `CameraHTTP`, BridgeEngine's
/// snapshot and runtime logs; `PortabilityTests.urlErrorSanitizingLivesOnlyInBridgeSupport` rejects others).
///
/// URLSession errors — what `AuthenticatingHTTPClient` rethrows — carry the failing URL in their user info
/// (`NSErrorFailingURLKey`, `NSErrorFailingURLStringKey`, and again in a nested `NSUnderlyingErrorKey` error): a Reolink
/// `token=`, a `password=`/`pwd=` query item, which a caller logging `\(error)` would write out. `sanitized` turns them
/// into errors to throw, `describe` into a summary to log.
package enum URLFreeErrors {
    /// The user info key CFNetwork errors carry their failing URL string under (`NSURLErrorFailingURLStringErrorKey`'s
    /// value; the constant is deprecated since macOS 15.4, but CFNetwork errors keyed only by the string still exist).
    package static let failingURLStringKey = "NSErrorFailingURLStringKey"

    /// `error` without the request URL. A URLError maps to `TransportError` — refused (`.connectionRefused`), lost
    /// (`.closed`) — or to `timedOut` (default `TransportError.timedOut`; RTSP passes `RTSPError.timeout`); a cancelled one
    /// to `CancellationError`, any other code to `TransportError.failed("<request> failed (URLError <code>)")`.
    /// `TransportError`, `HTTPClientError`, `CancellationError` and the caller's own errors (`passing`) are returned
    /// unchanged, unless they carry a URL; anything else keeps only its domain and code
    /// (`.failed("<request> failed (<domain> <code>)")`).
    package static func sanitized(_ error: any Error, request: String = "HTTP request", timedOut: any Error = TransportError.timedOut,
                                  passing ownErrors: (any Error) -> Bool = { _ in false }) -> any Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return timedOut
            case .cannotConnectToHost: return TransportError.connectionRefused
            case .networkConnectionLost: return TransportError.closed
            case .cancelled: return CancellationError()
            default: return TransportError.failed("\(request) failed (\(summary(error)))")
            }
        }
        switch error {
        case is TransportError, is HTTPClientError, is CancellationError:
            return error
        case _ where ownErrors(error) && !carriesURL(error):
            return error
        default:
            return TransportError.failed("\(request) failed (\(summary(error)))")
        }
    }

    /// `error` for the log: a URL-free summary of errors that carry a URL ("URLError <code>", or "<domain> <code>"),
    /// anything else as its description, redacted (`Redact.string`).
    package static func describe(_ error: any Error) -> String {
        carriesURL(error) ? summary(error) : Redact.string(String(describing: error))
    }

    /// "URLError <code>" for URL loading errors, else "<domain> <code>".
    private static func summary(_ error: any Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    /// Whether the error is a URL loading error, or names a failing URL in its user info (also in a nested underlying
    /// error, up to a few levels).
    private static func carriesURL(_ error: any Error, depth: Int = 0) -> Bool {
        if error is URLError { return true }
        let bridged = error as NSError
        if bridged.domain == NSURLErrorDomain { return true }
        let info = bridged.userInfo
        if info[failingURLStringKey] != nil || info[NSURLErrorFailingURLErrorKey] != nil || info.values.contains(where: { $0 is URL }) {
            return true
        }
        guard depth < 4, let underlying = info[NSUnderlyingErrorKey] as? any Error else { return false }
        return carriesURL(underlying, depth: depth + 1)
    }
}
