import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The AI description settings, the key (write-only, in the secret store) and the camera's switch.
@Suite struct AISettingsTests {
    static let key = "sk-test-0000"

    @MainActor static func inertEngine() throws -> (BridgeEngine, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        return (BridgeEngine(environment: .inert(directory: directory.url)), directory)
    }

    /// Every file under `directory` as text, by path.
    static func files(under directory: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in walker {
            if let data = try? Data(contentsOf: url) { result[url.lastPathComponent] = String(decoding: data, as: UTF8.self) }
        }
        return result
    }

    // MARK: Defaults and loading

    @Test func defaultsAreOffAndAConfigWithoutAILoads() throws {
        let defaults = AIDescriptionSettings()
        #expect(defaults.provider == nil && defaults.model == "claude-haiku-5-5" && defaults.baseURL == nil && defaults.dailyLimit == 200)
        #expect(BridgeSettings().ai == defaults)

        // A configuration written before this build has no `ai`, and a camera no `aiDescriptions`.
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"webhookPort":21090,"nvrKeepDays":3}"#.utf8))
        #expect(settings.ai == defaults && settings.nvrKeepDays == 3)
        let camera = NVRFixtures.camera()
        #expect(!camera.aiDescriptions)
        let older = try NVRFixtures.json(of: camera, removing: ["aiDescriptions"])
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: older).aiDescriptions == false)

        // What was saved is read back.
        var chosen = BridgeSettings()
        chosen.ai = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: "http://192.168.77.10:11434/v1", dailyLimit: 40)
        let reread = try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(chosen))
        #expect(reread.ai == chosen.ai)
        var on = camera
        on.aiDescriptions = true
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: JSONEncoder().encode(on)).aiDescriptions)
    }

    @Test func anUnreadableValueTakesItsDefaultAndTheOthersAreRead() throws {
        let json = #"{"ai":{"provider":"somethingNew","model":"llava:13b","baseURL":"https://user:secret@example.com/v1","dailyLimit":0}}"#
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))
        #expect(settings.ai == AIDescriptionSettings(provider: nil, model: "llava:13b", baseURL: nil, dailyLimit: 200),
                "an unknown provider, an address with a password in it and a limit of 0 are not kept")
        let noAddress = #"{"ai":{"provider":"openAICompatible","baseURL":"ftp://192.168.77.10/v1","dailyLimit":30}}"#
        let withoutAddress = try JSONDecoder().decode(BridgeSettings.self, from: Data(noAddress.utf8)).ai
        #expect(withoutAddress == AIDescriptionSettings(provider: nil, dailyLimit: 30),
                "an OpenAI-compatible service without a usable address is none: what is loaded can always be saved again")
        #expect(withoutAddress.validationProblem == nil)
        let blank = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"ai":{"model":"   ","dailyLimit":30}}"#.utf8)).ai
        #expect(blank == AIDescriptionSettings(dailyLimit: 30), "a model of blanks is not kept")
        let notAnObject = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"ai":7,"nvrKeepDays":3}"#.utf8))
        #expect(notAnObject.ai == AIDescriptionSettings() && notAnObject.nvrKeepDays == 3)
        let wrongKind = try NVRFixtures.json(of: NVRFixtures.camera(), setting: ["aiDescriptions": "yes"])
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: wrongKind).aiDescriptions == false)
    }

    // MARK: Validation

    @Test func validationRefusesABadAddressAndLimits() async throws {
        func problem(_ change: (inout AIDescriptionSettings) -> Void) -> String? {
            var ai = AIDescriptionSettings()
            change(&ai)
            return ai.validationProblem?.field
        }
        #expect(problem { _ in } == nil)
        #expect(problem { $0.provider = .anthropic } == nil)
        #expect(problem { $0.provider = .openAICompatible } == "baseURL", "an OpenAI-compatible service needs its address")
        for address in ["ftp://192.168.77.10/v1", "192.168.77.10:11434/v1", "http://", "https:///v1", "http://user@192.168.77.10/v1",
                        "http://user:secret@192.168.77.10/v1", "https://example.com/v1?key=abc", "https://example.com/v1#top",
                        "https://example.com/v1?", "https://exa mple.com/v1", "https://example.com/v1\n", "", String(repeating: "a", count: 501)] {
            #expect(problem { $0.provider = .openAICompatible; $0.baseURL = address } == "baseURL", "\(address.prefix(40))")
        }
        #expect(problem { $0.provider = .anthropic; $0.baseURL = "ftp://x/v1" } == "baseURL", "an address that is there is checked for any provider")
        for address in ["http://192.168.77.10:11434/v1", "https://api.example.com/v1", "HTTPS://Example.com/v1/", "http://[fd00::1]:8080/v1"] {
            #expect(problem { $0.provider = .openAICompatible; $0.baseURL = address } == nil, "\(address)")
        }
        #expect(problem { $0.dailyLimit = 0 } == "dailyLimit")
        #expect(problem { $0.dailyLimit = 5_001 } == "dailyLimit")
        #expect(problem { $0.dailyLimit = 1 } == nil && problem { $0.dailyLimit = 5_000 } == nil)
        #expect(problem { $0.model = "" } == "model")
        #expect(problem { $0.model = "   " } == "model", "the web layer trims a model; the engine refuses one that is only blanks")
        #expect(problem { $0.model = " \u{A0}\u{3000}" } == "model")
        #expect(problem { $0.model = String(repeating: "m", count: 101) } == "model")
        #expect(problem { $0.model = "two\nlines" } == "model")
        #expect(problem { $0.model = "tab\there" } == "model")
        #expect(problem { $0.model = String(repeating: "m", count: 100) } == nil)
    }

    @MainActor @Test func theEngineRefusesSettingsThatDoNotValidateAndKeepsTheOldOnes() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic, dailyLimit: 30) }
        let bad: [(inout BridgeSettings) -> Void] = [{ $0.ai.provider = .openAICompatible }, { $0.ai.dailyLimit = 0 }, { $0.ai.dailyLimit = 5_001 },
                                                      { $0.ai.baseURL = "ftp://192.168.77.10/v1" }, { $0.ai.model = "" }]
        for change in bad {
            await #expect(throws: EngineError.self) { try await engine.updateSettings(change) }
        }
        #expect(engine.settings.ai == AIDescriptionSettings(provider: .anthropic, dailyLimit: 30))
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: "http://192.168.77.10:11434/v1") }
        let saved = try #require(try ConfigurationStore(directory: directory.url).load())
        #expect(saved.settings.ai.provider == .openAICompatible && saved.settings.ai.baseURL == "http://192.168.77.10:11434/v1")
    }

    // MARK: The key

    @MainActor @Test func theKeyIsWriteOnly() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        #expect(try engine.aiKey() == nil && engine.aiKeyHint == nil && !engine.aiKeySaved)
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic) }   // the service first: a key is for one service

        try engine.setAIKey(Self.key)
        let stored = try engine.environment.platform.secrets.read(account: "ai.key")
        #expect(stored == Data(Self.key.utf8), "the platform secret store holds it, as ai.key")
        #expect(try engine.aiKey() == Self.key && engine.aiKeySaved)
        #expect(engine.aiKeyHint == "0000", "the last four characters, and nothing else about it")

        // Saving settings and a camera, and a snapshot of everything on disk: the key is in none of it.
        try await engine.addCamera(NVRFixtures.camera(), password: nil)
        try await engine.updateSettings { $0.ai.dailyLimit = 10 }
        #expect(try engine.aiKey() == Self.key, "still saved, so the checks below look at a file the key could have reached")
        let config = try String(contentsOf: directory.url.appending(path: ConfigurationStore.fileName), encoding: .utf8)
        #expect(config.contains("\"anthropic\"") && !config.contains("sk-test"))
        for (name, text) in Self.files(under: directory.url) { #expect(!text.contains("sk-test"), "\(name)") }
        #expect(!String(describing: engine.settings).contains("sk-test") && !String(reflecting: engine.settings).contains("sk-test"))
    }

    @MainActor @Test func aKeyIsTrimmedAndOneThatCannotBeAHeaderIsRefused() throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try engine.setAIKey("  \(Self.key)\n")
        #expect(try engine.aiKey() == Self.key, "a paste's trailing newline would make an invalid header")
        let bad = ["sk-test\n0000", "sk-test\r\n0000", "sk-test\t0000", "sk-test\u{7}0000", "sk\u{2028}test", "   \n ", String(repeating: "k", count: 501),
                   "sk-test 0000",                // an inner space
                   "sk-test\u{200B}0000",         // zero-width space
                   "sk-test-0000\u{200B}",        // a trailing one is not trimmed away
                   "\u{FEFF}sk-test-0000",        // a byte order mark from a pasted file
                   "sk-test\u{202E}0000",         // a bidi control
                   "sk-test-é0000", "sk-test-００００", "ключ-0000", "sk-test-0000\u{7F}"]
        for key in bad {
            #expect(throws: EngineError.self, "\(key.unicodeScalars.map(\.value))") { try engine.setAIKey(key) }
        }
        #expect(try engine.aiKey() == Self.key, "a refused key changes nothing")
        try engine.setAIKey(String(repeating: "k", count: 500))
        #expect(try engine.aiKey()?.count == 500)
        let punctuation = "sk-ant-api03_AbC.dEf+gh/ij=kl~!@#$%^&*()[]{}<>:;,?|\\'\"`"   // every kind of visible ASCII a service might use
        try engine.setAIKey(punctuation)
        #expect(try engine.aiKey() == punctuation)
        try engine.setAIKey("!")
        try engine.setAIKey("~")   // the ends of the visible range, 0x21 and 0x7E
    }

    @MainActor @Test func aShortKeyHasNoHint() throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try engine.setAIKey("1234")   // a home server's placeholder: the last four would be all of it
        #expect(engine.aiKeySaved && engine.aiKeyHint == nil)
        try engine.setAIKey("1234567")
        #expect(engine.aiKeyHint == nil)
        try engine.setAIKey("12345678")
        #expect(engine.aiKeyHint == "5678")
    }

    @MainActor @Test func deletingTheKeyClearsIt() throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        for removal: String? in [nil, ""] {
            try engine.setAIKey(Self.key)
            #expect(engine.aiKeySaved)
            try engine.setAIKey(removal)
            #expect(try engine.environment.platform.secrets.read(account: "ai.key") == nil)
            #expect(try engine.aiKey() == nil && engine.aiKeyHint == nil && !engine.aiKeySaved)
        }
        try engine.setAIKey(nil)   // deleting what is not there is not an error
    }

    // MARK: A key is for one service

    /// The engine with `before` chosen and the key saved, then `change` applied to the settings: whether the key is still there.
    @MainActor static func keyAfter(_ before: AIDescriptionSettings, _ change: @escaping (inout BridgeSettings) -> Void) async throws -> Bool {
        let (engine, directory) = try inertEngine()
        defer { directory.remove() }
        try await engine.updateSettings { $0.ai = before }
        try engine.setAIKey(key)
        #expect(engine.aiKeySaved, "the key is saved before the change")
        try await engine.updateSettings(change)
        return engine.aiKeySaved
    }

    @MainActor @Test func aKeyIsDeletedWhenTheProviderChanges() async throws {
        let home = "http://192.168.77.10:11434/v1"
        let claude = AIDescriptionSettings(provider: .anthropic)
        let openAI = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: home)
        #expect(try await Self.keyAfter(claude) { $0.ai = openAI } == false, "Claude to an OpenAI-compatible service")
        #expect(try await Self.keyAfter(openAI) { $0.ai = claude } == false, "and back")
        #expect(try await Self.keyAfter(claude) { $0.ai.provider = nil } == false, "turned off")
        #expect(try await Self.keyAfter(AIDescriptionSettings()) { $0.ai.provider = .anthropic } == false, "a key saved before any service was chosen")
        #expect(try await Self.keyAfter(claude) { $0.ai.provider = .openAICompatible; $0.ai.baseURL = home } == false, "the model staying the same changes nothing")
    }

    @MainActor @Test func aKeyIsDeletedWhenTheAddressMovesToAnotherServer() async throws {
        let home = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: "http://192.168.77.10:11434/v1")
        func moved(to address: String, from before: AIDescriptionSettings = home) async throws -> Bool {
            try await Self.keyAfter(before) { $0.ai.baseURL = address }
        }
        #expect(try await moved(to: "http://192.168.77.11:11434/v1") == false, "another host")
        #expect(try await moved(to: "http://192.168.77.10:8080/v1") == false, "another port")
        #expect(try await moved(to: "https://192.168.77.10:11434/v1") == false, "another scheme")
        #expect(try await moved(to: "http://192.168.77.10/v1") == false, "no port is the scheme's own port, not 11434")
        let named = AIDescriptionSettings(provider: .openAICompatible, baseURL: "http://Server.local/v1")
        #expect(try await moved(to: "https://server.local/v1", from: named) == false, "http to https")
        #expect(try await moved(to: "http://server.local:443/v1", from: named) == false, "443 is not the port of http")
        // The same server, said another way: the key stays.
        #expect(try await moved(to: "http://192.168.77.10:11434/v1/") == true, "a trailing slash")
        #expect(try await moved(to: "http://192.168.77.10:11434/openai/v1") == true, "another path on the same server")
        #expect(try await moved(to: "http://server.local/v1", from: named) == true)
        #expect(try await moved(to: "HTTP://SERVER.LOCAL/v2", from: named) == true, "scheme and host are not case sensitive")
        #expect(try await moved(to: "http://server.local:80/v1", from: named) == true, "http's own port, spelled out")
        let secure = AIDescriptionSettings(provider: .openAICompatible, baseURL: "https://api.example.com/v1")
        #expect(try await moved(to: "https://api.example.com:443/v1", from: secure) == true, "https's own port, spelled out")
        #expect(try await moved(to: "https://api.example.com:8443/v1", from: secure) == false)
    }

    @MainActor @Test func aKeyStaysWhenOnlyOtherThingsChange() async throws {
        let home = AIDescriptionSettings(provider: .openAICompatible, model: "llava:13b", baseURL: "http://192.168.77.10:11434/v1", dailyLimit: 40)
        #expect(try await Self.keyAfter(home) { $0.ai.model = "llava:34b" } == true, "another model")
        #expect(try await Self.keyAfter(home) { $0.ai.dailyLimit = 500 } == true, "another daily limit")
        #expect(try await Self.keyAfter(home) { $0.logLevel = .debug } == true, "an unrelated setting")
        #expect(try await Self.keyAfter(home) { $0.ai = home } == true, "the same settings saved again")
        let claude = AIDescriptionSettings(provider: .anthropic, baseURL: "http://192.168.77.10:11434/v1")
        #expect(try await Self.keyAfter(claude) { $0.ai.baseURL = "http://elsewhere.example/v1" } == true, "Claude ignores the address")
        #expect(try await Self.keyAfter(claude) { $0.ai.model = "claude-sonnet-5-5" } == true)
    }

    @MainActor @Test func aRefusedUpdateKeepsTheKey() async throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic) }
        try engine.setAIKey(Self.key)
        await #expect(throws: EngineError.self) { try await engine.updateSettings { $0.ai.provider = .openAICompatible } }   // no address
        await #expect(throws: EngineError.self) { try await engine.updateSettings { $0.ai.dailyLimit = 0 } }
        #expect(try engine.aiKey() == Self.key && engine.settings.ai.provider == .anthropic)
        // The key is gone with the move to another service, and the settings are saved: the new service is asked for its own.
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .openAICompatible, baseURL: "http://192.168.77.10:11434/v1") }
        #expect(try engine.aiKey() == nil && !engine.aiKeySaved)
        #expect(try ConfigurationStore(directory: directory.url).load()?.settings.ai.provider == .openAICompatible)
    }

    @MainActor @Test func aKeyThatCannotBeReadStillGoesWithAChangeOfService() async throws {
        let store = CountingSecrets()
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var environment = BridgeEnvironment.inert(directory: directory.url)
        environment.platform.secrets = store
        let engine = BridgeEngine(environment: environment)
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic) }
        try engine.setAIKey(Self.key)
        store.failReads(true)
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .openAICompatible, baseURL: "http://192.168.77.10:11434/v1") }
        #expect(engine.settings.ai.provider == .openAICompatible, "a key that cannot be read does not stop the change")
        store.failReads(false)
        #expect(try engine.aiKey() == nil, "and it was deleted all the same")
    }

    @MainActor @Test func theKeysRemovalIsLoggedOnlyOnceTheChangeIsSaved() async throws {
        let capture = LiveLogCapture()
        defer { capture.stop() }
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try await engine.updateSettings { $0.ai = AIDescriptionSettings(provider: .anthropic) }
        try engine.setAIKey(Self.key)
        // A newer build wrote the file since: this one cannot save over it.
        let file = directory.url.appending(path: ConfigurationStore.fileName)
        var contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        contents["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: contents).write(to: file)
        let elsewhere = AIDescriptionSettings(provider: .openAICompatible, baseURL: "http://192.168.77.239:11434/v1")   // no other test's address
        await #expect(throws: (any Error).self) { try await engine.updateSettings { $0.ai = elsewhere } }
        #expect(engine.settings.ai.provider == .anthropic)
        #expect(capture.lines(containing: "192.168.77.239").isEmpty, "the change was not saved: no line says it was made")
        try FileManager.default.removeItem(at: file)
        try engine.setAIKey(Self.key)   // (the key went before the save that failed: a key is never kept for a service it was not saved for)
        try await engine.updateSettings { $0.ai = elsewhere }
        #expect(capture.lines(containing: "The AI key was removed: the AI service changed to the OpenAI-compatible service at 192.168.77.239").count == 1,
                "once it is saved, it is said")
    }

    @Test func twoAddressesThatCannotBeReadAreNeverTheSameServer() {
        let unreadable = AIDescriptionSettings(provider: .openAICompatible, baseURL: nil)
        #expect(!unreadable.keepsKey(from: unreadable))
        let garbled = AIDescriptionSettings(provider: .openAICompatible, baseURL: "not an address")
        #expect(!garbled.keepsKey(from: garbled))
    }

    @MainActor @Test func aRefusedKeyIsToldTheRuleItBroke() throws {
        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        #expect {
            try engine.setAIKey("sk-test 0000")
        } throws: { error in
            guard case EngineError.invalidSettings(let message) = error else { return false }
            return message.contains("letters, digits and punctuation") && message.contains("no spaces") && !message.contains("sk-test")
        }
    }

    // MARK: Reading the key's state

    @MainActor @Test func theKeyStatusIsOneReadOffTheMainThread() async throws {
        let store = CountingSecrets()
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var environment = BridgeEnvironment.inert(directory: directory.url)
        environment.platform.secrets = store
        let engine = BridgeEngine(environment: environment)
        #expect(await engine.aiKeyStatus() == (saved: false, hint: nil))
        try engine.setAIKey(Self.key)
        store.forgetReads()
        let status = await engine.aiKeyStatus()
        #expect(status.saved && status.hint == "0000")
        #expect(store.readThreads == [.background], "one read, and not on the main thread")
        try engine.setAIKey("1234")
        #expect(await engine.aiKeyStatus() == (saved: true, hint: nil), "a short key is saved but has no hint")
        try engine.setAIKey(nil)
        #expect(await engine.aiKeyStatus() == (saved: false, hint: nil))
    }

    @MainActor @Test func aFailedReadIsLoggedOnceByNameAndCountsAsNoKey() async throws {
        let capture = LiveLogCapture()
        defer { capture.stop() }
        let store = CountingSecrets()
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var environment = BridgeEnvironment.inert(directory: directory.url)
        environment.platform.secrets = store
        let engine = BridgeEngine(environment: environment)
        try engine.setAIKey(Self.key)
        store.failReads(true)
        for _ in 0..<3 { #expect(await engine.aiKeyStatus() == (saved: false, hint: nil)) }
        let said = capture.lines(containing: "could not be read from the secret store", minimum: .warning)
        #expect(said.count == 1, "once, not for every page that asks: \(said)")
        #expect(said.first?.contains("ai.key") == true && said.allSatisfy { !$0.contains("sk-test") && !$0.contains("0000") })
        // Once it reads again and fails again, that is told once more.
        store.failReads(false)
        #expect(await engine.aiKeyStatus() == (saved: true, hint: "0000"))
        store.failReads(true)
        _ = await engine.aiKeyStatus()
        #expect(capture.lines(containing: "could not be read from the secret store", minimum: .warning).count == 2)
    }

    // MARK: The camera's switch

    @MainActor @Test func theCameraSwitchSavesWithoutARestart() async throws {
        let old = NVRFixtures.camera()
        var new = old
        new.aiDescriptions = true
        for paired in [false, true] {
            #expect(!BridgeEngine.needsRestart(old, new, paired: paired) && !BridgeEngine.needsRestart(new, old, paired: paired))
        }
        new.audioEnabled.toggle()
        #expect(BridgeEngine.needsRestart(old, new, paired: false), "the mask hides only the switch")

        let (engine, directory) = try Self.inertEngine()
        defer { directory.remove() }
        try await engine.addCamera(old, password: nil)
        var switched = old
        switched.aiDescriptions = true
        try await engine.updateCamera(switched, password: nil)
        #expect(engine.configurations.first?.aiDescriptions == true)
        #expect(try ConfigurationStore(directory: directory.url).load()?.cameras.first?.aiDescriptions == true)
        try await engine.updateCamera(old, password: nil)
        #expect(engine.configurations.first?.aiDescriptions == false)
    }
}

/// A secret store that remembers where its reads happened and can fail them.
final class CountingSecrets: SecretStore {
    enum Place: Equatable, Sendable { case main, background }
    struct Failure: Error {}

    private let items = Mutex<[String: Data]>([:])
    private let places = Mutex<[Place]>([])
    private let failing = Mutex(false)

    var readThreads: [Place] { places.withLock { $0 } }
    func forgetReads() { places.withLock { $0 = [] } }
    func failReads(_ fail: Bool) { failing.withLock { $0 = fail } }

    func read(account: String) throws -> Data? {
        places.withLock { $0.append(Thread.isMainThread ? .main : .background) }
        if failing.withLock({ $0 }) { throw Failure() }
        return items.withLock { $0[account] }
    }

    func write(_ data: Data?, account: String) throws {
        items.withLock { $0[account] = data }
    }
}
