import BridgeSupport
import Foundation

/// Raw ONVIF media/imaging/device values as the camera reports them, before `CameraSettingsService` turns them into
/// `CameraSettingsSnapshot`. Kept close to the wire (strings/doubles, not an enum) because firmwares disagree on which
/// optional fields they send; `CameraSettingsService` is what applies defaults and validates ranges.
struct ONVIFVideoSource: Sendable, Equatable {
    var token: String
    var width: Int?
    var height: Int?
}

struct ONVIFVideoEncoderConfiguration: Sendable, Equatable {
    var token: String
    var name: String
    var useCount: Int?
    var encoding: String
    var width: Int?
    var height: Int?
    var quality: Double?
    var frameRateLimit: Double?
    var encodingInterval: Int?
    var bitrateLimit: Int?
    var govLength: Int?
    var h264Profile: String?
    var sourceToken: String?
}

struct ONVIFResolution: Sendable, Equatable {
    var width: Int
    var height: Int
}

struct ONVIFEncoderOptionGroup: Sendable, Equatable {
    var encoding: String   // "H264", "JPEG", "MPEG4"
    var resolutions: [ONVIFResolution]
    var frameRateRange: ClosedRange<Double>?
    var encodingIntervalRange: ClosedRange<Int>?
    var bitrateRange: ClosedRange<Int>?
    var govLengthRange: ClosedRange<Int>?
    var profilesSupported: [String]
}

struct ONVIFVideoEncoderOptions: Sendable, Equatable {
    var qualityRange: ClosedRange<Double>?
    var groups: [ONVIFEncoderOptionGroup]
}

struct ONVIFImagingSettings: Sendable, Equatable {
    var brightness: Double?
    var contrast: Double?
    var saturation: Double?
    var sharpness: Double?
    var irCutFilter: String?               // "ON" / "OFF" / "AUTO"
    var wideDynamicRangeEnabled: Bool?
    var backlightCompensationEnabled: Bool?
}

struct ONVIFImagingOptions: Sendable, Equatable {
    var brightnessRange: ClosedRange<Double>?
    var contrastRange: ClosedRange<Double>?
    var saturationRange: ClosedRange<Double>?
    var sharpnessRange: ClosedRange<Double>?
    var irCutFilterModes: [String]
    var wideDynamicRangeSupported: Bool
    var backlightCompensationSupported: Bool
}

/// A media profile with the parts `CameraSettingsService` needs that `ONVIFClient.profiles()` doesn't carry (the
/// encoder configuration's own token, and the profile's video source token, both required to call
/// `GetVideoEncoderConfigurationOptions` / `SetVideoEncoderConfiguration` / imaging requests precisely).
struct ONVIFMediaProfile: Sendable, Equatable {
    var token: String
    var name: String
    var videoEncoderConfiguration: ONVIFVideoEncoderConfiguration?
    var videoSourceToken: String?
}

extension ONVIFClient {
    static let imagingNamespace = "http://www.onvif.org/ver20/imaging/wsdl"

    /// Full media profiles (unlike `profiles()`, keeps the encoder configuration's token and the video source token).
    func mediaProfiles() async throws -> [ONVIFMediaProfile] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetProfiles/>", action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles")
        let response = try responseBody(envelope, "GetProfilesResponse")
        return response.children("Profiles").compactMap { profile in
            guard let token = profile.attribute("token") else { return nil }
            let videoEncoder = profile.child("VideoEncoderConfiguration").flatMap(Self.parseEncoderConfiguration)
            let sourceToken = profile.child("VideoSourceConfiguration")?.string("SourceToken")
            return ONVIFMediaProfile(token: token, name: profile.string("Name") ?? token, videoEncoderConfiguration: videoEncoder,
                                     videoSourceToken: sourceToken)
        }
    }

    func imagingServiceURL() async -> URL {
        if let url = try? await services()[Self.imagingNamespace] { return url }
        return await mediaServiceURL()
    }

    // MARK: Media: video sources & encoder configurations

    func videoSources() async throws -> [ONVIFVideoSource] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetVideoSources/>",
                                      action: "http://www.onvif.org/ver10/media/wsdl/GetVideoSources")
        let response = try responseBody(envelope, "GetVideoSourcesResponse")
        return response.children("VideoSources").compactMap { node in
            guard let token = node.attribute("token") else { return nil }
            return ONVIFVideoSource(token: token,
                                    width: CameraNumbers.dimension(node.string("Resolution", "Width")),
                                    height: CameraNumbers.dimension(node.string("Resolution", "Height")))
        }
    }

    func videoEncoderConfigurations() async throws -> [ONVIFVideoEncoderConfiguration] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetVideoEncoderConfigurations/>",
                                      action: "http://www.onvif.org/ver10/media/wsdl/GetVideoEncoderConfigurations")
        let response = try responseBody(envelope, "GetVideoEncoderConfigurationsResponse")
        return response.children("Configurations").compactMap(Self.parseEncoderConfiguration)
    }

    static func parseEncoderConfiguration(_ node: XMLTree) -> ONVIFVideoEncoderConfiguration? {
        guard let token = node.attribute("token") else { return nil }
        let rate = node.child("RateControl")
        let h264 = node.child("H264")
        return ONVIFVideoEncoderConfiguration(
            token: token, name: node.string("Name") ?? token, useCount: node.string("UseCount").flatMap(Int.init),
            encoding: node.string("Encoding") ?? "H264", width: CameraNumbers.dimension(node.string("Resolution", "Width")),
            height: CameraNumbers.dimension(node.string("Resolution", "Height")),
            quality: node.string("Quality").flatMap(Double.init),
            frameRateLimit: rate?.string("FrameRateLimit").flatMap(Double.init),
            encodingInterval: rate?.string("EncodingInterval").flatMap(Int.init),
            bitrateLimit: rate?.string("BitrateLimit").flatMap(Int.init),
            govLength: h264?.string("GovLength").flatMap(Int.init), h264Profile: h264?.string("H264Profile"),
            sourceToken: node.string("SourceToken"))
    }

    /// `configurationToken` or `profileToken` (at least one the camera understands) scopes the options to that
    /// configuration/profile; nil asks for the camera-wide ranges.
    func videoEncoderConfigurationOptions(configurationToken: String?, profileToken: String?) async throws -> ONVIFVideoEncoderOptions {
        var body = "<trt:GetVideoEncoderConfigurationOptions>"
        if let configurationToken { body += "<trt:ConfigurationToken>\(XMLTree.escape(configurationToken))</trt:ConfigurationToken>" }
        if let profileToken { body += "<trt:ProfileToken>\(XMLTree.escape(profileToken))</trt:ProfileToken>" }
        body += "</trt:GetVideoEncoderConfigurationOptions>"
        let envelope = try await call(await mediaServiceURL(), body: body,
                                      action: "http://www.onvif.org/ver10/media/wsdl/GetVideoEncoderConfigurationOptions")
        let options = try responseBody(envelope, "GetVideoEncoderConfigurationOptionsResponse").child("Options") ?? XMLTree(
            name: "Options", prefix: nil, namespaceURI: nil, attributes: [:], text: "", children: [])
        return Self.parseEncoderOptions(options)
    }

    static func parseEncoderOptions(_ options: XMLTree) -> ONVIFVideoEncoderOptions {
        func range(_ node: XMLTree?) -> ClosedRange<Double>? {
            guard let node, let min = node.string("Min").flatMap(Double.init), let max = node.string("Max").flatMap(Double.init), min <= max else {
                return nil
            }
            return min...max
        }
        func intRange(_ node: XMLTree?) -> ClosedRange<Int>? {
            guard let node, let min = node.string("Min").flatMap(Int.init), let max = node.string("Max").flatMap(Int.init), min <= max else {
                return nil
            }
            return min...max
        }
        func resolutions(_ node: XMLTree?) -> [ONVIFResolution] {
            (node?.children("ResolutionsAvailable") ?? []).compactMap { res in
                guard let w = CameraNumbers.dimension(res.string("Width")), let h = CameraNumbers.dimension(res.string("Height")) else { return nil }
                return ONVIFResolution(width: w, height: h)
            }
        }
        var groups: [ONVIFEncoderOptionGroup] = []
        for (name, encoding) in [("H264", "H264"), ("JPEG", "JPEG"), ("MPEG4", "MPEG4")] {
            guard let node = options.child(name) else { continue }
            groups.append(ONVIFEncoderOptionGroup(
                encoding: encoding, resolutions: resolutions(node), frameRateRange: range(node.child("FrameRateRange")),
                encodingIntervalRange: intRange(node.child("EncodingIntervalRange")), bitrateRange: intRange(node.child("BitrateRange")),
                govLengthRange: intRange(node.child("GovLengthRange")),
                profilesSupported: node.children("H264ProfilesSupported").map { $0.text }.filter { !$0.isEmpty }))
        }
        return ONVIFVideoEncoderOptions(qualityRange: range(options.child("QualityRange")), groups: groups)
    }

    /// `ForcePersistence` is always sent true: the camera is asked to keep the change across its own restart.
    func setVideoEncoderConfiguration(_ configuration: ONVIFVideoEncoderConfiguration) async throws {
        var body = "<trt:SetVideoEncoderConfiguration><trt:Configuration token=\"\(XMLTree.escape(configuration.token))\">"
        body += "<tt:Name>\(XMLTree.escape(configuration.name))</tt:Name>"
        if let useCount = configuration.useCount { body += "<tt:UseCount>\(useCount)</tt:UseCount>" }
        if let sourceToken = configuration.sourceToken { body += "<tt:SourceToken>\(XMLTree.escape(sourceToken))</tt:SourceToken>" }
        body += "<tt:Encoding>\(XMLTree.escape(configuration.encoding))</tt:Encoding>"
        if let width = configuration.width, let height = configuration.height {
            body += "<tt:Resolution><tt:Width>\(width)</tt:Width><tt:Height>\(height)</tt:Height></tt:Resolution>"
        }
        if let quality = configuration.quality { body += "<tt:Quality>\(quality)</tt:Quality>" }
        body += "<tt:RateControl>"
        body += "<tt:FrameRateLimit>\(Int(configuration.frameRateLimit ?? 15))</tt:FrameRateLimit>"
        body += "<tt:EncodingInterval>\(configuration.encodingInterval ?? 1)</tt:EncodingInterval>"
        body += "<tt:BitrateLimit>\(configuration.bitrateLimit ?? 2048)</tt:BitrateLimit>"
        body += "</tt:RateControl>"
        if configuration.encoding.uppercased() == "H264" {
            body += "<tt:H264><tt:GovLength>\(configuration.govLength ?? 30)</tt:GovLength>"
            body += "<tt:H264Profile>\(XMLTree.escape(configuration.h264Profile ?? "Main"))</tt:H264Profile></tt:H264>"
        }
        body += "</trt:Configuration><trt:ForcePersistence>true</trt:ForcePersistence></trt:SetVideoEncoderConfiguration>"
        _ = try await call(await mediaServiceURL(), body: body, action: "http://www.onvif.org/ver10/media/wsdl/SetVideoEncoderConfiguration")
    }

    /// The camera's own `Configuration` element for encoder `token`, every child intact (multicast, session timeout, …),
    /// from `GetVideoEncoderConfigurations`.
    func rawVideoEncoderConfiguration(token: String) async throws -> XMLTree {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetVideoEncoderConfigurations/>",
                                      action: "http://www.onvif.org/ver10/media/wsdl/GetVideoEncoderConfigurations")
        let response = try responseBody(envelope, "GetVideoEncoderConfigurationsResponse")
        guard let node = response.children("Configurations").first(where: { $0.attribute("token") == token }) else {
            throw CameraAdapterError.invalidResponse("no video encoder configuration \(token)")
        }
        return node
    }

    /// The values `EncoderValues` tracks in an encoder `Configuration` element (keyframe interval from `H264` or `H265`).
    static func encoderValues(_ node: XMLTree) -> EncoderValues {
        let codecNode = node.child("H264") ?? node.child("H265")
        return EncoderValues(
            codec: node.string("Encoding").map(EncoderValues.normalizedCodec),
            width: CameraNumbers.dimension(node.string("Resolution", "Width")), height: CameraNumbers.dimension(node.string("Resolution", "Height")),
            frameRate: node.string("RateControl", "FrameRateLimit").flatMap(Double.init),
            bitrate: node.string("RateControl", "BitrateLimit").flatMap(Int.init),
            govLength: codecNode?.string("GovLength").flatMap(Int.init), h264Profile: codecNode?.string("H264Profile"))
    }

    /// `SetVideoEncoderConfiguration` carrying `node` (the camera's own configuration, as `rawVideoEncoderConfiguration`
    /// returned it) back with only `changes` altered: every element the camera reported (quality, multicast, session
    /// timeout, …) is preserved. A changed field the camera's configuration has no element for is not sent.
    func setVideoEncoderConfiguration(preserving node: XMLTree, changes: EncoderValues, forcePersistence: Bool) async throws {
        var edited = node
        func set(_ path: [String], _ value: String?) {
            guard let value, let updated = edited.setting(path: path, to: value) else { return }
            edited = updated
        }
        set(["Encoding"], changes.codec)
        set(["Resolution", "Width"], changes.width.map(String.init))
        set(["Resolution", "Height"], changes.height.map(String.init))
        set(["RateControl", "FrameRateLimit"], changes.frameRate.map { String(Int($0.rounded())) })
        set(["RateControl", "BitrateLimit"], changes.bitrate.map(String.init))
        let codecElement = node.child("H264") != nil ? "H264" : "H265"
        set([codecElement, "GovLength"], changes.govLength.map(String.init))
        set([codecElement, "H264Profile"], changes.h264Profile)
        var body = "<trt:SetVideoEncoderConfiguration><trt:Configuration"
        for (key, value) in edited.attributes.sorted(by: { $0.key < $1.key }) { body += " \(key)=\"\(XMLTree.escape(value))\"" }
        body += ">" + edited.children.map { $0.serialized() }.joined() + "</trt:Configuration>"
        body += "<trt:ForcePersistence>\(forcePersistence)</trt:ForcePersistence></trt:SetVideoEncoderConfiguration>"
        _ = try await call(await mediaServiceURL(), body: body, action: "http://www.onvif.org/ver10/media/wsdl/SetVideoEncoderConfiguration")
    }

    // MARK: Imaging

    func imagingSettings(videoSourceToken: String) async throws -> ONVIFImagingSettings {
        let body = "<timg:GetImagingSettings><timg:VideoSourceToken>\(XMLTree.escape(videoSourceToken))</timg:VideoSourceToken></timg:GetImagingSettings>"
        let envelope = try await call(await imagingServiceURL(), body: body,
                                      action: "http://www.onvif.org/ver20/imaging/wsdl/GetImagingSettings")
        let settings = try responseBody(envelope, "GetImagingSettingsResponse").child("ImagingSettings") ?? XMLTree(
            name: "ImagingSettings", prefix: nil, namespaceURI: nil, attributes: [:], text: "", children: [])
        return Self.parseImagingSettings(settings)
    }

    static func parseImagingSettings(_ node: XMLTree) -> ONVIFImagingSettings {
        func boolMode(_ element: XMLTree?) -> Bool? {
            guard let mode = element?.string("Mode") else { return nil }
            return mode.uppercased() == "ON"
        }
        return ONVIFImagingSettings(
            brightness: node.string("Brightness").flatMap(Double.init), contrast: node.string("Contrast").flatMap(Double.init),
            saturation: node.string("ColorSaturation").flatMap(Double.init), sharpness: node.string("Sharpness").flatMap(Double.init),
            irCutFilter: node.string("IrCutFilter")?.uppercased(), wideDynamicRangeEnabled: boolMode(node.child("WideDynamicRange")),
            backlightCompensationEnabled: boolMode(node.child("BacklightCompensation")))
    }

    func imagingOptions(videoSourceToken: String) async throws -> ONVIFImagingOptions {
        let body = "<timg:GetOptions><timg:VideoSourceToken>\(XMLTree.escape(videoSourceToken))</timg:VideoSourceToken></timg:GetOptions>"
        let envelope = try await call(await imagingServiceURL(), body: body, action: "http://www.onvif.org/ver20/imaging/wsdl/GetOptions")
        let options = try responseBody(envelope, "GetOptionsResponse").child("ImagingOptions") ?? XMLTree(
            name: "ImagingOptions", prefix: nil, namespaceURI: nil, attributes: [:], text: "", children: [])
        return Self.parseImagingOptions(options)
    }

    static func parseImagingOptions(_ node: XMLTree) -> ONVIFImagingOptions {
        func range(_ child: String) -> ClosedRange<Double>? {
            guard let element = node.child(child), let min = element.string("Min").flatMap(Double.init),
                  let max = element.string("Max").flatMap(Double.init), min <= max else { return nil }
            return min...max
        }
        // Camera firmwares disagree on whether the modes are sibling `<IrCutFilterModes>text</IrCutFilterModes>`
        // elements or one `<IrCutFilterModes>` with `<Mode>` children; accept either.
        var irModes = node.children("IrCutFilterModes").map { $0.text.uppercased() }.filter { !$0.isEmpty }
        if irModes.isEmpty, let container = node.child("IrCutFilterModes") {
            irModes = container.children.map { $0.text.uppercased() }.filter { !$0.isEmpty }
        }
        return ONVIFImagingOptions(
            brightnessRange: range("Brightness"), contrastRange: range("Contrast"), saturationRange: range("ColorSaturation"),
            sharpnessRange: range("Sharpness"), irCutFilterModes: irModes,
            wideDynamicRangeSupported: node.child("WideDynamicRange")?.child("Mode") != nil,
            backlightCompensationSupported: node.child("BacklightCompensation")?.child("Mode") != nil)
    }

    func setImagingSettings(videoSourceToken: String, settings: ONVIFImagingSettings) async throws {
        var body = "<timg:SetImagingSettings><timg:VideoSourceToken>\(XMLTree.escape(videoSourceToken))</timg:VideoSourceToken>"
        body += "<timg:ImagingSettings>"
        if let brightness = settings.brightness { body += "<tt:Brightness>\(brightness)</tt:Brightness>" }
        if let contrast = settings.contrast { body += "<tt:Contrast>\(contrast)</tt:Contrast>" }
        if let saturation = settings.saturation { body += "<tt:ColorSaturation>\(saturation)</tt:ColorSaturation>" }
        if let sharpness = settings.sharpness { body += "<tt:Sharpness>\(sharpness)</tt:Sharpness>" }
        if let irCutFilter = settings.irCutFilter { body += "<tt:IrCutFilter>\(XMLTree.escape(irCutFilter))</tt:IrCutFilter>" }
        if let wdr = settings.wideDynamicRangeEnabled {
            body += "<tt:WideDynamicRange><tt:Mode>\(wdr ? "ON" : "OFF")</tt:Mode></tt:WideDynamicRange>"
        }
        if let backlight = settings.backlightCompensationEnabled {
            body += "<tt:BacklightCompensation><tt:Mode>\(backlight ? "ON" : "OFF")</tt:Mode></tt:BacklightCompensation>"
        }
        body += "</timg:ImagingSettings><timg:ForcePersistence>true</timg:ForcePersistence></timg:SetImagingSettings>"
        _ = try await call(await imagingServiceURL(), body: body, action: "http://www.onvif.org/ver20/imaging/wsdl/SetImagingSettings")
    }

    // MARK: Device

    func systemReboot() async throws {
        _ = try await call(deviceServiceURL, body: "<tds:SystemReboot/>", action: "http://www.onvif.org/ver10/device/wsdl/SystemReboot")
    }
}
