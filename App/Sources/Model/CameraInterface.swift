import BridgeEngine
import CameraAdapters
import Foundation

extension CameraConfiguration {
    /// Whether the camera has an interface of its own on the network to read settings, readiness and clock from (ONVIF or a
    /// vendor API). The demo camera has none, a cloud camera is served by the helper on this Mac, and a UniFi Protect camera is
    /// reached through the console.
    var hasCameraInterface: Bool {
        switch vendor {
        case .demo, .go2rtc, .unifi: false
        case .hikvision, .reolink, .onvif, .rtsp, .amcrest, .doorbird: true
        }
    }

    /// The camera's address as people read it: the host, or the service for a cloud camera (whose address is the helper's).
    var displayAddress: String {
        if vendor == .go2rtc { return integration?.service.displayName ?? String(localized: "Cloud camera") }
        return CameraAddress.display(endpoint)
    }
}
