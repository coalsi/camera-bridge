import CameraAdapters
import Foundation

/// The words of the Add Camera check for a camera that has no admin password yet, and for one found through its maker's own interface.
enum NotSetUpText {
    static let openLabel = "Open the camera’s web page"
    static let checkAgainLabel = "Check again"

    static func title(maker: String) -> String { "This \(maker) camera hasn’t been set up yet." }

    static let step = "This camera hasn’t been set up yet. Open its web page and choose an admin password (you type it twice), then come back and add it."

    static func resource(_ camera: NotSetUp, endpoint: CameraEndpoint) -> WebApp.NotSetUpResource {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        let scheme = endpoint.useHTTPS ? "https" : "http"
        let defaultPort = endpoint.useHTTPS ? 443 : 80
        let port = endpoint.httpPort == defaultPort ? "" : ":\(endpoint.httpPort)"
        return WebApp.NotSetUpResource(maker: camera.maker, title: title(maker: camera.maker), step: step, webPage: "\(scheme)://\(host)\(port)")
    }

    /// "Found Hikvision's own interface (ANNKE I91ET); using it for settings and security."
    static func ownInterface(vendor: CameraVendor, manufacturer: String, model: String) -> String {
        let maker = StatusText.vendor(vendor)
        let name = [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
        return "Found \(maker)’s own interface\(name.isEmpty ? "" : " (\(name))"); using it for settings and security."
    }
}
