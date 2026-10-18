import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors from camera APIs (vendor drivers, event sources, talkback sinks).
public enum CameraAdapterError: Error, Equatable, Sendable {
    /// The camera rejected the credentials (HTTP 401, ONVIF `NotAuthorized`, Reolink login failure).
    case unauthorized
    /// Unexpected HTTP status.
    case httpStatus(Int)
    /// The response could not be understood.
    case invalidResponse(String)
    /// ONVIF SOAP fault (subcode or reason).
    case soapFault(String)
    /// Reolink API error (`rspCode`).
    case apiError(command: String, code: Int)
    /// The camera does not offer the feature (e.g. no audio backchannel).
    case unsupported(String)
    /// The camera itself locked its logins after too many wrong passwords (Hikvision's "locked" answer: 30 minutes; the IP camera web
    /// API's `passwordLock`; DoorBird's HTTP 423). Camera Bridge won't try again before `until`, since every attempt restarts the lock.
    case lockedOut(until: Date)
    /// Camera Bridge's own pause after the camera refused a login (on this API or another of the camera's: one account): no login is
    /// sent before `until` (2 minutes, `ONVIFLoginGuard`), so the wrong password is not tried again and again until the camera locks
    /// the account. The camera has locked nothing, and this call sent nothing.
    case loginsPaused(until: Date)
    /// The camera refused a change to the account Camera Bridge uses, which it had just signed in and read with: the account may not make
    /// it (it is not an administrator, or the camera's ONVIF user may not write). Not a wrong password, so no login is paused. The value
    /// names the refused operation for the log ("SetNTP").
    case notPermitted(String)

    /// What a step or a settings change says when the camera refused the account the change (`.notPermitted`).
    public static let notPermittedReason = "the account Camera Bridge uses may not change this; use an administrator account in the camera’s settings"

    /// Wrong credentials, a camera that has locked logins or Camera Bridge's pause after a refused one: either way, back off rather than
    /// retry soon. A change the account may not make (`.notPermitted`) is not one: its login works.
    public var isLoginRefusal: Bool {
        switch self {
        case .unauthorized, .lockedOut, .loginsPaused: true
        default: false
        }
    }

    /// Whether `error` says the account Camera Bridge uses may not make a change: `.notPermitted`, or the IPCamera Web family's API that
    /// stopped because the account has no privilege for it (532374 at the sign-in, `IPCamWebUnavailable.noPrivilege`). Set up for Camera
    /// Bridge carries it typed (`CameraSetupOutcome.notPermitted`): no wrong password, and the steps after it still run.
    public static func isNotPermitted(_ error: any Error) -> Bool {
        if case CameraAdapterError.notPermitted = error { return true }
        return (error as? IPCamWebUnavailable)?.notPermitted == true
    }

    /// How a refused settings change quotes `error`: a change the account may not make in words (`notPermittedReason`), anything else as it
    /// came (the camera's answer, "soapFault(\"ter:InvalidArgVal\")"), redacted.
    static func refusalWords(_ error: any Error) -> String {
        if case CameraAdapterError.notPermitted = error { return notPermittedReason }
        return Redact.string(String(describing: error))
    }
}

extension CameraEndpoint {
    /// Host as it appears in a URL (IPv6 literals bracketed).
    var urlHost: String {
        if host.contains(":") && !host.hasPrefix("[") { return "[\(host)]" }
        return host
    }

    var httpScheme: String { useHTTPS ? "https" : "http" }

    /// `http(s)://host:port<path>?<query>`; `path` must start with `/` and be URL-safe.
    func httpURL(path: String, query: [URLQueryItem] = [], port: Int? = nil) -> URL? {
        let base = "\(httpScheme)://\(urlHost):\(port ?? httpPort)\(path)"
        guard var components = URLComponents(string: base) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// `rtsp://host:rtspPort<path>` (no credentials).
    func rtspURL(path: String) -> URL? {
        URL(string: "rtsp://\(urlHost):\(rtspPort)\(path)")
    }
}

extension URL {
    // StreamInfo URLs never carry credentials: drivers strip them with BridgeSupport's `URL.removingUserInfo`.

    /// Replaces the host (keeping scheme, port, path and query) — cameras often report internal addresses.
    func replacingHost(with host: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.host != nil else { return self }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if components.host == bare { return self }
        if bare.contains(":") {
            guard let replaced = URL(string: absoluteString.replacingOccurrences(of: "//\(components.percentEncodedHost ?? "")", with: "//[\(bare)]")) else {
                return self
            }
            return replaced
        }
        components.host = bare
        return components.url ?? self
    }
}

/// Shared request helpers over `AuthenticatingHTTPClient`.
enum CameraHTTP {
    /// GET (or any method) returning the body; maps 401 → `.unauthorized` and non-2xx → `.httpStatus`.
    static func send(_ client: AuthenticatingHTTPClient, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await client.data(for: request)
        } catch {
            throw sanitized(error)
        }
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw CameraAdapterError.unauthorized
        default: throw CameraAdapterError.httpStatus(response.statusCode)
        }
    }

    /// A transport error without the request's URL: URLSession errors carry the failing URL in their user info (a
    /// Reolink `token=`, a password in an ONVIF snapshot URI's query), and callers log errors. BridgeSupport's
    /// `URLFreeErrors.sanitized` with its defaults (URLErrors → `TransportError`, a timeout `.timedOut`; other Foundation
    /// errors keep only their domain and code); the adapters' own errors pass unchanged.
    static func sanitized(_ error: any Error) -> any Error {
        URLFreeErrors.sanitized(error, passing: { $0 is CameraAdapterError })
    }

    static func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = body }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// True when the data starts like a JPEG (SOI marker).
    static func looksLikeJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }
}
