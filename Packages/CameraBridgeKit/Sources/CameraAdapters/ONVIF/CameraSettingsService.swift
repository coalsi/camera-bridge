import BridgeSupport
import Foundation

/// A video resolution a camera's encoder can be set to.
public struct CameraResolution: Sendable, Equatable, Codable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// IR-cut filter (day/night switching) mode.
public enum CameraIRCutMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case on = "ON"
    case off = "OFF"
    case auto = "AUTO"
    public var id: String { rawValue }
}

/// One stream's encoder settings (resolution, frame rate, bitrate, GOP, profile): the editable part of a video
/// profile. `token` is the ONVIF video encoder configuration token this was read from / is applied to.
public struct CameraVideoEncoderSettings: Sendable, Equatable, Codable {
    public var token: String
    public var name: String
    public var sourceToken: String?
    /// "H264", "H265"/"HEVC", "JPEG", "MPEG4".
    public var encoding: String
    public var resolution: CameraResolution?
    public var frameRate: Double?
    /// Frames per encoded picture (1 = every frame); HomeKit recording wants this at 1.
    public var encodingInterval: Int?
    /// Kbit/s.
    public var bitrate: Int?
    /// I-frame interval in pictures (ONVIF `H264.GovLength`).
    public var iFrameInterval: Int?
    public var h264Profile: String?
    public var quality: Double?

    public init(token: String, name: String, sourceToken: String? = nil, encoding: String, resolution: CameraResolution? = nil,
                frameRate: Double? = nil, encodingInterval: Int? = nil, bitrate: Int? = nil, iFrameInterval: Int? = nil,
                h264Profile: String? = nil, quality: Double? = nil) {
        self.token = token
        self.name = name
        self.sourceToken = sourceToken
        self.encoding = encoding
        self.resolution = resolution
        self.frameRate = frameRate
        self.encodingInterval = encodingInterval
        self.bitrate = bitrate
        self.iFrameInterval = iFrameInterval
        self.h264Profile = h264Profile
        self.quality = quality
    }

    /// Whether this setting is recommended for HomeKit Secure Video recording: H.264, an I-frame interval of at most
    /// 4 seconds and around twice the frame rate, no smart/"adaptive" codec switching (ONVIF has no such flag to
    /// check — this only validates what it can).
    public var isRecommendedForHomeKit: Bool {
        guard encoding.uppercased() == "H264", let fps = frameRate, fps > 0, let gov = iFrameInterval else { return false }
        let seconds = Double(gov) / fps
        let target = max(1, Int((fps * 2).rounded()))
        return seconds <= 4 && abs(gov - target) <= max(2, target / 4)
    }
}

/// The bounds a camera reports for one encoding (`CameraVideoEncoderSettings.encoding`) on a video encoder
/// configuration: every field the UI should clamp sliders/pickers to.
public struct CameraVideoEncoderOptions: Sendable, Equatable, Codable {
    public var encoding: String
    public var resolutions: [CameraResolution]
    public var frameRateRange: ClosedRange<Double>?
    public var bitrateRange: ClosedRange<Int>?
    public var iFrameIntervalRange: ClosedRange<Int>?
    public var qualityRange: ClosedRange<Double>?
    public var h264ProfilesSupported: [String]

    public init(encoding: String, resolutions: [CameraResolution] = [], frameRateRange: ClosedRange<Double>? = nil,
                bitrateRange: ClosedRange<Int>? = nil, iFrameIntervalRange: ClosedRange<Int>? = nil, qualityRange: ClosedRange<Double>? = nil,
                h264ProfilesSupported: [String] = []) {
        self.encoding = encoding
        self.resolutions = resolutions
        self.frameRateRange = frameRateRange
        self.bitrateRange = bitrateRange
        self.iFrameIntervalRange = iFrameIntervalRange
        self.qualityRange = qualityRange
        self.h264ProfilesSupported = h264ProfilesSupported
    }
}

/// A stream profile (main or sub) with its current encoder settings and the options the camera reports for each
/// encoding it offers (usually just H.264, sometimes also JPEG snapshots or H.265).
public struct CameraVideoProfile: Sendable, Equatable, Codable, Identifiable {
    public var id: String   // ONVIF media profile token
    public var name: String
    public var settings: CameraVideoEncoderSettings
    public var options: [CameraVideoEncoderOptions]

    public init(id: String, name: String, settings: CameraVideoEncoderSettings, options: [CameraVideoEncoderOptions]) {
        self.id = id
        self.name = name
        self.settings = settings
        self.options = options
    }

    /// The options for `settings.encoding`, if the camera reported any.
    public var currentEncodingOptions: CameraVideoEncoderOptions? {
        options.first { $0.encoding.caseInsensitiveCompare(settings.encoding) == .orderedSame }
    }
}

/// Image-quality controls (ONVIF Imaging service): brightness/contrast/saturation/sharpness and the IR-cut filter
/// / WDR / backlight toggles a camera offers.
public struct CameraImagingSettings: Sendable, Equatable, Codable {
    public var brightness: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var sharpness: Double?
    public var irCutMode: CameraIRCutMode?
    public var wideDynamicRangeEnabled: Bool?
    public var backlightCompensationEnabled: Bool?

    public init(brightness: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, sharpness: Double? = nil,
                irCutMode: CameraIRCutMode? = nil, wideDynamicRangeEnabled: Bool? = nil, backlightCompensationEnabled: Bool? = nil) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.sharpness = sharpness
        self.irCutMode = irCutMode
        self.wideDynamicRangeEnabled = wideDynamicRangeEnabled
        self.backlightCompensationEnabled = backlightCompensationEnabled
    }
}

public struct CameraImagingOptions: Sendable, Equatable, Codable {
    public var brightnessRange: ClosedRange<Double>?
    public var contrastRange: ClosedRange<Double>?
    public var saturationRange: ClosedRange<Double>?
    public var sharpnessRange: ClosedRange<Double>?
    public var irCutModesSupported: [CameraIRCutMode]
    public var wideDynamicRangeSupported: Bool
    public var backlightCompensationSupported: Bool

    public init(brightnessRange: ClosedRange<Double>? = nil, contrastRange: ClosedRange<Double>? = nil,
                saturationRange: ClosedRange<Double>? = nil, sharpnessRange: ClosedRange<Double>? = nil,
                irCutModesSupported: [CameraIRCutMode] = [], wideDynamicRangeSupported: Bool = false,
                backlightCompensationSupported: Bool = false) {
        self.brightnessRange = brightnessRange
        self.contrastRange = contrastRange
        self.saturationRange = saturationRange
        self.sharpnessRange = sharpnessRange
        self.irCutModesSupported = irCutModesSupported
        self.wideDynamicRangeSupported = wideDynamicRangeSupported
        self.backlightCompensationSupported = backlightCompensationSupported
    }
}

public struct CameraDeviceInfo: Sendable, Equatable, Codable {
    public var manufacturer: String
    public var model: String
    public var firmwareVersion: String
    public var serialNumber: String
    public var hardwareID: String

    public init(manufacturer: String, model: String, firmwareVersion: String, serialNumber: String, hardwareID: String) {
        self.manufacturer = manufacturer
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.hardwareID = hardwareID
    }
}

/// Everything the Camera Settings sheet shows for one camera. `supportsONVIF == false` means only `webPageURL` is
/// usable — the sheet shows just the "Open Camera Web Page" link.
public struct CameraSettingsSnapshot: Sendable, Equatable, Codable {
    public var supportsONVIF: Bool
    public var webPageURL: URL?
    public var deviceInfo: CameraDeviceInfo?
    public var videoSourceToken: String?
    public var mainProfile: CameraVideoProfile?
    public var subProfile: CameraVideoProfile?
    public var imaging: CameraImagingSettings?
    public var imagingOptions: CameraImagingOptions?
    /// ONVIF answered (its no-login time query worked) but refused CameraBridge's username/password. Hikvision
    /// keeps ONVIF users in a separate list from its web accounts, so this is common until one is added.
    public var onvifLoginRejected: Bool? = nil
    /// The camera's time mode ("NTP"/"Manual") and clock offset from this Mac, from ONVIF's no-login time query.
    public var cameraTimeType: String? = nil
    public var cameraClockOffsetSeconds: Double? = nil
    /// Set while CameraBridge is holding off ONVIF logins because the camera locked them (or just rejected one).
    public var onvifLoginPausedUntil: Date? = nil

    public init(supportsONVIF: Bool, webPageURL: URL? = nil, deviceInfo: CameraDeviceInfo? = nil, videoSourceToken: String? = nil,
                mainProfile: CameraVideoProfile? = nil, subProfile: CameraVideoProfile? = nil, imaging: CameraImagingSettings? = nil,
                imagingOptions: CameraImagingOptions? = nil) {
        self.supportsONVIF = supportsONVIF
        self.webPageURL = webPageURL
        self.deviceInfo = deviceInfo
        self.videoSourceToken = videoSourceToken
        self.mainProfile = mainProfile
        self.subProfile = subProfile
        self.imaging = imaging
        self.imagingOptions = imagingOptions
    }
}

/// What to change; nil fields are left alone. Applied by `CameraSettingsService.apply(_:)`.
public struct CameraSettingsChange: Sendable, Equatable {
    public var mainEncoder: CameraVideoEncoderSettings?
    public var subEncoder: CameraVideoEncoderSettings?
    public var imaging: CameraImagingSettings?

    public init(mainEncoder: CameraVideoEncoderSettings? = nil, subEncoder: CameraVideoEncoderSettings? = nil,
                imaging: CameraImagingSettings? = nil) {
        self.mainEncoder = mainEncoder
        self.subEncoder = subEncoder
        self.imaging = imaging
    }

    public var isEmpty: Bool { mainEncoder == nil && subEncoder == nil && imaging == nil }
}

/// Reads and applies a camera's own ONVIF video/imaging settings, and gives the app the camera's web UI address as a
/// fallback for cameras (or settings) that ONVIF doesn't cover. Hikvision and Reolink cameras generally also speak
/// ONVIF, so this is used for every vendor; `endpoint.onvifPort` is used when known, else the usual ONVIF ports are
/// probed (80/8000/8080/2020, `CameraDrivers.onvifPort`).
public actor CameraSettingsService {
    let endpoint: CameraEndpoint
    let credentials: HTTPCredentials?
    let cameraID: UUID?
    private var resolvedClient: ONVIFClient?
    let log: Log
    /// The camera's vendor (picks the encoder methods to try, `CameraConfigMethod.attemptOrder`); nil: ONVIF only.
    let vendor: CameraVendor?
    /// The camera's configured main stream URL (names a Hikvision NVR channel).
    let mainStreamURL: URL?
    /// Reolink channel (0-based) for `GetEnc` / `SetEnc`.
    let reolinkChannel: Int
    /// The method that worked last time for this camera: tried first.
    var preferredMethod: CameraConfigMethod?
    /// What the caller should do with the camera's remembered method after the encoder changes made through this service.
    public internal(set) var memoryUpdate: CameraConfigMemoryUpdate?
    /// Set once a method reported a credential problem: later changes through this service stop right away.
    var credentialFailure: CameraConfigFailure?

    /// `vendor`, `mainStreamURL`, `preferredMethod` and `reolinkChannel` steer encoder changes (`applyEncoder`).
    public init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, cameraID: UUID? = nil, vendor: CameraVendor? = nil,
                mainStreamURL: URL? = nil, preferredMethod: CameraConfigMethod? = nil, reolinkChannel: Int = 0) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.cameraID = cameraID
        self.vendor = vendor
        self.mainStreamURL = mainStreamURL
        self.preferredMethod = preferredMethod
        self.reolinkChannel = reolinkChannel
        self.log = Log(category: "camera-settings", cameraID: cameraID)
    }

    /// `http(s)://host:httpPort` — the camera's own web configuration page. Never includes credentials.
    public var webPageURL: URL? {
        endpoint.httpURL(path: "/", port: endpoint.httpPort)
    }

    func client() async -> ONVIFClient? {
        if let resolvedClient { return resolvedClient }
        var resolved = endpoint
        if resolved.onvifPort == nil {
            resolved.onvifPort = await CameraDrivers.onvifPort(endpoint: resolved)
        }
        guard let url = ONVIFClient.deviceServiceURL(for: resolved) else { return nil }
        let client = ONVIFClient(deviceServiceURL: url, credentials: credentials, cameraID: cameraID)
        resolvedClient = client
        return client
    }

    /// Reads device info, both video profiles (main = largest, sub = the next smaller one) with their options, and
    /// imaging settings/options. Individual sections that the camera doesn't support (e.g. no Imaging service, or
    /// just one profile) are left nil rather than failing the whole snapshot; only a total failure to reach ONVIF at
    /// all (wrong credentials, no ONVIF service) throws, in which case the caller should still offer `webPageURL`.
    public func fetchSnapshot() async throws -> CameraSettingsSnapshot {
        guard let client = await client() else {
            return CameraSettingsSnapshot(supportsONVIF: false, webPageURL: webPageURL)
        }
        let deviceInfo: CameraDeviceInfo?
        var answeredWithoutLogin = false
        var timeType: String?
        var clockOffset: Double?
        do {
            let cameraDate = try? await client.systemDateAndTime()
            answeredWithoutLogin = cameraDate != nil
            timeType = await client.dateTimeType
            clockOffset = cameraDate.map { $0.timeIntervalSinceNow }
            let info = try await client.deviceInformation()
            deviceInfo = CameraDeviceInfo(manufacturer: info.manufacturer, model: info.model, firmwareVersion: info.firmwareVersion,
                                          serialNumber: info.serialNumber, hardwareID: info.hardwareID)
        } catch {
            // No ONVIF device service reachable with these credentials: report only the web page link.
            log.info("ONVIF device information unavailable (\(error)); offering the camera's web page only")
            var snapshot = CameraSettingsSnapshot(supportsONVIF: false, webPageURL: webPageURL)
            snapshot.onvifLoginRejected = answeredWithoutLogin
            if case CameraAdapterError.lockedOut(let until) = error { snapshot.onvifLoginPausedUntil = until }
            snapshot.cameraTimeType = timeType
            snapshot.cameraClockOffsetSeconds = clockOffset
            return snapshot
        }

        let profiles = (try? await client.mediaProfiles()) ?? []
        let (mainProfile, subProfile) = Self.selectProfiles(profiles)
        var mainOut: CameraVideoProfile?
        var subOut: CameraVideoProfile?
        if let mainProfile { mainOut = try? await Self.buildProfile(mainProfile, client: client) }
        if let subProfile { subOut = try? await Self.buildProfile(subProfile, client: client) }

        var videoSourceToken = mainProfile?.videoSourceToken ?? subProfile?.videoSourceToken
        if videoSourceToken == nil { videoSourceToken = (try? await client.videoSources())?.first?.token }

        var imaging: CameraImagingSettings?
        var imagingOptions: CameraImagingOptions?
        if let videoSourceToken {
            if let raw = try? await client.imagingSettings(videoSourceToken: videoSourceToken) { imaging = Self.convert(raw) }
            if let raw = try? await client.imagingOptions(videoSourceToken: videoSourceToken) { imagingOptions = Self.convert(raw) }
        }

        var snapshot = CameraSettingsSnapshot(supportsONVIF: true, webPageURL: webPageURL, deviceInfo: deviceInfo, videoSourceToken: videoSourceToken,
                                              mainProfile: mainOut, subProfile: subOut, imaging: imaging, imagingOptions: imagingOptions)
        snapshot.cameraTimeType = timeType
        snapshot.cameraClockOffsetSeconds = clockOffset
        return snapshot
    }

    /// Applies encoder and/or imaging changes. Throws on the first failure; earlier changes in the same call may
    /// already have taken effect on the camera. The caller (`BridgeEngine`) restarts the camera's ingest afterward so
    /// a changed encoder resolution/bitrate takes effect on the live stream.
    public func apply(_ change: CameraSettingsChange) async throws {
        guard !change.isEmpty else { return }
        var edits: [CameraEncoderEdit] = []
        if let mainEncoder = change.mainEncoder { edits.append(CameraEncoderEdit(isSub: false, desired: mainEncoder)) }
        if let subEncoder = change.subEncoder { edits.append(CameraEncoderEdit(isSub: true, desired: subEncoder)) }
        if !edits.isEmpty {
            let failed = try await applyEncoder(edits).filter { !$0.succeeded }
            if !failed.isEmpty { throw CameraConfigError(attempts: failed.flatMap(\.failures)) }
        }
        if let imaging = change.imaging {
            guard let client = await client() else { throw CameraAdapterError.unsupported("camera has no ONVIF service") }
            let token: String?
            if let mainEncoder = change.mainEncoder?.sourceToken { token = mainEncoder } else {
                token = (try? await client.videoSources())?.first?.token
            }
            guard let token else { throw CameraAdapterError.unsupported("camera has no video source") }
            try await client.setImagingSettings(videoSourceToken: token, settings: Self.convert(imaging))
        }
    }

    /// Asks the camera to reboot (ONVIF `SystemReboot`). The caller should confirm with the person first — this just
    /// performs it.
    public func reboot() async throws {
        guard let client = await client() else { throw CameraAdapterError.unsupported("camera has no ONVIF service") }
        try await client.systemReboot()
    }

    /// Hikvision-only: whether channel `channelID`'s own "H.264+"/"H.265+" smart codec is on, read from
    /// `/ISAPI/Streaming/channels/<channelID>`. nil when the camera's document has no `SmartCodec` element (not a
    /// Hikvision camera, an older model, or a channel ISAPI doesn't expose this on). The caller (`BridgeEngine`'s
    /// optimizer) only calls this for cameras configured as Hikvision; it's harmless (just throws) on anything else.
    public func hikvisionSmartCodecEnabled(channelID: String) async throws -> Bool? {
        try await HikvisionISAPI(endpoint: endpoint, credentials: credentials).smartCodecEnabled(channelID: channelID)
    }

    /// Hikvision-only: read-modify-write `Video/SmartCodec/enabled` on `/ISAPI/Streaming/channels/<channelID>`
    /// (PUT replaces the whole document, so the read keeps every other field the camera already had). Does nothing
    /// if that channel has no `SmartCodec` element.
    public func setHikvisionSmartCodec(enabled: Bool, channelID: String) async throws {
        try await HikvisionISAPI(endpoint: endpoint, credentials: credentials).setSmartCodecEnabled(enabled, channelID: channelID)
    }

    /// Hikvision only: a channel's codec, frame rate and keyframe interval (frames) over ISAPI.
    public func hikvisionEncoder(channelID: String) async throws -> (codec: String?, fps: Double?, govLength: Int?) {
        try await HikvisionISAPI(endpoint: endpoint, credentials: credentials).encoderSettings(channelID: channelID)
    }

    /// Hikvision only: sets a channel's keyframe interval (frames) over ISAPI, leaving everything else unchanged.
    public func setHikvisionGovLength(_ frames: Int, channelID: String) async throws {
        try await HikvisionISAPI(endpoint: endpoint, credentials: credentials).setGovLength(frames, channelID: channelID)
    }

    // MARK: - Conversions

    static func selectProfiles(_ profiles: [ONVIFMediaProfile]) -> (main: ONVIFMediaProfile?, sub: ONVIFMediaProfile?) {
        func pixelCount(_ profile: ONVIFMediaProfile) -> Int {
            let config = profile.videoEncoderConfiguration
            let (product, overflow) = (config?.width ?? 0).multipliedReportingOverflow(by: config?.height ?? 0)
            return overflow ? Int.max : max(0, product)
        }
        let video = profiles.filter { $0.videoEncoderConfiguration != nil }
        let candidates = (video.isEmpty ? profiles : video).sorted { pixelCount($0) > pixelCount($1) }
        guard let main = candidates.first else { return (nil, nil) }
        let smaller = candidates.filter { $0.token != main.token && pixelCount($0) < pixelCount(main) }
        return (main, smaller.last { pixelCount($0) > 0 } ?? smaller.last)
    }

    private static func buildProfile(_ profile: ONVIFMediaProfile, client: ONVIFClient) async throws -> CameraVideoProfile? {
        guard let config = profile.videoEncoderConfiguration else { return nil }
        let settings = convert(config)
        var optionGroups: [CameraVideoEncoderOptions] = []
        if let raw = try? await client.videoEncoderConfigurationOptions(configurationToken: config.token, profileToken: profile.token) {
            optionGroups = raw.groups.map { convert($0, qualityRange: raw.qualityRange) }
        }
        return CameraVideoProfile(id: profile.token, name: profile.name, settings: settings, options: optionGroups)
    }

    private static func convert(_ config: ONVIFVideoEncoderConfiguration) -> CameraVideoEncoderSettings {
        CameraVideoEncoderSettings(token: config.token, name: config.name, sourceToken: config.sourceToken, encoding: config.encoding,
                                   resolution: (config.width.flatMap { w in config.height.map { CameraResolution(width: w, height: $0) } }),
                                   frameRate: config.frameRateLimit, encodingInterval: config.encodingInterval, bitrate: config.bitrateLimit,
                                   iFrameInterval: config.govLength, h264Profile: config.h264Profile, quality: config.quality)
    }

    static func convert(_ settings: CameraVideoEncoderSettings) -> ONVIFVideoEncoderConfiguration {
        ONVIFVideoEncoderConfiguration(token: settings.token, name: settings.name, useCount: nil, encoding: settings.encoding,
                                       width: settings.resolution?.width, height: settings.resolution?.height, quality: settings.quality,
                                       frameRateLimit: settings.frameRate, encodingInterval: settings.encodingInterval,
                                       bitrateLimit: settings.bitrate, govLength: settings.iFrameInterval, h264Profile: settings.h264Profile,
                                       sourceToken: settings.sourceToken)
    }

    private static func convert(_ group: ONVIFEncoderOptionGroup, qualityRange: ClosedRange<Double>?) -> CameraVideoEncoderOptions {
        CameraVideoEncoderOptions(encoding: group.encoding, resolutions: group.resolutions.map { CameraResolution(width: $0.width, height: $0.height) },
                                  frameRateRange: group.frameRateRange,
                                  bitrateRange: group.bitrateRange, iFrameIntervalRange: group.govLengthRange, qualityRange: qualityRange,
                                  h264ProfilesSupported: group.profilesSupported)
    }

    private static func convert(_ settings: ONVIFImagingSettings) -> CameraImagingSettings {
        CameraImagingSettings(brightness: settings.brightness, contrast: settings.contrast, saturation: settings.saturation,
                              sharpness: settings.sharpness, irCutMode: settings.irCutFilter.flatMap(CameraIRCutMode.init(rawValue:)),
                              wideDynamicRangeEnabled: settings.wideDynamicRangeEnabled,
                              backlightCompensationEnabled: settings.backlightCompensationEnabled)
    }

    private static func convert(_ settings: CameraImagingSettings) -> ONVIFImagingSettings {
        ONVIFImagingSettings(brightness: settings.brightness, contrast: settings.contrast, saturation: settings.saturation,
                             sharpness: settings.sharpness, irCutFilter: settings.irCutMode?.rawValue,
                             wideDynamicRangeEnabled: settings.wideDynamicRangeEnabled,
                             backlightCompensationEnabled: settings.backlightCompensationEnabled)
    }

    private static func convert(_ options: ONVIFImagingOptions) -> CameraImagingOptions {
        CameraImagingOptions(brightnessRange: options.brightnessRange, contrastRange: options.contrastRange,
                             saturationRange: options.saturationRange, sharpnessRange: options.sharpnessRange,
                             irCutModesSupported: options.irCutFilterModes.compactMap(CameraIRCutMode.init(rawValue:)),
                             wideDynamicRangeSupported: options.wideDynamicRangeSupported,
                             backlightCompensationSupported: options.backlightCompensationSupported)
    }
}
