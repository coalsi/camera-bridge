import BridgeSupport
import Foundation

/// The camera's own network features the setup turns off: Hikvision's UPnP (it opens ports on the router) and Hik-Connect (the EZVIZ
/// cloud: the camera keeps a connection to the maker's servers), through ISAPI; a Reolink's UPnP and UID (P2P: Reolink's cloud), through its
/// own API (`SetUpnp`, `SetP2p`: CameraSettingsService+Reolink.swift); and the maker's cloud of an ONVIF camera that speaks the IP camera web
/// API (`CameraSettingsService+IPCWeb.swift`) or is of the IPCamera Web family (`CameraSettingsService+IPCamWeb.swift`). ONVIF itself has no
/// such settings. For Hikvision only the switch is read and kept (a Hik-Connect document also holds the camera's verification code, which is
/// never saved or logged); turning it back on is a read-modify-write of the camera's document as it is then.
public enum CameraNetworkFeature: String, Sendable, Codable, CaseIterable {
    case upnp, cloud

    var paths: [String] { self == .upnp ? HikvisionISAPI.upnpPaths : HikvisionISAPI.cloudPaths }
    /// The flag of `/ISAPI/System/Network/capabilities` that says whether the camera has it.
    var capability: String { self == .upnp ? "isSupportUPnP" : "isSupportEZVIZ" }
    var label: String { self == .upnp ? "UPnP" : "Hik-Connect (the maker’s cloud)" }

    /// Why the step changes nothing on a camera Camera Bridge has no way to change it on, and what the person can do instead.
    var cannotChange: String {
        "Camera Bridge can’t change this camera’s \(self == .upnp ? "UPnP" : "cloud") setting yet. If it has one, block the camera’s internet "
            + "in your router (see Keep this camera local)."
    }
}

extension CameraSettingsService {
    /// Whether the feature is on, read from the first of its paths the camera answers; the backup holds that path and the switch. An ONVIF
    /// camera that speaks the IP camera web API has its cloud read there (`readIPCWebCloud`; not possible now while that API cannot be
    /// asked); it has no UPnP step. A camera of the IPCamera Web family has its cloud read through its API (`readIPCamWebCloud`), and its
    /// UPnP too (the family has none to change). A Reolink through its own API (`GetUpnp`, `GetP2p`; its cloud step's note says what the UID
    /// off means). Any other camera: Camera Bridge can't change it (`CameraNetworkFeature.cannotChange`).
    public func readFeature(_ feature: CameraNetworkFeature) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        if vendor == .reolink { return try await readReolinkFeature(feature) }
        if vendor != .hikvision {
            switch try await ipcWeb() {
            case .speaks(let client, _): if feature == .cloud { return try await readIPCWebCloud(client) }
            case .unavailable(let why): if feature == .cloud { return (.notSupported(why), nil) }
            case .none:
                switch try await ipcamWeb() {
                case .speaks(let client): return try await feature == .cloud ? readIPCamWebCloud(client) : readIPCamWebUPnP(client)
                case .unavailable(let why): return (.notSupported(why.reason), nil)
                case .none: break
                }
            }
        }
        guard vendor == .hikvision else { return (.notSupported(feature.cannotChange), nil) }
        guard let (path, document) = try await featureDocument(feature), let enabled = Self.featureEnabled(document) else { return (.notSupported(), nil) }
        let backup = CameraFeatureBackup(path: path, enabled: enabled)
        guard enabled else { return (CameraSetupReading(state: .alreadyRight), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: feature.label, now: "on", after: "off")]), backup)
    }

    /// Turns the feature on or off (at `path`, from the backup, when known), then reads it back. `saved`: the backup being restored (the
    /// IP camera web API's cloud gets its kind and sign-in value back from it).
    public func setFeature(_ feature: CameraNetworkFeature, enabled: Bool, path known: String? = nil,
                           saved: CameraFeatureBackup? = nil) async throws -> CameraSetupOutcome {
        if vendor == .reolink { return try await setReolinkFeature(feature, enabled: enabled) }
        if vendor != .hikvision, feature == .cloud {
            switch try await ipcWeb() {
            case .speaks(let client, _): return try await setIPCWebCloud(enabled: enabled, saved: saved, client: client)
            case .unavailable(let why): return .refused(why)
            case .none:
                switch try await ipcamWeb() {
                case .speaks(let client): return try await setIPCamWebCloud(enabled: enabled, client: client)
                case .unavailable(let why): return .refused(why)   // `notPermitted` for an account without privilege
                case .none: break
                }
            }
        }
        guard vendor == .hikvision else { return .refused(feature.cannotChange) }
        let api = isapi()
        let found: (String, String)?
        if let known, let document = try await api.document(known) { found = (known, document) } else { found = try await featureDocument(feature) }
        guard let (path, document) = found else { return .refused("the camera no longer shows this setting") }
        guard let current = Self.featureEnabled(document) else { return .refused("the camera shows no switch for it") }
        if current == enabled { return CameraSetupOutcome(succeeded: true, detail: "already \(enabled ? "on" : "off")") }
        guard let edited = HikvisionISAPI.replacingElement("enabled", in: document, with: enabled ? "true" : "false") else {
            return .refused("the camera shows no switch for it")
        }
        let answer: ISAPIWriteAnswer
        do {
            answer = try await api.write(path, document: edited)
        } catch let refusal as ISAPIRefusal {
            return .refused(refusal.words)
        } catch CameraAdapterError.notPermitted {
            return .notPermittedRefusal
        }
        if let after = try await api.document(path), let now = Self.featureEnabled(after), now != enabled, answer != .rebootRequired {
            return .refused("the camera kept it \(now ? "on" : "off")")
        }
        log.info("Turned \(feature == .upnp ? "UPnP" : "Hik-Connect") \(enabled ? "on" : "off") through ISAPI")
        return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
    }

    /// The feature's document: nil when the capabilities say the camera does not have it, or none of its paths answers. The setup's step
    /// reads it here, the security check through `featureLookup`.
    func featureDocument(_ feature: CameraNetworkFeature) async throws -> (path: String, document: String)? {
        guard case .found(let path, let document) = try await featureLookup(feature) else { return nil }
        return (path, document)
    }

    /// What the camera shows of the feature: the first of its paths that answers a document with a switch; `absent` only when the
    /// capabilities say the camera does not have it; `unreadable` when they say it has it (or say nothing) and no path answers.
    func featureLookup(_ feature: CameraNetworkFeature) async throws -> FeatureLookup {
        let api = isapi()
        let capabilities = try await api.document(HikvisionISAPI.networkCapabilitiesPath)
        if HikvisionISAPI.capability(feature.capability, in: capabilities) == false { return .absent }
        for path in feature.paths {
            if let document = try await api.document(path), Self.featureEnabled(document) != nil { return .found(path: path, document: document) }
        }
        return .unreadable
    }

    enum FeatureLookup: Sendable, Equatable {
        case found(path: String, document: String)
        case absent
        case unreadable
    }

    /// The document's first `enabled` (the feature's own switch: it comes before any nested element in these documents).
    static func featureEnabled(_ document: String) -> Bool? {
        HikvisionISAPI.elementText("enabled", in: document).flatMap(ONVIFNotification.parseBool)
    }
}
