import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TestSupport
import Testing
@testable import BridgeEngine

/// What a fake transport saw of one request.
private struct Sent: Sendable {
    var url: URL
    var method: String
    var body: Data
    private var headers: [String: String]

    init(_ request: URLRequest) {
        url = request.url ?? URL(fileURLWithPath: "/")
        method = request.httpMethod ?? "GET"
        body = request.httpBody ?? Data()
        headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// Records every request and answers one canned body (or fails).
private final class FakeAITransport: AITransport, Sendable {
    let requests = Box<[Sent]>([])
    private let status: Int
    private let body: String
    private let failure: (any Error & Sendable)?

    init(status: Int = 200, body: String = "", failure: (any Error & Sendable)? = nil) {
        self.status = status
        self.body = body
        self.failure = failure
    }

    var last: Sent? { requests.value.last }

    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        requests.update { $0.append(Sent(request)) }
        if let failure { throw failure }
        return (Data(body.utf8), status)
    }
}

private struct Failing: Error, CustomStringConvertible {
    var description: String
}

@Suite(.timeLimit(.minutes(1))) struct AIProviderTests {
    static let key = "sk-test-0000"
    static let fixed = Date(timeIntervalSince1970: 1_791_000_000)
    static let base = URL(string: "http://192.168.77.10:11434/v1")!

    static let pictures = [
        LabeledPicture(label: "2 s before", jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFB, 0xFF])),
        LabeledPicture(label: "at the event", jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x03, 0x04, 0xFE, 0xFF])),
        LabeledPicture(label: "2 s after", jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x05, 0x06, 0xFF, 0xFF])),
    ]
    static let request = DescriptionRequest(cameraName: "Front Door", eventKind: "Person", localTime: "Sat 18 Oct, 21:45", pictures: pictures)

    static let anthropicAnswer = #"""
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-5-5-20260101",
     "content":[{"type":"text","text":"Looking at the pictures."},
                {"type":"tool_use","id":"toolu_01","name":"describe_event",
                 "input":{"summary":"A delivery driver leaves a package at the front door","kind":"delivery","concern":"routine"}}],
     "stop_reason":"tool_use","usage":{"input_tokens":1100,"output_tokens":48}}
    """#
    static let openAIAnswer = #"""
    {"id":"chatcmpl-1","object":"chat.completion","model":"llava",
     "choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant",
       "content":"```json\n{\"summary\":\"A man in a red jacket walks up the driveway\",\"kind\":\"person\",\"concern\":\"routine\"}\n```"}}]}
    """#

    private func anthropic(_ transport: FakeAITransport, key: String = key) -> AnthropicVision {
        AnthropicVision(key: key, transport: transport, now: { Self.fixed })
    }

    private func openAI(_ transport: FakeAITransport, key: String? = key, base: URL = base) -> OpenAICompatibleVision {
        OpenAICompatibleVision(baseURL: base, key: key, model: "llava", transport: transport, now: { Self.fixed })
    }

    /// Both providers on one fake, to run a check against each.
    private func providers(_ transport: FakeAITransport) -> [any AIVisionDescribing] {
        [anthropic(transport), openAI(transport)]
    }

    private func blocks(_ content: Any?) -> [[String: Any]] {
        content as? [[String: Any]] ?? []
    }

    // MARK: Claude

    @Test func anthropicRequestShape() async throws {
        let transport = FakeAITransport(body: Self.anthropicAnswer)
        _ = try await anthropic(transport).describe(Self.request)

        let sent = try #require(transport.last)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.method == "POST")
        #expect(sent.header("x-api-key") == "sk-test-0000")
        #expect(sent.header("anthropic-version") == "2023-06-01")
        #expect(sent.header("content-type") == "application/json")
        #expect(sent.header("authorization") == nil)

        let body = sent.json
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 200)
        #expect(body["system"] as? String == DescriptionPrompt.system)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        // A text label before each picture, in the pictures' order, then the camera's words.
        let content = blocks(messages.first?["content"])
        #expect(content.count == 2 * Self.pictures.count + 1)
        for (index, picture) in Self.pictures.enumerated() {
            let label = content[2 * index]
            #expect(label["type"] as? String == "text")
            #expect(label["text"] as? String == picture.label)
            let image = content[2 * index + 1]
            #expect(image["type"] as? String == "image")
            let source = image["source"] as? [String: Any]
            #expect(source?["type"] as? String == "base64")
            #expect(source?["media_type"] as? String == "image/jpeg")
            #expect(source?["data"] as? String == picture.jpeg.base64EncodedString())
        }
        #expect(content.last?["type"] as? String == "text")
        #expect(content.last?["text"] as? String == DescriptionPrompt.userText(Self.request))

        // One forced tool call in the shape the description needs.
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["name"] as? String == "describe_event")
        #expect((tools.first?["description"] as? String)?.isEmpty == false)
        let schema = try #require(tools.first?["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["summary", "kind", "concern"])
        #expect((properties["summary"] as? [String: Any])?["type"] as? String == "string")
        #expect((properties["kind"] as? [String: Any])?["enum"] as? [String] == ["person", "vehicle", "animal", "delivery", "other", "nothing"])
        #expect((properties["concern"] as? [String: Any])?["enum"] as? [String] == ["routine", "unusual", "alarm"])
        #expect(Set(schema["required"] as? [String] ?? []) == ["summary", "kind", "concern"])
        let choice = try #require(body["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == "describe_event")
    }

    @Test func anthropicUsesTheModelItIsGiven() async throws {
        let transport = FakeAITransport(body: Self.anthropicAnswer)
        let vision = AnthropicVision(key: Self.key, model: "claude-test-1", transport: transport, now: { Self.fixed })
        let description = try await vision.describe(Self.request)
        #expect(vision.model == "claude-test-1")
        #expect(transport.last?.json["model"] as? String == "claude-test-1")
        #expect(description.model == "claude-test-1")
    }

    @Test func anthropicAnswerIsParsed() async throws {
        let transport = FakeAITransport(body: Self.anthropicAnswer)
        let description = try await anthropic(transport).describe(Self.request)
        #expect(description == EventDescription(summary: "A delivery driver leaves a package at the front door", kind: .delivery,
                                                concern: .routine, model: "claude-haiku-5-5", at: Self.fixed))
    }

    @Test func aToolAnswerGetsTheSameCareAsText() async throws {
        let long = Array(repeating: "package", count: 60).joined(separator: " ")
        let transport = FakeAITransport(body: #"{"content":[{"type":"tool_use","name":"describe_event","input":{"summary":"\#(long)","kind":"burglar","concern":"high"}}]}"#)
        let description = try await anthropic(transport).describe(Self.request)
        #expect(description.summary.count <= 140)
        #expect(description.summary.hasSuffix("…"))
        #expect(description.kind == .other)
        #expect(description.concern == .routine)
    }

    // MARK: OpenAI-compatible

    @Test func openAIRequestShape() async throws {
        let transport = FakeAITransport(body: Self.openAIAnswer)
        _ = try await openAI(transport).describe(Self.request)

        let sent = try #require(transport.last)
        #expect(sent.url.absoluteString == "http://192.168.77.10:11434/v1/chat/completions")
        #expect(sent.method == "POST")
        #expect(sent.header("authorization") == "Bearer sk-test-0000")
        #expect(sent.header("content-type") == "application/json")
        #expect(sent.header("x-api-key") == nil)

        let body = sent.json
        #expect(body["model"] as? String == "llava")
        #expect(body["max_tokens"] as? Int == 200)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        let system = try #require(messages[0]["content"] as? String)
        #expect(system.hasPrefix(DescriptionPrompt.system))
        #expect(system.hasSuffix("Reply with only a JSON object with keys summary, kind and concern."))
        #expect(messages[1]["role"] as? String == "user")
        let content = blocks(messages[1]["content"])
        #expect(content.count == 2 * Self.pictures.count + 1)
        for (index, picture) in Self.pictures.enumerated() {
            #expect(content[2 * index]["type"] as? String == "text")
            #expect(content[2 * index]["text"] as? String == picture.label)
            #expect(content[2 * index + 1]["type"] as? String == "image_url")
            let image = content[2 * index + 1]["image_url"] as? [String: Any]
            #expect(image?["url"] as? String == "data:image/jpeg;base64," + picture.jpeg.base64EncodedString())
        }
        #expect(content.last?["type"] as? String == "text")
        #expect(content.last?["text"] as? String == DescriptionPrompt.userText(Self.request))
    }

    @Test func openAISendsNoAuthorizationWithoutAKey() async throws {
        for key in [nil, ""] as [String?] {
            let transport = FakeAITransport(body: Self.openAIAnswer)
            _ = try await openAI(transport, key: key).describe(Self.request)
            let sent = try #require(transport.last)
            #expect(sent.header("authorization") == nil, "key \(String(describing: key))")
            #expect(!sent.headersMentionBearer)
        }
    }

    @Test func openAIAddressWithATrailingSlashIsTheSame() async throws {
        let transport = FakeAITransport(body: Self.openAIAnswer)
        _ = try await openAI(transport, base: URL(string: "https://llm.example.test/v1/")!).describe(Self.request)
        #expect(transport.last?.url.absoluteString == "https://llm.example.test/v1/chat/completions")
    }

    @Test func openAIAnswerIsParsed() async throws {
        let transport = FakeAITransport(body: Self.openAIAnswer)
        let description = try await openAI(transport).describe(Self.request)
        #expect(description == EventDescription(summary: "A man in a red jacket walks up the driveway", kind: .person,
                                                concern: .routine, model: "llava", at: Self.fixed))
    }

    @Test func aPictureWithoutALabelGetsNoEmptyText() async throws {
        let request = DescriptionRequest(cameraName: "Gate", eventKind: "Motion", localTime: "21:45",
                                         pictures: [LabeledPicture(label: "", jpeg: Data([1, 2, 3])), LabeledPicture(label: "later", jpeg: Data([4]))])
        #expect(DescriptionPrompt.parts(request) == [.jpeg(Data([1, 2, 3])), .text("later"), .jpeg(Data([4])), .text(DescriptionPrompt.userText(request))])
        let claude = FakeAITransport(body: Self.anthropicAnswer)
        _ = try await anthropic(claude).describe(request)
        let other = FakeAITransport(body: Self.openAIAnswer)
        _ = try await openAI(other).describe(request)
        for transport in [claude, other] {
            let body = String(decoding: try #require(transport.last).body, as: UTF8.self)
            #expect(!body.contains(#""text":"""#), "\(body)")
        }
    }

    // MARK: Errors

    @Test(arguments: [(401, AIProviderError.keyRefused), (403, .notAllowed), (429, .rateLimited), (500, .serviceFailed(500)),
                      (502, .serviceFailed(502)), (503, .serviceFailed(503)), (529, .serviceFailed(529)),
                      (404, .notFound), (400, .requestRefused), (422, .badAnswer), (302, .redirected), (307, .redirected), (308, .redirected),
                      (418, .badAnswer)])
    func statusesMapToErrors(status: Int, expected: AIProviderError) async {
        for provider in providers(FakeAITransport(status: status, body: #"{"error":{"message":"no"}}"#)) {
            await #expect(throws: expected) { try await provider.describe(Self.request) }
        }
    }

    /// Final review M2: a 400 (a model the service does not take, a parameter it does not know) is not "an answer that could not be used".
    @Test func aRefusedRequestSaysSoAndNamesTheModel() async {
        for provider in providers(FakeAITransport(status: 400, body: #"{"error":{"message":"max_tokens is not supported with this model"}}"#)) {
            await #expect(throws: AIProviderError.requestRefused) { try await provider.describe(Self.request) }
        }
        #expect(AIProviderError.requestRefused.sentence == "The service refused the request; check the model name.")
    }

    @Test func aRedirectHasItsOwnSentence() {
        #expect(AIProviderError.redirected.sentence == "The service tried to send the request elsewhere; check the address.")
    }

    /// Claude can answer 200 with `stop_reason` "refusal" and no tool call: the model chose not to describe the pictures.
    @Test func aModelThatDeclinesIsSaidToDecline() async {
        let declined = [#"{"content":[],"stop_reason":"refusal"}"#,
                        #"{"content":[{"type":"text","text":"I can't help with that."}],"stop_reason":"refusal","usage":{"input_tokens":1100,"output_tokens":9}}"#,
                        #"{"stop_reason":"refusal"}"#]
        for body in declined {
            await #expect(throws: AIProviderError.declined, "answer: \(body)") { try await anthropic(FakeAITransport(body: body)).describe(Self.request) }
        }
        #expect(AIProviderError.declined.sentence == "The service declined to describe these pictures.")
        // Any other stop without a tool call is still an answer that could not be used, and a normal answer still works.
        for stop in ["end_turn", "max_tokens", "pause_turn"] {
            await #expect(throws: AIProviderError.badAnswer, "stop_reason \(stop)") {
                try await anthropic(FakeAITransport(body: #"{"content":[{"type":"text","text":"A delivery"}],"stop_reason":"\#(stop)"}"#)).describe(Self.request)
            }
        }
        let worked = try? await anthropic(FakeAITransport(body: Self.anthropicAnswer)).describe(Self.request)
        #expect(worked?.kind == .delivery)
    }

    /// An OpenAI-compatible service that answers 401 when no key was saved needs one: that is not a refused key, so it is not paused as one.
    @Test func aServiceThatWantsAKeyWeDoNotHaveSaysSo() async {
        for key in [nil, ""] as [String?] {
            await #expect(throws: AIProviderError.keyNeeded, "key \(String(describing: key))") {
                try await openAI(FakeAITransport(status: 401, body: "{}"), key: key).describe(Self.request)
            }
        }
        // With a key saved it is the key that was refused, and Claude's key is never missing.
        await #expect(throws: AIProviderError.keyRefused) { try await openAI(FakeAITransport(status: 401, body: "{}")).describe(Self.request) }
        await #expect(throws: AIProviderError.keyRefused) { try await anthropic(FakeAITransport(status: 401, body: "{}")).describe(Self.request) }
        #expect(AIProviderError.keyNeeded.sentence == "The service needs a key.")
        // Without a key, the other statuses are what they were.
        await #expect(throws: AIProviderError.notAllowed) { try await openAI(FakeAITransport(status: 403, body: "{}"), key: nil).describe(Self.request) }
    }

    @Test func aFailedConnectionIsUnreachable() async {
        for failure in [URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.cannotFindHost)] as [URLError] {
            for provider in providers(FakeAITransport(failure: failure)) {
                await #expect(throws: AIProviderError.unreachable) { try await provider.describe(Self.request) }
            }
        }
        // What the live transport throws for a refused or lost connection (URLFreeErrors.sanitized).
        for provider in providers(FakeAITransport(failure: TransportError.connectionRefused)) {
            await #expect(throws: AIProviderError.unreachable) { try await provider.describe(Self.request) }
        }
    }

    @Test func anAnswerBeyondTheSizeLimitIsABadAnswer() async {
        for provider in providers(FakeAITransport(failure: HTTPClientError.bodyTooLarge(limit: 1 << 20))) {
            await #expect(throws: AIProviderError.badAnswer) { try await provider.describe(Self.request) }
        }
    }

    @Test func cancellingIsNotAnError() async {
        for provider in providers(FakeAITransport(failure: CancellationError())) {
            await #expect(throws: CancellationError.self) { try await provider.describe(Self.request) }
        }
    }

    @Test func answersThatCannotBeUsedAreBadAnswers() async {
        let unusable = ["", "not json", "{}", #"{"content":[]}"#, #"{"content":[{"type":"text","text":"A delivery"}]}"#,
                        #"{"content":[{"type":"tool_use","name":"describe_event","input":{"kind":"person"}}]}"#,
                        #"{"choices":[]}"#, #"{"choices":[{"message":{"content":"I cannot help with that"}}]}"#,
                        #"{"choices":[{"message":{"content":null}}]}"#]
        for body in unusable {
            for provider in providers(FakeAITransport(body: body)) {
                await #expect(throws: AIProviderError.badAnswer, "answer: \(body)") { try await provider.describe(Self.request) }
            }
        }
    }

    @Test func errorsNeverCarryTheKey() async {
        let echo = #"{"error":{"message":"Incorrect API key provided: sk-test-0000. Authorization: Bearer sk-test-0000"}}"#
        for status in [401, 403, 404, 429, 500, 529, 400, 302, 307] {
            for provider in providers(FakeAITransport(status: status, body: echo)) {
                do {
                    _ = try await provider.describe(Self.request)
                    Issue.record("status \(status) did not throw")
                } catch let error as AIProviderError {
                    for text in [error.sentence, String(describing: error), String(reflecting: error)] {
                        #expect(!text.contains("sk-test-0000"), "status \(status): \(text)")
                        #expect(!text.contains("Bearer"), "status \(status): \(text)")
                        #expect(!text.contains("Authorization"), "status \(status): \(text)")
                    }
                } catch {
                    Issue.record("status \(status) threw \(error)")
                }
            }
        }
        // A transport error that names the key (a proxy's message, a URL with a token) is not passed on either.
        let failure = Failing(description: "connect to https://proxy.example.test failed: Authorization: Bearer sk-test-0000")
        for provider in providers(FakeAITransport(failure: failure)) {
            do {
                _ = try await provider.describe(Self.request)
                Issue.record("a failing transport did not throw")
            } catch let error as AIProviderError {
                #expect(!error.sentence.contains("sk-test-0000") && !String(describing: error).contains("sk-test-0000"))
            } catch {
                Issue.record("threw \(error)")
            }
        }
    }

    @Test func theSentencesArePlainWordsWithoutRequestData() {
        let errors: [AIProviderError] = [.keyRefused, .notAllowed, .notFound, .rateLimited, .unreachable, .serviceFailed(503), .keyNeeded,
                                         .requestRefused, .redirected, .declined, .badAnswer]
        #expect(AIProviderError.keyRefused.sentence == "The key was refused.")
        #expect(AIProviderError.unreachable.sentence == "The service could not be reached.")
        #expect(AIProviderError.serviceFailed(503).sentence.contains("503"))
        for error in errors {
            #expect(error.sentence.hasSuffix("."), "\(error)")
            #expect(error.sentence.count < 80, "\(error)")
        }
        #expect(Set(errors.map(\.sentence)).count == errors.count, "each error has its own sentence")
    }

    @Test func theClientsDoNotPrintTheirKey() {
        let transport = FakeAITransport()
        let clients: [any AIVisionDescribing] = [anthropic(transport), openAI(transport)]
        for client in clients {
            var dumped = ""
            dump(client, to: &dumped)
            for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
                #expect(!text.contains("sk-test-0000"), "\(text)")
            }
        }
    }

    @Test func theLiveTransportFailsWithoutTheAddress() async throws {
        // Nothing listens on loopback port 1: the connection is refused. The error must not carry the address or its query.
        let url = try #require(URL(string: "http://127.0.0.1:1/chat/completions?token=sk-test-0000"))
        do {
            _ = try await URLSessionAITransport().send(URLRequest(url: url))
            Issue.record("a refused connection did not throw")
        } catch {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                #expect(!text.contains("sk-test-0000") && !text.contains("chat/completions"), "\(text)")
            }
        }
    }

    // MARK: The description

    @Test func lenientParsing() {
        func parse(_ text: String) -> EventDescription? { EventDescription.parse(text, model: "m", at: Self.fixed) }

        // Prose, a code fence and a second object around the answer.
        let wrapped = parse("""
        Sure! Here is the description you asked for:
        {"summary": "A person walks up the driveway", "kind": "person", "concern": "routine"}
        Let me know if you need anything else {not json}.
        """)
        #expect(wrapped == EventDescription(summary: "A person walks up the driveway", kind: .person, concern: .routine, model: "m", at: Self.fixed))
        #expect(parse("```json\n{\"summary\":\"A cat crosses the lawn\",\"kind\":\"animal\",\"concern\":\"routine\"}\n```")?.kind == .animal)
        // Braces inside the summary do not end the object; a first object that is not JSON is passed over.
        #expect(parse(#"{"summary":"A man {waving} at the door","kind":"person","concern":"unusual"}"#)?.summary == "A man {waving} at the door")
        #expect(parse(#"{oops} {"summary":"A van stops","kind":"vehicle","concern":"routine"}"#)?.summary == "A van stops")

        // Trimmed, first line only.
        #expect(parse(#"{"summary":"  A van stops outside.\nIt looks like a delivery.  ","kind":"vehicle","concern":"routine"}"#)?.summary == "A van stops outside.")
        #expect(parse(#"{"summary":"\n\n  A van stops outside.  ","kind":"vehicle","concern":"routine"}"#)?.summary == "A van stops outside.")

        // A 400-word summary is capped at 140 characters, at a word, with an ellipsis.
        let words = (1...400).map { "word\($0)" }
        let capped = parse(#"{"summary":"\#(words.joined(separator: " "))","kind":"person","concern":"routine"}"#)?.summary ?? ""
        #expect(capped.count <= 140)
        #expect(capped.count > 100)
        #expect(capped.hasSuffix("…"))
        let kept = capped.dropLast().split(separator: " ").map(String.init)
        #expect(!kept.isEmpty && kept == Array(words.prefix(kept.count)), "ends at a whole word: \(capped)")
        // Exactly 140 characters is left alone; one more is capped.
        let exact = String(repeating: "a", count: 139) + "b"
        #expect(parse(#"{"summary":"\#(exact)","kind":"other","concern":"routine"}"#)?.summary == exact)
        let longWord = parse(#"{"summary":"\#(exact)c","kind":"other","concern":"routine"}"#)?.summary ?? ""
        #expect(longWord.count == 140 && longWord.hasSuffix("…"), "one word longer than the limit is cut inside it")

        // Unknown or odd values fall back; the words are matched without regard to case.
        #expect(parse(#"{"summary":"A person climbs the fence","kind":"burglar","concern":"high"}"#).pair == "other/routine")
        #expect(parse(#"{"summary":"A person climbs the fence","kind":"Person","concern":"ALARM"}"#).pair == "person/alarm")
        #expect(parse(#"{"summary":"A person climbs the fence"}"#).pair == "other/routine")
        #expect(parse(#"{"summary":"A person climbs the fence","kind":7,"concern":null}"#).pair == "other/routine")

        // Nothing worth noting: always the same words.
        let nothing = parse(#"{"summary":"Leaves move in the wind","kind":"nothing","concern":"routine"}"#)
        #expect(nothing?.summary == "Nothing notable")
        #expect(nothing?.kind == .nothing)
        #expect(parse(#"{"kind":"nothing"}"#)?.summary == "Nothing notable")

        // No description at all.
        #expect(parse("I cannot help with that") == nil)
        #expect(parse("") == nil)
        #expect(parse("{}") == nil)
        #expect(parse(#"{"summary":"   ","kind":"person","concern":"routine"}"#) == nil)
        #expect(parse(#"{"summary":42,"kind":"person","concern":"routine"}"#) == nil)
        #expect(parse(#"{"summary": "An unfinished answer"#) == nil)
        #expect(parse("[1, 2, 3]") == nil)
    }

    /// The cap leaves room for the "…", so the cut is between the 139th and 140th characters. When that cut already falls between two words,
    /// every word before it is kept; one more is never dropped.
    @Test func aCutThatFallsBetweenTwoWordsKeepsEveryWordBeforeIt() {
        func summary(of line: String) -> String {
            EventDescription.parse(#"{"summary":"\#(line)","kind":"person","concern":"routine"}"#, model: "m", at: Self.fixed)?.summary ?? ""
        }
        // Four 30-letter words and a 14-letter one end at the 138th character; a space is the 139th and the next word starts at the 140th.
        let head = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccccccccc",
                    "dddddddddddddddddddddddddddddd", "eeeeeeeeeeeeee"]
        let spaceThenLetter = head.joined(separator: " ") + " " + "ffff gggg hhhh"
        #expect(Array(spaceThenLetter)[138] == " " && Array(spaceThenLetter)[139] == "f")
        #expect(summary(of: spaceThenLetter) == head.joined(separator: " ") + "…")

        // A word ends at the 139th character and a space is the 140th: that word stays, and the result is exactly 140 characters.
        let letterThenSpace = head.dropLast().joined(separator: " ") + " " + "eeeeeeeeeeeeeee" + " ffff gggg"
        #expect(Array(letterThenSpace)[138] == "e" && Array(letterThenSpace)[139] == " ")
        let kept = summary(of: letterThenSpace)
        #expect(kept == head.dropLast().joined(separator: " ") + " " + "eeeeeeeeeeeeeee…")
        #expect(kept.count == 140)

        // The word that runs across the cut goes, and every word before it stays.
        let across = head.dropLast().joined(separator: " ") + " eeeeeeeeeeeeeeeeee gggg hhhh"
        #expect(summary(of: across) == head.dropLast().joined(separator: " ") + "…")
    }

    /// Final review M3: control and format characters (bidi overrides, zero-width marks, a byte order mark, a bell) are taken out of what a
    /// model wrote, so they cannot reorder or hide what the row draws. The joiner that makes one emoji of several stays.
    @Test func controlAndFormatCharactersAreTakenOutOfTheSummary() throws {
        func summary(_ text: String) throws -> String? {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["summary": text, "kind": "person", "concern": "routine"]), as: UTF8.self)
            return EventDescription.parse(json, model: "m", at: Self.fixed)?.summary
        }
        // Bidi override and embedding, isolates, zero-width space, no-break joiner, word joiner, byte order mark, null, bell, escape, delete.
        #expect(try summary("A man\u{202E}walks\u{202C} up\u{2066} the\u{2069} drive\u{200B}way\u{200C}\u{2060}\u{FEFF}") == "A manwalks up the driveway")
        #expect(try summary("A\u{0000} van\u{0007} stops\u{001B}[0m\u{007F} outside") == "A van stops[0m outside")
        // A tab is a space between words, not a hole in one.
        #expect(try summary("A van\tstops") == "A van stops")
        // The zero-width joiner stays: it makes one emoji of three.
        let family = "A \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} waits at the door"
        #expect(try summary(family) == family)
        #expect(try #require(try summary(family)).unicodeScalars.contains("\u{200D}"))
        // Ordinary text, accents and other scripts are untouched.
        #expect(try summary("Un chat traverse la pelouse à côté du garage 猫") == "Un chat traverse la pelouse à côté du garage 猫")
        // Nothing left is no description (the first line that has something is the summary).
        #expect(try summary("\u{200B}\u{202E}\u{FEFF}") == nil)
        #expect(try summary("\u{200B}\nA van stops") == "A van stops")
        // The same care for the kind `nothing`, which needs no summary.
        #expect(EventDescription.parse(#"{"summary":"\u202E","kind":"nothing"}"#, model: "m", at: Self.fixed)?.summary == "Nothing notable")
    }

    /// A character can be many bytes (a letter with a pile of combining marks is one character): the summary is also at most 600 UTF-8 bytes,
    /// cut at a word with an ellipsis, so its line in the event log never passes the limit and is never dropped after the description was paid for.
    @Test func aSummaryIsAlsoCappedInBytesAtAWord() throws {
        func summary(_ text: String) throws -> String {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["summary": text, "kind": "person", "concern": "routine"]), as: UTF8.self)
            return try #require(EventDescription.parse(json, model: "m", at: Self.fixed)).summary
        }
        // Ten characters of seven bytes: a word of 70 bytes. Ten words are 100 characters (under 140) and 710 bytes.
        let word = String(repeating: "e\u{0301}\u{0302}\u{0303}", count: 10)
        #expect(word.utf8.count == 70 && word.count == 10)
        let words = Array(repeating: word, count: 10)
        let capped = try summary(words.joined(separator: " "))
        #expect(capped.utf8.count <= 600, "\(capped.utf8.count) bytes")
        #expect(capped.hasSuffix("…") && capped.count < EventDescription.maximumSummaryLength)
        let kept = capped.dropLast().split(separator: " ").map(String.init)
        #expect(kept == Array(words.prefix(8)), "whole words only: 8 words and the ellipsis are 570 bytes, a ninth would pass 600")
        // Exactly 600 bytes (120 characters of 5 bytes) is left alone; one more character is cut, inside its one word, between characters.
        let exact = String(repeating: "e\u{0301}\u{0302}", count: 120)
        #expect(exact.utf8.count == 600 && exact.count == 120)
        #expect(try summary(exact) == exact)
        let over = try summary(exact + "e\u{0301}\u{0302}")
        #expect(over.utf8.count <= 600 && over.hasSuffix("…") && over.count == 120, "\(over.utf8.count) bytes, \(over.count) characters")
        // Many marks on each character: the character cap alone would let 140 of them through (about 3 KB).
        let heavy = String(repeating: "e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A}", count: 100)
        let cut = try summary(heavy)
        #expect(cut.utf8.count <= 600 && cut.hasSuffix("…") && cut.count > 1, "\(cut.utf8.count) bytes")
        // Plain text under both caps is unchanged.
        #expect(try summary("A man in a red jacket walks up the driveway") == "A man in a red jacket walks up the driveway")
    }

    @Test func parsingHostileTextIsFast() {
        let started = ContinuousClock.now
        for text in [String(repeating: "{", count: 1 << 20), String(repeating: "{\"", count: 1 << 19), String(repeating: "{}", count: 1 << 19)] {
            #expect(EventDescription.parse(text, model: "m", at: Self.fixed) == nil)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aDescriptionRoundTripsThroughJSON() throws {
        let description = EventDescription(summary: "A van stops outside", kind: .vehicle, concern: .unusual, model: "m", at: Self.fixed)
        let data = try JSONEncoder().encode(description)
        #expect(try JSONDecoder().decode(EventDescription.self, from: data) == description)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["summary", "kind", "concern", "model", "at"])
    }

    // MARK: The prompt

    @Test func thePromptAsksForBriefPlainSentences() {
        let system = DescriptionPrompt.system
        #expect(system.contains("at most 12 words"))
        #expect(system.contains("Never guess who someone is"))
        #expect(system.contains("Nothing notable"))
        #expect(system.contains("present tense"))
        #expect(!system.contains("\n"), "one paragraph")
        for word in ["alarm", "unusual", "routine", "nothing"] {
            #expect(system.contains("\"\(word)\""), "\(word)")
        }

        let text = DescriptionPrompt.userText(Self.request)
        #expect(text == "Camera: Front Door. The camera reported: Person. Local time: Sat 18 Oct, 21:45.")
    }
}

private extension EventDescription? {
    /// "kind/concern", or "nil".
    var pair: String { map { "\($0.kind)/\($0.concern)" } ?? "nil" }
}

private extension Sent {
    /// Whether any header value says "Bearer".
    var headersMentionBearer: Bool {
        ["authorization", "x-api-key", "proxy-authorization"].contains { header($0)?.contains("Bearer") == true }
    }
}
