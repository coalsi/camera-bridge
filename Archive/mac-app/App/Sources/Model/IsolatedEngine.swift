#if DEBUG
import BridgeEngine
import CameraAdapters
import Foundation

/// Debug builds only. `-isolatedEngine <directory>` runs the app's real engine (cameras, recorders, the NVR store) on a throwaway data
/// directory instead of `~/Library/Application Support/CameraBridge`: in-memory secrets, loopback only, no Bonjour, no power assertions,
/// no login item, no profile download (`BridgeEnvironment.testing`). It exists so the NVR can be soaked and measured in the real app
/// without ever touching the owner's cameras, keychain items, HomeKit pairings or ports.
///
/// It refuses to run (`validated`) unless the bundle identifier ends in `.nvrtest` (a measurement build made with
/// `PRODUCT_BUNDLE_IDENTIFIER=com.coreysilvia.CameraBridge.nvrtest`), so the app a person installed can never be pointed at it by accident.
/// `AppModel.launching` exits with status 2 when the options are present but invalid: it never falls through to the live engine.
nonisolated struct IsolatedEngineOptions: Equatable, Sendable {
    static let directoryKey = "isolatedEngine"
    static let camerasKey = "isolatedDemoCameras"
    static let folderKey = "isolatedNVRFolder"
    static let basePortKey = "isolatedBasePort"
    static let keepDaysKey = "isolatedKeepDays"
    static let maxGBKey = "isolatedMaxGB"
    static let recordAfterKey = "isolatedRecordAfterSeconds"
    static let quitAfterKey = "isolatedQuitAfterMinutes"
    static let heartbeatKey = "isolatedHeartbeatSeconds"
    static let demoKeyframeKey = "isolatedDemoKeyframeSeconds"
    static let probeKey = "nvrProbe"
    static let ownerBundleIdentifier = "com.coreysilvia.CameraBridge"
    static let measurementBundleSuffix = ".nvrtest"
    /// The defaults domain of the measurement build (the app's own `UserDefaults.standard` is a different domain because the bundle differs).
    static let defaultsSuite = "com.coreysilvia.CameraBridge.nvrtest.isolated"
    /// The cameras the seed adds are called "Soak 1", "Soak 2", ...
    static let cameraNamePrefix = "Soak "
    static let basePortRange: ClosedRange<UInt16> = 22_000...48_900

    /// The paths exactly as given (a relative one must be refused, not quietly resolved against the working directory).
    var directoryPath: String
    var folderPath: String?
    var demoCameras = 0
    var basePort: UInt16 = 38_100
    var keepDays = 1
    var maxSizeGB = 10
    /// Record is switched on this many seconds after launch (0: before the engine starts).
    var recordAfter: TimeInterval = 0
    /// The app quits itself (`NSApp.terminate`, the Cmd-Q path) after this many seconds.
    var quitAfter: TimeInterval?
    /// Seconds between two lines of `probe/heartbeat.jsonl`.
    var heartbeat: TimeInterval = 10
    /// The demo cameras key every this many seconds (1 to 120; nil: every 2 s). `BridgeEnvironment.demoKeyframeSeconds`: a smart-codec stream.
    var demoKeyframeSeconds: Double?
    /// `-nvrProbe`: scenario names separated by commas, or `all` (the five budget scenarios; `drivehold` is named, never part of `all`).
    var probe: String?

    init(directoryPath: String) { self.directoryPath = directoryPath }
    init(directory: URL) { directoryPath = directory.path }

    var directory: URL { URL(fileURLWithPath: directoryPath, isDirectory: true) }
    var nvrFolder: URL? {
        get { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { folderPath = newValue?.path }
    }

    /// nil when `-isolatedEngine` is absent. Values are read as the argument domain gives them: strings that parse, else the defaults above.
    init?(defaults: UserDefaults) {
        guard let path = defaults.string(forKey: Self.directoryKey), !path.isEmpty else { return nil }
        self.init(directoryPath: path)
        demoCameras = defaults.object(forKey: Self.camerasKey) == nil ? 0 : defaults.integer(forKey: Self.camerasKey)
        folderPath = defaults.string(forKey: Self.folderKey).flatMap { $0.isEmpty ? nil : $0 }
        if defaults.object(forKey: Self.basePortKey) != nil { basePort = UInt16(clamping: defaults.integer(forKey: Self.basePortKey)) }
        if defaults.object(forKey: Self.keepDaysKey) != nil { keepDays = defaults.integer(forKey: Self.keepDaysKey) }
        if defaults.object(forKey: Self.maxGBKey) != nil { maxSizeGB = defaults.integer(forKey: Self.maxGBKey) }
        if defaults.object(forKey: Self.recordAfterKey) != nil { recordAfter = defaults.double(forKey: Self.recordAfterKey) }
        if defaults.object(forKey: Self.quitAfterKey) != nil { quitAfter = defaults.double(forKey: Self.quitAfterKey) * 60 }
        if defaults.object(forKey: Self.heartbeatKey) != nil { heartbeat = defaults.double(forKey: Self.heartbeatKey) }
        if defaults.object(forKey: Self.demoKeyframeKey) != nil { demoKeyframeSeconds = defaults.double(forKey: Self.demoKeyframeKey) }
        probe = defaults.string(forKey: Self.probeKey)
    }

    enum Refusal: Error, Equatable, LocalizedError {
        case notAMeasurementBuild
        case directoryNotUsable
        case ownerData
        case folderNotUsable
        case tooManyCameras
        case portOutOfRange
        case limitOutOfRange
        case unknownProbe(String)
        case timingOutOfRange

        var errorDescription: String? {
            switch self {
            case .notAMeasurementBuild: "the bundle identifier must end in \(IsolatedEngineOptions.measurementBundleSuffix) (build with PRODUCT_BUNDLE_IDENTIFIER=\(IsolatedEngineOptions.ownerBundleIdentifier)\(IsolatedEngineOptions.measurementBundleSuffix))"
            case .directoryNotUsable: "-isolatedEngine needs a full path with no “..” and no control characters"
            case .ownerData: "that path is inside the app’s own data (Application Support/CameraBridge or its container); use a throwaway directory"
            case .folderNotUsable: "-isolatedNVRFolder must be a full path that BridgeSettings accepts"
            case .tooManyCameras: "-isolatedDemoCameras runs from 0 to 9"
            case .portOutOfRange: "-isolatedBasePort runs from \(IsolatedEngineOptions.basePortRange.lowerBound) to \(IsolatedEngineOptions.basePortRange.upperBound)"
            case .limitOutOfRange: "-isolatedKeepDays or -isolatedMaxGB is outside the engine’s range"
            case .unknownProbe(let name): "unknown -nvrProbe “\(name)”"
            case .timingOutOfRange: "-isolatedRecordAfterSeconds runs from 0 to 3600, -isolatedQuitAfterMinutes from 0.5 to 600, -isolatedHeartbeatSeconds from 0.5 to 60 and -isolatedDemoKeyframeSeconds from 1 to 120"
            }
        }
    }

    /// The folders that belong to the person’s installed app, never to be used (resolved through symbolic links; a path that does not exist
    /// yet is resolved from its nearest existing parent).
    static func protectedDirectories(home: URL) -> [URL] {
        [home.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory),
         home.appending(path: "Library/Containers/\(ownerBundleIdentifier)", directoryHint: .isDirectory),
         home.appending(path: "Library/Group Containers", directoryHint: .isDirectory)]
    }

    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
    }

    static func isInside(_ url: URL, of directory: URL) -> Bool {
        let path = resolved(url).path, parent = resolved(directory).path
        return path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    /// `self` when it is safe to run, else the first reason it is not. Pure apart from reading which parents exist.
    func validated(bundleIdentifier: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<IsolatedEngineOptions, Refusal> {
        guard let bundleIdentifier, bundleIdentifier.hasSuffix(Self.measurementBundleSuffix), bundleIdentifier != Self.ownerBundleIdentifier else {
            return .failure(.notAMeasurementBuild)
        }
        guard BridgeSettings.isValidNVRFolder(directoryPath) else { return .failure(.directoryNotUsable) }
        let protected = Self.protectedDirectories(home: home)
        if protected.contains(where: { Self.isInside(directory, of: $0) }) { return .failure(.ownerData) }
        if let folderPath {
            guard BridgeSettings.isValidNVRFolder(folderPath) else { return .failure(.folderNotUsable) }
            if let nvrFolder, protected.contains(where: { Self.isInside(nvrFolder, of: $0) }) { return .failure(.ownerData) }
        }
        guard (0...9).contains(demoCameras) else { return .failure(.tooManyCameras) }
        guard Self.basePortRange.contains(basePort) else { return .failure(.portOutOfRange) }
        guard BridgeSettings.nvrKeepDaysRange.contains(keepDays), BridgeSettings.nvrMaxSizeGBRange.contains(maxSizeGB) else { return .failure(.limitOutOfRange) }
        guard (0...3_600).contains(recordAfter), quitAfter.map({ (30...36_000).contains($0) }) ?? true, (0.5...60).contains(heartbeat),
              demoKeyframeSeconds.map({ (1...120).contains($0) }) ?? true else {
            return .failure(.timingOutOfRange)
        }
        if let probe, ProbeScenario.parse(probe) == nil { return .failure(.unknownProbe(probe)) }
        return .success(self)
    }

    /// The defaults the isolated app uses: onboarding done, Dock on, menu bar item off (a second status item must not appear in the person’s menu bar).
    static func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? UserDefaults()
        defaults.set(true, forKey: "onboardingCompleted")
        defaults.set(true, forKey: "showInDock")
        defaults.set(false, forKey: "showInMenuBar")
        return defaults
    }
}

/// What `AppModel.launching` does with the launch arguments: run the live engine, run the isolated one, or stop. Present but invalid
/// isolated options are `refused`, never `live`: a typo must not start the person’s real bridge on a measurement run.
nonisolated enum IsolatedLaunchDecision: Equatable {
    case live
    case isolated(IsolatedEngineOptions)
    case refused(IsolatedEngineOptions.Refusal)

    static func decide(defaults: UserDefaults, bundleIdentifier: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        guard let requested = IsolatedEngineOptions(defaults: defaults) else { return .live }
        switch requested.validated(bundleIdentifier: bundleIdentifier, home: home) {
        case .success(let options): return .isolated(options)
        case .failure(let refusal): return .refused(refusal)
        }
    }
}

/// The probe scenarios `-nvrProbe` runs (NVRProbe, Debug builds only).
nonisolated enum ProbeScenario: String, CaseIterable, Sendable {
    case scrubcost, keyframe, exact, grid, play, drivehold

    /// What "all" runs: the five scenarios of the budgets. `drivehold` is only run by name (it belongs to `Tools/nvr-soak.sh yank`, which pulls the drive under it).
    static let budgets: [ProbeScenario] = [.scrubcost, .keyframe, .exact, .grid, .play]

    /// "keyframe,exact" in that order, or "all" for the budget scenarios; nil when a name is not one.
    static func parse(_ text: String) -> [ProbeScenario]? {
        if text == "all" { return budgets }
        let names = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let scenarios = names.compactMap(ProbeScenario.init(rawValue:))
        return scenarios.count == names.count && !names.isEmpty ? scenarios : nil
    }
}

/// What the isolated app puts into its engine before the engine starts. Idempotent: a relaunch on the same directory adds nothing twice.
nonisolated enum IsolatedEngineSeed {
    /// The settings the run needs: HomeKit ports away from the person’s app (21100...), Scrypted and Homebridge; no sensors bridge, no webhook;
    /// the recordings folder and limits.
    static func settings(_ options: IsolatedEngineOptions, applying base: BridgeSettings) -> BridgeSettings {
        var settings = base
        settings.basePort = options.basePort
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        settings.webhookEnabled = false
        settings.nvrFolder = options.nvrFolder?.path
        settings.nvrKeepDays = options.keepDays
        settings.nvrMaxSizeGB = options.maxSizeGB
        return settings
    }

    /// The demo cameras still missing: "Soak 1" ... "Soak N" (1920x1080, 30 fps, a two-second keyframe interval and a tone, from the engine’s demo source).
    static func missingCameras(_ options: IsolatedEngineOptions, existing: [CameraConfiguration]) -> [CameraConfiguration] {
        let have = Set(existing.map(\.name))
        return (1...max(1, options.demoCameras)).compactMap { number in
            let name = "\(IsolatedEngineOptions.cameraNamePrefix)\(number)"
            guard number <= options.demoCameras, !have.contains(name) else { return nil }
            return CameraConfiguration(name: name, kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        }
    }

    /// The seeded cameras of a configuration, in name order.
    static func seededCameras(_ cameras: [CameraConfiguration]) -> [CameraConfiguration] {
        cameras.filter { $0.name.hasPrefix(IsolatedEngineOptions.cameraNamePrefix) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func apply(_ options: IsolatedEngineOptions, to engine: BridgeEngine) async throws {
        try await engine.updateSettings(settings(options, applying: engine.settings))
        for camera in missingCameras(options, existing: engine.configurations) { try await engine.addCamera(camera, password: nil) }
        if options.recordAfter == 0, options.nvrFolder != nil {
            for camera in seededCameras(engine.configurations) where !camera.nvrEnabled { try await engine.setNVR(cameraID: camera.id, enabled: true) }
        }
    }
}
#endif
