import BridgeSupport
import Foundation

extension ONVIFClient {
    /// `SendAuxiliaryCommand` on the PTZ service (e.g. `tt:Lamp|On`, `tt:IRLamp|Off`).
    func sendAuxiliaryCommand(profileToken: String, _ command: String) async throws {
        let body = "<tptz:SendAuxiliaryCommand xmlns:tptz=\"\(Self.ptzNamespace)\"><tptz:ProfileToken>\(XMLTree.escape(profileToken))</tptz:ProfileToken>"
            + "<tptz:AuxiliaryData>\(XMLTree.escape(command))</tptz:AuxiliaryData></tptz:SendAuxiliaryCommand>"
        _ = try await call(await ptzServiceURL(), body: body, action: "\(Self.ptzNamespace)/SendAuxiliaryCommand")
    }
}

/// Night vision of an ONVIF camera: the imaging IR-cut filter (`AUTO`; `OFF` lets infrared through, the camera's night mode with its IR
/// lights on; `ON` blocks it, day mode, IR lights off), and a lamp switched by the PTZ node's auxiliary commands (`tt:IRLamp|On/Off`, or
/// `tt:Lamp|On/Off`, which on some cameras is a white spotlight). Only the IR-cut field is written, nothing else of the imaging settings.
actor ONVIFNightVision: NightVisionControl {
    private let client: ONVIFClient
    private let log: Log
    private var source: String?
    private var lampCommands: (on: String, off: String)?
    private var profileToken: String?
    private var known: NightVisionCapabilities?

    init(client: ONVIFClient, log: Log) {
        self.client = client
        self.log = log
    }

    static func mode(irCutFilter: String?) -> NightVisionMode? {
        switch irCutFilter?.uppercased() {
        case "AUTO": .auto
        case "OFF": .on
        case "ON": .off
        default: nil
        }
    }

    static func irCutFilter(_ mode: NightVisionMode) -> String {
        switch mode {
        case .auto: "AUTO"
        case .on: "OFF"
        case .off: "ON"
        }
    }

    /// The lamp's on and off commands from a node's auxiliary commands (an IR lamp first).
    static func lampCommands(_ commands: [String]) -> (on: String, off: String)? {
        for name in ["tt:IRLamp", "tt:Lamp"] {
            let on = commands.first { $0.caseInsensitiveCompare("\(name)|On") == .orderedSame }
            let off = commands.first { $0.caseInsensitiveCompare("\(name)|Off") == .orderedSame }
            if let on, let off { return (on, off) }
        }
        return nil
    }

    func capabilities() async throws -> NightVisionCapabilities {
        if let known { return known }
        var modes: [NightVisionMode] = []
        if let token = try await client.videoSourceTokens().first {
            source = token
            let options = try? await client.imagingOptions(videoSourceToken: token)
            modes = NightVisionMode.allCases.filter { (options?.irCutFilterModes ?? []).contains(Self.irCutFilter($0)) }
        }
        let profiles = (try? await client.profiles()) ?? []
        if let profile = profiles.first(where: \.ptzConfigured), let nodes = try? await client.ptzNodes() {
            profileToken = profile.token
            lampCommands = Self.lampCommands(nodes.flatMap(\.auxiliaryCommands))
        }
        let result = NightVisionCapabilities(modes: modes, light: lampCommands != nil)
        known = result
        if !modes.isEmpty || result.light {
            log.info("Night vision: modes \(modes.map(\.rawValue).joined(separator: ", "))\(result.light ? "; a lamp (\(lampCommands!.on))" : "")")
        }
        return result
    }

    func currentMode() async throws -> NightVisionMode? {
        _ = try await capabilities()
        guard let source else { return nil }
        return Self.mode(irCutFilter: try await client.imagingSettings(videoSourceToken: source).irCutFilter)
    }

    func setMode(_ mode: NightVisionMode) async throws {
        let known = try await capabilities()
        guard let source, known.modes.contains(mode) else { throw CameraAdapterError.unsupported("this camera has no \(mode.rawValue) night vision mode") }
        let wanted = Self.irCutFilter(mode)
        try await client.setImagingSettings(videoSourceToken: source, settings: ONVIFImagingSettings(irCutFilter: wanted))
        if try await client.imagingSettings(videoSourceToken: source).irCutFilter?.uppercased() != wanted {
            // Some cameras take the IR-cut change only with the rest of the imaging settings in the same request.
            var all = try await client.imagingSettings(videoSourceToken: source)
            all.irCutFilter = wanted
            try await client.setImagingSettings(videoSourceToken: source, settings: all)
            let now = try await client.imagingSettings(videoSourceToken: source).irCutFilter?.uppercased()
            guard now == wanted else {
                throw CameraAdapterError.unsupported("the camera accepted night vision \(mode.rawValue) but stayed in \(now ?? "its own mode")")
            }
        }
        log.info("Night vision set to \(mode.rawValue)")
    }

    func setLight(_ on: Bool) async throws {
        _ = try await capabilities()
        guard let lampCommands, let profileToken else { throw CameraAdapterError.unsupported("this camera has no lamp the bridge can switch") }
        try await client.sendAuxiliaryCommand(profileToken: profileToken, on ? lampCommands.on : lampCommands.off)
        log.info("Lamp turned \(on ? "on" : "off")")
    }
}

/// The night vision of an ONVIF camera: through the IP camera web API when the camera speaks it (`IPCWebNightVision`: these cameras'
/// ONVIF ignores IR-cut writes and refuses its lamp command), else through ONVIF (`ONVIFNightVision`). Which one is decided in the first
/// `capabilities()` that can tell (the web API's probe), so making it asks the camera nothing. A camera that does not speak the API, or has
/// no night vision in it, gets ONVIF. A camera of the family (`IPCWebNightVision.isOfTheFamily`) never does: while its API cannot be asked
/// (paused, not answering, its login refused) `capabilities()` throws and asks again next time. While the web server does not answer at
/// all, nothing is chosen either: when ONVIF does answer, the web server gets `unansweredTries` more tries before ONVIF is chosen.
actor NightVisionSelector: NightVisionControl {
    /// The tries the web server gets while ONVIF answers and it does not (the camera's runtime asks again after a growing pause, 10 s
    /// first): a camera still starting can answer ONVIF before its web server.
    static let unansweredTries = 3

    private let web: IPCWebNightVision?
    private let onvif: (any NightVisionControl)?
    private var chosen: (any NightVisionControl)?
    /// The times the web server did not answer while ONVIF did.
    private var unanswered = 0
    /// The web API was chosen (tests).
    private(set) var usesWebAPI = false

    init(web: IPCWebNightVision?, onvif: (any NightVisionControl)?) {
        self.web = web
        self.onvif = onvif
    }

    func capabilities() async throws -> NightVisionCapabilities {
        if let chosen { return try await chosen.capabilities() }
        var webUnanswered = false
        if let web {
            do {
                let known = try await web.capabilities()
                if !known.modes.isEmpty || known.light {
                    chosen = web
                    usesWebAPI = true
                    return known
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where web.isOfTheFamily {
                throw error   // its ONVIF ignores night vision: nothing is chosen, asked again next time
            } catch is IPCWebNoAnswer {
                webUnanswered = true
            } catch {
                // No web API: ONVIF.
            }
        }
        guard let onvif else {
            if webUnanswered { throw IPCWebNoAnswer() }
            throw CameraAdapterError.unsupported("this camera has no night vision the bridge can switch")
        }
        let known = try await onvif.capabilities()
        if webUnanswered, unanswered < Self.unansweredTries {
            unanswered += 1
            throw IPCWebNoAnswer()
        }
        chosen = onvif
        return known
    }

    func currentMode() async throws -> NightVisionMode? { try await control().currentMode() }

    func currentLight() async throws -> Bool? { try await control().currentLight() }

    func setMode(_ mode: NightVisionMode) async throws { try await control().setMode(mode) }

    func setLight(_ on: Bool) async throws { try await control().setLight(on) }

    private func control() async throws -> any NightVisionControl {
        if let chosen { return chosen }
        _ = try await capabilities()
        guard let chosen else { throw CameraAdapterError.unsupported("this camera has no night vision the bridge can switch") }
        return chosen
    }
}
