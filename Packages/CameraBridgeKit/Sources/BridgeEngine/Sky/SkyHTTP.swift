import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One plain GET of a document, for the sky detector's flight, orbit and weather data. Replaced in tests by a fake that answers from memory.
protocol SkyHTTP: Sendable {
    /// The answer to a GET of `url`: its status (any HTTP answer is one, 404 and 429 included) and body. Waits at most `timeout` for the whole
    /// answer, and reads at most `maximumBytes` of body: a longer one (announced or not) fails with `HTTPClientError.bodyTooLarge`, as a wait
    /// that ran out fails with `TransportError.timedOut`; no error names the address. A cancelled caller gets `CancellationError`.
    func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int)
}

/// The live `SkyHTTP`: one `AuthenticatingHTTPClient` for the bridge's life, shared by every instance (sessions made and invalidated per
/// request can crash FoundationNetworking on Linux when requests overlap, see `URLSessionAITransport`), with no credentials, the
/// certificate checks on and redirects never followed: a 3xx is the answer, and nothing is sent to the address it names. The wait and the
/// size are each call's own: the answer is read as it arrives and cut off when it passes `maximumBytes`, and the whole call is cut off at
/// `timeout`, so a host that trickles a body or never answers holds nothing for longer than the caller said.
final class URLSessionSkyHTTP: SkyHTTP {
    init() {}

    /// The longest a call may wait whatever it asks for (the client's own bound).
    static let longestWait: Duration = .seconds(120)

    private static let client = AuthenticatingHTTPClient(credentials: nil, timeout: longestWait, allowSelfSignedTLS: false,
                                                         maximumBodySize: AuthenticatingHTTPClient.defaultMaximumBodySize,
                                                         downgradeGuard: BasicDowngradeGuard(), followsRedirects: false)

    func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let limit = max(1, maximumBytes)
        do {
            return try await withDeadline(min(max(timeout, .milliseconds(100)), Self.longestWait)) { [request] in
                let (response, body) = try await Self.client.stream(for: request)
                if response.expectedContentLength > Int64(limit) { throw HTTPClientError.bodyTooLarge(limit: limit) }
                var data = Data()
                for try await chunk in body {
                    // Leaving the loop drops the stream, which cancels the request.
                    guard chunk.count <= limit - data.count else { throw HTTPClientError.bodyTooLarge(limit: limit) }
                    data.append(chunk)
                }
                return (data, response.statusCode)
            }
        } catch is DeadlineExceeded {
            throw TransportError.timedOut
        } catch {
            throw URLFreeErrors.sanitized(error, request: "Flight data request")
        }
    }
}
