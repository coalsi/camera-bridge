import BridgeSupport
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// What the website said or why it could not be reached. `message` is a sentence for the person.
struct BoxClientError: Error, Equatable, CustomStringConvertible {
    enum Kind: Equatable, Sendable { case unreachable, notReady, refused, rateLimited, unauthorized }
    var kind: Kind
    var message: String
    var description: String { message }
}

/// One HTTP exchange with the website. Replaced in tests.
protocol BoxTransport: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data)
}

struct URLSessionBoxTransport: BoxTransport {
    private static let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(20), allowSelfSignedTLS: false, maximumBodySize: 64 * 1024)

    func send(method: String, url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await Self.client.data(for: request)
            return (response.statusCode, data)
        } catch {
            throw URLFreeErrors.sanitized(error, request: "Camera Bridge website request")
        }
    }
}

/// The website's box API (`/api/v1/box/`). Everything about its format is here: the paths, the body shapes, the signature and the headers,
/// so a later change touches this file only.
///
/// A signed call carries `X-CB-Name`, `X-CB-Timestamp` (Unix milliseconds, strictly greater than the one before) and `X-CB-Signature`
/// (base64 Ed25519 over `METHOD\nPATH\nTIMESTAMP\nSHA256hex(body)`, the path without a query, the body as sent).
final class BoxClient: Sendable {
    static let defaultBase = URL(string: "https://www.camera-bridge.app/api/v1/box/")!

    struct Registration: Equatable, Sendable { var name: String; var host: String }

    private let base: URL
    private let transport: any BoxTransport
    private let now: @Sendable () -> Date
    private let lastTimestamp: Mutex<Int64>

    init(base: URL = BoxClient.defaultBase, transport: any BoxTransport = URLSessionBoxTransport(), lastTimestamp: Int64 = 0,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.transport = transport
        self.now = now
        self.lastTimestamp = Mutex(lastTimestamp)
    }

    /// The last timestamp sent (kept in the state so a restart never goes backwards).
    var lastSentTimestamp: Int64 { lastTimestamp.withLock { $0 } }

    /// Never go below `last` (a timestamp sent before a restart).
    func seed(_ last: Int64) { lastTimestamp.withLock { $0 = max($0, last) } }

    // MARK: Signing

    static func signedMessage(method: String, path: String, timestamp: Int64, body: Data) -> Data {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("\(method)\n\(path)\n\(timestamp)\n\(digest)".utf8)
    }

    static func signature(key: Curve25519.Signing.PrivateKey, method: String, path: String, timestamp: Int64, body: Data) throws -> String {
        try key.signature(for: signedMessage(method: method, path: path, timestamp: timestamp, body: body)).base64EncodedString()
    }

    private func nextTimestamp() -> Int64 {
        let wanted = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        return lastTimestamp.withLock { last in
            last = max(wanted, last + 1)
            return last
        }
    }

    // MARK: Calls

    func register(publicKey: String) async throws -> Registration {
        struct Body: Encodable { var publicKey: String }
        struct Answer: Decodable { var name: String; var host: String }
        let data = try await exchange("POST", "register", body: try JSONEncoder().encode(Body(publicKey: publicKey)), signer: nil)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw Self.badAnswer }
        return Registration(name: answer.name, host: answer.host)
    }

    func sendAddress(_ ip: String, as identity: (name: String, key: Curve25519.Signing.PrivateKey)) async throws {
        struct Body: Encodable { var ip: String }
        _ = try await exchange("POST", "address", body: try JSONEncoder().encode(Body(ip: ip)), signer: identity)
    }

    func setChallenge(_ value: String, as identity: (name: String, key: Curve25519.Signing.PrivateKey)) async throws {
        struct Body: Encodable { var value: String }
        _ = try await exchange("POST", "acme", body: try JSONEncoder().encode(Body(value: value)), signer: identity)
    }

    func clearChallenge(as identity: (name: String, key: Curve25519.Signing.PrivateKey)) async throws {
        _ = try await exchange("DELETE", "acme", body: Data(), signer: identity)
    }

    // MARK: Exchange

    private static let badAnswer = BoxClientError(kind: .refused, message: "The Camera Bridge website gave an answer this box doesn’t understand.")

    private func exchange(_ method: String, _ endpoint: String, body: Data, signer: (name: String, key: Curve25519.Signing.PrivateKey)?) async throws -> Data {
        let url = base.appending(path: endpoint, directoryHint: .notDirectory)
        var headers: [String: String] = ["Accept": "application/json"]
        if !body.isEmpty { headers["Content-Type"] = "application/json" }
        if let signer {
            let timestamp = nextTimestamp()
            headers["X-CB-Name"] = signer.name
            headers["X-CB-Timestamp"] = String(timestamp)
            headers["X-CB-Signature"] = try Self.signature(key: signer.key, method: method, path: url.path(percentEncoded: true), timestamp: timestamp, body: body)
        }
        let answer: (status: Int, body: Data)
        do {
            answer = try await transport.send(method: method, url: url, headers: headers, body: body)
        } catch {
            throw BoxClientError(kind: .unreachable, message: "The Camera Bridge website can’t be reached. Check that the box has internet.")
        }
        if (200..<300).contains(answer.status) { return answer.body }
        struct Failure: Decodable { var error: String }
        let said = (try? JSONDecoder().decode(Failure.self, from: answer.body))?.error
        switch answer.status {
        case 503: throw BoxClientError(kind: .notReady, message: "The secure address service isn’t ready yet. The box will try again later.")
        case 429: throw BoxClientError(kind: .rateLimited, message: "The secure address service has had too many requests from this box today. It will try again later.")
        case 401: throw BoxClientError(kind: .unauthorized, message: "The Camera Bridge website didn’t accept this box’s signature\(said.map { ": \($0)" } ?? "").")
        default: throw BoxClientError(kind: .refused, message: "The Camera Bridge website refused the request\(said.map { ": \($0)" } ?? "").")
        }
    }
}
