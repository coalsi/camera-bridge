import Foundation

/// The web API an ONVIF camera can have next to ONVIF, as Camera Bridge saw it at the camera's address since the camera last started in the
/// bridge: the IP camera web API (Jennov and other Anjvision cameras, docs/integrations/ip-camera-web-api.md) or the IPCamera Web family
/// (docs/integrations/ipcamera-web.md). Read from what their clients already learned (`IPCWebLatch`, `IPCamWebLatch`): nothing is sent to
/// the camera. The engine's "Change it by hand" help names the family's own menus with it (BridgeEngine `CameraFamily`).
public enum CameraWebAPIFamily: String, Sendable, Codable, CaseIterable {
    case ipcWebAPI, ipcamWeb

    /// The family the address of `endpoint` showed in this run; nil when none was seen (not one of them, or not asked yet).
    public static func seen(at endpoint: CameraEndpoint) -> CameraWebAPIFamily? {
        if IPCWebLatch.shared.isFamily(IPCWebLatch.key(endpoint)) { return .ipcWebAPI }
        if IPCamWebLatch.shared.isFamily(IPCamWebLatch.key(endpoint)) { return .ipcamWeb }
        return nil
    }
}
