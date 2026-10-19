import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The AI description settings in the API: the provider choice in `settings`, the write-only key (`PUT`/`DELETE ai/key`) and the camera's
/// switch. The key is never in an answer, a log line or the stored settings.
@Suite(.timeLimit(.minutes(1))) struct AIAPITests {
    static let key = "sk-test-0000"

    private func addCamera(_ session: Harness.Session) async throws -> UUID {
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "viewer", "password": "pw", "name": "Front Door"])
        return try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
    }

    private func ai(_ answer: Answer) -> [String: Any] { answer.json["ai"] as? [String: Any] ?? [:] }

    @Test func settingsStartWithNoServiceAndNoKey() async throws {
        let session = try await Harness().signIn()
        let answer = await session.get("/api/v1/settings")
        let ai = ai(answer)
        #expect(ai["provider"] is NSNull && ai.keys.contains("provider"), "no service chosen: null, not missing")
        #expect(ai["model"] as? String == "claude-haiku-5-5" && ai["dailyLimit"] as? Int == 200)
        #expect(ai["baseURL"] is NSNull && ai["keySaved"] as? Bool == false && ai["keyHint"] is NSNull)
    }

    @Test func theServiceIsChosenAndChangedThroughSettings() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let claude = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["provider": "anthropic", "dailyLimit": 50]])
        #expect(claude.status == 200, "\(claude.text)")
        #expect(ai(claude)["provider"] as? String == "anthropic" && ai(claude)["dailyLimit"] as? Int == 50)
        #expect(ai(claude)["model"] as? String == "claude-haiku-5-5", "what was not sent stays")

        let home = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["provider": "openAICompatible", "model": " llava:13b ",
                                                                              "baseURL": " http://192.168.77.10:11434/v1 "]])
        #expect(home.status == 200, "\(home.text)")
        #expect(backend.read { $0.settings.ai } == AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b",
                                                                        baseURL: "http://192.168.77.10:11434/v1", dailyLimit: 50),
                "trimmed, and the daily limit stays")
        #expect(ai(home)["baseURL"] as? String == "http://192.168.77.10:11434/v1")

        // Back to Claude: the address can be cleared with null or an empty string; null as the provider turns the service off.
        let cleared = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["provider": "anthropic", "baseURL": NSNull()]])
        #expect(cleared.status == 200 && ai(cleared)["baseURL"] is NSNull)
        _ = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["baseURL": "https://api.example.com/v1"]])
        #expect(ai(await session.send("PATCH", "/api/v1/settings", json: ["ai": ["baseURL": ""]]))["baseURL"] is NSNull)
        let off = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["provider": NSNull()]])
        #expect(off.status == 200 && ai(off)["provider"] is NSNull)
        #expect(backend.read { $0.settings.ai.provider } == nil)
        let stays = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["dailyLimit": 60]])
        #expect(stays.status == 200 && backend.read { $0.settings.ai.provider } == nil, "a patch without a provider leaves it alone")
    }

    @Test func validationRefusesABadAddressAndLimits() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let refused: [([String: Any], String)] = [
            (["provider": "openAICompatible"], "ai.baseURL"),
            (["provider": "openAICompatible", "baseURL": "ftp://192.168.77.10/v1"], "ai.baseURL"),
            (["provider": "openAICompatible", "baseURL": "192.168.77.10:11434/v1"], "ai.baseURL"),
            (["provider": "openAICompatible", "baseURL": "http://user:secret@192.168.77.10/v1"], "ai.baseURL"),
            (["provider": "openAICompatible", "baseURL": "https://example.com/v1?key=abc"], "ai.baseURL"),
            (["provider": "openAICompatible", "baseURL": "https://example.com/v1#top"], "ai.baseURL"),
            (["provider": "anthropic", "baseURL": "ftp://x/v1"], "ai.baseURL"),
            (["dailyLimit": 0], "ai.dailyLimit"),
            (["dailyLimit": 5_001], "ai.dailyLimit"),
            (["model": "  "], "ai.model"),
            (["model": String(repeating: "m", count: 101)], "ai.model"),
            (["model": "two\nlines"], "ai.model"),
            (["provider": "skynet"], "ai.provider"),
        ]
        for (body, field) in refused {
            let answer = await session.send("PATCH", "/api/v1/settings", json: ["ai": body])
            #expect(answer.status == 400 && answer.json["field"] as? String == field, "\(body): \(answer.status) \(answer.text)")
        }
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["ai": ["dailyLimit": "many"]]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["ai": "anthropic"]).status == 400)
        #expect(backend.read { $0.settings.ai } == AIDescriptionSettings(), "nothing was saved")

        // A refusal stops the whole request: the name and the port in the same patch are not applied.
        let mixed = await session.send("PATCH", "/api/v1/settings", json: ["bridgeName": "Garage", "basePort": 22_000, "ai": ["dailyLimit": 0]])
        #expect(mixed.status == 400)
        let after = await session.get("/api/v1/settings")
        #expect(after.json["basePort"] as? Int == 21_100 && after.json["bridgeName"] as? String == "Hallway")

        // The edges that are allowed.
        for (body, expected) in [(["dailyLimit": 1], 1), (["dailyLimit": 5_000], 5_000)] {
            #expect(await session.send("PATCH", "/api/v1/settings", json: ["ai": body]).status == 200)
            #expect(backend.read { $0.settings.ai.dailyLimit } == expected)
        }
    }

    @Test func theKeyIsWriteOnly() async throws {
        let capture = LogCapture()
        defer { capture.stop() }
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let saved = await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        #expect(saved.status == 204 && saved.body.isEmpty, "\(saved.text)")
        #expect(backend.read { $0.aiKey } == Self.key)

        // A paste with a newline or spaces around it is stored without them.
        #expect(await session.send("PUT", "/api/v1/ai/key", json: ["key": "  \(Self.key)\n"]).status == 204)
        #expect(backend.read { $0.aiKey } == Self.key)

        // Nothing the page can read holds it.
        let everything = [await session.get("/api/v1/settings"), await session.get("/api/v1/status"), await session.get("/api/v1/cameras")]
        for answer in everything { #expect(!answer.text.contains("sk-test"), "\(answer.text.prefix(80))") }
        #expect(backend.read { $0.settings.ai } == AIDescriptionSettings(), "the key is not part of the settings")
        _ = await session.send("PUT", "/api/v1/ai/key", json: ["key": "bad\nkey-\(Self.key)"])   // a refused key is not logged either
        #expect(capture.text.contains { $0.contains("PUT /api/v1/ai/key") }, "the request line names method and path")
        #expect(!capture.text.contains { $0.contains("sk-test") }, "and no log line holds the key: \(capture.text.filter { $0.contains("sk-test") })")
    }

    @Test func settingsNeverReturnTheKey() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        _ = await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        let answer = await session.get("/api/v1/settings")
        #expect(ai(answer)["keySaved"] as? Bool == true && ai(answer)["keyHint"] as? String == "0000")
        #expect(!answer.text.contains("sk-test") && !answer.text.contains("-0000"), "only the last four characters")
        #expect(answer.json["key"] == nil && ai(answer)["key"] == nil)
        let changed = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["provider": "anthropic"]])
        #expect(ai(changed)["keySaved"] as? Bool == true && !changed.text.contains("sk-test"))
        // A body that carries a key in the settings is no way to set one.
        let sneaky = await session.send("PATCH", "/api/v1/settings", json: ["ai": ["key": "sk-test-1111"]])
        #expect(sneaky.status == 200 && backend.read { $0.aiKey } == Self.key && !sneaky.text.contains("1111"))
    }

    @Test func aKeyThatCannotBeAHeaderIsRefusedWithoutBeingEchoed() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        _ = await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        let refused: [Any] = ["", "   ", "\n", "sk-test\n0000", "sk-test\t0000", "sk-test\u{7}0000", String(repeating: "k", count: 501), 12, NSNull(),
                              "sk-test 0000",           // an inner space
                              "sk-test\u{200B}0000",    // zero-width space
                              "sk-test-0000\u{200B}",   // a trailing one is not trimmed away
                              "\u{FEFF}sk-test-0000",   // a byte order mark
                              "sk-test\u{202E}0000",    // a bidi control
                              "sk-test-é0000", "sk-test-００００", "ключ-sk-test", "sk-test-0000\u{7F}"]
        for key in refused {
            let answer = await session.send("PUT", "/api/v1/ai/key", json: ["key": key])
            #expect(answer.status == 400 && answer.json["field"] as? String == "key", "\(answer.status) \(answer.text)")
            #expect(!answer.text.contains("sk-test"), "an error never quotes the key")
        }
        #expect(await session.send("PUT", "/api/v1/ai/key", json: ["other": "x"]).status == 400)
        #expect(await session.send("PUT", "/api/v1/ai/key").status == 400, "no body")
        #expect(backend.read { $0.aiKey } == Self.key, "a refused key changes nothing")
        #expect(await session.send("PUT", "/api/v1/ai/key", json: ["key": String(repeating: "k", count: 500)]).status == 204)
    }

    @Test func anyVisibleASCIIKeyIsAccepted() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        for key in ["sk-ant-api03_AbC.dEf+gh/ij=kl~", "!", "~", "sk-test-0000!@#$%^&*()[]{}<>:;,?|'\"`\\"] {
            #expect(await session.send("PUT", "/api/v1/ai/key", json: ["key": " \(key)\n"]).status == 204, "\(key)")
            #expect(backend.read { $0.aiKey } == key)
        }
    }

    /// A key that reveals itself in its own failure.
    struct LeakyFailure: LocalizedError, CustomStringConvertible {
        var key: String
        var description: String { "could not store \(key)" }
        var errorDescription: String? { "The store refused \(key)." }
    }

    @Test func aFailureToSaveTheKeyIsAnswered422WithoutTheKey() async throws {
        let capture = LogCapture()
        defer { capture.stop() }
        let backend = FakeBackend()
        backend.write { $0.aiKeyError = LeakyFailure(key: Self.key) }
        let session = try await Harness(backend: backend).signIn()
        let saved = await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        #expect(saved.status == 422 && saved.json["error"] as? String == "ai_key_failed", "\(saved.status) \(saved.text)")
        #expect(!saved.text.contains("sk-test") && !saved.text.contains("0000"), "the answer does not quote the key")
        #expect(backend.read { $0.aiKey } == nil)
        backend.write { $0.aiKeyError = EngineError.cameraNotRunning }   // a deletion has no key of its own to take out of an error
        let removed = await session.send("DELETE", "/api/v1/ai/key")
        #expect(removed.status == 422 && removed.json["error"] as? String == "ai_key_failed")
        #expect(capture.text.contains { $0.contains("saving the AI key failed") }, "the failure is logged")
        #expect(!capture.text.contains { $0.contains("sk-test") }, "but not with the key in it: \(capture.text.filter { $0.contains("sk-test") })")
        #expect(await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key]).status == 422, "a plain failure is answered the same way")
    }

    @Test func deletingTheKeyClearsIt() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        _ = await session.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        #expect(await session.send("DELETE", "/api/v1/ai/key").status == 204)
        #expect(backend.read { $0.aiKey } == nil)
        let answer = await session.get("/api/v1/settings")
        #expect(ai(answer)["keySaved"] as? Bool == false && ai(answer)["keyHint"] is NSNull)
        #expect(await session.send("DELETE", "/api/v1/ai/key").status == 204, "deleting what is not there is fine")
    }

    @Test func theKeyRoutesNeedASignedInPageWithItsToken() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let signedOut = await harness.send("PUT", "/api/v1/ai/key", json: ["key": Self.key])
        #expect(signedOut.status == 401)
        let noToken = await harness.send("PUT", "/api/v1/ai/key", json: ["key": Self.key], cookie: session.cookie)
        #expect(noToken.status == 403)
        #expect(await harness.send("DELETE", "/api/v1/ai/key", cookie: session.cookie).status == 403)
        #expect(await session.get("/api/v1/ai/key").status == 405, "there is no way to read it back")
    }

    // MARK: The describer's state and Try it

    @Test func settingsCarryTheDaysCountsTheLastErrorAndWhetherAFolderIsNeeded() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let fresh = ai(await session.get("/api/v1/settings"))
        #expect(fresh["today"] as? Int == 0 && fresh["last7Days"] as? Int == 0 && fresh["limitReached"] as? Bool == false)
        #expect(fresh["lastError"] is NSNull && fresh["lastErrorAt"] is NSNull, "none yet: null, not missing")
        #expect(fresh["needsRecordingsFolder"] as? Bool == true, "no recordings folder is chosen: no event is kept, so none is described")
        #expect(fresh["paused"] as? Bool == false)

        backend.write {
            $0.aiStatus = AIStatus(today: 200, last7Days: 640, limitReached: true, paused: true, lastError: "The key was refused.",
                                   lastErrorAt: Date(timeIntervalSince1970: 1_792_383_540), needsRecordingsFolder: false)
        }
        let answer = await session.get("/api/v1/settings")
        let busy = ai(answer)
        #expect(busy["today"] as? Int == 200 && busy["last7Days"] as? Int == 640 && busy["limitReached"] as? Bool == true)
        #expect(busy["lastError"] as? String == "The key was refused." && busy["lastErrorAt"] as? String == "2026-10-19T04:19:00Z")
        #expect(busy["paused"] as? Bool == true, "the page need not read it from the sentence")
        #expect(busy["needsRecordingsFolder"] as? Bool == false)
        #expect(ai(await session.send("PATCH", "/api/v1/settings", json: ["ai": ["dailyLimit": 300]]))["today"] as? Int == 200,
                "a settings change answers the same")
    }

    @Test func tryItAnswersTheSentenceAndHowLongItTook() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.aiTry = .success(EventDescription(summary: "A delivery driver leaves a package at the front door", kind: .delivery, concern: .routine,
                                                 model: "claude-haiku-5-5", at: Date()))
            $0.aiTryDelay = .milliseconds(300)
        }
        let session = try await Harness(backend: backend).signIn()
        let id = try await addCamera(session)
        let answer = await session.send("POST", "/api/v1/ai/try", json: ["cameraID": id.uuidString])
        #expect(answer.status == 200, "\(answer.status) \(answer.text)")
        #expect(answer.json["summary"] as? String == "A delivery driver leaves a package at the front door")
        #expect(answer.json["kind"] as? String == "delivery" && answer.json["concern"] as? String == "routine")
        let seconds = try #require(answer.json["seconds"] as? Double)
        #expect(seconds >= 0.3 && seconds < 5, "\(seconds)")
        #expect(Set(answer.json.keys) == ["summary", "kind", "concern", "seconds"], "nothing else: no model, no key")
        #expect(backend.read { $0.aiTries } == [id])
    }

    @Test func aFailedTryIs502WithTheSentence() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let id = try await addCamera(session)
        let failures: [(any Error, String)] = [
            (AIProviderError.keyRefused, "The key was refused."),
            (AIProviderError.unreachable, "The service could not be reached."),
            (AIProviderError.serviceFailed(529), "The service had a problem (error 529)."),
            (AIDescriberError.noService, AIDescriberError.noService.sentence),
            (AIDescriberError.limitReached(200), "Today’s limit of 200 descriptions is reached."),
            (AIDescriberError.noPictures, AIDescriberError.noPictures.sentence),
            (AIDescriberError.cameraNotRunning, AIDescriberError.cameraNotRunning.sentence),
        ]
        for (failure, sentence) in failures {
            backend.write { $0.aiTry = .failure(failure) }
            let answer = await session.send("POST", "/api/v1/ai/try", json: ["cameraID": id.uuidString])
            #expect(answer.status == 502 && answer.json["error"] as? String == sentence, "\(failure): \(answer.status) \(answer.text)")
            #expect(answer.json["message"] as? String == sentence, "the page's error helper reads the same words")
        }
        backend.write { $0.aiTry = .failure(AIDescriberError.alreadyTrying) }
        let busy = await session.send("POST", "/api/v1/ai/try", json: ["cameraID": id.uuidString])
        #expect(busy.status == 409 && busy.json["error"] as? String == "A try is already running." && busy.json["message"] as? String == "A try is already running.",
                "\(busy.status) \(busy.text)")
        backend.write { $0.aiTry = .failure(EngineError.unknownCamera) }
        #expect(await session.send("POST", "/api/v1/ai/try", json: ["cameraID": UUID().uuidString]).status == 404)
        for body: [String: Any] in [["cameraID": "not-a-camera"], ["camera": id.uuidString], [:]] {
            let answer = await session.send("POST", "/api/v1/ai/try", json: body)
            #expect(answer.status == 400 && answer.json["field"] as? String == "cameraID", "\(body): \(answer.text)")
        }
        #expect(backend.read { $0.aiTries }.count == failures.count + 2, "a request without a camera never reaches the bridge")
    }

    @Test func tryItNeedsASignedInPageWithItsToken() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        #expect(await harness.send("POST", "/api/v1/ai/try", json: ["cameraID": id.uuidString]).status == 401)
        #expect(await harness.send("POST", "/api/v1/ai/try", json: ["cameraID": id.uuidString], cookie: session.cookie).status == 403)
        #expect(backend.read { $0.aiTries }.isEmpty)
    }

    @Test func theCameraSwitchSavesWithoutARestart() async throws {
        let backend = FakeBackend()
        let session = try await Harness(backend: backend).signIn()
        let id = try await addCamera(session)
        #expect(await session.get("/api/v1/cameras/\(id)").json["aiDescriptions"] as? Bool == false)
        let on = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["aiDescriptions": true])
        #expect(on.status == 200 && on.json["aiDescriptions"] as? Bool == true, "\(on.text)")
        #expect(backend.read { $0.configurations.first?.aiDescriptions } == true)
        let renamed = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "Porch"])
        #expect(renamed.json["aiDescriptions"] as? Bool == true, "another change leaves the switch alone")
        let off = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["aiDescriptions": false])
        #expect(off.json["aiDescriptions"] as? Bool == false && backend.read { $0.configurations.first?.aiDescriptions } == false)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["aiDescriptions": "yes"]).status == 400)
    }
}
