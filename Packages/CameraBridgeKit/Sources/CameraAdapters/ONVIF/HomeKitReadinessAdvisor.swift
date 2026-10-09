import BridgeSupport
import Foundation

/// Measured facts about one of a camera's own streams, as the runtime observed them (codec/size/fps from
/// `MediaHub`, GOP/B-frame facts from `StreamTraits`). All optional: nothing is measured until the stream has
/// delivered video. `HomeKitReadinessAdvisor` only grades what it has evidence for.
public struct MeasuredStreamFacts: Sendable, Equatable {
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    /// The longest recently observed keyframe interval, in seconds (smart/adaptive codecs stretch single GOPs far
    /// beyond their average, which a plain mean hides).
    public var measuredGOPSeconds: Double?
    public var hasBFrames: Bool?
    public var audioCodec: String?
    public var bitrateKbps: Int?

    public init(codec: String? = nil, width: Int? = nil, height: Int? = nil, fps: Double? = nil, measuredGOPSeconds: Double? = nil,
                hasBFrames: Bool? = nil, audioCodec: String? = nil, bitrateKbps: Int? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.measuredGOPSeconds = measuredGOPSeconds
        self.hasBFrames = hasBFrames
        self.audioCodec = audioCodec
        self.bitrateKbps = bitrateKbps
    }
}

/// One finding in a `HomeKitReadinessReport`. `fixMethod` tells the UI whether "Optimize for HomeKit…" can fix it by
/// itself (`.automatic`) or whether the person has to change it on the camera/vendor app (`.manual`).
public struct HomeKitReadinessCheck: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable { case ok, warning, problem }
    public enum FixMethod: Sendable, Equatable {
        /// Fixable by `BridgeEngine.optimizeForHomeKit(cameraID:)` (ONVIF / vendor API).
        case automatic
        /// Steps the person has to follow in the camera's own web page or vendor app.
        case manual([String])
        /// Nothing to fix, or nothing CameraBridge can act on either way (e.g. "no issue found").
        case none
    }

    public var id: String
    public var title: String
    public var status: Status
    /// Plain-English explanation of why this matters for HomeKit Secure Video.
    public var explanation: String
    public var recommendedValue: String?
    public var fixMethod: FixMethod

    public init(id: String, title: String, status: Status, explanation: String, recommendedValue: String? = nil, fixMethod: FixMethod = .none) {
        self.id = id
        self.title = title
        self.status = status
        self.explanation = explanation
        self.recommendedValue = recommendedValue
        self.fixMethod = fixMethod
    }
}

/// The full result of grading one camera against HomeKit Secure Video's expectations.
public struct HomeKitReadinessReport: Sendable, Equatable {
    public var checks: [HomeKitReadinessCheck]

    public init(checks: [HomeKitReadinessCheck]) {
        self.checks = checks
    }

    /// 0–100: `ok` counts fully, `warning` counts half, `problem` counts nothing.
    public var score: Int {
        guard !checks.isEmpty else { return 100 }
        let total = checks.reduce(0.0) { sum, check in
            sum + (check.status == .ok ? 1.0 : check.status == .warning ? 0.5 : 0.0)
        }
        return Int((total / Double(checks.count) * 100).rounded())
    }

    public var problemCount: Int { checks.filter { $0.status == .problem }.count }
    public var warningCount: Int { checks.filter { $0.status == .warning }.count }

    public var summary: String {
        if problemCount == 0 && warningCount == 0 { return "This camera is ready for HomeKit Secure Video." }
        var parts: [String] = []
        if problemCount > 0 { parts.append("\(problemCount) problem\(problemCount == 1 ? "" : "s")") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + " found."
    }
}

/// Grades a camera's encoder settings and measured stream facts against what HomeKit Secure Video needs for
/// reliable, low-CPU recording, and offers vendor-specific manual instructions for whatever it can't fix itself.
/// Pure, portable Swift: takes only values already read elsewhere (`CameraSettingsSnapshot`, `MeasuredStreamFacts`),
/// does no networking.
public enum HomeKitReadinessAdvisor {
    /// `mainStreamFacts`/`subStreamFacts` should be the runtime's measured facts for the camera's main/sub ingest,
    /// when available (nil before the stream has delivered video, or when the camera is offline — those checks are
    /// graded from the ONVIF snapshot alone).
    public static func evaluate(vendor: CameraVendor, deviceInfo: CameraDeviceInfo?, snapshot: CameraSettingsSnapshot,
                                 mainStreamFacts: MeasuredStreamFacts? = nil, subStreamFacts: MeasuredStreamFacts? = nil,
                                 manualStepOverrides: [String: [String]] = [:]) -> HomeKitReadinessReport {
        var checks: [HomeKitReadinessCheck] = []
        if !snapshot.supportsONVIF { checks.append(onvifAccessCheck(vendor: vendor, loginRejected: snapshot.onvifLoginRejected == true, pausedUntil: snapshot.onvifLoginPausedUntil)) }
        let main = snapshot.mainProfile?.settings
        let effectiveCodec = (mainStreamFacts?.codec ?? main?.encoding)?.uppercased()
        let effectiveFPS = mainStreamFacts?.fps ?? main?.frameRate
        let effectiveGOPSeconds: Double? = {
            if let measured = mainStreamFacts?.measuredGOPSeconds { return measured }
            if let gov = main?.iFrameInterval, let fps = main?.frameRate, fps > 0 { return Double(gov) / fps }
            return nil
        }()
        let effectiveBFrames = mainStreamFacts?.hasBFrames

        checks.append(codecCheck(vendor: vendor, codec: effectiveCodec))
        checks.append(keyframeIntervalCheck(vendor: vendor, seconds: effectiveGOPSeconds, fps: effectiveFPS))
        checks.append(smartCodecCheck(vendor: vendor))
        checks.append(bFramesCheck(vendor: vendor, hasBFrames: effectiveBFrames))
        checks.append(frameRateCheck(vendor: vendor, fps: effectiveFPS))
        checks.append(bitrateCheck(vendor: vendor, bitrateKbps: mainStreamFacts?.bitrateKbps ?? main?.bitrate))
        checks.append(resolutionCheck(vendor: vendor, width: mainStreamFacts?.width ?? main?.resolution?.width,
                                      height: mainStreamFacts?.height ?? main?.resolution?.height))
        checks.append(subStreamCheck(vendor: vendor, snapshot: snapshot, facts: subStreamFacts))
        checks.append(audioCheck(vendor: vendor, audioCodec: mainStreamFacts?.audioCodec ?? (main == nil ? nil : "present")))
        checks.append(motionEventsCheck(vendor: vendor, snapshot: snapshot))
        checks.append(timeSyncCheck(vendor: vendor, snapshot: snapshot))
        // Steps from the camera profiles feed replace the built-in ones for a check that still needs the person's hands.
        if !manualStepOverrides.isEmpty {
            checks = checks.map { check in
                guard check.status != .ok, let steps = manualStepOverrides[check.id], !steps.isEmpty else { return check }
                if case .automatic = check.fixMethod { return check }
                var replaced = check
                replaced.fixMethod = .manual(steps)
                return replaced
            }
        }
        return HomeKitReadinessReport(checks: checks)
    }

    // MARK: - Individual checks

    private static func codecCheck(vendor: CameraVendor, codec: String?) -> HomeKitReadinessCheck {
        guard let codec else {
            return HomeKitReadinessCheck(id: "codec", title: "Main stream codec", status: .warning,
                                         explanation: "The main stream's codec could not be read yet.", fixMethod: .none)
        }
        if codec == "H264" {
            return HomeKitReadinessCheck(id: "codec", title: "Main stream codec", status: .ok,
                                         explanation: "H.264 passes through to HomeKit Secure Video without re-encoding.",
                                         recommendedValue: "H.264", fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "codec", title: "Main stream codec", status: .warning,
            explanation: "H.265/HEVC main streams must be transcoded to H.264 for HomeKit Secure Video, which costs CPU "
                + "and some quality versus passthrough. It still works, but switching the main stream to H.264 avoids that.",
            recommendedValue: "H.264", fixMethod: .automatic)
    }

    private static func keyframeIntervalCheck(vendor: CameraVendor, seconds: Double?, fps: Double?) -> HomeKitReadinessCheck {
        guard let seconds else {
            return HomeKitReadinessCheck(id: "keyframeInterval", title: "Keyframe interval", status: .warning,
                                         explanation: "The keyframe (I-frame) interval could not be read yet.", fixMethod: .none)
        }
        if seconds <= 4.0 {
            return HomeKitReadinessCheck(
                id: "keyframeInterval", title: "Keyframe interval", status: .ok,
                explanation: "HomeKit Secure Video's recording fragments must start on a keyframe; a short interval keeps "
                    + "fragments on schedule and recordings gapless.", recommendedValue: "≤ 4 s (ideally 2× the frame rate)",
                fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "keyframeInterval", title: "Keyframe interval", status: .problem,
            explanation: "This camera's keyframe interval is about \(String(format: "%.1f", seconds)) s. HomeKit Secure "
                + "Video fragments must start on an IDR (keyframe); a long interval delays recording start and can "
                + "produce stretched or dropped fragments.", recommendedValue: "≤ 4 s (ideally 2× the frame rate)",
            fixMethod: .automatic)
    }

    private static func smartCodecCheck(vendor: CameraVendor) -> HomeKitReadinessCheck {
        // ONVIF has no standard flag for vendor "smart codec" features, so this is always a manual check: the
        // advisor can't see the setting, only warn it may be on and explain why it matters.
        let steps = manualSteps(vendor: vendor, checkID: "smartCodec")
        return HomeKitReadinessCheck(
            id: "smartCodec", title: "Smart / adaptive codec", status: .warning,
            explanation: "Hikvision H.264+/H.265+, Dahua Smart Codec, and similar Reolink/Tapo features save bandwidth by "
                + "stretching the keyframe interval on static scenes — sometimes to tens of seconds. ONVIF has no "
                + "standard way to read this setting, so Camera Bridge can't confirm it's off; if the keyframe interval "
                + "check above looks fine but recordings still feel laggy to start, check for this on the camera itself.",
            recommendedValue: "Off",
            // Hikvision exposes SmartCodec over ISAPI, which the optimizer turns off; other vendors stay manual.
            fixMethod: vendor == .hikvision ? .automatic : (steps.isEmpty ? .none : .manual(steps)))
    }

    private static func bFramesCheck(vendor: CameraVendor, hasBFrames: Bool?) -> HomeKitReadinessCheck {
        guard let hasBFrames else {
            return HomeKitReadinessCheck(id: "bFrames", title: "B-frames", status: .warning,
                                         explanation: "Whether the main stream uses B-frames could not be measured yet.", fixMethod: .none)
        }
        if !hasBFrames {
            return HomeKitReadinessCheck(id: "bFrames", title: "B-frames", status: .ok,
                                         explanation: "No B-frames (reordered pictures) were seen; the stream decodes and "
                                            + "passes through cleanly.", recommendedValue: "Off", fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "bFrames", title: "B-frames", status: .problem,
            explanation: "B-frames (reordered pictures) were detected in the main stream. HomeKit Secure Video's fragmenter "
                + "assumes decode order == presentation order; B-frames force transcoding and can show up as choppy or "
                + "out-of-order recordings until the camera stops sending them.", recommendedValue: "Off", fixMethod: .automatic)
    }

    private static func frameRateCheck(vendor: CameraVendor, fps: Double?) -> HomeKitReadinessCheck {
        guard let fps else {
            return HomeKitReadinessCheck(id: "frameRate", title: "Frame rate", status: .warning,
                                         explanation: "The main stream's frame rate could not be read yet.", fixMethod: .none)
        }
        if (15...25).contains(fps) {
            return HomeKitReadinessCheck(id: "frameRate", title: "Frame rate", status: .ok,
                                         explanation: "15–25 fps is smooth for HomeKit Secure Video recordings without "
                                            + "wasting bitrate on redundant frames.", recommendedValue: "15–25 fps", fixMethod: .none)
        }
        let status: HomeKitReadinessCheck.Status = fps < 8 || fps > 30 ? .problem : .warning
        return HomeKitReadinessCheck(
            id: "frameRate", title: "Frame rate", status: status,
            explanation: fps < 15
                ? "At \(Int(fps)) fps, motion can look choppy in recordings and live view."
                : "At \(Int(fps)) fps, the stream spends bitrate on frames HomeKit doesn't need, which can push the "
                    + "bitrate limit too low for each individual frame's quality.",
            recommendedValue: "15–25 fps", fixMethod: .automatic)
    }

    private static func bitrateCheck(vendor: CameraVendor, bitrateKbps: Int?) -> HomeKitReadinessCheck {
        guard let bitrateKbps else {
            return HomeKitReadinessCheck(id: "bitrate", title: "Main stream bitrate", status: .warning,
                                         explanation: "The main stream's bitrate could not be read yet.", fixMethod: .none)
        }
        if (2000...6000).contains(bitrateKbps) {
            return HomeKitReadinessCheck(id: "bitrate", title: "Main stream bitrate", status: .ok,
                                         explanation: "2–6 Mbps (CBR, or VBR with that cap) balances recording quality "
                                            + "against storage and network use.", recommendedValue: "2–6 Mbps", fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "bitrate", title: "Main stream bitrate", status: .warning,
            explanation: bitrateKbps < 2000
                ? "Under 2 Mbps can look soft in HomeKit Secure Video recordings, especially at night."
                : "Over 6 Mbps uses more iCloud storage and network bandwidth than HomeKit recordings typically need.",
            recommendedValue: "2–6 Mbps (CBR or capped VBR)", fixMethod: .automatic)
    }

    private static func resolutionCheck(vendor: CameraVendor, width: Int?, height: Int?) -> HomeKitReadinessCheck {
        guard let width, let height else {
            return HomeKitReadinessCheck(id: "resolution", title: "Main stream resolution", status: .warning,
                                         explanation: "The main stream's resolution could not be read yet.", fixMethod: .none)
        }
        if height <= 1080 {
            return HomeKitReadinessCheck(id: "resolution", title: "Main stream resolution", status: .ok,
                                         explanation: "\(width)×\(height) passes through to HomeKit Secure Video without "
                                            + "re-encoding.", fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "resolution", title: "Main stream resolution", status: .warning,
            explanation: "\(width)×\(height) is above 1080p. Whether this passes through or gets transcoded for HomeKit "
                + "depends on the requested stream's level — 1440p/4K sources are usually fine for live view and "
                + "recording, but check the camera's Streams settings if recordings look softer than expected.",
            fixMethod: .none)
    }

    private static func subStreamCheck(vendor: CameraVendor, snapshot: CameraSettingsSnapshot, facts: MeasuredStreamFacts?) -> HomeKitReadinessCheck {
        guard let sub = snapshot.subProfile?.settings else {
            // No ONVIF profile to read (or none offered): judge the sub stream CameraBridge actually receives.
            if let facts, let codec = facts.codec?.uppercased(), let width = facts.width, let height = facts.height {
                let good = codec == "H264" && (360...720).contains(height)
                return HomeKitReadinessCheck(
                    id: "subStream", title: "Sub stream", status: good ? .ok : .warning,
                    explanation: good ? "\(codec) at \(width)×\(height) is a good fit for Apple Watch and remote live view."
                        : "The sub stream is \(codec) at \(width)×\(height); H.264 at roughly 640×360 to 1280×720 is best for "
                            + "Apple Watch and remote view.",
                    recommendedValue: "H.264, 640×360–1280×720",
                    fixMethod: good ? .none : { let steps = manualSteps(vendor: vendor, checkID: "subStream"); return steps.isEmpty ? .none : .manual(steps) }())
            }
            let steps = manualSteps(vendor: vendor, checkID: "subStream")
            return HomeKitReadinessCheck(
                id: "subStream", title: "Sub stream", status: .warning,
                explanation: "No second (sub) stream profile was found. HomeKit uses a smaller stream for the Watch and "
                    + "remote viewing when the main stream is more than it needs.", recommendedValue: "H.264, 640×360–1280×720",
                fixMethod: steps.isEmpty ? .none : .manual(steps))
        }
        let codec = (facts?.codec ?? sub.encoding).uppercased()
        let width = facts?.width ?? sub.resolution?.width ?? 0
        let height = facts?.height ?? sub.resolution?.height ?? 0
        let sizeOK = width > 0 && height > 0 && (360...720).contains(height)
        if codec == "H264" && sizeOK {
            return HomeKitReadinessCheck(id: "subStream", title: "Sub stream", status: .ok,
                                         explanation: "H.264 at \(width)×\(height) is a good fit for Apple Watch and "
                                            + "remote live view.", recommendedValue: "H.264, 640×360–1280×720", fixMethod: .none)
        }
        return HomeKitReadinessCheck(
            id: "subStream", title: "Sub stream", status: .warning,
            explanation: "The sub stream should be H.264 at roughly 640×360 to 1280×720 for a fast, low-bandwidth Watch "
                + "and remote view.", recommendedValue: "H.264, 640×360–1280×720", fixMethod: .automatic)
    }

    private static func audioCheck(vendor: CameraVendor, audioCodec: String?) -> HomeKitReadinessCheck {
        guard audioCodec != nil else {
            let steps = manualSteps(vendor: vendor, checkID: "audio")
            return HomeKitReadinessCheck(id: "audio", title: "Audio", status: .warning,
                                         explanation: "No audio was detected on the main stream. HomeKit Secure Video "
                                            + "recordings include audio when the camera sends it (AAC or G.711 both work).",
                                         fixMethod: steps.isEmpty ? .none : .manual(steps))
        }
        return HomeKitReadinessCheck(id: "audio", title: "Audio", status: .ok,
                                     explanation: "Audio is present (AAC/G.711 both work with Camera Bridge).", fixMethod: .none)
    }

    private static func onvifAccessCheck(vendor: CameraVendor, loginRejected: Bool, pausedUntil: Date? = nil) -> HomeKitReadinessCheck {
        if let pausedUntil {
            let time = pausedUntil.formatted(date: .omitted, time: .shortened)
            return HomeKitReadinessCheck(
                id: "onvif", title: "ONVIF access", status: .problem,
                explanation: "The camera has temporarily locked logins after too many wrong passwords. Camera Bridge won't "
                    + "try again until \(time), because each attempt restarts the camera's lock. If you've already added "
                    + "the ONVIF user, just wait, then click Check Again.",
                recommendedValue: "Wait until \(time)", fixMethod: .none)
        }
        let steps = manualSteps(vendor: vendor, checkID: loginRejected ? "onvifLogin" : "onvif")
        return HomeKitReadinessCheck(
            id: "onvif", title: "ONVIF access", status: .problem,
            explanation: (loginRejected
                ? "Add an ONVIF user on this camera. ONVIF is on, but the camera rejected Camera Bridge's username and password for it. "
                    + (vendor == .hikvision ? "Hikvision keeps ONVIF users separate from its web accounts. " : "")
                : "The camera didn't answer ONVIF. Many cameras ship with it turned off. ")
                + "Until this is fixed Camera Bridge can't read or change the video settings (Optimize, sub stream and bitrate need it).",
            recommendedValue: loginRejected ? "Add an ONVIF user on this camera" : "ONVIF enabled, with a user Camera Bridge can log in as",
            fixMethod: steps.isEmpty ? .none : .manual(steps))
    }

    private static func motionEventsCheck(vendor: CameraVendor, snapshot: CameraSettingsSnapshot) -> HomeKitReadinessCheck {
        // The advisor can't see the live event channel state from the snapshot alone; this is informational unless
        // the camera doesn't even support ONVIF (then it falls back to built-in motion detection).
        if !snapshot.supportsONVIF && vendor != .hikvision && vendor != .reolink {
            return HomeKitReadinessCheck(
                id: "motionEvents", title: "Motion events", status: .warning,
                explanation: "This camera doesn't answer ONVIF, so Camera Bridge will use its own built-in motion "
                    + "detection (decoding the stream) instead of the camera's own motion events. That works, but "
                    + "camera-side detection is usually more accurate and uses less CPU.",
                recommendedValue: "Camera-reported motion events", fixMethod: .none)
        }
        let steps = manualSteps(vendor: vendor, checkID: "motionEvents")
        return HomeKitReadinessCheck(
            id: "motionEvents", title: "Motion events", status: .ok,
            explanation: vendor == .hikvision
                ? "Hikvision cameras need \"Notify Surveillance Center\" turned on for their motion/VMD rules so "
                    + "Camera Bridge's event stream sees them; ONVIF events and built-in motion are also available as a fallback."
                : "ONVIF motion/analytics events (or the camera's own API) let HomeKit start recording the moment "
                    + "motion starts, instead of waiting on Camera Bridge's built-in detector.",
            fixMethod: steps.isEmpty ? .none : .manual(steps))
    }

    private static func timeSyncCheck(vendor: CameraVendor, snapshot: CameraSettingsSnapshot) -> HomeKitReadinessCheck {
        let steps = manualSteps(vendor: vendor, checkID: "timeSync")
        let offset = snapshot.cameraClockOffsetSeconds.map { abs($0) }
        if snapshot.cameraTimeType?.uppercased() == "NTP", (offset ?? 0) <= 10 {
            return HomeKitReadinessCheck(id: "timeSync", title: "Time sync (NTP)", status: .ok,
                                         explanation: "The camera keeps its clock with NTP"
                                            + (offset.map { " and is within \(Int($0.rounded())) s of this Mac." } ?? "."),
                                         recommendedValue: "NTP enabled", fixMethod: .none)
        }
        if let offset, offset > 10 {
            return HomeKitReadinessCheck(
                id: "timeSync", title: "Time sync (NTP)", status: .problem,
                explanation: "The camera's clock is \(Int(offset.rounded())) s off from this Mac. That can misorder recording "
                    + "fragments and event times. Point the camera at an NTP server.",
                recommendedValue: "NTP enabled", fixMethod: steps.isEmpty ? .none : .manual(steps))
        }
        return HomeKitReadinessCheck(
            id: "timeSync", title: "Time sync (NTP)", status: .warning,
            explanation: "A camera clock that drifts can misorder recording fragments and event timestamps. Point the "
                + "camera at an NTP server (or \"Sync with computer time\") so its clock stays accurate.",
            recommendedValue: "NTP enabled", fixMethod: steps.isEmpty ? .none : .manual(steps))
    }

    // MARK: - Vendor-specific manual steps

    /// Manual fix-up steps for a check this advisor can't apply automatically, worded for the given vendor. Empty
    /// when there's nothing vendor-specific to add (the check's `explanation` already says enough).
    public static func manualSteps(vendor: CameraVendor, checkID: String) -> [String] {
        switch (vendor, checkID) {
        case (.hikvision, "onvif"):
            return ["Camera web page → Configuration → Network → Platform Access → ONVIF (older firmware: Network → Advanced Settings → Integration Protocol).",
                    "Tick \"Enable Open Network Video Interface\" and save.",
                    "In the ONVIF user list on the same page, click Add: the same username and password you gave "
                        + "Camera Bridge, User Type Administrator.",
                    "Come back here and the checklist reloads; Optimize can then change the video settings."]
        case (.hikvision, "onvifLogin"):
            return ["Camera web page → Configuration → Network → Platform Access → ONVIF (older firmware: Network → Advanced Settings → Integration Protocol).",
                    "Make sure \"Enable Open Network Video Interface\" is ticked and Authentication is \"Digest&ws-username token\".",
                    "In the ONVIF user list (it is often empty: \"No data\"), click Add: use the same username and password you gave Camera Bridge, User Type Administrator.",
                    "Save. The checklist here reloads, and Optimize can then change the video settings."]
        case (_, "onvifLogin"):
            return ["Open the camera's web page and find its ONVIF user settings.",
                    "Add an ONVIF user with the same username and password you gave Camera Bridge (administrator level)."]
        case (.reolink, "onvif"):
            return ["Reolink app or web client → Settings → Network → Advanced → Server Settings (or Port Settings).",
                    "Turn on ONVIF (port 8000) and save."]
        case (_, "onvif"):
            return ["Open the camera's web page and find its ONVIF / Integration / Network Services setting.",
                    "Enable ONVIF and, if asked, create an ONVIF user with the username and password you gave Camera Bridge."]
        case (.hikvision, "smartCodec"):
            return ["Open the camera's web page or iVMS-4200/Hik-Connect.",
                    "Configuration → Video/Audio → Video (or Streaming/channels/101 in the ISAPI UI).",
                    "Set \"Video Type\" encoding to H.264/H.265, then turn off \"H.264+\"/\"H.265+\" (sometimes called "
                        + "\"Smart Codec\" or \"Highlight Compression\").",
                    "Repeat for the sub stream (channel 102) if it also offers H.264+/H.265+.",
                    "Save, then let Camera Bridge reconnect the stream."]
        case (.hikvision, "subStream"):
            return ["Camera web page → Configuration → Video/Audio → Video, select the \"Sub Stream\" tab.",
                    "Set Video Type H.264, resolution around 640×360 or 704×480, frame rate 15, bitrate 512–1024 Kbps."]
        case (.hikvision, "audio"):
            return ["Camera web page → Configuration → Video/Audio → Audio.",
                    "Enable audio and choose G.711ulaw or AAC; make sure a microphone is connected if the camera needs one."]
        case (.hikvision, "motionEvents"):
            return ["Camera web page → Configuration → Event → Basic Event → Motion Detection.",
                    "Edit the detection area/schedule, then under \"Linkage Method\" enable \"Notify Surveillance Center\" "
                        + "(this is what makes the event reach Camera Bridge's alert stream).",
                    "If you use smart/line/field detection instead of plain motion, enable the same linkage there."]
        case (.hikvision, "timeSync"):
            return ["Camera web page → Configuration → System → System Settings → Time Settings.",
                    "Choose \"NTP Synchronization\", enter an NTP server (e.g. time.apple.com or your router's address), and save."]

        case (.reolink, "smartCodec"):
            return ["Open the Reolink app or web client for the camera.",
                    "Device Settings → Image → Encode Settings (or Stream).",
                    "Turn off any \"Smart Codec\"/variable-GOP option on both the main (Clear) and sub (Fluent) streams."]
        case (.reolink, "subStream"):
            return ["Device Settings → Image → Encode Settings, select the \"Fluent\" (sub) stream.",
                    "Set Encode Type H.264, resolution 640×360, frame rate 15."]
        case (.reolink, "audio"):
            return ["Device Settings → Audio, enable the microphone (built-in or external)."]
        case (.reolink, "motionEvents"):
            return ["Device Settings → Detection & Alarm → turn on Motion Detection (and AI detection if supported).",
                    "Device Settings → Network → Advanced → ONVIF, make sure ONVIF is enabled so Camera Bridge gets instant events."]
        case (.reolink, "timeSync"):
            return ["Device Settings → General → Device Time, enable \"Sync with NTP Server\" and save."]

        case (.onvif, "smartCodec"):
            return ["Open the camera's own web page (ONVIF has no standard switch for this).",
                    "Look in the video/encoding settings for \"Smart Codec\", \"Adaptive GOP\", or a similarly named "
                        + "bandwidth-saving feature and turn it off."]
        case (.onvif, "subStream"):
            return ["In the camera's web page, create or edit a second (sub) video profile at H.264, roughly "
                        + "640×360–1280×720, 15 fps."]
        case (.onvif, "audio"):
            return ["In the camera's web page, enable the microphone and add an audio encoder configuration (AAC or G.711) "
                        + "to the ONVIF media profile."]
        case (.onvif, "motionEvents"):
            return ["In the camera's web page, enable its own motion/analytics rules so they reach ONVIF events; "
                        + "Camera Bridge subscribes to ONVIF PullPoint automatically when a camera supports it."]
        case (.onvif, "timeSync"):
            return ["In the camera's web page (System/Date & Time), enable NTP and set a server address."]

        default:
            return []
        }
    }
}
