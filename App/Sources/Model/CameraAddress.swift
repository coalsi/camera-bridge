import CameraAdapters
import Foundation

/// How a camera's address is shown next to its name (sidebar, camera page, menu): the host, plus the web port only when
/// it isn't the default for the scheme (80, or 443 with HTTPS).
enum CameraAddress {
    static func display(_ endpoint: CameraEndpoint) -> String {
        let host = endpoint.host.contains(":") && !endpoint.host.hasPrefix("[") ? "[\(endpoint.host)]" : endpoint.host   // IPv6
        let defaultPort = endpoint.useHTTPS ? 443 : 80
        return endpoint.httpPort == defaultPort ? host : "\(host):\(endpoint.httpPort)"
    }
}
