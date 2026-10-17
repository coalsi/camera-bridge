import Foundation

// Camera Bridge OS's internet guard in the engine, the pure pieces (docs/superpowers/specs/2026-10-17-internet-guard-design.md, stage 1):
// its words, what it saw of a camera for the camera page, the names it shows, and the day's notice. The engine's wiring (the step's
// address, the list kept in step with the box, the report polled as evidence) is BridgeEngine+InternetGuard.swift.

/// The internet guard's words (one table, so the guard and its levels can be renamed in one place; owner decision, 2026-10-17).
public enum InternetGuardText {
    public static let name = "Internet guard"
    /// The levels' names. Seal is not built yet (stage 2).
    public static let watch = "Watch"
    public static let seal = "Seal"
    /// The setup steps' titles ("Seal it from the internet" will be its own button, never part of a plain run).
    public static let watchStep = "Watch its internet"
    public static let sealStep = "Seal it from the internet"
    /// Why "Watch its internet" is not offered: on a bridge without the guard (the Mac, a development run), and for a camera the bridge has
    /// no address next to.
    public static let notOnThisBridge = "Camera Bridge OS watches cameras’ internet; this bridge does not."
    public static let notOnItsNetwork = "Camera Bridge can watch only cameras on its own local network."

    /// "Internet guard blocked 7 lookups from 2 cameras today."
    static func blockedToday(lookups: Int, cameras: Int) -> String {
        "\(name) blocked \(lookups) lookup\(lookups == 1 ? "" : "s") from \(cameras) camera\(cameras == 1 ? "" : "s") today."
    }

    static func noticeTitle(cameras: Int) -> String {
        cameras == 1 ? "A Camera Tried to Reach the Internet" : "Cameras Tried to Reach the Internet"
    }
}

extension GuardLevel {
    /// The level's name ("Watch").
    public var title: String {
        switch self {
        case .watch: InternetGuardText.watch
        }
    }
}

/// What the internet guard saw of a camera (`CameraSecurity.internetGuard`): whether it watches it, its blocked lookups today and in the
/// last 24 hours, and the names it asked for in the last 7 days, most asked first (at most 10, shown as `GuardNames.shown` has them).
public struct CameraGuardActivity: Sendable, Codable, Equatable {
    public var watched: Bool
    public var today: Int
    public var last24h: Int
    public var names: [GuardReport.Lookup]

    public init(watched: Bool, today: Int, last24h: Int, names: [GuardReport.Lookup]) {
        self.watched = watched
        self.today = today
        self.last24h = last24h
        self.names = names
    }

    /// At most this many names.
    public static let maximumNames = 10
}

/// The names a camera looked up as the bridge shows them: a part that looks like an identifier (at least 12 letters and digits with at
/// least 4 digits, as a camera's serial number or cloud id in a name would) becomes "*", so "a1b2c3d4e5f6.p2p.example.com" is shown as
/// "*.p2p.example.com".
enum GuardNames {
    static func shown(_ name: String) -> String {
        name.split(separator: ".", omittingEmptySubsequences: false).map { label in
            let digits = label.filter(\.isNumber).count
            let identifier = label.count >= 12 && digits >= 4 && label.contains(where: \.isLetter)
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            return identifier ? "*" : String(label)
        }.joined(separator: ".")
    }

    /// `lookups` with their names shown, one entry per shown name (counts added, the earliest first and the latest last), in their order.
    static func shown(_ lookups: [GuardReport.Lookup]) -> [GuardReport.Lookup] {
        var result: [GuardReport.Lookup] = []
        for lookup in lookups {
            let name = shown(lookup.name)
            if let index = result.firstIndex(where: { $0.name == name }) {
                result[index].count += lookup.count
                result[index].first = [result[index].first, lookup.first].compactMap { $0 }.min()
                result[index].last = [result[index].last, lookup.last].compactMap { $0 }.max()
            } else {
                result.append(GuardReport.Lookup(name: name, count: lookup.count, first: lookup.first, last: lookup.last))
            }
        }
        return result
    }
}

/// The bridge's notice for the day (one a day, from the first blocked lookup until the day ends; its figures are refreshed at most every
/// `EngineTuning.guardNoticeRefresh`): "Internet guard blocked N lookups from M cameras today.", with the camera that tried most for the
/// camera page it opens.
public struct InternetGuardNotice: Sendable, Equatable {
    /// Where the guard's day starts (`GuardReport.todayStart`).
    public var day: Date
    public var lookups: Int
    public var cameras: Int
    /// The camera that tried most today.
    public var cameraID: UUID?
    public var cameraName: String?
    /// When these figures were taken.
    public var date: Date

    public init(day: Date, lookups: Int, cameras: Int, cameraID: UUID?, cameraName: String?, date: Date) {
        self.day = day
        self.lookups = lookups
        self.cameras = cameras
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.date = date
    }

    public var title: String { InternetGuardText.noticeTitle(cameras: cameras) }
    public var sentence: String { InternetGuardText.blockedToday(lookups: lookups, cameras: cameras) }

    /// Today's figures of the watched `cameras` (by their address) from `report`; nil when nothing was blocked today or the box has no guard.
    static func make(report: GuardReport?, cameras: [(id: UUID, name: String, address: String)], now: Date) -> InternetGuardNotice? {
        guard let report, report.available else { return nil }
        var lookups = 0, count = 0
        var most: (id: UUID, name: String, today: Int)?
        for camera in cameras {
            guard let entry = report.camera(at: camera.address), entry.level == .watch, entry.today > 0 else { continue }
            lookups += entry.today
            count += 1
            if entry.today > (most?.today ?? 0) { most = (camera.id, camera.name, entry.today) }
        }
        guard lookups > 0 else { return nil }
        let day = report.todayStart ?? Calendar.current.startOfDay(for: now)
        return InternetGuardNotice(day: day, lookups: lookups, cameras: count, cameraID: most?.id, cameraName: most?.name, date: now)
    }
}
