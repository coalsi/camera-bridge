import BridgeSupport
import Foundation

/// The camera's own network features the setup turns off: Hikvision's UPnP (it opens ports on the router) and Hik-Connect (the EZVIZ
/// cloud: the camera keeps a connection to the maker's servers). Hikvision only, through ISAPI: ONVIF has no such settings. Only the switch
/// is read and kept (a Hik-Connect document also holds the camera's verification code, which is never saved or logged); turning it back on
/// is a read-modify-write of the camera's document as it is then.
public enum CameraNetworkFeature: String, Sendable, Codable, CaseIterable {
    case upnp, cloud

    var paths: [String] { self == .upnp ? HikvisionISAPI.upnpPaths : HikvisionISAPI.cloudPaths }
    /// The flag of `/ISAPI/System/Network/capabilities` that says whether the camera has it.
    var capability: String { self == .upnp ? "isSupportUPnP" : "isSupportEZVIZ" }
    var label: String { self == .upnp ? "UPnP" : "Hik-Connect (the maker’s cloud)" }
}

extension CameraSettingsService {
    /// Whether the feature is on, read from the first of its paths the camera answers; the backup holds that path and the switch.
    public func readFeature(_ feature: CameraNetworkFeature) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        guard vendor == .hikvision else { return (.notSupported(), nil) }
        guard let (path, document) = try await featureDocument(feature), let enabled = Self.featureEnabled(document) else { return (.notSupported(), nil) }
        let backup = CameraFeatureBackup(path: path, enabled: enabled)
        guard enabled else { return (CameraSetupReading(state: .alreadyRight), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: feature.label, now: "on", after: "off")]), backup)
    }

    /// Turns the feature on or off (at `path`, from the backup, when known), then reads it back.
    public func setFeature(_ feature: CameraNetworkFeature, enabled: Bool, path known: String? = nil) async throws -> CameraSetupOutcome {
        guard vendor == .hikvision else { return .refused("not supported by this camera") }
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
        do { answer = try await api.write(path, document: edited) } catch let refusal as ISAPIRefusal { return .refused(refusal.words) }
        if let after = try await api.document(path), let now = Self.featureEnabled(after), now != enabled, answer != .rebootRequired {
            return .refused("the camera kept it \(now ? "on" : "off")")
        }
        log.info("Turned \(feature == .upnp ? "UPnP" : "Hik-Connect") \(enabled ? "on" : "off") through ISAPI")
        return CameraSetupOutcome(succeeded: true, needsRestart: answer == .rebootRequired, detail: "via ISAPI")
    }

    /// The feature's document: nil when the capabilities say the camera does not have it, or none of its paths answers.
    private func featureDocument(_ feature: CameraNetworkFeature) async throws -> (path: String, document: String)? {
        let api = isapi()
        let capabilities = try await api.document(HikvisionISAPI.networkCapabilitiesPath)
        if HikvisionISAPI.capability(feature.capability, in: capabilities) == false { return nil }
        for path in feature.paths {
            if let document = try await api.document(path), Self.featureEnabled(document) != nil { return (path, document) }
        }
        return nil
    }

    /// The document's first `enabled` (the feature's own switch: it comes before any nested element in these documents).
    static func featureEnabled(_ document: String) -> Bool? {
        HikvisionISAPI.elementText("enabled", in: document).flatMap(ONVIFNotification.parseBool)
    }
}
