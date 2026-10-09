import Foundation
import Synchronization

/// Which corner of the picture the timestamp overlay sits in.
public enum OverlayPosition: String, Sendable, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// How large the timestamp overlay is, relative to the output picture's height (so it looks the same at 360p and 1080p).
public enum OverlaySize: String, Sendable, Codable, CaseIterable {
    case small, medium, large

    /// The overlay's font size as a fraction of the output height.
    public var fontHeightFraction: Double {
        switch self {
        case .small: 0.026
        case .medium: 0.032
        case .large: 0.042
        }
    }
}

/// The per-camera "CameraBridge timestamp" overlay: the Mac's clock drawn on every transcoded live and recorded picture,
/// so every camera shows the same time whatever its own clock says. Decoding fills every missing or unreadable key with
/// its default (settings written by an older or newer build never fail to load).
public struct TimestampOverlaySettings: Sendable, Codable, Equatable {
    /// Off by default. Turning it on makes live view and recording use the Mac's video encoder (no passthrough).
    public var enabled: Bool
    /// Top right by default: the Home app keeps its own controls at the top left and its timeline at the bottom.
    public var position: OverlayPosition
    /// The camera's name in front of the time.
    public var showCameraName: Bool
    /// The date ("Thu, Oct 2") in front of the time.
    public var showDate: Bool
    /// The seconds ("7:42:15 PM" instead of "7:42 PM").
    public var showSeconds: Bool
    /// 24-hour time instead of 12-hour; by default what the Mac's region uses.
    public var use24Hour: Bool
    public var size: OverlaySize

    public init(enabled: Bool = false, position: OverlayPosition = .topRight, showCameraName: Bool = false, showDate: Bool = true,
                showSeconds: Bool = true, use24Hour: Bool = TimestampOverlayText.systemUses24Hour, size: OverlaySize = .medium) {
        self.enabled = enabled
        self.position = position
        self.showCameraName = showCameraName
        self.showDate = showDate
        self.showSeconds = showSeconds
        self.use24Hour = use24Hour
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case enabled, position, showCameraName, showDate, showSeconds, use24Hour, size }

    public init(from decoder: any Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        enabled = value(.enabled, enabled)
        position = value(.position, position)
        showCameraName = value(.showCameraName, showCameraName)
        showDate = value(.showDate, showDate)
        showSeconds = value(.showSeconds, showSeconds)
        use24Hour = value(.use24Hour, use24Hour)
        size = value(.size, size)
    }
}

/// The words of one overlay: optional camera name, optional date, the time. System locale, Home-app style:
/// "Thu, Oct 2  7:42:15 PM".
public struct TimestampOverlayText: Sendable, Equatable {
    public var name: String?
    public var date: String?
    public var time: String

    public init(name: String? = nil, date: String? = nil, time: String) {
        self.name = name
        self.date = date
        self.time = time
    }

    /// Longest camera name shown; more is cut with an ellipsis.
    public static let maximumNameLength = 28

    /// The overlay's words for `date` (the Mac's clock) in `locale` and `timeZone`. The date uses the locale's own
    /// weekday/month/day pattern ("Thu, Oct 2"), the time its own pattern for 12- or 24-hour time (`settings.use24Hour`).
    public static func make(at date: Date, settings: TimestampOverlaySettings, cameraName: String = "", locale: Locale = .current,
                            timeZone: TimeZone = .current) -> TimestampOverlayText {
        let key = TextCache.Key(second: Int(date.timeIntervalSinceReferenceDate.rounded(.down)), showDate: settings.showDate,
                                showSeconds: settings.showSeconds, use24Hour: settings.use24Hour, showCameraName: settings.showCameraName,
                                cameraName: cameraName, locale: locale.identifier, timeZone: timeZone.identifier)
        if let cached = textCache.cached(key) { return cached }
        func format(_ template: String) -> String {
            let formatter = formatters.formatter(template: template, locale: locale, timeZone: timeZone)
            // ICU puts a narrow no-break space before AM/PM; a plain one is what the overlay's tests and fonts expect.
            return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let timeTemplate = (settings.use24Hour ? "H" : "h") + "m" + (settings.showSeconds ? "s" : "") + (settings.use24Hour ? "" : "a")
        let trimmedName = cameraName.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        if settings.showCameraName, !trimmedName.isEmpty {
            name = trimmedName.count > maximumNameLength ? String(trimmedName.prefix(maximumNameLength - 1)) + "…" : trimmedName
        }
        let text = TimestampOverlayText(name: name, date: settings.showDate ? format("EEEMMMd") : nil, time: format(timeTemplate))
        textCache.store(key, text)
        return text
    }

    /// The last words made, for the same second and settings: a stream draws the overlay on every picture (30 a second), and
    /// the words change once a second, so the formatting runs once a second instead of 30 times.
    private static let textCache = TextCache()
    private static let formatters = FormatterCache()

    private final class TextCache: Sendable {
        struct Key: Equatable, Sendable {
            var second: Int
            var showDate: Bool
            var showSeconds: Bool
            var use24Hour: Bool
            var showCameraName: Bool
            var cameraName: String
            var locale: String
            var timeZone: String
        }

        private let last = Mutex<(key: Key, text: TimestampOverlayText)?>(nil)

        func cached(_ key: Key) -> TimestampOverlayText? {
            last.withLock { entry in entry.flatMap { $0.key == key ? $0.text : nil } }
        }

        func store(_ key: Key, _ text: TimestampOverlayText) {
            last.withLock { $0 = (key, text) }
        }
    }

    /// `DateFormatter`s by template, locale and time zone (building one costs far more than formatting with it).
    private final class FormatterCache: Sendable {
        private let formatters = Mutex<[String: DateFormatter]>([:])

        func formatter(template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
            let key = "\(template)|\(locale.identifier)|\(timeZone.identifier)"
            return formatters.withLock { formatters in
                if let existing = formatters[key] { return existing }
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
                if formatters.count > 32 { formatters.removeAll() }
                formatters[key] = formatter
                return formatter
            }
        }
    }

    /// Whether the Mac's current region shows a 24-hour clock.
    public static var systemUses24Hour: Bool { uses24Hour(locale: .current) }

    /// Whether `locale`'s own time pattern is 24-hour (no AM/PM marker).
    public static func uses24Hour(locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
        return !pattern.contains("a")
    }
}

/// Where the overlay's time comes from. Pictures carry a `wallClock`; for RTSP that may be the camera's clock (RTCP
/// sender reports, within 3 s of arrival), so the clock turns it into the Mac's time.
public protocol OverlayClock: Sendable {
    /// The Mac's time to show on a picture whose `wallClock` is `pictureWallClock`.
    func displayTime(for pictureWallClock: Date) -> Date
}

/// Shows each picture's own `wallClock` unchanged.
public struct PictureWallClock: OverlayClock {
    public init() {}
    public func displayTime(for pictureWallClock: Date) -> Date { pictureWallClock }
}

/// Always the same moment (the Add/Settings preview, tests).
public struct FixedOverlayClock: OverlayClock {
    public var date: Date
    public init(_ date: Date) { self.date = date }
    public func displayTime(for pictureWallClock: Date) -> Date { date }
}

/// A picture's `wallClock` corrected by the offset measured at a `MediaHub` (`MediaHub.wallClockOffset`): the camera's
/// clock in, the Mac's clock out. A result more than an hour from `now` (a source with no usable timestamps) shows
/// `now` instead.
public struct OffsetOverlayClock: OverlayClock {
    private let offset: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date

    public init(offset: @escaping @Sendable () -> TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.offset = offset
        self.now = now
    }

    public func displayTime(for pictureWallClock: Date) -> Date {
        let shown = pictureWallClock.addingTimeInterval(offset())
        let current = now()
        guard shown.timeIntervalSince(current).magnitude < 3_600 else { return current }
        return shown
    }
}

/// What a transcoder draws on the pictures it encodes.
public struct TimestampOverlay: Sendable {
    public var settings: TimestampOverlaySettings
    public var cameraName: String
    public var clock: any OverlayClock

    public init(settings: TimestampOverlaySettings, cameraName: String = "", clock: any OverlayClock = PictureWallClock()) {
        self.settings = settings
        self.cameraName = cameraName
        self.clock = clock
    }

    /// The words for a picture captured at `pictureWallClock`.
    public func text(for pictureWallClock: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> TimestampOverlayText {
        TimestampOverlayText.make(at: clock.displayTime(for: pictureWallClock), settings: settings, cameraName: cameraName, locale: locale,
                                  timeZone: timeZone)
    }
}

/// Supplies the overlay a transcoder draws, asked for every picture: settings changed while a stream runs take effect
/// at once, and nil (overlay off) leaves the picture untouched.
public protocol TimestampOverlayProviding: Sendable {
    var current: TimestampOverlay? { get }
}

/// An overlay that never changes.
public struct StaticTimestampOverlay: TimestampOverlayProviding {
    public var overlay: TimestampOverlay?
    public init(_ overlay: TimestampOverlay?) { self.overlay = overlay }
    public var current: TimestampOverlay? { overlay }
}
