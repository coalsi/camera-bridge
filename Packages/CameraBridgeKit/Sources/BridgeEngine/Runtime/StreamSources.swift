import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import RTSP

/// A synthetic stream of the demo camera.
struct DemoStream: Sendable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var keyframeInterval: Duration
}

/// Where a camera's video comes from (plan W3-1 item 1): RTSP main and sub streams (URLs from the configuration, the
/// vendor's defaults, or the driver's probe), Reolink's HTTP-FLV as the fallback, the demo camera's synthetic streams.
enum StreamSources {
    struct URLs: Sendable, Equatable {
        var main: URL?
        var sub: URL?
    }

    /// Configured URLs, else the vendor's well-known paths: Hikvision ISAPI channels 101 / 102, Reolink
    /// `h264Preview_01_main|sub`. ONVIF and plain RTSP cameras have none (ONVIF asks the camera: `CameraDriver.probe()`), nor do go2rtc cameras (the helper's port is
    /// picked at run time: `Go2RTCDriver.probe()` returns the address).
    static func urls(for camera: CameraConfiguration) -> URLs {
        var urls = URLs(main: camera.mainStreamURL, sub: camera.subStreamURL)
        switch camera.vendor {
        case .hikvision:
            if urls.main == nil { urls.main = rtspURL(camera.endpoint, path: "/ISAPI/Streaming/channels/101") }
            if urls.sub == nil, camera.mainStreamURL == nil { urls.sub = rtspURL(camera.endpoint, path: "/ISAPI/Streaming/channels/102") }
        case .reolink:
            if urls.main == nil { urls.main = ReolinkStreamURLs.rtsp(endpoint: camera.endpoint, main: true) }
            if urls.sub == nil, camera.mainStreamURL == nil { urls.sub = ReolinkStreamURLs.rtsp(endpoint: camera.endpoint, main: false) }
        case .amcrest:
            if urls.main == nil { urls.main = rtspURL(camera.endpoint, path: AmcrestRTSP.path(channel: 1, sub: false)) }
            if urls.sub == nil, camera.mainStreamURL == nil { urls.sub = rtspURL(camera.endpoint, path: AmcrestRTSP.path(channel: 1, sub: true)) }
        case .doorbird:
            if urls.main == nil { urls.main = rtspURL(camera.endpoint, path: DoorBirdRTSP.path) }
        case .onvif, .rtsp, .demo, .go2rtc, .unifi:
            break
        }
        return urls
    }

    /// `rtsp://host:port/path` (IPv6 hosts in brackets).
    static func rtspURL(_ endpoint: CameraEndpoint, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = endpoint.host.contains(":") && !endpoint.host.hasPrefix("[") ? "[\(endpoint.host)]" : endpoint.host
        components.port = endpoint.rtspPort
        components.path = path
        return components.url
    }

    static func rtsp(url: URL, credentials: HTTPCredentials?, displayName: String, cameraID: UUID, transport: any NetworkTransport)
        -> IngestSupervisor.Source {
        IngestSupervisor.Source(label: "RTSP") {
            RTSPMediaSource(configuration: rtspConfiguration(url: url, credentials: credentials, cameraID: cameraID), displayName: displayName,
                            transport: transport)
        }
    }

    /// A camera's RTSP session: its log lines carry the camera's ID (they show in the camera's own log).
    static func rtspConfiguration(url: URL, credentials: HTTPCredentials?, cameraID: UUID) -> RTSPConfiguration {
        var configuration = RTSPConfiguration(url: url, credentials: credentials)
        configuration.cameraID = cameraID
        return configuration
    }

    /// Reolink's HTTP-FLV stream (credentials go in its URL, which is therefore never logged or stored).
    static func reolinkFLV(camera: CameraConfiguration, credentials: HTTPCredentials?, main: Bool, displayName: String) -> IngestSupervisor.Source? {
        guard camera.vendor == .reolink, let url = ReolinkStreamURLs.flv(endpoint: camera.endpoint, main: main, credentials: credentials) else { return nil }
        let cameraID = camera.id
        return IngestSupervisor.Source(label: "HTTP-FLV") {
            HTTPFLVMediaSource(url: url, credentials: nil, displayName: displayName, timeout: .seconds(10), cameraID: cameraID)
        }
    }

    /// The demo camera: `MediaCodecs.makeSyntheticSource` (moving pattern, AAC 32 kHz tone on the main stream).
    static func demo(_ stream: DemoStream, codecs: any MediaCodecs, displayName: String, audio: Bool) -> IngestSupervisor.Source {
        IngestSupervisor.Source(label: "Demo") {
            codecs.makeSyntheticSource(displayName: displayName, width: stream.width, height: stream.height, fps: stream.fps,
                                       keyframeInterval: stream.keyframeInterval, audio: audio ? .aac : nil, audioSampleRate: 32_000)
        }
    }

    /// "H.264 1920×1080 · 20 fps".
    static func summary(_ format: VideoFormat?, frameRate: Double?) -> String? {
        guard let format else { return nil }
        let codec = format.codec == .h264 ? "H.264" : "H.265"
        var text = "\(codec) \(format.width)×\(format.height)"
        if let frameRate, frameRate.isFinite, frameRate > 0 { text += " · \(Int(frameRate.rounded())) fps" }
        return text
    }
}
