import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One still picture of an event, with the words that place it in time ("2 s before", "at the event", "2 s after").
public struct LabeledPicture: Sendable, Equatable {
    public var label: String
    public var jpeg: Data

    public init(label: String, jpeg: Data) {
        self.label = label
        self.jpeg = jpeg
    }
}

/// What one description is asked of: the camera's name, the kind of event it reported, the local time, and the pictures in time order.
public struct DescriptionRequest: Sendable {
    public var cameraName: String
    public var eventKind: String
    public var localTime: String
    public var pictures: [LabeledPicture]

    public init(cameraName: String, eventKind: String, localTime: String, pictures: [LabeledPicture]) {
        self.cameraName = cameraName
        self.eventKind = eventKind
        self.localTime = localTime
        self.pictures = pictures
    }
}

/// An AI vision service that writes one `EventDescription` from a few pictures. Throws `AIProviderError` (or `CancellationError`).
public protocol AIVisionDescribing: Sendable {
    /// The model it asks for.
    var model: String { get }
    func describe(_ request: DescriptionRequest) async throws -> EventDescription
}

/// Sends one HTTP request to an AI service. Replaced in tests.
public protocol AITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int)
}

/// The live transport: `AuthenticatingHTTPClient` without credentials, certificate checks on, 20 s per round trip, answers up to 1 MiB.
/// It never follows a redirect: the key header and the pictures go to the address that was saved and to no other, so a 3xx is the answer
/// (`AIProviderError.redirected`). Errors are thrown without the request address.
public final class URLSessionAITransport: AITransport {
    public init() {}

    /// One client for the bridge's life, shared by every instance: sessions made and invalidated per request (or per provider change) can
    /// crash FoundationNetworking on Linux when requests overlap (see `URLSessionWyzeTransport`).
    private static let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(20), allowSelfSignedTLS: false,
                                                         maximumBodySize: 1 << 20, downgradeGuard: BasicDowngradeGuard(), followsRedirects: false)

    public func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        do {
            let (data, response) = try await Self.client.data(for: request)
            return (data, response.statusCode)
        } catch {
            throw URLFreeErrors.sanitized(error, request: "AI request")
        }
    }
}

/// Why a description could not be had. Carries no request or answer data (no key, no address, no picture, no text the service sent), so it is
/// safe to log, store and show; `sentence` is the plain words for the person.
public enum AIProviderError: Error, Equatable, Sendable {
    /// 401: the service did not accept the key.
    case keyRefused
    /// 403: the key is known but may not do this.
    case notAllowed
    /// 404: the service has no such address or model (a mistyped address, a model it does not offer).
    case notFound
    /// 429
    case rateLimited
    /// No answer: the connection failed, was lost or timed out.
    case unreachable
    /// A 5xx answer (Claude's 529 "overloaded" among them), with its code.
    case serviceFailed(Int)
    /// 401 from a service with no key to send (an OpenAI-compatible one at home that wants one): the person has to save a key. Unlike a refused
    /// key it pauses nothing: there was no key to refuse.
    case keyNeeded
    /// 400: the service refused the request itself, most often for a model it does not take.
    case requestRefused
    /// A 3xx: the service tried to send the request to another address. Never followed (the key and the pictures go to the address that was
    /// saved and nowhere else), so the answer is this.
    case redirected
    /// Claude's `stop_reason` "refusal": the model chose not to describe the pictures.
    case declined
    /// An answer that is no description: another status, a body that is too large, or text with no summary.
    case badAnswer

    public var sentence: String {
        switch self {
        case .keyRefused: "The key was refused."
        case .notAllowed: "The key is not allowed to use this model or service."
        case .notFound: "The service doesn't know that address or model."
        case .rateLimited: "The service is limiting requests; try again later."
        case .unreachable: "The service could not be reached."
        case .serviceFailed(let code): "The service had a problem (error \(code))."
        case .keyNeeded: "The service needs a key."
        case .requestRefused: "The service refused the request; check the model name."
        case .redirected: "The service tried to send the request elsewhere; check the address."
        case .declined: "The service declined to describe these pictures."
        case .badAnswer: "The service gave an answer that could not be used."
        }
    }
}

/// A key as the clients hold it: it prints as nothing, so a log line or a dump that mentions a client never shows it.
struct AISecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { "(key)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension AITransport {
    /// Sends the request and returns the body of a 2xx answer; every other outcome is an `AIProviderError`, built from the status and nothing
    /// the service wrote (a 401 body may echo the key). A cancelled caller gets `CancellationError`.
    func answer(to request: URLRequest) async throws -> Data {
        let body: Data
        let status: Int
        do {
            (body, status) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch HTTPClientError.bodyTooLarge {
            throw AIProviderError.badAnswer
        } catch {
            throw AIProviderError.unreachable
        }
        switch status {
        case 200..<300: return body
        case 300..<400: throw AIProviderError.redirected
        case 400: throw AIProviderError.requestRefused
        case 401: throw AIProviderError.keyRefused
        case 403: throw AIProviderError.notAllowed
        case 404: throw AIProviderError.notFound
        case 429: throw AIProviderError.rateLimited
        case 500..<600: throw AIProviderError.serviceFailed(status)
        default: throw AIProviderError.badAnswer
        }
    }
}

/// The JSON the two clients send and read.
enum AIJSON {
    /// A POST of `body` as JSON to `url` with `headers` as well.
    static func post(_ url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // (Not reachable: the body is built from strings, numbers and arrays of them.)
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw AIProviderError.badAnswer
        }
        request.httpBody = data
        return request
    }

    /// The JSON object in an answer.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
