import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude (Anthropic's Messages API): the pictures go in as base64 JPEGs, in time order, each after a text label, and the answer is forced
/// through one tool call, `describe_event`, so it always has the shape of an `EventDescription`.
public struct AnthropicVision: AIVisionDescribing {
    /// The cheapest Claude model that reads pictures.
    public static let defaultModel = "claude-haiku-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2023-06-01"
    static let toolName = "describe_event"
    /// A description is one sentence and two words: this is far above it.
    static let maximumTokens = 200

    public let model: String
    private let key: AISecret
    private let transport: any AITransport
    private let now: @Sendable () -> Date

    /// `now` stamps the description (`EventDescription.at`).
    public init(key: String, model: String = AnthropicVision.defaultModel, transport: any AITransport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.key = AISecret(key)
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
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
            }
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maximumTokens,
            "system": DescriptionPrompt.system,
            "messages": [["role": "user", "content": content]],
            "tools": [Self.tool],
            "tool_choice": ["type": "tool", "name": Self.toolName],
        ]
        let http = try AIJSON.post(Self.endpoint, headers: ["x-api-key": key.value, "anthropic-version": Self.version], body: body)
        let answer = try await transport.answer(to: http)

        let reply = AIJSON.object(answer)
        // The model can decline with a 200: its `stop_reason` says so, and there is no tool call to read.
        if reply?["stop_reason"] as? String == "refusal" { throw AIProviderError.declined }
        guard let blocks = reply?["content"] as? [[String: Any]],
              let call = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == Self.toolName }),
              let input = call["input"] as? [String: Any],
              let description = EventDescription(fields: input, model: model, at: now()) else {
            throw AIProviderError.badAnswer
        }
        return description
    }

    /// The one tool: its input is the description.
    private static var tool: [String: Any] {
        [
            "name": toolName,
            "description": "Report what is happening in the pictures, as one short plain sentence.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string",
                                "description": "At most 12 words, present tense: who or what, and what they are doing. \"Nothing notable\" for kind nothing."],
                    "kind": ["type": "string", "enum": EventDescription.Kind.allCases.map(\.rawValue)],
                    "concern": ["type": "string", "enum": EventDescription.Concern.allCases.map(\.rawValue)],
                ] as [String: Any],
                "required": ["summary", "kind", "concern"],
            ] as [String: Any],
        ]
    }
}
