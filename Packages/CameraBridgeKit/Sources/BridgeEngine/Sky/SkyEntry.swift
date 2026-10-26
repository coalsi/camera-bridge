import Foundation

/// What the Sky Watcher logs a light as having been: a track that crossed the sky, a light that appeared and stayed or went (a point light), or a
/// flash.
public enum SkyEntryKind: String, Codable, Sendable {
    case track, newLight, flash
}

/// What gave a log entry its label.
public enum SkyLabelSource: String, Codable, Sendable {
    case flight, orbit, rule, model, ai, person
}

/// What a person says an entry was ("That was a…": the buttons Plane, Bird, Bug, Satellite, Meteor and Not sure).
public enum SkyCorrection: String, Codable, Sendable, CaseIterable {
    case plane, bird, bug, satellite, meteor, notSure
}

/// Why an unexplained light is unusual (compared with the planes and satellites known at that place in the view).
public enum SkyUnusualReason: String, Codable, Sendable {
    case faster, larger, brighter, suddenStop, sharpTurn
}

/// One point of an entry's path: seconds from its start, and where in the camera's ORIGINAL picture (never the straightened one), 0…1 from the
/// left and from the top.
public struct SkyPathPoint: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double

    /// A path is kept with at most this many points, evenly picked.
    public static let maximumPerEntry = 64

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

/// What the AI service said about a light: `kind` is one of its kinds (a `SkyAIKind` raw value: plane, satellite, bird, insect, meteor, balloon,
/// drone, artifact, unknown), `sentence` its one sentence, `model` which model, `at` when.
public struct SkyAIAnswer: Codable, Sendable, Equatable {
    public var kind: String
    public var sentence: String
    public var model: String
    public var at: Date

    public static let maximumSentenceLength = 600
    static let maximumModelLength = 100
    static let maximumKindLength = 40

    public init(kind: String, sentence: String, model: String, at: Date) {
        self.kind = kind
        self.sentence = sentence
        self.model = model
        self.at = at
    }
}

/// One light in the sky log. Times are the box's clock; the path is in the original picture; the measures are on the sky, in degrees and
/// ratios, never in real units. `label` is what the box decided and `by` what decided it; `correction` is the person's word, which wins on
/// screen (`SkyDisplay.label`) and counts most to the box's learning. `candidate`: unexplained and unusual (`unusual` not empty: Task 11), so it
/// may alert once the camera has learned its sky. `hasStill`: a picture of it was kept (`SkyLogStore.writeStill`). An unexplained light has
/// `priority` and `reasons` (`SkyGuide`: how interesting it is and why, in short phrases for the page); `doubtful` when the rules doubt it is a
/// light at all (`SkyRules.doubt`), and `group` (set when the log is read, `SkyFormations`) names the lights it moved together with.
/// `sortedLater`: logged before the rules, and sorted by them as the log was read (`SkySortLater`): its label, `by`, `detail` and the guide's
/// fields are the rules' now, not the log's. Neither it nor `group` is ever kept.
public struct SkyEntry: Codable, Sendable, Equatable, Identifiable {
    /// Letters, digits, `-` and `_`, 1 to 64 of them (`isValidID`): it names the entry's picture, so it must be safe in a path.
    public var id: String
    public var camera: UUID
    public var kind: SkyEntryKind
    public var start: Date
    public var end: Date
    /// At most `SkyPathPoint.maximumPerEntry` points.
    public var path: [SkyPathPoint]
    public var measures: SkyMeasures
    public var label: SkyLabel
    public var by: SkyLabelSource?
    /// "TEST123 · 35,000 ft", "ISS (ZARYA)": what the label rests on, when it has something to show.
    public var detail: String?
    public var unusual: [SkyUnusualReason]
    /// How much faster across the sky than the planes known at that place in the view (a ratio; never a real speed).
    public var speedVsPlanes: Double?
    public var candidate: Bool
    public var alerted: Bool
    public var hasStill: Bool
    public var ai: SkyAIAnswer?
    public var correction: SkyCorrection?
    public var priority: SkyPriority?
    public var reasons: [String]
    public var doubtful: Bool
    public var group: String?
    /// Set as the log is read (`SkySortLater`), never written or read back (it is not one of the coding keys).
    public var sortedLater: Bool

    public static let maximumDetailLength = 200
    public static let maximumIDLength = 64
    /// An entry keeps at most this many reasons, each at most this long.
    static let maximumReasons = 8
    static let maximumReasonLength = 160

    public init(id: String, camera: UUID, kind: SkyEntryKind, start: Date, end: Date, path: [SkyPathPoint], measures: SkyMeasures, label: SkyLabel,
                by: SkyLabelSource? = nil, detail: String? = nil, unusual: [SkyUnusualReason] = [], speedVsPlanes: Double? = nil, candidate: Bool = false,
                alerted: Bool = false, hasStill: Bool = false, ai: SkyAIAnswer? = nil, correction: SkyCorrection? = nil, priority: SkyPriority? = nil,
                reasons: [String] = [], doubtful: Bool = false, group: String? = nil, sortedLater: Bool = false) {
        self.id = id
        self.camera = camera
        self.kind = kind
        self.start = start
        self.end = end
        self.path = path
        self.measures = measures
        self.label = label
        self.by = by
        self.detail = detail
        self.unusual = unusual
        self.speedVsPlanes = speedVsPlanes
        self.candidate = candidate
        self.alerted = alerted
        self.hasStill = hasStill
        self.ai = ai
        self.correction = correction
        self.priority = priority
        self.reasons = reasons
        self.doubtful = doubtful
        self.group = group
        self.sortedLater = sortedLater
    }

    /// Whether `text` can be an entry's id: 1 to 64 ASCII letters, digits, `-` and `_`.
    public static func isValidID(_ text: String) -> Bool {
        guard (1...maximumIDLength).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, camera, kind, start, end, path, measures, label, by, detail, unusual, speedVsPlanes, candidate, alerted, hasStill, ai, correction
        case priority, reasons, doubtful, group
    }

    /// An entry written without the fields a later build added (or with a value it cannot read) reads with their defaults; the entry's own
    /// identity, times, path, measures and label are required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        camera = try container.decode(UUID.self, forKey: .camera)
        kind = try container.decode(SkyEntryKind.self, forKey: .kind)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        path = try container.decode([SkyPathPoint].self, forKey: .path)
        measures = try container.decode(SkyMeasures.self, forKey: .measures)
        label = try container.decode(SkyLabel.self, forKey: .label)
        by = (try? container.decodeIfPresent(SkyLabelSource.self, forKey: .by)) ?? nil
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        unusual = ((try? container.decodeIfPresent([String].self, forKey: .unusual)) ?? nil)?.compactMap(SkyUnusualReason.init(rawValue:)) ?? []
        speedVsPlanes = (try? container.decodeIfPresent(Double.self, forKey: .speedVsPlanes)) ?? nil
        candidate = (try? container.decodeIfPresent(Bool.self, forKey: .candidate)) ?? false
        alerted = (try? container.decodeIfPresent(Bool.self, forKey: .alerted)) ?? false
        hasStill = (try? container.decodeIfPresent(Bool.self, forKey: .hasStill)) ?? false
        ai = (try? container.decodeIfPresent(SkyAIAnswer.self, forKey: .ai)) ?? nil
        correction = (try? container.decodeIfPresent(SkyCorrection.self, forKey: .correction)) ?? nil
        priority = (try? container.decodeIfPresent(SkyPriority.self, forKey: .priority)) ?? nil
        reasons = ((try? container.decodeIfPresent([String].self, forKey: .reasons)) ?? nil) ?? []
        doubtful = (try? container.decodeIfPresent(Bool.self, forKey: .doubtful)) ?? false
        group = (try? container.decodeIfPresent(String.self, forKey: .group)) ?? nil
        sortedLater = false
    }
}

/// What the log shows an entry as: a person's correction wins (plane, bird, bug, satellite, meteor), and "not sure" shows the entry's own label.
public struct SkyDisplay: Sendable {
    public static func label(_ entry: SkyEntry) -> SkyLabel {
        switch entry.correction {
        case .plane?: .plane
        case .bird?: .bird
        case .bug?: .bug
        case .satellite?: .satellite
        case .meteor?: .meteor
        case .notSure?, nil: entry.label
        }
    }
}

// MARK: - A night's log as the page reads it

/// How clearly the sky could be seen for a stretch of time.
public enum SkyConditionState: String, Codable, Sendable {
    case clear, cloudy, notVisible, unknown
}

/// A stretch of time and how the sky was ("☁︎ clear until 3 AM; sky not visible 3–5 AM"): `cloudCover` percent when the weather said.
public struct SkyConditions: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var state: SkyConditionState
    public var cloudCover: Int?

    public init(from: Date, to: Date, state: SkyConditionState, cloudCover: Int? = nil) {
        self.from = from
        self.to = to
        self.state = state
        self.cloudCover = cloudCover
    }
}

/// The counts above a night's log: "Last night: 1 unexplained, 214 explained". Counted by what the log shows (`SkyDisplay.label`): a person's
/// word wins, and a light they were not sure of, among the explained, is `notSure`.
public struct SkyCounts: Codable, Sendable, Equatable {
    public var unexplained: Int
    public var planes: Int
    public var satellites: Int
    public var meteors: Int
    public var bugsAndBirds: Int
    public var notSure: Int
    public var explained: Int

    public init(unexplained: Int = 0, planes: Int = 0, satellites: Int = 0, meteors: Int = 0, bugsAndBirds: Int = 0, notSure: Int = 0, explained: Int = 0) {
        self.unexplained = unexplained
        self.planes = planes
        self.satellites = satellites
        self.meteors = meteors
        self.bugsAndBirds = bugsAndBirds
        self.notSure = notSure
        self.explained = explained
    }

    /// The counts of `entries`: planes and satellites (including probable ones, and satellites' flares), meteors, bugs and birds, the explained ones the
    /// person was not sure of, and the unexplained; `explained` is the sum of all but the last.
    public init(counting entries: [SkyEntry]) {
        self.init()
        for entry in entries {
            switch (SkyDisplay.label(entry), entry.correction == .notSure) {
            case (.unexplained, _): unexplained += 1
            case (_, true): notSure += 1
            case (.plane, _), (.probablePlane, _): planes += 1
            case (.satellite, _), (.probableSatellite, _), (.satelliteFlare, _): satellites += 1
            case (.meteor, _): meteors += 1
            case (.bug, _), (.bird, _): bugsAndBirds += 1
            }
        }
        explained = planes + satellites + meteors + bugsAndBirds + notSure
    }
}

/// Whether the box has learned this camera's sky ("Still learning this sky: 12 of 30 planes matched. No alerts until then."): matched planes and
/// satellites against what the baseline needs.
public struct SkyLearning: Codable, Sendable, Equatable {
    public var ready: Bool
    public var planes: Int
    public var satellites: Int

    public static let planesNeeded = 30
    public static let satellitesNeeded = 10

    public init(ready: Bool, planes: Int, satellites: Int) {
        self.ready = ready
        self.planes = planes
        self.satellites = satellites
    }
}

/// A clock hour in which a camera followed more lights that nothing explains than it logs (`SkyLightFilter.unexplainedPerHour`, 60): when the
/// hour began, and how many more there were, counted and not logged ("4 PM: 212 more lights weren't logged").
public struct SkyCappedHour: Codable, Sendable, Equatable {
    public var hour: Date
    public var count: Int

    public init(hour: Date, count: Int) {
        self.hour = hour
        self.count = count
    }
}

/// A night's (or a day's) log of one camera, as `BridgeEngine.skyNightLog` reads it: the entries and conditions of `from…to`, their counts, the
/// hours of it in which more lights were followed than logged (`capped`, oldest first), and the camera's aim and learning now. `night` names the
/// log (the local date of its sunset; a day by its own date).
public struct SkyNightLog: Sendable, Equatable {
    public var camera: UUID
    public var night: String
    public var view: SkyLogView
    public var from: Date
    public var to: Date
    public var entries: [SkyEntry]
    public var conditions: [SkyConditions]
    public var counts: SkyCounts
    public var aim: SkyAimStatus
    public var learning: SkyLearning
    public var capped: [SkyCappedHour]
    /// How big the night's pictures are (from the newest light with one that can be read), for the page to draw a path over a thumbnail of one; nil when
    /// none can be read.
    public var picture: SkyPictureSize?

    public init(camera: UUID, night: String, view: SkyLogView, from: Date, to: Date, entries: [SkyEntry], conditions: [SkyConditions], counts: SkyCounts,
                aim: SkyAimStatus, learning: SkyLearning, capped: [SkyCappedHour] = [], picture: SkyPictureSize? = nil) {
        self.camera = camera
        self.night = night
        self.view = view
        self.from = from
        self.to = to
        self.entries = entries
        self.conditions = conditions
        self.counts = counts
        self.aim = aim
        self.learning = learning
        self.capped = capped
        self.picture = picture
    }
}

/// Why the sky log cannot answer, in the words the person reads.
public enum SkyLogError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The box does not know where it is (the sun's times and the aim need it).
    case noLocation
    /// No place for recordings is chosen: the log is kept with them.
    case noFolder
    /// A night's name is not a date.
    case unknownNight
    /// The log has no such entry.
    case unknownEntry
    /// The entry has no picture.
    case noStill
    /// This bridge keeps no sky log (a backend without one).
    case unavailable

    public var description: String {
        switch self {
        case .noLocation: "Set where the box is first."
        case .noFolder: "Choose a recordings folder first: the sky log is kept with the recordings."
        case .unknownNight: "That isn’t a night in the sky log."
        case .unknownEntry: "That isn’t in the sky log."
        case .noStill: "There is no picture of it."
        case .unavailable: "This bridge keeps no sky log."
        }
    }
}
