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
    /// Its blocked lookups in the last 7 days (all the names, not only the `names` listed).
    public var last7d: Int

    public init(watched: Bool, today: Int, last24h: Int, names: [GuardReport.Lookup], last7d: Int = 0) {
        self.watched = watched
        self.today = today
        self.last24h = last24h
        self.names = names
        self.last7d = last7d
    }

    private enum CodingKeys: String, CodingKey { case watched, today, last24h, names, last7d }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watched = try container.decode(Bool.self, forKey: .watched)
        today = try container.decode(Int.self, forKey: .today)
        last24h = try container.decode(Int.self, forKey: .last24h)
        names = try container.decode([GuardReport.Lookup].self, forKey: .names)
        last7d = try container.decodeIfPresent(Int.self, forKey: .last7d) ?? 0
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

/// Something the internet guard found that needs the person (Camera Bridge OS's notifications): a camera seen trying the internet for
/// the first time (blocked, so it says so: once per camera, the notification log keeps it from coming back), or a camera it can no
/// longer watch. A blocked lookup of a watched camera is the guard working, so it raises nothing more.
public struct InternetGuardAlert: Sendable, Equatable {
    public enum Kind: String, Sendable { case firstTry, stoppedAsking }

    public var cameraID: UUID
    public var cameraName: String
    public var kind: Kind
    public var date: Date

    public init(cameraID: UUID, cameraName: String, kind: Kind, date: Date) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.kind = kind
        self.date = date
    }

    public var id: String { "guard-\(kind == .firstTry ? "tried" : "away")-\(cameraID.uuidString)" }
    public var isWarning: Bool { kind == .stoppedAsking }
    public var title: String {
        switch kind {
        case .firstTry: "\(cameraName) tried to reach the internet"
        case .stoppedAsking: "The Internet guard can’t watch \(cameraName)"
        }
    }
    public var detail: String {
        switch kind {
        case .firstTry: "Camera Bridge blocked it. Nothing got out."
        case .stoppedAsking: "\(cameraName) no longer asks Camera Bridge for its lookups. Run Set up for Camera Bridge again to watch it."
        }
    }

    /// A watched camera (by its address) the box has seen asking for a name outside the home network, now or in the last 7 days.
    static func firstTries(report: GuardReport?, cameras: [(id: UUID, name: String, address: String)], now: Date) -> [InternetGuardAlert] {
        guard let report, report.available else { return [] }
        return cameras.compactMap { camera in
            guard let entry = report.camera(at: camera.address), entry.level == .watch, entry.today > 0 || entry.last24h > 0 || !entry.names.isEmpty else { return nil }
            return InternetGuardAlert(cameraID: camera.id, cameraName: camera.name, kind: .firstTry, date: now)
        }
    }
}
