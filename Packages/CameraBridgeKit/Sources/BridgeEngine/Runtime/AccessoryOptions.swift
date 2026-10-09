import CameraAdapters
import Foundation
import HAP
import HAPCamera

/// The HAP camera options of one camera (plan W3-1 item 2, integration brief §5.1, spec §5).
///
/// Recording resolutions are frozen per camera: 1280×720 and 1920×1080, plus 1280×960 and 1600×1200 for 4:3 sources
/// (the hub's selection is only kept while the Supported*RecordingConfiguration values stay the same). The aspect is
/// stored in the camera's HAP state (`frozenKey`) the first time a picture shows it — or, without a picture, once a
/// controller pairs with what was advertised — and read back on every later start. Live resolutions follow the source
/// (4K and 1440p only when the camera delivers them, 4:3 sizes for 4:3 sources) and may change freely: the main
/// stream's picture size is remembered (`sourceSizeKey`) so a start before the stream delivers a picture still offers
/// the source's sizes.
enum AccessoryOptions {
    enum Aspect: String, Codable, Sendable, Equatable {
        /// 16:9 and wider.
        case wide
        /// 4:3, 5:4 and similar (width / height below 1.5).
        case standard

        init?(width: Int, height: Int) {
            guard width > 0, height > 0 else { return nil }
            self = Double(width) / Double(height) < 1.5 ? .standard : .wide
        }
    }

    /// `HAPPersistentState.extras` key of the frozen recording options.
    static let frozenKey = "cameraBridge.recordingOptions"

    private struct Frozen: Codable {
        var aspect: Aspect
    }

    /// `sourceWidth`/`sourceHeight`: the main stream's picture size, when known, used to add the camera's own native
    /// resolution class on top of the frozen base sizes (docs/CONTRACT_CHANGES.md 2026-10-01) — 2560×1440 and 3840×2160
    /// for 16:9 sources that large, 2048×1536 for 4:3 sources that large. Changing this list changes a hash the hub uses
    /// to decide whether to re-fetch the options; the UI warns that changing it may need recording re-enabled in Home.
    static func recordingResolutions(aspect: Aspect, sourceWidth: Int? = nil, sourceHeight: Int? = nil) -> [VideoResolution] {
        let wide = [VideoResolution(1280, 720, 30), VideoResolution(1920, 1080, 30)]
        let height = sourceHeight ?? 0
        switch aspect {
        case .wide:
            var result = wide
            if height >= 2160 { result.append(VideoResolution(3840, 2160, 30)) }
            if height >= 1440 { result.append(VideoResolution(2560, 1440, 30)) }
            return result
        case .standard:
            var result = wide + [VideoResolution(1280, 960, 30), VideoResolution(1600, 1200, 30)]
            if height >= 1536 { result.append(VideoResolution(2048, 1536, 30)) }
            return result
        }
    }

    /// Integration brief §5.1's list (largest first): 4K and 1440p only for sources that tall, 4:3 sizes for 4:3 sources,
    /// always 1080p down to the Watch's 320×240 at 15 fps.
    static func streamingResolutions(sourceWidth: Int?, sourceHeight: Int?) -> [VideoResolution] {
        let height = sourceHeight ?? 0
        var result: [VideoResolution] = []
        if height >= 2160 { result.append(VideoResolution(3840, 2160, 30)) }
        if height >= 1440 { result.append(VideoResolution(2560, 1440, 30)) }
        let standard = sourceWidth.flatMap { width in Aspect(width: width, height: height) } == .standard
        if standard { result.append(VideoResolution(1600, 1200, 30)) }
        result.append(VideoResolution(1920, 1080, 30))
        if standard { result.append(VideoResolution(1280, 960, 30)) }
        result.append(VideoResolution(1280, 720, 30))
        if standard { result.append(VideoResolution(1024, 768, 30)) }
        result.append(VideoResolution(960, 540, 30))
        if standard { result.append(VideoResolution(640, 480, 30)) }
        result.append(VideoResolution(640, 360, 30))
        result.append(VideoResolution(320, 240, 15))
        return result
    }

    /// The frozen aspect in `store`'s HAP state, nil when none was stored (or it cannot be read).
    static func frozenAspect(in store: any HAPStore) throws -> Aspect? {
        guard let data = try store.loadState()?.extras[frozenKey] else { return nil }
        return (try? JSONDecoder().decode(Frozen.self, from: data))?.aspect
    }

    static func encodeFrozen(_ aspect: Aspect) throws -> Data {
        try JSONEncoder().encode(Frozen(aspect: aspect))
    }

    /// `HAPPersistentState.extras` key of the main stream's last known picture size.
    static let sourceSizeKey = "cameraBridge.sourceSize"

    /// A main-stream picture size.
    struct SourceSize: Codable, Sendable, Equatable {
        var width: Int
        var height: Int

        var isPlausible: Bool { (1...16_384).contains(width) && (1...16_384).contains(height) }
        var aspect: Aspect? { Aspect(width: width, height: height) }
    }

    /// The remembered picture size in `store`'s HAP state, nil when none (or an implausible one) was stored.
    static func sourceSize(in store: any HAPStore) -> SourceSize? {
        guard let data = (try? store.loadState())?.extras[sourceSizeKey],
              let size = try? JSONDecoder().decode(SourceSize.self, from: data), size.isPlausible else { return nil }
        return size
    }

    static func encode(_ size: SourceSize) throws -> Data {
        try JSONEncoder().encode(size)
    }

    /// Two stream services (two viewers), Opus-only live audio, AES_CM_128 SRTP, Main profile levels 3.1–4.0; HKSV with a
    /// 4 s prebuffer and 4 s fragments, Baseline/Main/High, AAC-LC 32 kHz mono. Two-way audio when the user enabled it
    /// and the camera has a talkback path; doorbells publish the Doorbell service.
    static func controllerConfiguration(for camera: CameraConfiguration, aspect: Aspect, sourceWidth: Int?, sourceHeight: Int?,
                                        talkback: Bool) -> CameraControllerConfiguration {
        let streaming = CameraStreamingOptions(resolutions: streamingResolutions(sourceWidth: sourceWidth, sourceHeight: sourceHeight),
                                               twoWayAudio: camera.twoWayAudio && talkback)
        let recording = CameraRecordingOptions(prebufferLengthMs: 4000, fragmentLengthMs: 4000,
                                               resolutions: recordingResolutions(aspect: aspect, sourceWidth: sourceWidth, sourceHeight: sourceHeight))
        return CameraControllerConfiguration(streamCount: 2, streaming: streaming, recording: recording, isDoorbell: camera.kind == .doorbell)
    }

    /// AccessoryInformation for the camera: a Home-safe name ("Camera" when nothing is left), the probed device info with
    /// vendor fallbacks, a serial number (the camera id when unknown) and a numeric firmware revision ("1.0" when none).
    static func accessoryInfo(for camera: CameraConfiguration) -> AccessoryInfo {
        let name = SensorsBridge.homeSafe(String(camera.name.prefix(SensorsBridge.maximumNameLength)))
        let (vendorName, vendorModel) = vendorDefaults(camera.vendor)
        let manufacturer = camera.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = camera.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = camera.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccessoryInfo(name: name.isEmpty ? "Camera" : name, manufacturer: String((manufacturer.isEmpty ? vendorName : manufacturer).prefix(64)),
                             model: String((model.isEmpty ? vendorModel : model).prefix(64)),
                             serialNumber: String((serial.isEmpty ? camera.id.uuidString : serial).prefix(64)),
                             firmwareRevision: firmwareRevision(camera.firmware))
    }

    /// "x[.y[.z]]" from the first number group of a vendor firmware string ("V5.7.15 build 230412" → "5.7.15").
    static func firmwareRevision(_ text: String) -> String {
        func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
        guard let start = text.firstIndex(where: isDigit) else { return "1.0" }
        var parts: [String] = []
        var current = ""
        for character in text[start...] {
            if isDigit(character) {
                current.append(character)
            } else if character == ".", !current.isEmpty {
                parts.append(current)
                current = ""
                if parts.count == 3 { break }
            } else {
                break   // "2.800.00AC" stops at the letter after the digits
            }
        }
        if !current.isEmpty, parts.count < 3 { parts.append(current) }
        let numbers = parts.prefix(3).compactMap { UInt32($0.prefix(9)) }.map(String.init)
        guard !numbers.isEmpty else { return "1.0" }
        return numbers.count == 1 ? numbers[0] + ".0" : numbers.joined(separator: ".")
    }

    private static func vendorDefaults(_ vendor: CameraVendor) -> (manufacturer: String, model: String) {
        switch vendor {
        case .hikvision: ("Hikvision", "Hikvision Camera")
        case .reolink: ("Reolink", "Reolink Camera")
        case .onvif: ("ONVIF", "ONVIF Camera")
        case .rtsp: ("Generic", "RTSP Camera")
        case .go2rtc: ("Generic", "Camera")
        case .amcrest: ("Amcrest", "Amcrest Camera")
        case .unifi: ("Ubiquiti", "UniFi Protect Camera")
        case .doorbird: ("DoorBird", "DoorBird")
        case .demo: ("CameraBridge", "Demo Camera")
        }
    }
}
