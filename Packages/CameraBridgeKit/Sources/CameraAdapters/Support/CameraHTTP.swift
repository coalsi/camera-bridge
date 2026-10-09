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
    /// The camera locked logins after too many wrong passwords (Hikvision: 30 minutes). CameraBridge won't try
    /// again before `until`, since every attempt restarts the camera's lock.
    case lockedOut(until: Date)

    /// Wrong credentials, or a camera that has locked logins: either way, back off rather than retry soon.
    public var isLoginRefusal: Bool {
        switch self {
        case .unauthorized, .lockedOut: true
        default: false
        }
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
