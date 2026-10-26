import Foundation

/// What the rules know of a light besides its measures (`SkyRules`): how it began, the daylight, where it went in the picture, and whether a
/// satellite could be in sunlight where it was.
struct SkyRuleLight: Sendable, Equatable {
    var measures: SkyMeasures
    var kind: SkyEntryKind = .track
    /// Born from two streaks along their own path (`SkyTrack.streakBorn`), and how many pictures it was seen in.
    var streakBorn = false
    var samples = 3
    /// The Sun's elevation at the light's middle (degrees).
    var sunElevation: Double
    /// How many lights began in the picture it began in, itself included (`SkyTracker.births`), and whether it began as the camera changed
    /// its whole picture (`SkyRules.cameraChangeLights` beginning in one picture, `SkyRules.cameraChangeWindow` around it).
    var beganWith = 1
    var afterCameraChange = false
    /// How many lights began within `SkyRules.meteorAloneWithin` of it, itself included: a meteor comes alone.
    var beganNear = 1
    /// Its way across the picture, from its first point to its last, in degrees from straight down (0: straight down; 180: straight up); nil
    /// when it did not move in the picture.
    var fromStraightDown: Double? = nil
    /// How far it went across the sky from one picture to the next (degrees); nil when not known.
    var degreesPerPicture: Double? = nil
    /// Whether a satellite on its line of sight could be in sunlight at its middle (`SkyRules.satelliteCouldBeSunlit`); nil when not known.
    var satelliteSunlit: Bool? = nil
}

/// What the rules call a light, and why, in the words the log shows under it (`SkyEntry.detail`).
struct SkyRuleVerdict: Sendable, Equatable {
    var label: SkyLabel
    var detail: String
}

/// The rules that tell what a light was when no flight (and, later, no orbit) explains it: meteors, bugs and birds (the plan's Task 11), and
/// the overnight prototype's probable planes and probable satellites, which told kinds apart on the owner's camera without any feed. Then, for
/// what they leave unexplained, the doubts: a light that is most likely not a light at all (the camera changing its picture, a twinkling light
/// hopping, a chain of noise, a track faster than anything in the sky could cross). Nothing here is a real size, distance or speed: the measures are on the sky, in degrees.
///
/// **Pinned (the plan's Task 11):**
/// - a meteor lasts at most 2 s, is at least 0.98 straight and does not blink; it is streak-born or seen in 3 pictures;
/// - a bug is blurred (focus at most 0.35, close to the lens) and either at least 1° across or turned by 45° or more at least 3 times;
/// - a bird is seen with the Sun at −6° or above, 0.2–4° across, in focus (over 0.35), its path curved or straight, and is not a meteor.
///
/// **Changed by the owner's own nights** (the report says why):
/// - a meteor crosses at least 1.5°/s, not 4: the overnight test's meteors crossed 1.84 to 5.1°/s in the engine's degrees, its clear meteor
///   (Oct 24, 9:28 PM) 2.6°/s, and at 4°/s five of its seven stayed unexplained (the prototype's own threshold was 20 of its pixels a second,
///   1.7°/s; its 363 satellites crossed at most 1.13°/s);
/// - a bird crosses 1 to 300°/s, not 1 to 30: four of the nine dusk lights the owner said were birds crossed 34 to 148°/s;
/// - a bird is 0.1° across or more, not 0.2°, and need not be in focus: by day the owner's camera sees birds as dark blobs whose focus reads 0
///   to 0.33, some 0.13° across (a blurred one that is large or erratic is still a bug: that rule comes first);
/// - a meteor needs the Sun under −6° and must come alone (no other light began within 1 s of it): the owner's dusk birds were short, fast
///   and straight, and at dusk the camera changing its picture made 31 straight streaks along the power lines in one picture. Nor can it cross
///   faster than a meteor can at its height (72 km/s at the distance of a height of 100 km, with half again for a rough aim): near the horizon
///   meteors are far and slow, and the fast streaks there were the tracker linking lights along the skyline;
/// - a bug is never a steady light (below): a bright plane's lights spread to a degree on the owner's camera and read as blurred.
///
/// **Ported from the prototype** (the overnight test of Oct 24; its pixels at 2128 across, about 0.085° each, are degrees here):
/// - a probable plane flashes like a strobe: a regular flash every 0.6 to 1.6 s (`SkyMeasures.strobePeriod`) of strength 0.3 or more (0.25
///   or more over 30 s), over a light followed 5 s or more; or it is a chain of flashes in a line (an entry of kind `.flash`, straight);
/// - a steady light is followed 5 s or more, at least 0.98 straight, smooth (its path within 0.25° of a smooth one, or within half its own
///   size: a bright plane's lights jump about within its blob as its strobes flash; `SkyMeasures.wobble`), seen in 40 % or more of its
///   pictures, and does not flash like a strobe. At night, at 0.15 to 2°/s (the
///   prototype's 2.5 to 30 pixels a second), it is a probable satellite where a satellite could be in sunlight; where none could
///   (`satelliteCouldBeSunlit`: the Earth's shadow up to 1,500 km), a probable plane: in the middle of the night satellites are in the shadow and
///   a steady light is a plane whose strobe is too faint to see. Slower than the band and followed 8 s or more: a distant plane;
/// - by day (the Sun at −6° or above) a light followed 5 s or more, at least 0.95 straight and slower than 3°/s, is a plane (whatever the
///   shape: a contrail's plane often reads as stopping);
/// - a bug on silk (the prototype's "drop"): a short straight streak like a meteor's, 1.5 to 8°/s, going straight down the picture (within 8°):
///   something hanging in front of the lens. It comes before the meteor, as in the prototype: gravity fits better.
enum SkyRules {
    // MARK: Pinned values (Task 11)

    static let meteorLongest: TimeInterval = 2
    static let meteorStraightness = 0.98
    static let meteorSamples = 3
    static let bugFocus = 0.35
    static let bugSize = 1.0
    static let bugTurns = 3
    static let birdSunElevation = -6.0

    // MARK: Changed by the owner's nights

    /// The plan's 4°/s: the overnight test's clear meteor crossed 2.6°/s.
    static let meteorSpeed = 1.5
    /// The plan's 1–30°/s: the owner's dusk birds crossed up to 148°/s.
    static let birdSpeeds = 1.0...300.0
    /// The plan's 0.2–4°: some of the owner's birds by day were 0.13° across.
    static let birdSizes = 0.1...4.0
    /// A meteor comes alone: no other light began within this (s) of it.
    static let meteorAloneWithin: TimeInterval = 1
    /// The fastest a meteor crosses (°/s): 72 km/s at the distance of `meteorHeight` km in its direction, times `meteorSpeedMargin`.
    static let meteorFastestKilometresPerSecond = 72.0
    static let meteorHeight = 100.0
    static let meteorSpeedMargin = 1.5
    /// A meteor needs a dark sky: the Sun under this (degrees).
    static let meteorSunElevation = SunEphemeris.darkElevation

    // MARK: The prototype's values, ported

    static let strobeStrength = 0.3
    static let strobeStrengthWhenLong = 0.25
    static let strobeLongAfter: TimeInterval = 30
    static let strobeShortest: TimeInterval = 5
    static let steadyShortest: TimeInterval = 5
    static let steadyStraightness = 0.98
    static let steadyWobble = 0.25
    static let steadySeen = 0.4
    static let satelliteSpeeds = 0.15...2.0
    static let slowPlaneShortest: TimeInterval = 8
    static let dayPlaneFastest = 3.0
    static let dayPlaneStraightness = 0.95
    static let silkFromStraightDown = 8.0
    static let silkSpeeds = 1.5...8.0
    /// The heights (km) a satellite a camera like this can see is looked for in the sunlight at: the brightest are below 1,500 km.
    static let satelliteHeights: [Double] = [200, 300, 400, 500, 600, 800, 1_000, 1_200, 1_500]

    // MARK: The doubts (the builder's, from the owner's nights)

    /// A light that began with others, in one picture or within `meteorAloneWithin`, this many in all or more, is the camera changing its
    /// picture.
    static let togetherLights = 3
    /// A picture in which this many lights began is the camera changing its picture: a light that began this long before or after it (s) is
    /// doubted too.
    static let cameraChangeLights = 5
    static let cameraChangeWindow: ClosedRange<TimeInterval> = -1...10
    /// A light that went out and came back: less straight than this, over at least this long.
    static let backAndForthStraightness = 0.3
    static let backAndForthShortest: TimeInterval = 1
    /// A ragged path: from this speed (°/s) on, straying from a smooth path (`SkyMeasures.wobble`) by more than this many degrees and this
    /// share of its step from one picture to the next.
    static let raggedFrom = 2.0
    static let raggedDegrees = 0.3
    static let raggedShareOfStep = 0.25
    /// Too fast for its size: at least this fast (°/s) and smaller than this (°): no lens follows a light like that.
    static let noiseFastest = 60.0
    static let noiseSmallest = 0.25
    // And faster than a meteor can cross at its height (`meteorFastest`, about 5°/s on the horizon): nothing that far away; on the owner's
    // evening of Oct 25 these were tracks along the power lines and the skyline, the tracker linking lights that were not one.

    // MARK: The plan's interface

    /// Task 11's rules alone: `.meteor`, `.bug`, `.bird`, or nil. The light is taken to have begun alone, in 3 pictures or more.
    static func classify(_ m: SkyMeasures, streakBorn: Bool, sunElevation: Double) -> SkyLabel? {
        let light = SkyRuleLight(measures: m, streakBorn: streakBorn, sunElevation: sunElevation)
        if isMeteor(light) { return .meteor }
        if isBug(light) { return .bug }
        if isBird(light) { return .bird }
        return nil
    }

    // MARK: The rules

    /// What the rules call `light`, in order: a bug on silk, a meteor, a bug, a probable plane by its strobe or its chain of flashes, a bird,
    /// and a steady light's probable plane or probable satellite. Nil: the rules do not know it (unexplained).
    static func verdict(_ light: SkyRuleLight) -> SkyRuleVerdict? {
        let m = light.measures
        if isOnSilk(light) { return SkyRuleVerdict(label: .bug, detail: "Bug on silk: straight down in front of the lens") }
        if isMeteor(light) { return SkyRuleVerdict(label: .meteor, detail: "Meteor: short, fast and straight") }
        if isBug(light) { return SkyRuleVerdict(label: .bug, detail: "Bug: blurred, close to the lens") }
        if let period = strobe(m) {
            return SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: it flashes every \(seconds(period)) s, like a plane’s strobe")
        }
        if light.kind == .flash && m.straightness >= steadyStraightness {
            return SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: flashes in a line at a steady pace, a distant plane’s strobe")
        }
        if isBird(light) { return SkyRuleVerdict(label: .bird, detail: "Bird: it crossed in daylight") }
        if light.sunElevation >= SunEphemeris.darkElevation {
            guard m.duration >= steadyShortest, m.straightness >= dayPlaneStraightness, m.speed < dayPlaneFastest else { return nil }
            return SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: a steady light crossing in daylight")
        }
        guard isSteady(m) else { return nil }
        if m.speed < satelliteSpeeds.lowerBound {
            guard m.duration >= slowPlaneShortest else { return nil }
            return SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: slow and steady, far away")
        }
        guard satelliteSpeeds.contains(m.speed) else { return nil }
        if light.satelliteSunlit == false {
            return SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: a steady light where no satellite can catch the sunlight")
        }
        return SkyRuleVerdict(label: .probableSatellite, detail: "Probable satellite: a steady light at a steady speed (no orbit check yet)")
    }

    /// The rules for a light no flight explains, as `entry` (`SkyCameraDetector`, live; `SkySortLater`, for a light logged before them): their
    /// verdict, by `.rule`, with its words in `detail`; or for one they leave unexplained, the unusual rule against what the camera learned
    /// (`baseline`: `unusual`, `speedVsPlanes`), whether it is a candidate (unexplained and unusual: it may alert once the camera has learned its
    /// sky), whether they doubt it is a light at all (`doubtful`: then never unusual), and the guide's priority and reasons (`SkyGuide`).
    static func judge(_ entry: inout SkyEntry, light: SkyRuleLight, baseline: SkyBaseline) {
        if let verdict = Self.verdict(light) {
            entry.label = verdict.label
            entry.by = .rule
            entry.detail = verdict.detail
            return
        }
        let doubt = Self.doubt(light)
        entry.unusual = doubt == nil ? baseline.unusual(light.measures) : []
        entry.speedVsPlanes = baseline.speedVsPlanes(light.measures)
        entry.candidate = !entry.unusual.isEmpty
        entry.doubtful = doubt != nil
        let guide = SkyGuide.assess(light.measures, unusual: entry.unusual, speedVsPlanes: entry.speedVsPlanes, learned: baseline.isLearned,
                                    doubt: doubt)
        entry.priority = guide.priority
        entry.reasons = guide.reasons
    }

    /// Why a light the rules leave unexplained is most likely not a light at all, in the words the log shows; nil: no doubt.
    static func doubt(_ light: SkyRuleLight) -> String? {
        let m = light.measures
        if max(light.beganWith, light.beganNear) >= togetherLights {
            return "Began with \(max(light.beganWith, light.beganNear) - 1) other lights at the same moment: the camera changing its picture, most likely"
        }
        if light.afterCameraChange { return "Began as the camera changed its picture" }
        if m.straightness < backAndForthStraightness && m.duration >= backAndForthShortest {
            return "Went out and came back: a twinkling light, most likely"
        }
        if m.speed >= raggedFrom, let wobble = m.wobble, wobble > max(raggedDegrees, raggedShareOfStep * (light.degreesPerPicture ?? 0)) {
            return "A ragged path: noise, most likely"
        }
        if m.speed >= noiseFastest && m.sizeDegrees < noiseSmallest { return "Too fast and small to follow: noise, most likely" }
        if m.speed > meteorFastest(m) { return "Faster than anything in the sky could cross there: close to the lens, or noise, most likely" }
        return nil
    }

    /// A meteor: in a dark sky, alone, short, straight, fast (but no faster than a meteor can be at its height), not blinking, streak-born or
    /// seen in 3 pictures.
    static func isMeteor(_ light: SkyRuleLight) -> Bool {
        let m = light.measures
        return light.sunElevation < meteorSunElevation && light.beganWith <= 1 && light.beganNear <= 1 && !light.afterCameraChange
            && isStreak(light) && m.speed >= meteorSpeed && m.speed <= meteorFastest(m)
    }

    /// The fastest a meteor can cross the sky (°/s) at the lower end of `m`'s path: 72 km/s across the line of sight, at the distance of a
    /// height of 100 km in that direction (about 115 km overhead, 480 km at 10° up, 1,130 km on the horizon), with a margin for a rough aim.
    static func meteorFastest(_ m: SkyMeasures) -> Double {
        let elevation = min(90, max(0, min(m.elevation, m.elevationEnd))) * SkyMath.radians
        let radius = 6_371.0, shell = radius + meteorHeight
        let distance = (shell * shell - radius * radius * cos(elevation) * cos(elevation)).squareRoot() - radius * sin(elevation)
        return meteorSpeedMargin * meteorFastestKilometresPerSecond / distance * SkyMath.degrees
    }

    /// Short, straight and not blinking, as a meteor's or a bug's on silk.
    private static func isStreak(_ light: SkyRuleLight) -> Bool {
        let m = light.measures
        return m.duration <= meteorLongest && m.straightness >= meteorStraightness && !m.blinks
            && (light.streakBorn || light.samples >= meteorSamples)
    }

    /// A bug on silk: a short straight streak going straight down the picture (a meteor seldom does: it comes first).
    static func isOnSilk(_ light: SkyRuleLight) -> Bool {
        guard let down = light.fromStraightDown else { return false }
        return isStreak(light) && down <= silkFromStraightDown && silkSpeeds.contains(light.measures.speed)
    }

    /// A bug: blurred, and large or turning sharply again and again; never a steady light (a light that crossed straight and smooth for
    /// seconds is far from the lens: on the owner's camera a bright plane's lights spread to a degree, and read as blurred).
    static func isBug(_ light: SkyRuleLight) -> Bool {
        let m = light.measures
        return m.focus <= bugFocus && (m.sizeDegrees >= bugSize || (m.turns ?? 0) >= bugTurns) && !isSteady(m)
    }

    /// A bird: in daylight (the Sun at −6° or above), its size and speed a bird's, its path curved or straight.
    static func isBird(_ light: SkyRuleLight) -> Bool {
        let m = light.measures
        return light.sunElevation >= birdSunElevation && birdSizes.contains(m.sizeDegrees) && birdSpeeds.contains(m.speed)
            && (m.shape == .curved || m.shape == .straight)
    }

    /// The period of a plane's strobe, when the light flashes like one.
    static func strobe(_ m: SkyMeasures) -> Double? {
        guard let period = m.strobePeriod, let strength = m.strobeStrength, m.duration >= strobeShortest else { return nil }
        return strength >= strobeStrength || (strength >= strobeStrengthWhenLong && m.duration >= strobeLongAfter) ? period : nil
    }

    /// A steady light: long enough, straight, smooth (within `steadyWobble`, or half its own size), seen most of the time, and no strobe.
    static func isSteady(_ m: SkyMeasures) -> Bool {
        m.duration >= steadyShortest && m.straightness >= steadyStraightness && (m.wobble ?? 0) <= max(steadyWobble, m.sizeDegrees / 2)
            && (m.seenShare ?? 1) >= steadySeen && strobe(m) == nil
    }

    /// "1.2": a period to a tenth of a second.
    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: Satellites in the sunlight

    /// Halfway along a light's way across the sky: the middle of the great circle from where it was first seen to where it was last seen.
    static func halfway(_ m: SkyMeasures) -> SkyDirection {
        let start = SkyMath.unitVector(SkyDirection(azimuth: m.azimuth, elevation: m.elevation))
        let end = SkyMath.unitVector(SkyDirection(azimuth: m.azimuthEnd, elevation: m.elevationEnd))
        let sum = start + end
        let length = SkyMath.length(sum)
        return SkyMath.direction(of: length > 1e-9 ? sum / length : start)
    }

    /// Whether a satellite seen in `direction` at `date` could be in sunlight: some point of the line of sight at one of `satelliteHeights` is
    /// outside the Earth's shadow (a cylinder behind the Earth, away from the Sun). A light under the horizon is looked at along the horizon.
    static func satelliteCouldBeSunlit(_ direction: SkyDirection, at date: Date, observer: SkyObserver) -> Bool {
        let sun = SkyMath.unitVector(SunEphemeris.direction(at: date, observer: observer))
        let look = SkyMath.unitVector(SkyDirection(azimuth: direction.azimuth, elevation: max(0, direction.elevation)))
        let radius = 6_371.0
        // The Earth's centre is `radius` below the observer: positions from it, in the observer's east-north-up frame.
        let observerFromCentre = SIMD3(0.0, 0, radius)
        for height in satelliteHeights {
            let up = look.z
            let along = -radius * up + ((radius * up) * (radius * up) + (radius + height) * (radius + height) - radius * radius).squareRoot()
            let point = observerFromCentre + look * along
            let towardSun = SkyMath.dot(point, sun)
            if towardSun >= 0 { return true }
            let off = point - sun * towardSun
            if SkyMath.dot(off, off) > radius * radius { return true }
        }
        return false
    }
}
