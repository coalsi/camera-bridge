import BridgeSupport
import Foundation

/// Night vision and the IR lights of a camera that speaks the IP camera web API, through the `Capture` element of its video settings
/// (`getMediaVideoConfig`, written back whole with `setMediaVideoCaptureConfig` and read back). These cameras' ONVIF ignores IR-cut
/// writes and always reads back AUTO, and refuses its own lamp command, so this is the way that works on them.
///
/// `IrcutMode`: 0 picture-based, 1 by the clock, 2 the light sensor (the factory setting) are the camera's own choice (`auto`); 3 is
/// manual, day or night set with `setIRCutManual_DayNight` (`DayMode` / `NightMode`, which has no read); 6 and 7 are manual with the
/// lights always on or off. `on` (IR on, a black-and-white night picture) is 3 then `NightMode`; `off` (IR off, a colour day picture) is
/// 3 then `DayMode`; `auto` leaves an automatic mode as it is, and otherwise goes back to the automatic mode last seen during this run
/// (2 when none was). The lights: on is `led_brightness_mode` 2 (automatic brightness); off is 1 (manual) at `led_brightness_value` 0;
/// turning them on again also puts the manual brightness back (the last non-zero value seen, else 100), so manual never stays at 0.
actor IPCWebNightVision: NightVisionControl {
    static let readName = "getMediaVideoConfig"
    static let writeName = "setMediaVideoCaptureConfig"
    static let dayNightName = "setIRCutManual_DayNight"
    /// The camera's own choice (`IrcutMode` 0, 1, 2).
    static let automaticModes: Set<Int> = [0, 1, 2]
    static let factoryAutomaticMode = 2
    static let manualMode = 3

    private let client: IPCWebClient
    private let log: Log
    /// One call at a time, whole: each suspends at every request, and two read-modify-writes of `Capture` that overlapped would write
    /// back each other's old values (Apple Home's Night Vision and the bridge's page can change it at once).
    private let serial = AsyncSerialLock()
    private var known: NightVisionCapabilities?
    /// The automatic `IrcutMode` last seen on the camera during this run.
    private var automaticMode: Int?
    /// What this client last set while the camera is in manual mode 3 (which cannot be read back).
    private var manualChoice: NightVisionMode?
    /// The last non-zero `led_brightness_value` seen.
    private var brightness: Int?

    init(client: IPCWebClient, log: Log) {
        self.client = client
        self.log = log
    }

    /// The mode an `IrcutMode` stands for; `manualChoice` for 3 (nil when unknown).
    static func mode(ircutMode: Int?, manualChoice: NightVisionMode?) -> NightVisionMode? {
        switch ircutMode {
        case .some(let value) where automaticModes.contains(value): .auto
        case manualMode: manualChoice
        case 6: .on
        case 7: .off
        default: nil
        }
    }

    /// Whether the IR lights are on: anything but manual brightness at 0. nil when the camera does not say.
    static func lightOn(brightnessMode: Int?, value: Int?) -> Bool? {
        guard let brightnessMode, let value else { return nil }
        return !(brightnessMode == 1 && value == 0)
    }

    /// The camera's sign-in script showed it is of the family during this run (`IPCWebClient.isFamily`): ONVIF's night vision, which
    /// these cameras ignore, is never used for it (`NightVisionSelector`).
    nonisolated var isOfTheFamily: Bool { client.isFamily }

    /// Throws `CameraAdapterError.unsupported` when the camera does not speak the API, `IPCWebNoAnswer` when its web server did not answer
    /// (not known yet), and `IPCWebUnavailable` or the login refusal when a camera of the family cannot be asked now (`IPCWebClient.probe()`).
    func capabilities() async throws -> NightVisionCapabilities {
        try await serial.withLock { try await knownCapabilities() }
    }

    func currentMode() async throws -> NightVisionMode? {
        try await serial.withLock {
            guard try await knownCapabilities().modes.isEmpty == false else { return nil }
            return Self.mode(ircutMode: Self.int("IrcutMode", try await readCapture()), manualChoice: manualChoice)
        }
    }

    func currentLight() async throws -> Bool? {
        try await serial.withLock {
            guard try await knownCapabilities().light else { return nil }
            let capture = try await readCapture()
            return Self.lightOn(brightnessMode: Self.int("led_brightness_mode", capture), value: Self.int("led_brightness_value", capture))
        }
    }

    func setMode(_ mode: NightVisionMode) async throws {
        try await serial.withLock { try await apply(mode) }
    }

    func setLight(_ on: Bool) async throws {
        try await serial.withLock { try await applyLight(on) }
    }

    // MARK: Under the lock

    private func knownCapabilities() async throws -> NightVisionCapabilities {
        if let known { return known }
        guard let device = try await client.probe() else { throw CameraAdapterError.unsupported("the camera has no IP camera web API") }
        var modes: [NightVisionMode] = []
        var light = false
        if device.has(IPCWebDevice.nightVisionFeature) || device.has(IPCWebDevice.lightFeature) {
            let capture = try await readCapture()
            if device.has(IPCWebDevice.nightVisionFeature), Self.int("IrcutMode", capture) != nil { modes = NightVisionMode.allCases }
            light = device.has(IPCWebDevice.lightFeature) && Self.lightOn(brightnessMode: Self.int("led_brightness_mode", capture),
                                                                          value: Self.int("led_brightness_value", capture)) != nil
        }
        let result = NightVisionCapabilities(modes: modes, light: light)
        known = result
        if !modes.isEmpty || light {
            log.info("Night vision through the camera's web API: modes \(modes.map(\.rawValue).joined(separator: ", "))\(light ? "; IR lights" : "")")
        }
        return result
    }

    private func apply(_ mode: NightVisionMode) async throws {
        guard try await knownCapabilities().modes.contains(mode) else { throw CameraAdapterError.unsupported("this camera has no \(mode.rawValue) night vision mode") }
        let capture = try await readCapture()
        let current = Self.int("IrcutMode", capture)
        switch mode {
        case .auto:
            if let current, Self.automaticModes.contains(current) { break }
            try await writeCapture(capture, ["IrcutMode": String(automaticMode ?? Self.factoryAutomaticMode)], what: "night vision auto")
            manualChoice = nil
        case .on, .off:
            // The capture as read back after the switch to manual: what goes back if the day/night command then fails.
            var switched: String?
            if current != Self.manualMode {
                switched = try await writeCapture(capture, ["IrcutMode": String(Self.manualMode)], what: "night vision \(mode.rawValue)")
            }
            do {
                try await client.write(Self.dayNightName, body: mode == .on ? "NightMode" : "DayMode")
            } catch {
                manualChoice = nil   // whether the camera took it is not known
                if let switched, let current { await putBack(current, in: switched) }
                throw error
            }
            manualChoice = mode
        }
        log.info("Night vision set to \(mode.rawValue) through the camera's web API")
    }

    /// After a day/night command that failed: the camera's mode from before the switch to manual, so it does not stay in a manual day
    /// or night that nothing shows. Once, best effort (after a refusal the client sends nothing: its latch is tripped).
    private func putBack(_ mode: Int, in capture: String) async {
        do {
            try await writeCapture(capture, ["IrcutMode": String(mode)], what: "its old night vision mode")
            log.info("The day/night command failed: the camera's night vision mode was put back as it was")
        } catch {
            log.warning("The day/night command failed and the camera's old night vision mode could not be put back: it may stay in manual mode")
        }
    }

    private func applyLight(_ on: Bool) async throws {
        guard try await knownCapabilities().light else { throw CameraAdapterError.unsupported("this camera has no IR lights the bridge can switch") }
        let capture = try await readCapture()
        guard Self.lightOn(brightnessMode: Self.int("led_brightness_mode", capture), value: Self.int("led_brightness_value", capture)) != on else { return }
        let changes = on ? ["led_brightness_mode": "2", "led_brightness_value": String(brightness ?? 100)]
            : ["led_brightness_mode": "1", "led_brightness_value": "0"]
        try await writeCapture(capture, changes, what: "the IR lights \(on ? "on" : "off")")
        log.info("IR lights turned \(on ? "on" : "off") through the camera's web API")
    }

    // MARK: The Capture element

    /// The `Capture` element of the video settings, as the camera wrote it (what this run remembers is taken from it).
    private func readCapture() async throws -> String {
        let video = try await client.read(Self.readName, root: "Video")
        guard let capture = IPCWebXML.element("Capture", in: video) else { throw CameraAdapterError.invalidResponse("no Capture in the video settings") }
        remember(String(capture))
        return String(capture)
    }

    private func remember(_ capture: String) {
        if let mode = Self.int("IrcutMode", capture), Self.automaticModes.contains(mode) { automaticMode = mode }
        if let value = Self.int("led_brightness_value", capture), value > 0 { brightness = value }
    }

    /// Writes `capture` back with only `changes` replaced, then reads it back (the answer): throws when the camera kept another value.
    @discardableResult
    private func writeCapture(_ capture: String, _ changes: [String: String], what: String) async throws -> String {
        guard let edited = IPCWebXML.replacingAttributes(changes, in: capture) else {
            throw CameraAdapterError.unsupported("the camera's video settings have no \(changes.keys.sorted().joined(separator: ", "))")
        }
        try await client.write(Self.writeName, body: "<Video>\(edited)</Video>")
        let after = try await readCapture()
        let kept = changes.filter { IPCWebXML.attribute($0.key, of: after) != $0.value }
        guard kept.isEmpty else { throw CameraAdapterError.unsupported("the camera accepted \(what) but kept its old setting") }
        return after
    }

    static func int(_ name: String, _ element: String) -> Int? {
        IPCWebXML.attribute(name, of: element).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
