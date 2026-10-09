import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RTSP

/// HTTP-FLV's error mapping over BridgeSupport's one URL-free sanitizer (`URLFreeErrors`, tested in BridgeSupportTests):
/// a timeout is `RTSPError.timeout` (what the ingest supervisor expects of a media source), the source's own errors pass
/// unchanged, and nothing carries the URL with its `password=`.
@Suite struct HTTPFLVErrorTests {
    static let url = "http://192.0.2.10/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=admin&password=S3CRETPW99"

    static func urlError(_ code: URLError.Code) -> URLError {
        URLError(code, userInfo: [URLFreeErrors.failingURLStringKey: url, NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
    }

    @Test func mapsOverTheSharedSanitizer() {
        #expect(HTTPFLVMediaSource.sanitized(Self.urlError(.timedOut)) as? RTSPError == .timeout)
        #expect(HTTPFLVMediaSource.sanitized(Self.urlError(.cannotConnectToHost)) as? TransportError == .connectionRefused)
        #expect(HTTPFLVMediaSource.sanitized(Self.urlError(.networkConnectionLost)) as? TransportError == .closed)
        #expect(HTTPFLVMediaSource.sanitized(Self.urlError(.cancelled)) is CancellationError)
        let other = HTTPFLVMediaSource.sanitized(Self.urlError(.badServerResponse))
        #expect(other as? TransportError == .failed("HTTP-FLV request failed (URLError \(URLError.Code.badServerResponse.rawValue))"))
        #expect(HTTPFLVMediaSource.sanitized(RTSPError.badStatus(503)) as? RTSPError == .badStatus(503))
        for error in [Self.urlError(.timedOut), Self.urlError(.secureConnectionFailed)].map(HTTPFLVMediaSource.sanitized) {
            #expect(!"\(error) \((error as NSError).userInfo)".contains("S3CRETPW99"))
        }
    }
}
