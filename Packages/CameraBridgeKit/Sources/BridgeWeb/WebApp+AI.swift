import BridgeEngine
import Foundation

// AI descriptions of events: the provider settings that `PATCH /settings` takes and `GET /settings` shows (with the day's counts and the last
// failure), the write-only key (`PUT` and `DELETE /ai/key`) and Try it (`POST /ai/try`). The key goes in once and comes out nowhere:
// `GET /settings` says only whether one is saved and its last four characters, and no answer, log line or error quotes it. The camera's switch
// is `aiDescriptions` on `PATCH /cameras/:id`.

extension WebApp {
    static let aiRoutes: [Route] = [
        Route("PUT", "ai/key", takesBody: true) { app, ctx in try await app.putAIKey(ctx) },
        Route("DELETE", "ai/key") { app, _ in try await app.deleteAIKey() },
        Route("POST", "ai/try", takesBody: true) { app, ctx in try await app.tryAI(ctx) },
    ]

    // MARK: Try it

    private struct AITryBody: Decodable {
        var cameraID: String
    }

    /// What Try it answers: the description and how long it took, in seconds (to the tenth).
    private struct AITryResource: Encodable {
        var summary: String
        var kind: String
        var concern: String
        var seconds: Double
    }

    /// What a Try it that did not work answers (502, or 409 while another runs): the sentence, as `error`, and as `message` for the page's error
    /// helper.
    private struct AITryFailure: Encodable {
        var error: String
        var message: String
    }

    /// `POST /ai/try {cameraID}`: describes the pictures around now of the camera with the chosen service and stores nothing. `200 {summary,
    /// kind, concern, seconds}`; `502 {error}` with the plain sentence when no description could be had (the service's failure, no service, the
    /// day's limit, no picture); `409 {error}` ("A try is already running.") while another try runs; 404 for a camera the bridge does not have.
    func tryAI(_ ctx: RequestContext) async throws -> HTTPResponse {
        guard let body = try? decode(AITryBody.self, from: ctx), let cameraID = UUID(uuidString: body.cameraID) else {
            throw APIError.badRequest("Choose a camera to try.", field: "cameraID")
        }
        let started = ContinuousClock.now
        let sentence: String
        var status = 502
        do {
            let description = try await backend.tryAIDescription(cameraID: cameraID)
            let seconds = (ContinuousClock.now - started).timeInterval
            return .json(AITryResource(summary: description.summary, kind: description.kind.rawValue, concern: description.concern.rawValue,
                                       seconds: (seconds * 10).rounded() / 10))
        } catch EngineError.unknownCamera {
            throw APIError.notFound("That camera doesn’t exist.")
        } catch let error as AIProviderError {
            sentence = error.sentence
        } catch let error as AIDescriberError {
            sentence = error.sentence
            if error == .alreadyTrying { status = 409 }
        } catch {
            sentence = ErrorText.describe(error)
        }
        return .json(AITryFailure(error: sentence, message: sentence), status: status)
    }

    // MARK: The key

    private struct AIKeyBody: Decodable {
        var key: String
    }

    func putAIKey(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(AIKeyBody.self, from: ctx)
        // Trimmed, like the engine does: a pasted key brings a trailing newline, which would make an invalid header. Only visible ASCII is
        // left; the words never quote it.
        guard let key = AIDescriptionSettings.cleanedKey(body.key) else {
            throw APIError.badRequest("Paste the key from your AI service as it is: one line of letters, digits and punctuation with no spaces, up to \(AIDescriptionSettings.maximumKeyLength) characters.", field: "key")
        }
        try await storeAIKey(key)
        return .empty()
    }

    func deleteAIKey() async throws -> HTTPResponse {
        try await storeAIKey(nil)
        return .empty()
    }

    /// A failure is answered `422 ai_key_failed` and logged, with the key taken out of both: an error that quotes what it was asked to store
    /// must not carry it to the page or the log.
    private func storeAIKey(_ key: String?) async throws {
        do {
            try await backend.setAIKey(key)
        } catch {
            func withoutKey(_ text: String) -> String { key.map { text.replacingOccurrences(of: $0, with: "(key)") } ?? text }
            log.warning("saving the AI key failed: \(withoutKey(ErrorText.logDescription(error)))")
            throw APIError(status: 422, code: "ai_key_failed", message: withoutKey(ErrorText.describe(error)))
        }
    }

    // MARK: The settings

    /// `ai` in `PATCH /settings`: what was sent. A field that is left out stays; `provider` and `baseURL` can also be null (or, for the address, an
    /// empty string) to take them away.
    struct AIPatch: Decodable {
        var provider: PatchField<String>
        var model: String?
        var baseURL: PatchField<String>
        var dailyLimit: Int?

        private enum CodingKeys: String, CodingKey { case provider, model, baseURL, dailyLimit }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try PatchField(container, .provider)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            baseURL = try PatchField(container, .baseURL)
            dailyLimit = try container.decodeIfPresent(Int.self, forKey: .dailyLimit)
        }
    }

    /// A field of a patch that tells "left out" from "null".
    enum PatchField<Value: Decodable & Sendable>: Sendable {
        case absent
        case null
        case value(Value)

        init<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws {
            if !container.contains(key) {
                self = .absent
            } else if try container.decodeNil(forKey: key) {
                self = .null
            } else {
                self = .value(try container.decode(Value.self, forKey: key))
            }
        }
    }

    /// What `PATCH /settings` changes in `BridgeSettings.ai`, cleaned and checked, applied inside the engine's own settings change (so a change
    /// made meanwhile to another field stays).
    struct AIChange: Sendable {
        var provider: PatchField<AIProviderKind> = .absent
        var model: String?
        var baseURL: PatchField<String> = .absent
        var dailyLimit: Int?

        func apply(to settings: inout AIDescriptionSettings) {
            switch provider {
            case .absent: break
            case .null: settings.provider = nil
            case .value(let kind): settings.provider = kind
            }
            if let model { settings.model = model }
            switch baseURL {
            case .absent: break
            case .null: settings.baseURL = nil
            case .value(let address): settings.baseURL = address
            }
            if let dailyLimit { settings.dailyLimit = dailyLimit }
        }
    }

    /// The patch cleaned (text trimmed, an empty address taken as none) and checked against the settings as they are: `400` with the field
    /// (`ai.provider`, `ai.model`, `ai.baseURL`, `ai.dailyLimit`) when the result could not be saved. Nothing is changed here.
    func aiChange(from patch: AIPatch) async throws -> AIChange {
        var change = AIChange()
        switch patch.provider {
        case .absent: break
        case .null: change.provider = .null
        case .value(let name):
            guard let kind = AIProviderKind(rawValue: name) else {
                throw APIError.badRequest("Choose Claude or an OpenAI-compatible service.", field: "ai.provider")
            }
            change.provider = .value(kind)
        }
        change.model = patch.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch patch.baseURL {
        case .absent: break
        case .null: change.baseURL = .null
        case .value(let text):
            let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            change.baseURL = address.isEmpty ? .null : .value(address)
        }
        change.dailyLimit = patch.dailyLimit
        var merged = await backend.overview().settings.ai
        change.apply(to: &merged)
        if let problem = merged.validationProblem {
            throw APIError.badRequest(problem.message, field: "ai." + problem.field)
        }
        return change
    }
}

/// `BridgeSettings.ai` as the page reads it, with whether a key is saved and its last four characters (never the key), the day's and the
/// week's counts, whether today's limit is reached, whether describing is paused after a refused key, the last failure in plain words and
/// when it was, and whether descriptions wait for a recordings folder (without one no event is kept, so none is described). Absent values
/// are null.
struct AISettingsResource: Encodable {
    var provider: String?
    var model: String
    var baseURL: String?
    var dailyLimit: Int
    var keySaved: Bool
    var keyHint: String?
    var today: Int
    var last7Days: Int
    var limitReached: Bool
    var paused: Bool
    var lastError: String?
    var lastErrorAt: Date?
    var needsRecordingsFolder: Bool

    init(_ settings: AIDescriptionSettings, key: (saved: Bool, hint: String?), status: AIStatus) {
        provider = settings.provider?.rawValue
        model = settings.model
        baseURL = settings.baseURL
        dailyLimit = settings.dailyLimit
        keySaved = key.saved
        keyHint = key.hint
        today = status.today
        last7Days = status.last7Days
        limitReached = status.limitReached
        paused = status.paused
        lastError = status.lastError
        lastErrorAt = status.lastErrorAt
        needsRecordingsFolder = status.needsRecordingsFolder
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, baseURL, dailyLimit, keySaved, keyHint, today, last7Days, limitReached, paused, lastError, lastErrorAt
        case needsRecordingsFolder
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(dailyLimit, forKey: .dailyLimit)
        try container.encode(keySaved, forKey: .keySaved)
        try container.encode(keyHint, forKey: .keyHint)
        try container.encode(today, forKey: .today)
        try container.encode(last7Days, forKey: .last7Days)
        try container.encode(limitReached, forKey: .limitReached)
        try container.encode(paused, forKey: .paused)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(lastErrorAt, forKey: .lastErrorAt)
        try container.encode(needsRecordingsFolder, forKey: .needsRecordingsFolder)
    }
}
