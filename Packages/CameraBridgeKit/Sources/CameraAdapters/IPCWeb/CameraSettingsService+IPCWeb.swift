import BridgeSupport
import Foundation

/// "Set up for Camera Bridge" on an ONVIF camera that speaks the IP camera web API (`CameraSettingsService.ipcWeb()`), for what its ONVIF
/// reports wrongly: its own labels (the `Overlay` element of the video settings; `Enable` 0 takes both its title and its clock off the
/// picture) and its maker's cloud (`P2PConfig` of the network settings). Each is a read-modify-write of the element as the camera wrote
/// it, read back after. The network settings also hold the camera's other passwords (e-mail, FTP, Wi-Fi): only the `P2PConfig` element
/// is looked at here (and `LANConfig` for the DNS servers, `IPCWebDNS.swift`), nothing of the answer is logged or kept.
extension CameraSettingsService {
    static let ipcVideoRead = "getMediaVideoConfig"
    static let ipcOverlayWrite = "setMediaVideoOverlayConfig"
    static let ipcNetworkRead = "getNetworkConfig"
    static let ipcCloudWrite = "setNetworkP2PConfig"
    /// The change row's label for these cameras' cloud (they are sold under many brands: the service has no one name).
    static let ipcCloudLabel = "The maker’s cloud"

    // MARK: Clean picture

    /// The `Overlay` element as the camera has it now; nil when its video settings have none (or no `Enable` on it).
    func ipcWebOverlay(_ client: IPCWebClient) async throws -> String? {
        let video = try await client.read(Self.ipcVideoRead, root: "Video")
        guard let overlay = IPCWebXML.element("Overlay", in: video), IPCWebXML.attribute("Enable", of: overlay) != nil else { return nil }
        return String(overlay)
    }

    /// What the overlay shows, in plain words (nothing when it is off).
    static func ipcWebLabels(_ overlay: String) -> [String] {
        guard IPCWebXML.attribute("Enable", of: overlay) != "0" else { return [] }
        var shown: [String] = []
        if IPCWebXML.element("TimeOverlay", in: overlay) != nil { shown.append("date and time") }
        if IPCWebXML.element("TitleOverlay", in: overlay) != nil { shown.append("camera name") }
        return shown.isEmpty ? ["the camera’s labels"] : shown
    }

    func readIPCWebCleanPicture(_ client: IPCWebClient) async throws -> CameraSetupReading {
        guard let overlay = try await ipcWebOverlay(client) else { return .notSupported() }
        let shown = Self.ipcWebLabels(overlay)
        if shown.isEmpty { return CameraSetupReading(state: .alreadyRight) }
        return CameraSetupReading(state: .willChange, changes: [.init(label: "The camera’s own labels", now: CameraSetupText.list(shown),
                                                                      after: "off (the bridge draws its own)")])
    }

    /// Turns the overlay off (when it is on) and reads it back; the backup's `document` is its `Enable` as it was.
    func cleanViaIPCWeb(_ client: IPCWebClient) async throws -> CleanPictureBackup {
        guard let overlay = try await ipcWebOverlay(client), let enabled = IPCWebXML.attribute("Enable", of: overlay) else {
            throw CameraAdapterError.unsupported("no on-screen text in the camera's video settings")
        }
        if enabled != "0" { try await writeIPCWebOverlay(overlay, enable: "0", client: client) }
        return CleanPictureBackup(method: .ipcWebAPI, document: enabled)
    }

    func restoreViaIPCWeb(_ backup: CleanPictureBackup, client: IPCWebClient) async throws {
        guard let enabled = backup.document, !enabled.isEmpty else { throw CameraAdapterError.invalidResponse("no saved on-screen text switch") }
        guard let overlay = try await ipcWebOverlay(client) else { throw CameraAdapterError.unsupported("no on-screen text in the camera's video settings") }
        if IPCWebXML.attribute("Enable", of: overlay) != enabled { try await writeIPCWebOverlay(overlay, enable: enabled, client: client) }
    }

    /// `overlay` written back with only `Enable` changed, then read back.
    private func writeIPCWebOverlay(_ overlay: String, enable: String, client: IPCWebClient) async throws {
        guard let edited = IPCWebXML.replacingAttributes(["Enable": enable], in: overlay) else {
            throw CameraAdapterError.unsupported("no on-screen text switch in the camera's video settings")
        }
        try await client.write(Self.ipcOverlayWrite, body: edited)
        guard let after = try await ipcWebOverlay(client), IPCWebXML.attribute("Enable", of: after) == enable else {
            throw CameraAdapterError.unsupported("the camera kept its own labels as they were")
        }
    }

    // MARK: The maker's cloud

    /// The cloud's switch, kind and sign-in value; nil when the network settings have no `P2PConfig`.
    private func ipcWebCloud(_ client: IPCWebClient) async throws -> (enabled: String, type: String, code: String)? {
        Self.ipcWebCloud(in: try await client.read(Self.ipcNetworkRead, root: "NetworkConfig"))
    }

    /// The `P2PConfig` of the network settings (the setup's cloud step and the security check read it here alike).
    static func ipcWebCloud(in network: String) -> (enabled: String, type: String, code: String)? {
        guard let element = IPCWebXML.element("P2PConfig", in: network), let enabled = IPCWebXML.attribute("Enable", of: element) else { return nil }
        return (enabled, IPCWebXML.attribute("Type", of: element) ?? "", IPCWebXML.attribute("Authcode", of: element) ?? "")
    }

    /// Whether the cloud is on; the backup holds the switch, `Type` and `Authcode` (the camera's sign-in to its maker's cloud: kept only in
    /// the engine's setup backup, to give it back exactly; never logged).
    func readIPCWebCloud(_ client: IPCWebClient) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        guard let cloud = try await ipcWebCloud(client) else { return (.notSupported(), nil) }
        let on = cloud.enabled != "0"
        let backup = CameraFeatureBackup(path: Self.ipcNetworkRead, enabled: on, cloudType: cloud.type, cloudAuthcode: cloud.code)
        guard on else { return (CameraSetupReading(state: .alreadyRight), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: Self.ipcCloudLabel, now: "on", after: "off")]), backup)
    }

    /// Turns the cloud on or off with the kind and sign-in value it has (or, restoring, the saved ones), then reads it back.
    func setIPCWebCloud(enabled: Bool, saved: CameraFeatureBackup?, client: IPCWebClient) async throws -> CameraSetupOutcome {
        guard let cloud = try await ipcWebCloud(client) else { return .refused("the camera no longer shows this setting") }
        let wanted = enabled ? "1" : "0"
        let type = saved?.cloudType ?? cloud.type, code = saved?.cloudAuthcode ?? cloud.code
        if (cloud.enabled != "0") == enabled, type == cloud.type, code == cloud.code {
            return CameraSetupOutcome(succeeded: true, detail: "already \(enabled ? "on" : "off")")
        }
        let body = "<NetworkConfig><P2PConfig Enable=\"\(wanted)\" Type=\"\(IPCWebXML.escape(type))\" Authcode=\"\(IPCWebXML.escape(code))\"/></NetworkConfig>"
        try await client.write(Self.ipcCloudWrite, body: body)
        guard let after = try await ipcWebCloud(client) else { return .refused("the camera no longer shows this setting") }
        guard (after.enabled != "0") == enabled else { return .refused("the camera kept it \(enabled ? "off" : "on")") }
        log.info("Turned the maker's cloud \(enabled ? "on" : "off") through the camera's web API")
        return CameraSetupOutcome(succeeded: true, detail: "via web API")
    }
}

/// What `CameraSettingsService.ipcWeb()` found.
enum IPCWebAccess: Sendable {
    /// Not an ONVIF camera of the family (or credentials the API cannot take): the steps work as for any other camera.
    case none
    case speaks(IPCWebClient, IPCWebDevice)
    /// A camera of the family whose web API cannot be asked now (paused after a refusal, or no answer), with why: its clean picture, cloud
    /// and DNS steps are not possible now (its DNS reading is unreadable), and never go through ONVIF (whose answers these cameras get wrong).
    case unavailable(String)

    var isNone: Bool { if case .none = self { true } else { false } }
}
