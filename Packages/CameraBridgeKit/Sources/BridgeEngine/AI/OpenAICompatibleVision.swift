import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Any service that speaks the OpenAI chat API with pictures (OpenAI, OpenRouter, or a model at home such as Ollama or LM Studio): the
/// pictures go in as data URLs after a text label each, and the model is asked to reply with a bare JSON object, read leniently.
public struct OpenAICompatibleVision: AIVisionDescribing {
    static let maximumTokens = 200
    /// Added to the system text: the other API's tool call has no counterpart here.
    static let jsonInstruction = "Reply with only a JSON object with keys summary, kind and concern."

    public let model: String
    private let baseURL: URL
    private let key: AISecret?
    private let transport: any AITransport
    private let now: @Sendable () -> Date

    /// `baseURL` is the service's API address ("https://…/v1", "http://192.168.77.10:11434/v1"); the request goes to its
    /// `chat/completions`. A nil or empty `key` sends no `Authorization` header (a home server often has none). `now` stamps the description.
    public init(baseURL: URL, key: String?, model: String, transport: any AITransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.baseURL = baseURL
        self.key = key.flatMap { $0.isEmpty ? nil : AISecret($0) }
        self.model = model
        self.transport = transport
        self.now = now
    }

    public func describe(_ request: DescriptionRequest) async throws -> EventDescription {
        let content: [[String: Any]] = DescriptionPrompt.parts(request).map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .jpeg(let data):
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]]
            }
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maximumTokens,
            "messages": [
                ["role": "system", "content": DescriptionPrompt.system + " " + Self.jsonInstruction],
                ["role": "user", "content": content],
            ],
        ]
        var headers: [String: String] = [:]
        if let key { headers["Authorization"] = "Bearer " + key.value }
        let http = try AIJSON.post(baseURL.appendingPathComponent("chat/completions"), headers: headers, body: body)
        let answer: Data
        do {
            answer = try await transport.answer(to: http)
        } catch AIProviderError.keyRefused where key == nil {
            throw AIProviderError.keyNeeded   // no key was sent, so none was refused: the service wants one
        }

        guard let choices = AIJSON.object(answer)?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              let description = EventDescription.parse(text, model: model, at: now()) else {
            throw AIProviderError.badAnswer
        }
        return description
    }
}
