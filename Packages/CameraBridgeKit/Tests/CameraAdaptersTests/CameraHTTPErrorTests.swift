import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// Review finding (W4): transport errors from camera HTTP requests carried the request URL (a Reolink session token, a
/// password in an ONVIF snapshot URI's query) in their user info, and callers log errors. `CameraHTTP.sanitized` is
/// BridgeSupport's one sanitizer (`URLFreeErrors`, every case tested in BridgeSupportTests) with the adapters' choices.
@Suite struct CameraHTTPErrorTests {
    static let url = "http://192.0.2.10/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=a1b2&token=S3CRETTOKEN0123&pwd=FOSCAMPW77"

    static func urlError(_ code: URLError.Code) -> URLError {
        URLError(code, userInfo: [URLFreeErrors.failingURLStringKey: url, NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
    }

    @Test func transportErrorsLoseTheirURL() {
        // A timeout stays a `TransportError` here (RTSP's HTTP-FLV source makes it `RTSPError.timeout`).
        #expect(CameraHTTP.sanitized(Self.urlError(.timedOut)) as? TransportError == .timedOut)
        #expect(CameraHTTP.sanitized(Self.urlError(.cannotConnectToHost)) as? TransportError == .connectionRefused)
        let other = CameraHTTP.sanitized(Self.urlError(.badServerResponse))
        #expect(other as? TransportError == .failed("HTTP request failed (URLError \(URLError.Code.badServerResponse.rawValue))"))
        #expect(!"\(other)".contains("S3CRETTOKEN0123"))
        // The adapters' own errors pass unchanged.
        #expect(CameraHTTP.sanitized(CameraAdapterError.unauthorized) as? CameraAdapterError == .unauthorized)
        #expect(CameraHTTP.sanitized(CameraAdapterError.httpStatus(503)) as? CameraAdapterError == .httpStatus(503))
        #expect(CameraHTTP.sanitized(TransportError.localNetworkDenied) as? TransportError == .localNetworkDenied)
    }

    #if os(macOS)
    @Test(.timeLimit(.minutes(1))) func aReolinkSnapshotThatFailsInTransportCarriesNoToken() async throws {
        let server = try await MockHTTPServer.start { request in
            if request.query("cmd") == "Login" {
                return .json(#"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"S3CRETTOKEN0123"}}}]"#)
            }
            return .status(500)
        }
        let api = ReolinkAPI(endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)),
                             credentials: HTTPCredentials(username: "admin", password: "secret"))
        _ = try await api.login()
        server.stop()   // the camera reboots: the Snap request (with the token in its query) cannot connect
        do {
            _ = try await api.snapshot()
            Issue.record("the snapshot cannot succeed")
        } catch {
            let text = String(describing: error)
            #expect(!text.contains("S3CRETTOKEN0123"), "\(text)")
            #expect(error is TransportError)
        }
    }
    #endif
}
