import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

/// Review finding (BridgeSupport, round 2): the URLError sanitizer that keeps `AuthenticatingHTTPClient`'s failing URL (a
/// Reolink `token=`, a `password=` query item) out of thrown and logged errors existed as copies in RTSP
/// (`HTTPFLVMediaSource.sanitized`), CameraAdapters (`CameraHTTP.sanitized`) and BridgeEngine
/// (`SnapshotProvider.describe`). BridgeSupport now has the one copy, `URLFreeErrors`; the modules only choose their
/// own error types, the timeout error and the request's name.
@Suite struct URLFreeErrorsTests {
    static let secrets = ["S3CRETTOKEN0123", "FOSCAMPW77", "hunter2", "192.0.2.10"]
    static let url = "http://admin:hunter2@192.0.2.10/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=a1b2&token=S3CRETTOKEN0123&pwd=FOSCAMPW77"

    /// A URLError as URLSession reports it: the failing URL under both user info keys.
    static func urlError(_ code: URLError.Code) -> URLError {
        URLError(code, userInfo: [URLFreeErrors.failingURLStringKey: url, NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
    }

    /// Neither the description nor the user info (nor a nested error's) of `error` names the URL.
    static func expectURLFree(_ error: any Error, sourceLocation: SourceLocation = #_sourceLocation) {
        let texts = [String(describing: error), String(reflecting: error), "\((error as NSError).userInfo)", error.localizedDescription]
        for text in texts {
            #expect(!secrets.contains { text.contains($0) }, "\(text)", sourceLocation: sourceLocation)
        }
    }

    enum OwnError: Error, Equatable { case timeout, rejected }

    @Test func urlErrorsBecomeTransportErrors() {
        #expect(URLFreeErrors.sanitized(Self.urlError(.timedOut)) as? TransportError == .timedOut)
        #expect(URLFreeErrors.sanitized(Self.urlError(.cannotConnectToHost)) as? TransportError == .connectionRefused)
        #expect(URLFreeErrors.sanitized(Self.urlError(.networkConnectionLost)) as? TransportError == .closed)
        #expect(URLFreeErrors.sanitized(Self.urlError(.cancelled)) is CancellationError)
        for code: URLError.Code in [.badServerResponse, .secureConnectionFailed, .cannotFindHost, .notConnectedToInternet, .badURL] {
            let sanitized = URLFreeErrors.sanitized(Self.urlError(code))
            #expect(sanitized as? TransportError == .failed("HTTP request failed (URLError \(code.rawValue))"))
            Self.expectURLFree(sanitized)
        }
    }

    @Test func otherFoundationErrorsKeepOnlyTheirDomainAndCode() {
        let cfNetwork = NSError(domain: "kCFErrorDomainCFNetwork", code: 303, userInfo: [URLFreeErrors.failingURLStringKey: Self.url])
        #expect(URLFreeErrors.sanitized(cfNetwork) as? TransportError == .failed("HTTP request failed (kCFErrorDomainCFNetwork 303)"))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: [NSUnderlyingErrorKey: Self.urlError(.cannotConnectToHost)])
        #expect(URLFreeErrors.sanitized(posix) as? TransportError == .failed("HTTP request failed (\(NSPOSIXErrorDomain) 61)"))
        for error in [cfNetwork, posix] { Self.expectURLFree(URLFreeErrors.sanitized(error)) }
    }

    /// RTSP's HTTP-FLV source turns a timeout into `RTSPError.timeout` and names its request; CameraAdapters keeps the
    /// defaults. Each module's own errors pass unchanged.
    @Test func callersChooseTheirTimeoutErrorRequestNameAndOwnErrors() {
        #expect(URLFreeErrors.sanitized(Self.urlError(.timedOut), timedOut: OwnError.timeout) as? OwnError == .timeout)
        #expect(URLFreeErrors.sanitized(Self.urlError(.badServerResponse), request: "HTTP-FLV request") as? TransportError
                == .failed("HTTP-FLV request failed (URLError \(URLError.Code.badServerResponse.rawValue))"))
        #expect(URLFreeErrors.sanitized(OwnError.rejected, passing: { $0 is OwnError }) as? OwnError == .rejected)
        // Not declared as the caller's own: reduced like any other unknown error.
        let unknown = URLFreeErrors.sanitized(OwnError.rejected)
        #expect(unknown is TransportError)
        #expect(String(describing: unknown).contains("HTTP request failed ("))
        // A caller's predicate never lets a URL-carrying error through as its own.
        #expect(URLFreeErrors.sanitized(Self.urlError(.cannotConnectToHost), passing: { _ in true }) as? TransportError == .connectionRefused)
    }

    @Test func sharedErrorsPassUnchanged() {
        #expect(URLFreeErrors.sanitized(TransportError.localNetworkDenied) as? TransportError == .localNetworkDenied)
        #expect(URLFreeErrors.sanitized(TransportError.failed("x")) as? TransportError == .failed("x"))
        #expect(URLFreeErrors.sanitized(HTTPClientError.bodyTooLarge(limit: 16)) as? HTTPClientError == .bodyTooLarge(limit: 16))
        #expect(URLFreeErrors.sanitized(HTTPClientError.notHTTPResponse) as? HTTPClientError == .notHTTPResponse)
        #expect(URLFreeErrors.sanitized(CancellationError()) is CancellationError)
    }

    /// The log summary (BridgeEngine's snapshot and runtime logs): URL-carrying errors as code or domain and code, anything
    /// else redacted.
    @Test func describeSummarisesURLCarryingErrorsForTheLog() {
        #expect(URLFreeErrors.describe(Self.urlError(.networkConnectionLost)) == "URLError \(URLError.Code.networkConnectionLost.rawValue)")
        let cfNetwork = NSError(domain: "kCFErrorDomainCFNetwork", code: 303, userInfo: [URLFreeErrors.failingURLStringKey: Self.url])
        #expect(URLFreeErrors.describe(cfNetwork) == "kCFErrorDomainCFNetwork 303")
        let keyedByURL = NSError(domain: "SomeDomain", code: 7, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: Self.url) as Any])
        #expect(URLFreeErrors.describe(keyedByURL) == "SomeDomain 7")
        let urlDomain = NSError(domain: NSURLErrorDomain, code: -1004, userInfo: [:])
        #expect(URLFreeErrors.describe(urlDomain) == "URLError -1004")
        // A wrapper whose underlying error carries the URL (CFNetwork nests the URLError) is summarised too.
        let nested = NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: [NSUnderlyingErrorKey: Self.urlError(.cannotConnectToHost)])
        #expect(URLFreeErrors.describe(nested) == "\(NSPOSIXErrorDomain) 61")
        for error: any Error in [Self.urlError(.timedOut), cfNetwork, keyedByURL, nested] {
            let text = URLFreeErrors.describe(error)
            #expect(!Self.secrets.contains { text.contains($0) }, "\(text)")
        }
        // Anything else: its description, redacted.
        let other = TransportError.failed("rtsp://admin:hunter2@192.0.2.10/s?password=hunter2")
        #expect(URLFreeErrors.describe(other) == Redact.string(String(describing: other)))
        #expect(!URLFreeErrors.describe(other).contains("hunter2"))
        #expect(URLFreeErrors.describe(HTTPClientError.bodyTooLarge(limit: 16)) == "bodyTooLarge(limit: 16)")
    }

    @Test func failingURLStringKeyIsCFNetworksKey() {
        #expect(URLFreeErrors.failingURLStringKey == "NSErrorFailingURLStringKey")
    }

    #if os(macOS)
    /// End to end: what `AuthenticatingHTTPClient` throws for a camera that cannot be reached does carry the URL (with
    /// its token), and the sanitized error and the log summary do not.
    @Test(.timeLimit(.minutes(1))) func anUnreachableCameraErrorLosesItsURL() async throws {
        let port = try await Self.closedLoopbackPort()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/cgi-bin/api.cgi?cmd=Snap&channel=0&token=S3CRETTOKEN0123&pwd=FOSCAMPW77"))
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(2))
        defer { client.invalidate() }
        do {
            _ = try await client.data(for: URLRequest(url: url))
            Issue.record("nothing listens on port \(port)")
        } catch {
            #expect("\((error as NSError).userInfo)".contains("S3CRETTOKEN0123"), "the premise: URLSession errors carry the URL")
            let sanitized = URLFreeErrors.sanitized(error)
            #expect(sanitized is TransportError)
            Self.expectURLFree(sanitized)
            let text = URLFreeErrors.describe(error)
            #expect(!Self.secrets.contains { text.contains($0) }, "\(text)")
        }
    }

    /// A loopback port nothing listens on any more.
    static func closedLoopbackPort() async throws -> UInt16 {
        let server = try await LoopbackHTTPServer { _, _ in (200, [], Data()) }
        server.stop()
        return server.port
    }
    #endif
}
