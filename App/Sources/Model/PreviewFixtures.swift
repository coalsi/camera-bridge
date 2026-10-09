import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore

/// Discovery and probe answers for preview mode (`-previewEngine YES`) and SwiftUI previews, so the Add Camera wizard
/// can be walked through without networking. Hosts are RFC 5737 documentation addresses.
enum PreviewFixtures {
    static let discovered: [DiscoveredCamera] = [
        DiscoveredCamera(host: "192.0.2.31", name: "Porch", hardware: "DS-2CD2387G2-LU",
                         xAddrs: [URL(string: "http://192.0.2.31/onvif/device_service")].compactMap { $0 }),
        DiscoveredCamera(host: "192.0.2.32", name: "Reolink Video Doorbell", hardware: "Reolink Video Doorbell WiFi",
                         xAddrs: [URL(string: "http://192.0.2.32:8000/onvif/device_service")].compactMap { $0 }),
        DiscoveredCamera(host: "192.0.2.33", name: nil, hardware: "IPC-T5442T",
                         xAddrs: [URL(string: "http://192.0.2.33/onvif/device_service")].compactMap { $0 }),
    ]

    /// A plausible result for `vendor` (nil = auto-detect, which "finds" a Hikvision camera).
    static func probeResult(vendor: CameraVendor?, endpoint: CameraEndpoint, mainStreamURL: URL?, subStreamURL: URL?) -> CameraProbeResult {
        let host = endpoint.host
        func rtsp(_ path: String) -> URL? { URL(string: "rtsp://\(host):\(endpoint.rtspPort)\(path)") }

        switch vendor ?? .hikvision {
        case .hikvision:
            return CameraProbeResult(
                vendor: .hikvision, manufacturer: "Hikvision", model: "DS-2CD2387G2-LU", serialNumber: "DS-2CD2387G2-LU20240101AAWRK00000001",
                firmware: "V5.7.18 build 240110",
                mainStream: rtsp("/ISAPI/Streaming/channels/101").map {
                    StreamInfo(url: $0, videoCodec: .h264, width: 3840, height: 2160, fps: 20, audioCodec: .aac, audioSampleRate: 16_000, audioChannels: 1)
                },
                subStream: rtsp("/ISAPI/Streaming/channels/102").map { StreamInfo(url: $0, videoCodec: .h264, width: 640, height: 360, fps: 15) },
                capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .tamper, .dayNight, .digitalInput], twoWayAudio: true,
                                                 snapshotAPI: true, nightVisionControl: true))
        case .reolink:
            return CameraProbeResult(
                vendor: .reolink, manufacturer: "Reolink", model: "Reolink Video Doorbell WiFi", serialNumber: "192168100032", firmware: "v3.0.0.2356",
                mainStream: rtsp("/h264Preview_01_main").map {
                    StreamInfo(url: $0, videoCodec: .h264, width: 2560, height: 1920, fps: 15, audioCodec: .aac, audioSampleRate: 16_000, audioChannels: 1)
                },
                subStream: rtsp("/h264Preview_01_sub").map { StreamInfo(url: $0, videoCodec: .h264, width: 640, height: 480, fps: 10) },
                capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .animal, .package, .doorbell, .dayNight], twoWayAudio: true,
                                                 isDoorbell: true, snapshotAPI: true))
        case .onvif:
            return CameraProbeResult(
                vendor: .onvif, manufacturer: "Dahua", model: "IPC-T5442T", serialNumber: "7J0A1B2C3D4E5F6", firmware: "V2.840.0000000.3.R",
                mainStream: rtsp("/cam/realmonitor?channel=1&subtype=0").map { StreamInfo(url: $0, videoCodec: .h264, width: 2688, height: 1520, fps: 20) },
                subStream: rtsp("/cam/realmonitor?channel=1&subtype=1").map { StreamInfo(url: $0, videoCodec: .h264, width: 704, height: 480, fps: 15) },
                capabilities: CameraCapabilities(events: [.motion, .tamper, .digitalInput], snapshotAPI: true))
        case .rtsp:
            return CameraProbeResult(
                vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "",
                mainStream: mainStreamURL.map { StreamInfo(url: $0, videoCodec: .h264, width: 1920, height: 1080, fps: 25) },
                subStream: subStreamURL.map { StreamInfo(url: $0, videoCodec: .h264, width: 640, height: 360, fps: 10) })
        case .demo:
            return CameraProbeResult(vendor: .demo, manufacturer: "CameraBridge", model: "Demo Camera", serialNumber: "DEMO-0002", firmware: "1.0",
                                     capabilities: CameraCapabilities(events: [.motion]))
        case .amcrest:
            return CameraProbeResult(
                vendor: .amcrest, manufacturer: "Amcrest", model: "AD410", serialNumber: "AMC0123456789", firmware: "2.800.0000000.4.R",
                mainStream: rtsp("/cam/realmonitor?channel=1&subtype=0").map { StreamInfo(url: $0, videoCodec: .h264, width: 2560, height: 1920, fps: 20) },
                subStream: rtsp("/cam/realmonitor?channel=1&subtype=1").map { StreamInfo(url: $0, videoCodec: .h264, width: 640, height: 480, fps: 15) },
                capabilities: CameraCapabilities(events: [.motion, .person, .vehicle, .tamper, .audioAlarm, .doorbell], isDoorbell: true, snapshotAPI: true))
        case .doorbird:
            return CameraProbeResult(
                vendor: .doorbird, manufacturer: "DoorBird", model: "DoorBird D2101V", serialNumber: "1CCAE3700000", firmware: "000125",
                mainStream: rtsp("/mpeg/720p/media.amp").map { StreamInfo(url: $0, videoCodec: .h264, width: 1280, height: 720, fps: 12) },
                capabilities: CameraCapabilities(events: [.motion, .doorbell], isDoorbell: true, snapshotAPI: true))
        case .unifi, .go2rtc:
            return integrationProbeResult(vendor: vendor ?? .go2rtc, integration: IntegrationSettings(service: .other), endpoint: endpoint)
        }
    }

    /// The answer for a camera behind a service (preview mode).
    static func integrationProbeResult(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint) -> CameraProbeResult {
        let isDoorbell = integration.service == .ring || integration.details[IntegrationSettings.Key.deviceName]?.localizedCaseInsensitiveContains("door") == true
        let stream = URL(string: "rtsp://127.0.0.1:41002/cb-preview").map {
            StreamInfo(url: $0, videoCodec: .h264, width: 1920, height: 1080, fps: 15, audioCodec: .aac, audioSampleRate: 16_000, audioChannels: 1)
        }
        let events: Set<CameraEventKind> = vendor == .unifi ? [.motion, .person, .vehicle, .animal, .package, .doorbell] : []
        return CameraProbeResult(vendor: vendor, manufacturer: vendor == .unifi ? "Ubiquiti" : integration.service.displayName,
                                 model: integration.deviceName ?? "\(integration.service.displayName) camera", serialNumber: "PREVIEW-0003", firmware: "",
                                 mainStream: stream, capabilities: CameraCapabilities(events: events, isDoorbell: vendor == .unifi && isDoorbell,
                                                                                      snapshotAPI: vendor == .unifi))
    }

    /// A Protect console's cameras (preview mode).
    static let protectCameras = [UnifiProtectCamera(id: "preview-front", name: "Front Door", model: "UVC G4 Doorbell Pro", isConnected: true, isDoorbell: true),
                                 UnifiProtectCamera(id: "preview-yard", name: "Back Yard", model: "UVC G5 Bullet", isConnected: true, isDoorbell: false)]

    /// A plausible Camera Settings snapshot (preview mode and SwiftUI previews): one main and one sub H.264 profile
    /// with camera-reported option ranges, and imaging settings/options — enough to exercise the sheet's sliders,
    /// pickers and the HomeKit recommendation hint without a camera.
    static func cameraSettingsSnapshot(endpoint: CameraEndpoint, vendor: CameraVendor?, cameraName: String? = nil) -> CameraSettingsSnapshot {
        #if DEBUG
        // Screenshot states (`-previewEngine YES`): the Garage camera is set up badly for HomeKit Secure Video; with
        // `-demoLockedONVIF YES` the Driveway's ONVIF login is refused (Hikvision keeps ONVIF users apart from web accounts).
        if cameraName == "Garage" { return problematicSnapshot(endpoint: endpoint) }
        if cameraName == "Driveway", UserDefaults.standard.bool(forKey: "demoLockedONVIF") { return lockedSnapshot(endpoint: endpoint) }
        #endif
        guard vendor != .demo, vendor != .rtsp, vendor != .go2rtc, vendor != .unifi, vendor != .doorbird else {
            return CameraSettingsSnapshot(supportsONVIF: false, webPageURL: endpoint.httpURL)
        }
        let h264Options = CameraVideoEncoderOptions(
            encoding: "H264", resolutions: [CameraResolution(width: 2560, height: 1920), CameraResolution(width: 1920, height: 1080),
                                            CameraResolution(width: 1280, height: 720), CameraResolution(width: 640, height: 480)],
            frameRateRange: 1...30, bitrateRange: 32...8192, iFrameIntervalRange: 1...120, qualityRange: 0...10,
            h264ProfilesSupported: ["Baseline", "Main", "High"])
        let main = CameraVideoProfile(
            id: "main", name: "MainStream",
            settings: CameraVideoEncoderSettings(token: "main", name: "MainStream", sourceToken: "video0", encoding: "H264",
                                                 resolution: CameraResolution(width: 2560, height: 1920), frameRate: 20, encodingInterval: 1,
                                                 bitrate: 4096, iFrameInterval: 40, h264Profile: "High", quality: 6),
            options: [h264Options])
        let sub = CameraVideoProfile(
            id: "sub", name: "SubStream",
            settings: CameraVideoEncoderSettings(token: "sub", name: "SubStream", sourceToken: "video0", encoding: "H264",
                                                 resolution: CameraResolution(width: 640, height: 480), frameRate: 15, encodingInterval: 1,
                                                 bitrate: 512, iFrameInterval: 30, h264Profile: "Main", quality: 5),
            options: [h264Options])
        let imaging = CameraImagingSettings(brightness: 55, contrast: 60, saturation: 65, sharpness: 50, irCutMode: .auto,
                                            wideDynamicRangeEnabled: false, backlightCompensationEnabled: false)
        let imagingOptions = CameraImagingOptions(brightnessRange: 0...100, contrastRange: 0...100, saturationRange: 0...100,
                                                  sharpnessRange: 0...100, irCutModesSupported: CameraIRCutMode.allCases,
                                                  wideDynamicRangeSupported: true, backlightCompensationSupported: true)
        let device = CameraDeviceInfo(manufacturer: "Hikvision", model: "DS-2CD2387G2-LU", firmwareVersion: "V5.7.18 build 240110",
                                      serialNumber: "DS-2CD2387G2-LU20240101AAWRK00000001", hardwareID: "DS-2CD2387G2-LU")
        return CameraSettingsSnapshot(supportsONVIF: true, webPageURL: endpoint.httpURL, deviceInfo: device, videoSourceToken: "video0",
                                      mainProfile: main, subProfile: sub, imaging: imaging, imagingOptions: imagingOptions)
    }
}

#if DEBUG
extension PreviewFixtures {
    /// A camera that sends H.265 at 4K and 30 fps with a 16 Mbit/s bit rate and a long keyframe interval: every automatic fix applies.
    static func problematicSnapshot(endpoint: CameraEndpoint) -> CameraSettingsSnapshot {
        var snapshot = cameraSettingsSnapshot(endpoint: endpoint, vendor: .onvif)
        let h265Options = CameraVideoEncoderOptions(
            encoding: "H265", resolutions: [CameraResolution(width: 3840, height: 2160), CameraResolution(width: 2560, height: 1440),
                                            CameraResolution(width: 1920, height: 1080)],
            frameRateRange: 1...30, bitrateRange: 32...16384, iFrameIntervalRange: 1...150, qualityRange: 0...10, h264ProfilesSupported: [])
        if var main = snapshot.mainProfile {
            main.settings.encoding = "H265"
            main.settings.resolution = CameraResolution(width: 3840, height: 2160)
            main.settings.frameRate = 30
            main.settings.bitrate = 16_384
            main.settings.iFrameInterval = 150
            main.options = [h265Options, main.options.first].compactMap { $0 }
            snapshot.mainProfile = main
        }
        return snapshot
    }

    /// ONVIF answered but refused CameraBridge's login, which the camera will not accept again for a while.
    static func lockedSnapshot(endpoint: CameraEndpoint) -> CameraSettingsSnapshot {
        var snapshot = CameraSettingsSnapshot(supportsONVIF: false, webPageURL: URL(string: "http://\(endpoint.host):\(endpoint.httpPort)/"))
        snapshot.onvifLoginRejected = true
        snapshot.onvifLoginPausedUntil = Date().addingTimeInterval(25 * 60)
        return snapshot
    }
}
#endif

private extension CameraEndpoint {
    var httpURL: URL? { URL(string: "\(useHTTPS ? "https" : "http")://\(host):\(httpPort)/") }
}
