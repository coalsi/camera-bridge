import Foundation

/// One entry of the camera profiles feed (`GET /api/v1/camera-profiles`): what is known about a camera family.
public struct CameraProfile: Sendable, Equatable, Codable {
    /// The brand, matched case-insensitively against the camera's manufacturer and its `CameraVendor` name.
    public var vendor: String
    /// A regular expression matched (case-insensitively, anywhere in the text unless anchored) against the model.
    public var modelPattern: String
    public var firmwarePattern: String?
    /// The way to change this family's encoder first. A value this build doesn't know reads as nil.
    public var preferredConfigMethod: CameraConfigMethod?
    public var notes: String?
    /// Readiness check ID → steps that replace the advisor's built-in manual steps for it.
    public var manualSteps: [String: [String]]?

    public init(vendor: String, modelPattern: String, firmwarePattern: String? = nil, preferredConfigMethod: CameraConfigMethod? = nil,
                notes: String? = nil, manualSteps: [String: [String]]? = nil) {
        self.vendor = vendor
        self.modelPattern = modelPattern
        self.firmwarePattern = firmwarePattern
        self.preferredConfigMethod = preferredConfigMethod
        self.notes = notes
        self.manualSteps = manualSteps
    }

    private enum CodingKeys: String, CodingKey {
        case vendor, modelPattern, firmwarePattern, preferredConfigMethod, notes, manualSteps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try container.decode(String.self, forKey: .vendor)
        modelPattern = try container.decode(String.self, forKey: .modelPattern)
        firmwarePattern = try container.decodeIfPresent(String.self, forKey: .firmwarePattern)
        // An unknown method name (a newer feed) is no preference, not a broken feed.
        let methodName = try? container.decodeIfPresent(String.self, forKey: .preferredConfigMethod)
        preferredConfigMethod = methodName.flatMap { CameraConfigMethod(rawValue: $0) }
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        manualSteps = (try? container.decodeIfPresent([String: [String]].self, forKey: .manualSteps)) ?? nil
    }
}

/// What the feed says about one camera (the first matching profile wins per field).
public struct CameraProfileMatch: Sendable, Equatable {
    public var preferredConfigMethod: CameraConfigMethod?
    public var manualSteps: [String: [String]]
    public var notes: String?

    public static let empty = CameraProfileMatch(preferredConfigMethod: nil, manualSteps: [:], notes: nil)
}

/// The camera profiles feed: decoded leniently (a profile that doesn't parse is dropped, the rest still apply) and
/// matched against a camera's brand, model and firmware. Pure, portable logic: fetching and caching live in the app.
public struct CameraProfileFeed: Sendable, Equatable {
    public var version: String
    public var updated: String?
    public var profiles: [CameraProfile]

    public static let empty = CameraProfileFeed(version: "0", updated: nil, profiles: [])

    /// Longest text a pattern is matched against and longest pattern accepted (bounds a hostile or careless feed).
    static let maximumInputLength = 128
    static let maximumPatternLength = 200
    /// A feed larger than this is ignored.
    public static let maximumFeedBytes = 1_000_000

    public init(version: String, updated: String?, profiles: [CameraProfile]) {
        self.version = version
        self.updated = updated
        self.profiles = profiles
    }

    /// Decodes feed JSON. Nil when it isn't a feed at all (not JSON, no `profiles` array, or too large).
    public static func decode(_ data: Data) -> CameraProfileFeed? {
        guard data.count <= maximumFeedBytes, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return CameraProfileFeed(version: wire.version ?? "0", updated: wire.updated, profiles: wire.profiles.compactMap(\.value))
    }

    /// What the feed knows about this camera: `manufacturer` is the brand text the camera reported (or the vendor name),
    /// `vendor` the detected `CameraVendor`.
    public func match(vendor: CameraVendor?, manufacturer: String?, model: String?, firmware: String?) -> CameraProfileMatch {
        var result = CameraProfileMatch.empty
        for profile in profiles where Self.matches(profile, vendor: vendor, manufacturer: manufacturer, model: model, firmware: firmware) {
            if result.preferredConfigMethod == nil { result.preferredConfigMethod = profile.preferredConfigMethod }
            if result.notes == nil { result.notes = profile.notes }
            for (checkID, steps) in profile.manualSteps ?? [:] where result.manualSteps[checkID] == nil && !steps.isEmpty {
                result.manualSteps[checkID] = steps
            }
        }
        return result
    }

    static func matches(_ profile: CameraProfile, vendor: CameraVendor?, manufacturer: String?, model: String?, firmware: String?) -> Bool {
        let wanted = profile.vendor.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return false }
        let brand = (manufacturer ?? "").lowercased()
        guard (vendor?.rawValue == wanted) || (!brand.isEmpty && brand.contains(wanted)) else { return false }
        guard regexMatches(profile.modelPattern, in: model ?? "") else { return false }
        if let pattern = profile.firmwarePattern, !pattern.isEmpty {
            guard let firmware, !firmware.isEmpty, regexMatches(pattern, in: firmware) else { return false }
        }
        return true
    }

    /// Whether `pattern` (a case-insensitive regular expression) matches somewhere in `text`. An empty pattern matches
    /// anything; an invalid or over-long pattern matches nothing.
    static func regexMatches(_ pattern: String, in text: String) -> Bool {
        if pattern.isEmpty { return true }
        guard pattern.count <= maximumPatternLength, let regex = try? Regex(pattern).ignoresCase() else { return false }
        return (try? regex.firstMatch(in: String(text.prefix(maximumInputLength)))) != nil
    }

    private struct Wire: Decodable {
        var version: String?
        var updated: String?
        var profiles: [Lossy]

        enum CodingKeys: String, CodingKey { case version, updated, profiles }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .version) {
                version = text
            } else if let number = try? container.decode(Int.self, forKey: .version) {
                version = String(number)
            }
            updated = try? container.decodeIfPresent(String.self, forKey: .updated)
            profiles = try container.decode([Lossy].self, forKey: .profiles)
        }
    }

    private struct Lossy: Decodable {
        var value: CameraProfile?
        init(from decoder: any Decoder) throws { value = try? CameraProfile(from: decoder) }
    }
}

/// When the app should ask the server for the feed again.
public enum CameraProfileRefreshPolicy {
    public static let interval: Duration = .seconds(24 * 3600)

    /// True when the feed was never checked, or last checked at least `interval` ago (or "in the future": a clock change).
    public static func isDue(lastCheck: Date?, now: Date, interval: Duration = interval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed < 0 { return true }
        return elapsed >= Double(interval.components.seconds)
    }
}
