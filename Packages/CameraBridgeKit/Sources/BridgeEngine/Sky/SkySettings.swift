import BridgeSupport
import Foundation

/// Where the box is, for the Sky Watcher: WGS84 in degrees (longitude east of Greenwich, so 100° W is −100) and the height above sea level in
/// metres. It is kept only on this box: it is in `config.json`, in the signed-in page's settings and in nothing else. It never appears in a log
/// line, the diagnostics, a notification, an AI request or an export; online requests carry only a rounded centre. Printed, interpolated or
/// dumped, it says only that it is hidden (like `SkyObserver`).
public struct SkyLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var heightMeters: Double

    /// The heights a home can have (the Dead Sea to the high Andes).
    public static let heightRange: ClosedRange<Double> = -500...9_000

    public init(latitude: Double, longitude: Double, heightMeters: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.heightMeters = heightMeters
    }

    /// A latitude from −90 to 90 and a longitude from −180 to 180, and not (0, 0) (an unset place reads like that).
    var hasPlace: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }

    var hasPossibleHeight: Bool { heightMeters.isFinite && Self.heightRange.contains(heightMeters) }

    /// Whether the maths can use it.
    public var isValid: Bool { hasPlace && hasPossibleHeight }

    private enum CodingKeys: String, CodingKey { case latitude, longitude, heightMeters }

    /// The height is optional (a place saved with two numbers is at 0 m), and one that is not a number is 0 too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        heightMeters = (try? container.decodeIfPresent(Double.self, forKey: .heightMeters)) ?? 0
    }
}

extension SkyLocation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SkyLocation(location hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The bridge-wide Sky Watcher settings (`BridgeSettings.sky`): where the box is, the flight feed on the home network, and the AI's daily limit
/// for what the box cannot explain. Nothing is sent off the box while no camera has the Sky Watcher on. Decoding is lenient: a missing or
/// unreadable value takes its default and the others are read, logged by key name (never by value: one of them is where the box is).
public struct SkySettings: Codable, Sendable, Equatable {
    /// nil until the person says where the box is (typed in, or taken from the browser).
    public var location: SkyLocation?
    /// A flight feed on the network (dump1090, readsb, tar1090 or PiAware `aircraft.json`): http or https, with a host. nil: none set.
    public var flightFeedURL: String?
    /// The most questions to the AI service a day about lights nothing else explains (`aiDailyLimitRange`), separate from event descriptions.
    public var aiDailyLimit: Int

    public static let aiDailyLimitRange = 1...1_000
    public static let defaultAIDailyLimit = 50
    static let maximumFeedLength = 500

    /// What is wrong with settings that cannot be saved: the field in the settings answer (`sky.location`, `sky.flightFeedURL`, `sky.aiDailyLimit`,
    /// or `skyDetector.…` for a camera's) and the words for the person. The words never repeat what was typed.
    public struct Problem: Equatable, Sendable {
        public var field: String
        public var message: String

        public init(field: String, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// No place, no feed, 50 questions a day.
    public init(location: SkyLocation? = nil, flightFeedURL: String? = nil, aiDailyLimit: Int = SkySettings.defaultAIDailyLimit) {
        self.location = location
        self.flightFeedURL = flightFeedURL
        self.aiDailyLimit = aiDailyLimit
    }

    private enum CodingKeys: String, CodingKey { case location, flightFeedURL, aiDailyLimit }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String] = []
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                unreadable.append(key.stringValue)
                return fallback
            }
        }
        // What this build would refuse to save takes its default, so what was loaded can always be saved again.
        if let place: SkyLocation = value(.location, default: nil) {
            if place.isValid { location = place } else { unreadable.append(CodingKeys.location.stringValue) }
        }
        if let feed: String = value(.flightFeedURL, default: nil) {
            if Self.isValidFeed(feed) { flightFeedURL = feed } else { unreadable.append(CodingKeys.flightFeedURL.stringValue) }
        }
        let limit = value(.aiDailyLimit, default: aiDailyLimit)
        if Self.aiDailyLimitRange.contains(limit) { aiDailyLimit = limit } else { unreadable.append(CodingKeys.aiDailyLimit.stringValue) }
        if !unreadable.isEmpty {
            Log(category: "Engine").warning("Unreadable Sky Watcher settings \(unreadable.joined(separator: ", ")) in the configuration; defaults are used")
        }
    }

    // MARK: Validation

    /// The first thing wrong with these settings, the place first, then the feed, then the limit; nil when they can be saved.
    public var validationProblem: Problem? {
        if let location {
            if !location.hasPlace {
                return Problem(field: "sky.location", message: "Where the box is needs a latitude from −90 to 90 and a longitude from −180 to 180, and not 0 and 0 together.")
            }
            if !location.hasPossibleHeight {
                return Problem(field: "sky.location", message: "The box’s height above sea level isn’t one this can use.")
            }
        }
        if let flightFeedURL, !Self.isValidFeed(flightFeedURL) {
            return Problem(field: "sky.flightFeedURL", message: "Enter the flight feed’s address as a browser shows it, like http://192.168.77.20/tar1090/data/aircraft.json: "
                + "http or https, with a host, no name or password in it, and nothing after a #.")
        }
        if !Self.aiDailyLimitRange.contains(aiDailyLimit) {
            return Problem(field: "sky.aiDailyLimit", message: "The Sky Watcher’s daily limit for asking the AI is \(Self.aiDailyLimitRange.lowerBound) to 1,000.")
        }
        return nil
    }

    /// A feed's address: http or https, a host, no user info, no fragment, one line of at most `maximumFeedLength` characters. (A query is
    /// allowed: some feeds are served with one.)
    static func isValidFeed(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumFeedLength,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                                                      || $0.properties.generalCategory == .paragraphSeparator || $0.properties.isWhitespace }),
              let components = URLComponents(string: text), URL(string: text) != nil,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else { return false }
        return true
    }
}

extension BridgeSettings {
    /// Whether the Sky Watcher plugin is switched on: the switch on the Plugins page, kept as `plugins["sky"]`. It is off on a new box. While it is
    /// off the box runs none of the Sky Watcher (no detector, no flight feed, no downloads) and no camera can be turned on for it; the box's own
    /// Sky Watcher settings and each camera's are kept, so switching it on again brings the same cameras back.
    public var skyPluginOn: Bool { plugins["sky"]?.enabled == true }
}

/// How a sky camera's picture is made of lenses: one lens, or two side by side that the camera stitches (`SkyCameraModel`).
public enum SkyLensLayout: String, Codable, Sendable, CaseIterable {
    case single, dual
}

/// One camera's Sky Watcher settings (`CameraConfiguration.skyDetector`; nil: never set). Applied in place: changing them never restarts the camera.
/// Decoding is lenient: a missing, unreadable or out-of-range value takes its default, and a layout this build does not know (a newer build wrote
/// it) is automatic.
public struct SkyDetectorSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Which way the camera faces, degrees clockwise from true north (`facingRange`): 0 is north.
    public var facing: Double
    /// How far above the horizon it looks, degrees (`tiltRange`).
    public var tilt: Double
    /// How much of the bottom of the picture is ground and horizon, percent (`groundPercentRange`).
    public var groundPercent: Int
    /// Whether the camera is put on its night-sky settings after sunset (and back after sunrise).
    public var nightProfile: Bool
    /// nil: automatic (two lenses for a picture of 2:1 or wider, else one).
    public var lensLayout: SkyLensLayout?

    public static let facingRange: Range<Double> = 0..<360
    public static let tiltRange: ClosedRange<Double> = 0...90
    public static let groundPercentRange = 0...60

    /// Off, facing north, 20° up, 12 % ground, the night profile on, the lenses automatic.
    public init(enabled: Bool = false, facing: Double = 0, tilt: Double = 20, groundPercent: Int = 12, nightProfile: Bool = true, lensLayout: SkyLensLayout? = nil) {
        self.enabled = enabled
        self.facing = facing
        self.tilt = tilt
        self.groundPercent = groundPercent
        self.nightProfile = nightProfile
        self.lensLayout = lensLayout
    }

    private enum CodingKeys: String, CodingKey { case enabled, facing, tilt, groundPercent, nightProfile, lensLayout }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String] = []
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                unreadable.append(key.stringValue)
                return fallback
            }
        }
        enabled = value(.enabled, default: enabled)
        nightProfile = value(.nightProfile, default: nightProfile)
        let facing = value(.facing, default: self.facing)
        if Self.facingRange.contains(facing) { self.facing = facing } else { unreadable.append(CodingKeys.facing.stringValue) }
        let tilt = value(.tilt, default: self.tilt)
        if Self.tiltRange.contains(tilt) { self.tilt = tilt } else { unreadable.append(CodingKeys.tilt.stringValue) }
        let ground = value(.groundPercent, default: groundPercent)
        if Self.groundPercentRange.contains(ground) { groundPercent = ground } else { unreadable.append(CodingKeys.groundPercent.stringValue) }
        if let name: String = value(.lensLayout, default: nil) {
            if let layout = SkyLensLayout(rawValue: name) { lensLayout = layout } else { unreadable.append(CodingKeys.lensLayout.stringValue) }
        }
        if !unreadable.isEmpty {
            Log(category: "Engine").warning("Unreadable Sky Watcher camera settings \(unreadable.joined(separator: ", ")) in the configuration; defaults are used")
        }
    }

    /// Every key is written, `lensLayout` as null while the lenses are automatic: the page reads the key, and a camera that never had one saved
    /// reads as automatic all the same.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(facing, forKey: .facing)
        try container.encode(tilt, forKey: .tilt)
        try container.encode(groundPercent, forKey: .groundPercent)
        try container.encode(nightProfile, forKey: .nightProfile)
        try container.encode(lensLayout, forKey: .lensLayout)
    }

    /// The first thing wrong with these settings; nil when they can be saved.
    public var validationProblem: SkySettings.Problem? {
        if !Self.facingRange.contains(facing) {
            return SkySettings.Problem(field: "skyDetector.facing", message: "Choose which way the camera faces: 0 up to 360 degrees from north.")
        }
        if !Self.tiltRange.contains(tilt) {
            return SkySettings.Problem(field: "skyDetector.tilt", message: "The tilt above the horizon is 0 to 90 degrees.")
        }
        if !Self.groundPercentRange.contains(groundPercent) {
            return SkySettings.Problem(field: "skyDetector.groundPercent", message: "Ground and horizon at the bottom of the picture is 0 to 60 percent.")
        }
        return nil
    }
}
