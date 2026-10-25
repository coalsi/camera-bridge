import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The Sky Watcher's settings: the bridge's (`BridgeSettings.sky`: where the box is, the flight feed, the AI limit) and each camera's
/// (`CameraConfiguration.skyDetector`). Their defaults, tolerant decoding and validation, that where the box is stays on the box (never in a
/// log, the diagnostics or anything printed), that a camera's switch never restarts the camera, and the diagnostics line.
///
/// Serialized (Ruling S26): the tests that decode settings log what they could not read, and `theLocationNeverReachesDiagnosticsOrLogs` counts
/// lines on the shared `LogHub` and sets its level; side by side they were counting each other's lines.
@Suite(.serialized, .timeLimit(.minutes(2))) struct SkySettingsTests {
    /// The made-up place: 40.0000, −100.0000 (100° W), 0 m.
    static let place = SkyLocation(latitude: 40.0, longitude: -100.0, heightMeters: 0)

    private static func settings(_ json: String) throws -> BridgeSettings {
        try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))
    }

    private static func camera(_ name: String = "North Sky") -> CameraConfiguration {
        CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.30"), username: "admin")
    }

    // MARK: The bridge's settings

    @Test func settingsDecodeLenientlyAndValidate() throws {
        // A configuration saved before the Sky Watcher has no `sky`: the defaults, and the other keys are read.
        let old = try Self.settings(#"{"webhookPort":21091,"nvrKeepDays":3}"#)
        #expect(old.sky == SkySettings() && old.sky.location == nil && old.sky.flightFeedURL == nil && old.sky.aiDailyLimit == 50)
        #expect(old.webhookPort == 21_091 && old.nvrKeepDays == 3 && old.sky.validationProblem == nil)
        #expect(BridgeSettings().sky == SkySettings() && SkySettings.aiDailyLimitRange == 1...1_000)

        // Values this build would refuse take their defaults, logged by key name; the others stay.
        let refused = try Self.settings(#"""
        {"webhookPort":21092,"sky":{"location":{"latitude":91,"longitude":-100,"heightMeters":0},"flightFeedURL":"ftp://x","aiDailyLimit":5000}}
        """#)
        #expect(refused.webhookPort == 21_092)
        #expect(refused.sky == SkySettings() && refused.sky.validationProblem == nil, "what was loaded can always be saved again")
        let mixed = try Self.settings(#"""
        {"sky":{"location":{"latitude":40,"longitude":-100},"flightFeedURL":7,"aiDailyLimit":"many"}}
        """#)
        #expect(mixed.sky.location == SkyLocation(latitude: 40, longitude: -100, heightMeters: 0), "a place with no height is at 0 m")
        #expect(mixed.sky.flightFeedURL == nil && mixed.sky.aiDailyLimit == 50)
        #expect(try Self.settings(#"{"sky":"nope"}"#).sky == SkySettings(), "not an object: the defaults")
        let kept = try Self.settings(#"""
        {"sky":{"location":{"latitude":40,"longitude":-100,"heightMeters":412},"flightFeedURL":"http://192.168.77.20/tar1090/data/aircraft.json","aiDailyLimit":1000}}
        """#)
        #expect(kept.sky.location?.heightMeters == 412 && kept.sky.flightFeedURL == "http://192.168.77.20/tar1090/data/aircraft.json")
        #expect(kept.sky.aiDailyLimit == 1_000 && kept.sky.validationProblem == nil)

        // The first problem, by field. The words never quote what was typed.
        func problem(_ sky: SkySettings) -> SkySettings.Problem? { sky.validationProblem }
        let at = { (latitude: Double, longitude: Double, height: Double) in
            SkySettings(location: SkyLocation(latitude: latitude, longitude: longitude, heightMeters: height))
        }
        for bad in [at(91, -100, 0), at(-91, -100, 0), at(40, 181, 0), at(40, -181, 0), at(0, 0, 0), at(.nan, -100, 0), at(40, .infinity, 0),
                    at(40, -100, 9_001), at(40, -100, -501), at(40, -100, .nan)] {
            let found = try #require(problem(bad), "\(bad)")
            #expect(found.field == "sky.location" && !found.message.isEmpty)
            #expect(!found.message.contains("91") && !found.message.contains("100"), "the words do not repeat what was typed: \(found.message)")
        }
        for good in [at(90, 180, 0), at(-90, -180, 0), at(0, 1, 0), at(1, 0, 0), at(40, -100, 9_000), at(40, -100, -500)] {
            #expect(problem(good) == nil, "\(good)")
        }
        for feed in ["ftp://x", "http://", "http:///data/aircraft.json", "192.168.77.20/data/aircraft.json", "http://user:pw@192.168.77.20/aircraft.json",
                     "http://192.168.77.20/a b", "http://192.168.77.20/aircraft.json#top", "", "http://192.168.77.20/\n", "file:///etc/passwd",
                     "http://192.168.77.20/" + String(repeating: "a", count: 600)] {
            #expect(problem(SkySettings(flightFeedURL: feed))?.field == "sky.flightFeedURL", "\(feed.prefix(40))")
        }
        for feed in ["http://192.168.77.20/tar1090/data/aircraft.json", "https://feed.example.com:8443/data/aircraft.json",
                     "HTTP://192.168.77.20:8080/data/aircraft.json", "http://192.168.77.20/data/aircraft.json?x=1"] {
            #expect(problem(SkySettings(flightFeedURL: feed)) == nil, "\(feed)")
        }
        for limit in [0, -5, 1_001] { #expect(problem(SkySettings(aiDailyLimit: limit))?.field == "sky.aiDailyLimit", "\(limit)") }
        for limit in [1, 50, 1_000] { #expect(problem(SkySettings(aiDailyLimit: limit)) == nil) }
        let several = SkySettings(location: SkyLocation(latitude: 91, longitude: 0), flightFeedURL: "ftp://x", aiDailyLimit: 0)
        #expect(problem(several)?.field == "sky.location", "the place first, then the feed, then the limit")
        #expect(problem(SkySettings(flightFeedURL: "ftp://x", aiDailyLimit: 0))?.field == "sky.flightFeedURL")
    }

    @Test func settingsRoundTripAndAnEmptyPlaceHasNoKey() throws {
        var settings = BridgeSettings()
        settings.sky = SkySettings(location: Self.place, flightFeedURL: "http://192.168.77.20/tar1090/data/aircraft.json", aiDailyLimit: 25)
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let none = String(decoding: try JSONEncoder().encode(SkySettings()), as: UTF8.self)
        #expect(!none.contains("location") && !none.contains("flightFeedURL") && none.contains("\"aiDailyLimit\":50"), "no place, no key: \(none)")
    }

    // MARK: The plugin

    /// The Sky Watcher is a plugin (`plugins["sky"]`, the switch on the Plugins page): off on a new box and in every configuration from before it
    /// existed, on only when its own switch says so. The engine runs nothing of it while it is off.
    @Test func theSkyWatcherPluginIsOffUntilItsOwnSwitchIsOn() throws {
        #expect(BridgeSettings().skyPluginOn == false && BridgeSettings().plugins["sky"] == nil, "a new box")
        #expect(try Self.settings(#"{"webhookPort":21091}"#).skyPluginOn == false, "a configuration from before the plugin")
        #expect(try Self.settings(#"{"plugins":{"wyze":{"enabled":true,"account":"someone@example.com"}}}"#).skyPluginOn == false, "another plugin's switch is not this one's")

        var settings = BridgeSettings()
        settings.plugins["sky"] = PluginState(enabled: true)
        #expect(settings.skyPluginOn)
        settings.plugins["sky"] = PluginState(enabled: false, account: "left over", lastSync: Date(timeIntervalSince1970: 1_800_000_000), lastError: "x")
        #expect(settings.skyPluginOn == false, "only the switch counts: not the account, the last sync or the last error")
        settings.plugins["sky"] = nil
        #expect(settings.skyPluginOn == false)

        // The switch is kept in the configuration file, and a value that cannot be read is off.
        settings.plugins["sky"] = PluginState(enabled: true)
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings)).skyPluginOn)
        #expect(try Self.settings(#"{"plugins":{"sky":{"enabled":true}}}"#).skyPluginOn)
        #expect(try Self.settings(#"{"plugins":{"sky":{"enabled":"yes"}}}"#).skyPluginOn == false, "unreadable is off")
        #expect(try Self.settings(#"{"plugins":{"sky":{}}}"#).skyPluginOn == false)
    }

    /// Switching the plugin off or on changes nothing the Sky Watcher keeps: the box's place and feed, and each camera's own settings.
    @Test func theSwitchDoesNotTouchTheSkyWatchersOwnSettings() throws {
        var settings = BridgeSettings()
        settings.sky = SkySettings(location: Self.place, flightFeedURL: "http://192.168.77.20/tar1090/data/aircraft.json", aiDailyLimit: 25)
        var camera = Self.camera()
        camera.skyDetector = SkyDetectorSettings(enabled: true, facing: 315, tilt: 30, groundPercent: 8, nightProfile: false, lensLayout: .dual)
        let sky = settings.sky, kept = camera.skyDetector
        for on in [true, false, true, false] {
            settings.plugins["sky"] = PluginState(enabled: on)
            #expect(settings.skyPluginOn == on && settings.sky == sky && camera.skyDetector == kept)
            let reloaded = try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings))
            #expect(reloaded.skyPluginOn == on && reloaded.sky == sky)
        }
    }

    // MARK: A camera's settings

    @Test func aCameraStartsWithNoSkySettingsAndTheDefaultsAreTheDesigns() throws {
        #expect(Self.camera().skyDetector == nil)
        let defaults = SkyDetectorSettings()
        #expect(!defaults.enabled && defaults.facing == 0 && defaults.tilt == 20 && defaults.groundPercent == 12 && defaults.nightProfile)
        #expect(defaults.lensLayout == nil, "missing means automatic")
        #expect(defaults.validationProblem == nil)
        #expect(SkyLensLayout.allCases.map(\.rawValue).sorted() == ["dual", "single"])
        // A configuration saved before the Sky Watcher has no key.
        let old = try NVRFixtures.json(of: Self.camera(), removing: ["skyDetector"])
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: old).skyDetector == nil)
        // Never set: no key at all in the file.
        #expect(!String(decoding: try JSONEncoder().encode(Self.camera()), as: UTF8.self).contains("skyDetector"))
    }

    @Test func cameraSkySettingsRoundTripAndDecodeLeniently() throws {
        var camera = Self.camera()
        camera.skyDetector = SkyDetectorSettings(enabled: true, facing: 315, tilt: 30, groundPercent: 8, nightProfile: false, lensLayout: .dual)
        let data = try JSONEncoder().encode(camera)
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: data) == camera)
        let written = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sky = try #require(written["skyDetector"] as? [String: Any], "the key is skyDetector")
        #expect(sky["enabled"] as? Bool == true && (sky["facing"] as? NSNumber)?.doubleValue == 315 && sky["groundPercent"] as? Int == 8)
        #expect(sky["lensLayout"] as? String == "dual")

        func decoded(_ value: Any) throws -> CameraConfiguration {
            try JSONDecoder().decode(CameraConfiguration.self, from: NVRFixtures.json(of: Self.camera(), setting: ["skyDetector": value, "motionHoldSeconds": 33]))
        }
        // A lens layout this build does not know (a newer build wrote it) is automatic; the other fields are read.
        let unknownLayout = try decoded(["enabled": true, "facing": 90, "tilt": 45, "groundPercent": 5, "nightProfile": false, "lensLayout": "triple"])
        #expect(unknownLayout.skyDetector == SkyDetectorSettings(enabled: true, facing: 90, tilt: 45, groundPercent: 5, nightProfile: false, lensLayout: nil))
        #expect(unknownLayout.motionHoldSeconds == 33, "the rest of the camera still loads")
        // A value this build would refuse takes its default, and the others stay.
        let odd = try decoded(["enabled": true, "facing": 360, "tilt": 200, "groundPercent": 61, "nightProfile": "yes"])
        #expect(odd.skyDetector == SkyDetectorSettings(enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: nil))
        let partial = try decoded(["enabled": true, "facing": 270])
        #expect(partial.skyDetector == SkyDetectorSettings(enabled: true, facing: 270))
        let edges = try decoded(["facing": 359.9, "tilt": 90, "groundPercent": 60])
        #expect(edges.skyDetector == SkyDetectorSettings(facing: 359.9, tilt: 90, groundPercent: 60))
        let notANumber = try decoded(["facing": "north", "tilt": NSNull(), "groundPercent": 12.5])
        #expect(notANumber.skyDetector == SkyDetectorSettings(), "text, null and a fraction of a percent are not what a field takes")
        // Not an object at all: no settings (the camera loads).
        let broken = try decoded("on")
        #expect(broken.skyDetector == nil && broken.motionHoldSeconds == 33)
    }

    @Test func aCameraSkySettingsProblemNamesItsField() {
        func problem(_ change: (inout SkyDetectorSettings) -> Void) -> String? {
            var settings = SkyDetectorSettings()
            change(&settings)
            return settings.validationProblem?.field
        }
        #expect(problem { $0.facing = 360 } == "skyDetector.facing" && problem { $0.facing = -1 } == "skyDetector.facing")
        #expect(problem { $0.facing = .nan } == "skyDetector.facing" && problem { $0.facing = 359.99 } == nil && problem { $0.facing = 0 } == nil)
        #expect(problem { $0.tilt = 91 } == "skyDetector.tilt" && problem { $0.tilt = -0.5 } == "skyDetector.tilt" && problem { $0.tilt = 90 } == nil)
        #expect(problem { $0.groundPercent = 61 } == "skyDetector.groundPercent" && problem { $0.groundPercent = -1 } == "skyDetector.groundPercent")
        #expect(problem { $0.groundPercent = 60 } == nil && problem { $0.groundPercent = 0 } == nil)
    }

    @MainActor @Test func cameraSkySettingsDoNotRestartTheCamera() {
        let old = Self.camera()
        var new = old
        new.skyDetector = SkyDetectorSettings(enabled: true, facing: 300)
        #expect(!BridgeEngine.needsRestart(old, new, paired: true) && !BridgeEngine.needsRestart(new, old, paired: false))
        #expect(!BridgeEngine.needsRestart(old, new, paired: false) && !BridgeEngine.needsRestart(new, old, paired: true))
        var layout = new
        layout.skyDetector?.lensLayout = .single
        layout.skyDetector?.nightProfile = false
        #expect(!BridgeEngine.needsRestart(new, layout, paired: true))
        // Another change still restarts, with the Sky Watcher on or off.
        var other = new
        other.endpoint.host = "192.168.77.31"
        #expect(BridgeEngine.needsRestart(new, other, paired: true) && BridgeEngine.needsRestart(old, other, paired: false))
    }

    @Test func aCameraStreamsOnDemandExactlyWhenItsDriverSaysSo() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let transport = BridgeEnvironment.inert(directory: directory.url).platform.transport
        var asked = 0
        let services: [IntegrationService?] = [nil] + IntegrationService.allCases.map { Optional($0) }
        for vendor in CameraVendor.allCases {
            for service in services {
                var camera = Self.camera()
                camera.vendor = vendor
                camera.integration = service.map { IntegrationSettings(service: $0) }
                let driver = CameraDrivers.make(vendor: vendor, endpoint: camera.endpoint, credentials: nil, mainStreamURL: nil, subStreamURL: nil,
                                                transport: transport, cameraID: camera.id, integration: camera.integration)
                #expect(camera.streamsOnDemand == driver.streamsOnDemand, "\(vendor) \(String(describing: service))")
                asked += 1
            }
        }
        #expect(asked == CameraVendor.allCases.count * (IntegrationService.allCases.count + 1))
        var eufy = Self.camera()
        eufy.vendor = .go2rtc
        eufy.integration = IntegrationSettings(service: .eufy)
        #expect(eufy.streamsOnDemand && !Self.camera().streamsOnDemand)
    }

    // MARK: The engine

    @MainActor @Test func theEngineRefusesSettingsItCouldNotKeep() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        try await engine.updateSettings { $0.sky = SkySettings(location: Self.place, aiDailyLimit: 20) }
        for bad: SkySettings in [SkySettings(location: SkyLocation(latitude: 0, longitude: 0)), SkySettings(flightFeedURL: "ftp://x"), SkySettings(aiDailyLimit: 0)] {
            await #expect {
                try await engine.updateSettings { $0.sky = bad }
            } throws: { error in
                guard case EngineError.invalidSettings(let message) = error else { return false }
                return !message.isEmpty && !message.contains("40.0")
            }
        }
        #expect(engine.settings.sky == SkySettings(location: Self.place, aiDailyLimit: 20), "nothing was changed")
        // What was saved loads again, with the place.
        let again = BridgeEngine(environment: .inert(directory: directory.url))
        #expect(again.settings.sky.location == Self.place && again.settings.sky.aiDailyLimit == 20)
    }

    // MARK: The place stays on the box

    @Test func thePlaceIsHiddenWhereverItIsPrinted() {
        let place = SkyLocation(latitude: 40.0, longitude: -100.0, heightMeters: 412.5)
        let settings = SkySettings(location: place, flightFeedURL: nil, aiDailyLimit: 50)
        var bridge = BridgeSettings()
        bridge.sky = settings
        var dumped = ""
        dump(bridge, to: &dumped)
        for text in ["\(place)", "\(settings)", String(describing: place), String(reflecting: place), "\(Optional(place) as Any)", dumped, "\(bridge)"] {
            #expect(!text.contains("40.0") && !text.contains("100.0") && !text.contains("412.5"), "\(text)")
        }
        #expect("\(place)" == "SkyLocation(location hidden)")
    }

    @Test func theDiagnosticsSayHowManyCamerasWatchTheSkyAndNothingMore() {
        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 90_000, processUptime: 4_000, generated: Date(timeIntervalSince1970: 1_790_000_000), locale: "en_US")
        var settings = BridgeSettings()
        settings.sky = SkySettings(location: Self.place, flightFeedURL: "http://192.168.77.20/tar1090/data/aircraft.json", aiDailyLimit: 50)
        settings.plugins["sky"] = PluginState(enabled: true)
        var watching = Self.camera("North Sky"), second = Self.camera("East Sky"), idle = Self.camera("Porch"), off = Self.camera("Garage")
        watching.skyDetector = SkyDetectorSettings(enabled: true, facing: 0, tilt: 20)
        second.skyDetector = SkyDetectorSettings(enabled: true, facing: 90, tilt: 10)
        off.skyDetector = SkyDetectorSettings(enabled: false)
        func report(_ cameras: [CameraConfiguration]) -> String {
            DiagnosticsReport.render(context: context, state: .running, localNetwork: .granted, settings: settings, cameras: [], configurations: cameras,
                                     sessions: [], logEntries: [])
        }
        let two = report([watching, second, idle, off])
        #expect(two.contains("Sky Watcher on for 2 cameras"), "\(two.prefix(900))")
        #expect(report([watching, idle, off]).contains("Sky Watcher on for 1 camera\n"), "one camera, in the singular")
        #expect(!report([idle, off]).contains("Sky Watcher"), "nothing to say while it is off")
        #expect(!report([]).contains("Sky Watcher"))
        // The plugin switched off: nothing runs, and the report says why instead of saying the cameras are on (they keep their settings).
        settings.plugins["sky"] = PluginState(enabled: false)
        #expect(report([watching, second, idle, off]).contains("Sky Watcher is off in Plugins (2 cameras are set to watch the sky)"))
        #expect(report([watching, idle, off]).contains("Sky Watcher is off in Plugins (1 camera is set to watch the sky)\n"))
        #expect(!report([watching, second]).contains("Sky Watcher on for"), "never “on for” while the plugin is off")
        #expect(!report([idle, off]).contains("Sky Watcher") && !report([]).contains("Sky Watcher"), "no camera set: nothing to say, plugin or no plugin")
        settings.plugins["sky"] = PluginState(enabled: true)
        for text in [two, report([watching])] {
            #expect(!text.contains("40.0") && !text.contains("100.0") && !text.localizedCaseInsensitiveContains("latitude"), "no place, in any form")
            #expect(!text.contains("192.168.77.20"), "nor the feed's address")
            #expect(!text.contains("Sky detector"), "the feature is called Sky Watcher wherever a person reads")
        }
    }

    /// Every log entry of the process (the log is shared by the tests that run side by side).
    private final class EntrySink: LogSink {
        private let all = Mutex<[LogEntry]>([])
        func record(_ entry: LogEntry) { all.withLock { $0.append(entry) } }
        var entries: [LogEntry] { all.withLock { $0 } }
    }

    @MainActor @Test func theLocationNeverReachesDiagnosticsOrLogs() async throws {
        let previousLevel = LogHub.minimumLevel
        LogHub.minimumLevel = .debug
        let sink = EntrySink()
        let token = LogHub.addSink(sink)
        defer {
            LogHub.removeSink(token)
            LogHub.minimumLevel = previousLevel
        }
        // The made-up place with four more digits: the sink sees every test's lines, and none of theirs has these. The brief's coarse needles
        // ("40.0", "100.0") are looked for in the diagnostics and in the lines about this test's cameras.
        let place = SkyLocation(latitude: 40.0123, longitude: -100.0456, heightMeters: 0)
        let directory = try TemporaryDirectory()
        let recordings = try TemporaryDirectory()
        defer {
            directory.remove()
            recordings.remove()
        }
        // A configuration with a place that cannot be read (a height no one lives at) and a feed that cannot: logged by the keys' names, never by their
        // values. (The limit is left alone, so that these two keys are a message of this test's own: the settings test above logs all three at once, and
        // the log is shared by tests that run side by side.)
        let file = directory.file(ConfigurationStore.fileName)
        try Data(#"{"schemaVersion":1,"settings":{"sky":{"location":{"latitude":40.0,"longitude":-100.0,"heightMeters":99999},"flightFeedURL":"ftp://x"}},"cameras":[]}"#.utf8)
            .write(to: file)
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        try await engine.updateSettings { settings in
            settings.nvrFolder = recordings.url.path(percentEncoded: false)
            settings.sky.location = place
            settings.plugins["sky"] = PluginState(enabled: true)   // the plugin is off on a new box
        }
        var north = Self.camera("North Sky"), east = Self.camera("East Sky")
        east.endpoint.host = "192.168.77.31"
        try await engine.addCamera(north, password: nil)
        try await engine.addCamera(east, password: nil)
        north.skyDetector = SkyDetectorSettings(enabled: true, facing: 0, tilt: 20)
        east.skyDetector = SkyDetectorSettings(enabled: true, facing: 90, tilt: 10, lensLayout: .single)
        try await engine.updateCamera(north, password: nil)
        try await engine.updateCamera(east, password: nil)
        north.skyDetector?.enabled = false
        try await engine.updateCamera(north, password: nil)
        #expect(engine.configurations.filter { $0.skyDetector?.enabled == true }.map(\.name) == ["East Sky"])
        #expect(engine.settings.sky.location == place, "the engine has it")

        let context = DiagnosticsContext(appVersion: "1.0", appBuild: "7", macOSVersion: "Version 27.0", macModel: "Mac15,3", architecture: "arm64",
                                         systemUptime: 90_000, processUptime: 4_000, generated: Date(timeIntervalSince1970: 1_790_000_000), locale: "en_US")
        let text = engine.diagnosticsReport(context: context)
        #expect(text.contains("Sky Watcher on for 1 camera"), "\(text.prefix(1_200))")
        let entries = sink.entries
        let about = entries.filter { entry in
            ["Sky Watcher", "North Sky", "East Sky"].contains { entry.message.contains($0) } || [north.id, east.id].contains { $0 == entry.cameraID }
        }
        #expect(!about.isEmpty)
        for needle in ["40.0", "100.0"] {
            #expect(!text.contains(needle), "the diagnostics hold \(needle)")
            #expect(!about.contains { $0.message.contains(needle) }, "log lines hold \(needle): \(about.filter { $0.message.contains(needle) }.map(\.message))")
        }
        for needle in ["40.0123", "100.0456", "40.012", "100.045"] {
            #expect(!text.contains(needle) && !entries.contains { $0.message.contains(needle) }, "something holds \(needle)")
        }
        #expect(!entries.contains { $0.message.contains("ftp://x") }, "nor is a feed's address")
        let unreadable = entries.filter { $0.message.contains("Unreadable Sky Watcher settings location, flightFeedURL in the configuration") }
        #expect(unreadable.count == 1 && unreadable.first?.level == .warning, "what could not be read is logged by the names of its keys")
        let switched = entries.filter { $0.message == "Sky Watcher turned on for East Sky" }
        #expect(switched.count == 1 && switched.first?.level == .notice, "the switch is logged, in the feature's name")
    }
}
