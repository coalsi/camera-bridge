import Foundation
import Testing
@testable import BridgeSupport

@Suite struct HTTPReasonPhraseTests {
    /// The NVR's web routes answer 409, 410, 502 and 504; the status line names them (it was "Status 409" and so on).
    @Test func theStatusesTheWebApiUsesHaveTheirOwnPhrases() {
        let phrases: [Int: String] = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                                      409: "Conflict", 410: "Gone", 422: "Unprocessable Entity", 429: "Too Many Requests", 500: "Internal Server Error",
                                      502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"]
        for (status, phrase) in phrases { #expect(HTTPSerializer.reasonPhrase(for: status) == phrase, "\(status)") }
        #expect(HTTPSerializer.reasonPhrase(for: 599) == "Status 599", "an unknown status still gets a phrase")
        let wire = HTTPSerializer.response(status: 410, headers: HTTPHeaders(), body: Data())
        #expect(String(decoding: wire.prefix(19), as: UTF8.self) == "HTTP/1.1 410 Gone\r\n")
    }
}
