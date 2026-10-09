import Foundation

/// One way CameraBridge can change a camera's video encoder settings. `CameraSettingsService.applyEncoder` tries them in
/// `attemptOrder` until one works and its result reads back from the camera; the winner is remembered per camera
/// (`CameraConfiguration.preferredConfigMethod`) and tried first the next time.
///
/// Raw values are persisted: an unknown one (written by a newer build) reads back as no preference.
public enum CameraConfigMethod: String, Sendable, Codable, CaseIterable, Hashable {
    /// Hikvision's own ISAPI: read-modify-write of the channel's `StreamingChannel` document.
    case hikvisionISAPI
    /// Reolink's HTTP API: `GetEnc` / `SetEnc`.
    case reolinkAPI
    /// ONVIF `SetVideoEncoderConfiguration` carrying the camera's own configuration back with only the changed fields
    /// altered (every other element the camera reported is preserved).
    case onvifMinimal
    /// ONVIF `SetVideoEncoderConfiguration` with CameraBridge's complete request.
    case onvifFull

    /// Short name for results ("ONVIF minimal: InvalidArgVal; ISAPI: unsupported").
    public var displayName: String {
        switch self {
        case .hikvisionISAPI: "ISAPI"
        case .reolinkAPI: "Reolink API"
        case .onvifMinimal: "ONVIF minimal"
        case .onvifFull: "ONVIF full"
        }
    }

    /// The methods to try for a camera of `vendor`, in order: the vendor's own API first, then ONVIF minimal, then
    /// ONVIF full. A `preferred` method (the one that worked last time) moves to the front when it applies to the vendor.
    public static func attemptOrder(vendor: CameraVendor?, preferred: CameraConfigMethod? = nil) -> [CameraConfigMethod] {
        var order: [CameraConfigMethod]
        switch vendor {
        case .hikvision: order = [.hikvisionISAPI, .onvifMinimal, .onvifFull]
        case .reolink: order = [.reolinkAPI, .onvifMinimal, .onvifFull]
        default: order = [.onvifMinimal, .onvifFull]
        }
        if let preferred, let index = order.firstIndex(of: preferred), index != 0 {
            order.remove(at: index)
            order.insert(preferred, at: 0)
        }
        return order
    }
}

/// Why one method did not change a setting.
public enum CameraConfigFailure: Sendable, Equatable {
    /// The camera (or this method) has no such setting or service.
    case unsupported(String)
    /// The camera refused the value (an ONVIF fault such as `InvalidArgVal`, an HTTP or vendor error code).
    case rejected(String)
    /// The camera refused the credentials. Ends the chain: another method would only add failed logins.
    case unauthorized
    /// The camera locked logins. Ends the chain.
    case lockedOut(until: Date)
    /// The camera did not answer.
    case network(String)
    /// The camera accepted the change but reading the setting back showed the old value.
    case didNotStick

    /// Credential problems end the chain (continuing could lock the camera out).
    public var stopsChain: Bool {
        switch self {
        case .unauthorized, .lockedOut: true
        default: false
        }
    }

    /// A few words: "unsupported", "InvalidArgVal", "login rejected", "didn't stick".
    public var summary: String {
        switch self {
        case .unsupported:
            return "unsupported"
        case .rejected(let reason):
            let head = reason.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? reason
            return head.isEmpty ? "rejected" : String(head.prefix(40))
        case .unauthorized:
            return "login rejected"
        case .lockedOut:
            return "logins locked"
        case .network:
            return "no answer"
        case .didNotStick:
            return "didn't stick"
        }
    }

    /// The failure for an error a method threw. `CancellationError` is the caller's to rethrow, not mapped here.
    static func from(_ error: any Error) -> CameraConfigFailure {
        switch error {
        case let adapter as CameraAdapterError:
            switch adapter {
            case .unauthorized: return .unauthorized
            case .lockedOut(let until): return .lockedOut(until: until)
            case .unsupported(let reason): return .unsupported(reason)
            case .soapFault(let reason):
                let lowered = reason.lowercased()
                if lowered.contains("actionnotsupported") || lowered.contains("notsupported") { return .unsupported(reason) }
                // A bare "Sender" (the SOAP code, with no subcode or reason): the camera cannot take the request at all, as
                // a Reolink doorbell answers an OSD change it has no ability for.
                if lowered == "sender" { return .unsupported("the camera rejects the request (SOAP Sender fault)") }
                return .rejected(reason)
            case .httpStatus(let status):
                return [404, 405, 501].contains(status) ? .unsupported("HTTP \(status)") : .rejected("HTTP \(status)")
            case .invalidResponse(let reason): return .rejected("unreadable answer (\(reason))")
            case .apiError(let command, let code):
                // -9 "not support", -26 "ability error": the camera does not have the feature, and asking again will not give it.
                return ReolinkAPI.unsupportedCodes.contains(code) ? .unsupported("\(command) not supported") : .rejected("\(command) error \(code)")
            }
        default:
            return .network("the camera did not answer")
        }
    }
}

/// One method's failed attempt.
public struct CameraConfigAttempt: Sendable, Equatable {
    public var method: CameraConfigMethod
    public var failure: CameraConfigFailure

    public init(method: CameraConfigMethod, failure: CameraConfigFailure) {
        self.method = method
        self.failure = failure
    }

    /// "ONVIF minimal: InvalidArgVal"
    public var summary: String { "\(method.displayName): \(failure.summary)" }

    /// "ONVIF minimal: InvalidArgVal; ISAPI: unsupported"
    public static func summary(_ attempts: [CameraConfigAttempt]) -> String {
        attempts.map(\.summary).joined(separator: "; ")
    }
}

/// One stream's encoder change for `CameraSettingsService.applyEncoder`.
public struct CameraEncoderEdit: Sendable, Equatable {
    public var isSub: Bool
    /// The settings the stream should end up with (a full settings value; only what differs from the camera's current
    /// values is changed by the minimal methods).
    public var desired: CameraVideoEncoderSettings
    /// The camera's reported options for the stream, used to clamp values on ONVIF minimal.
    public var options: [CameraVideoEncoderOptions]

    public init(isSub: Bool, desired: CameraVideoEncoderSettings, options: [CameraVideoEncoderOptions] = []) {
        self.isSub = isSub
        self.desired = desired
        self.options = options
    }
}

/// What happened to one `CameraEncoderEdit`.
public struct CameraEncoderEditResult: Sendable, Equatable {
    public var isSub: Bool
    /// True when the settings now match (written and read back, or already as wanted).
    public var succeeded: Bool
    /// The method that wrote the change; nil when it failed or nothing needed writing.
    public var method: CameraConfigMethod?
    /// Methods that failed, in order: all of them when `succeeded` is false, the ones before the winner otherwise.
    public var failures: [CameraConfigAttempt]

    public init(isSub: Bool, succeeded: Bool, method: CameraConfigMethod?, failures: [CameraConfigAttempt]) {
        self.isSub = isSub
        self.succeeded = succeeded
        self.method = method
        self.failures = failures
    }

    /// "via ISAPI", "already set", or "ONVIF minimal: InvalidArgVal; ONVIF full: InvalidArgVal".
    public var summary: String {
        if succeeded { return method.map { "via \($0.displayName)" } ?? "already set" }
        return CameraConfigAttempt.summary(failures)
    }
}

/// Thrown by `CameraSettingsService.apply` when no method could change an encoder.
public struct CameraConfigError: Error, Equatable, Sendable {
    public var attempts: [CameraConfigAttempt]
    public init(attempts: [CameraConfigAttempt]) { self.attempts = attempts }

    public var summary: String { CameraConfigAttempt.summary(attempts) }
}

/// What the engine should do with the camera's remembered method after a service call.
public enum CameraConfigMemoryUpdate: Sendable, Equatable {
    case remember(CameraConfigMethod)
    case forget
}

/// The video settings a method reads and writes (units as `CameraVideoEncoderSettings`).
struct EncoderValues: Sendable, Equatable {
    var codec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var bitrate: Int?
    var govLength: Int?
    var h264Profile: String?

    var isEmpty: Bool {
        codec == nil && width == nil && height == nil && frameRate == nil && bitrate == nil && govLength == nil && h264Profile == nil
    }

    /// "H.264", "h264", "AVC" → "H264"; "H.265", "HEVC" → "H265"; anything else uppercased without punctuation.
    static func normalizedCodec(_ text: String) -> String {
        let cleaned = text.uppercased().filter { $0 != "." && $0 != "-" && $0 != " " }
        switch cleaned {
        case "AVC": return "H264"
        case "HEVC": return "H265"
        default: return cleaned
        }
    }

    /// What must change so these current values become `desired`, and the wanted fields the camera did not report (a
    /// method cannot change a setting it cannot see, so those are left out of the change).
    func changes(toReach desired: CameraVideoEncoderSettings) -> (changes: EncoderValues, unreadable: [String]) {
        var result = EncoderValues()
        var unreadable: [String] = []
        let wanted = Self.normalizedCodec(desired.encoding)
        if let codec {
            if codec != wanted { result.codec = wanted }
        } else {
            unreadable.append("codec")
        }
        if let resolution = desired.resolution {
            if let width, let height {
                if width != resolution.width || height != resolution.height {
                    result.width = resolution.width
                    result.height = resolution.height
                }
            } else {
                unreadable.append("resolution")
            }
        }
        if let rate = desired.frameRate {
            if let frameRate {
                if abs(frameRate - rate) > 0.01 { result.frameRate = rate }
            } else {
                unreadable.append("frame rate")
            }
        }
        if let target = desired.bitrate {
            if let bitrate {
                if bitrate != target { result.bitrate = target }
            } else {
                unreadable.append("bitrate")
            }
        }
        if let target = desired.iFrameInterval {
            if let govLength {
                if govLength != target { result.govLength = target }
            } else {
                unreadable.append("keyframe interval")
            }
        }
        if let target = desired.h264Profile {
            if let h264Profile {
                if h264Profile.caseInsensitiveCompare(target) != .orderedSame { result.h264Profile = target }
            } else {
                unreadable.append("profile")
            }
        }
        return (result, unreadable)
    }

    /// These changes with frame rate, bit rate and keyframe interval clamped into the camera's reported ranges.
    func clamped(to options: CameraVideoEncoderOptions?) -> EncoderValues {
        guard let options else { return self }
        var result = self
        if let frameRate, let range = options.frameRateRange { result.frameRate = min(max(frameRate, range.lowerBound), range.upperBound) }
        if let bitrate, let range = options.bitrateRange { result.bitrate = min(max(bitrate, range.lowerBound), range.upperBound) }
        if let govLength, let range = options.iFrameIntervalRange { result.govLength = min(max(govLength, range.lowerBound), range.upperBound) }
        return result
    }

    /// These changes without the fields that already equal `current` (what a clamp can leave behind).
    func dropping(unchangedFrom current: EncoderValues) -> EncoderValues {
        var result = self
        if result.codec == current.codec { result.codec = nil }
        if result.width == current.width && result.height == current.height { result.width = nil; result.height = nil }
        if result.frameRate == current.frameRate { result.frameRate = nil }
        if result.bitrate == current.bitrate { result.bitrate = nil }
        if result.govLength == current.govLength { result.govLength = nil }
        if result.h264Profile == current.h264Profile { result.h264Profile = nil }
        return result
    }

    /// Whether values read back from the camera show every field of `expected` (the camera may round the bit rate).
    func satisfies(_ expected: EncoderValues) -> Bool {
        if let value = expected.codec, codec != value { return false }
        if let value = expected.width, width != value { return false }
        if let value = expected.height, height != value { return false }
        if let value = expected.frameRate {
            guard let frameRate, abs(frameRate - value) <= 0.5 else { return false }
        }
        if let value = expected.bitrate {
            guard let bitrate, abs(bitrate - value) <= max(64, value / 10) else { return false }
        }
        if let value = expected.govLength, govLength != value { return false }
        if let value = expected.h264Profile {
            guard let h264Profile, h264Profile.caseInsensitiveCompare(value) == .orderedSame else { return false }
        }
        return true
    }
}
