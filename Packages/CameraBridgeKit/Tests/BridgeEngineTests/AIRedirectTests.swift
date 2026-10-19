#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// Final review I1: URLSession follows a redirect by itself, and on both macOS and Linux (swift-corelibs-foundation) it sends the key header
/// to the new host, with the pictures too on a 307 or 308. The key goes only to the server it was saved for, so the AI client never follows
/// one: the 3xx answer is the answer, and it becomes a plain sentence. Two loopback servers (a real URLSession, real sockets, on both
/// platforms): the first answers every request with a redirect to the second, which must never be asked at all.
@Suite(.timeLimit(.minutes(1))) struct AIRedirectTests {
    static let key = "sk-test-0000"
    static let pictures = [LabeledPicture(label: "at the event", jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x03, 0x04, 0xFE, 0xFF]))]
    static let request = DescriptionRequest(cameraName: "Front Door", eventKind: "Person", localTime: "Sat 18 Oct, 21:45", pictures: pictures)
    /// What a loopback server saw of one request.
    struct Seen: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// A loopback HTTP server that notes every request and answers it from `answer`.
    final class Server: Sendable {
        typealias Answer = @Sendable (HTTPRequestHead) -> (status: Int, headers: [(String, String)], body: Data)
        let requests = Box<[Seen]>([])
        let port: UInt16
        private let listener: any TCPListener
        private let acceptor: Task<Void, Never>

        init(answer: @escaping Answer) async throws {
            let listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            let requests = requests
            self.listener = listener
            port = listener.port
            acceptor = Task {
                for await connection in listener.connections {
                    Task { await Self.serve(connection, requests: requests, answer: answer) }
                }
            }
        }

        func stop() {
            listener.close()
            acceptor.cancel()
        }

        private static func serve(_ connection: any TCPConnection, requests: Box<[Seen]>, answer: Answer) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while let data = try? await connection.receive(maximumLength: 65_536), let parsed = try? parser.feed(data) {
                for (head, body) in parsed {
                    var headers: [String: String] = [:]
                    for (name, value) in head.headers { headers[name.lowercased()] = value }
                    requests.update { $0.append(Seen(method: head.method, path: head.path, headers: headers, body: body)) }
                    let (status, answerHeaders, answerBody) = answer(head)
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders(answerHeaders), body: answerBody)
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }
    }

    /// Sends Claude's request (its own address is fixed) to a loopback server instead, over the live transport.
    struct Rerouted: AITransport {
        var target: URL

        func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
            var request = request
            request.url = target
            return try await URLSessionAITransport().send(request)
        }
    }

    /// The target answers 200 with a description for either provider, so a followed redirect would succeed; the redirecting server sends
    /// everything there.
    private func servers(status: Int) async throws -> (redirecting: Server, target: Server) {
        let fields: [String: Any] = ["summary": "A person walks up the driveway", "kind": "person", "concern": "routine"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let answer: [String: Any] = ["choices": [["message": ["content": text]]], "content": [["type": "tool_use", "name": "describe_event", "input": fields]]]
        let body = try JSONSerialization.data(withJSONObject: answer)
        let target = try await Server { _ in (200, [("Content-Type", "application/json")], body) }
        let location = "http://127.0.0.1:\(target.port)/elsewhere"
        let redirecting = try await Server { _ in (status, [("Location", location)], Data()) }
        return (redirecting, target)
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func aRedirectIsNeverFollowed(status: Int) async throws {
        for claude in [true, false] {
            let (redirecting, target) = try await servers(status: status)
            defer { redirecting.stop(); target.stop() }
            let base = try #require(URL(string: "http://127.0.0.1:\(redirecting.port)/v1"))
            let vision: any AIVisionDescribing = claude
                ? AnthropicVision(key: Self.key, transport: Rerouted(target: base.appendingPathComponent("messages")))
                : OpenAICompatibleVision(baseURL: base, key: Self.key, model: "llava", transport: URLSessionAITransport())

            await #expect(throws: AIProviderError.redirected, "\(claude ? "Claude" : "OpenAI-compatible"), \(status)") {
                try await vision.describe(Self.request)
            }

            let asked = redirecting.requests.value
            #expect(asked.count == 1 && asked.first?.method == "POST", "the service itself was asked once")
            let header = claude ? "x-api-key" : "authorization"
            #expect(asked.first?.headers[header] == (claude ? Self.key : "Bearer " + Self.key), "it got the key (and it is the one that must not travel on)")
            #expect(target.requests.value.isEmpty, "the redirect's target was never asked: no key, no pictures (\(claude ? "Claude" : "OpenAI-compatible"), \(status))")
        }
    }

    @Test func aRedirectIsAPlainSentenceThatCarriesNothing() async throws {
        let (redirecting, target) = try await servers(status: 307)
        defer { redirecting.stop(); target.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(redirecting.port)/chat/completions?token=\(Self.key)"))
        do {
            _ = try await URLSessionAITransport().answer(to: URLRequest(url: url))
            Issue.record("a redirect did not throw")
        } catch let error as AIProviderError {
            #expect(error == .redirected)
            #expect(error.sentence == "The service tried to send the request elsewhere; check the address.")
            for text in [error.sentence, String(describing: error), String(reflecting: error)] {
                #expect(!text.contains(Self.key) && !text.contains("127.0.0.1") && !text.contains("elsewhere?"), "\(text)")
            }
        } catch {
            Issue.record("threw \(error)")
        }
        #expect(target.requests.value.isEmpty)
    }

    /// Only the AI client refuses redirects: the camera clients that share `AuthenticatingHTTPClient` still follow them, as they always did.
    @Test func theCameraClientsStillFollowRedirects() async throws {
        let (redirecting, target) = try await servers(status: 307)
        defer { redirecting.stop(); target.stop() }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5))
        defer { client.invalidate() }
        let url = try #require(URL(string: "http://127.0.0.1:\(redirecting.port)/snapshot.jpg"))
        let (_, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(target.requests.value.count == 1, "a camera behind a redirect still answers")
    }
}
#endif
