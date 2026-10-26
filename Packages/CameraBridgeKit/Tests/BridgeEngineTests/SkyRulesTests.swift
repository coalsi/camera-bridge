import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import BridgeEngine

// The rules before anything is "unexplained" (the plan's Task 11, and the overnight prototype's probable planes and satellites), the unusual
// rule learned per camera, the alert gate, and the guide that ranks the unexplained with its reasons (the owner's request of 2026-10-25). All
// made up: the place is 40.0000, −100.0000, the lights are synthetic.

@Suite(.timeLimit(.minutes(3))) struct SkyRulesTests {
    /// 2026-10-25 01:00 UTC at the made-up place: the Sun is about 14° under the horizon (dark), and a satellite overhead is in the sunlight
    /// from 300 km up.
    static let evening = SkyFixtures.aimEpoch.addingTimeInterval(-7_200)
    /// 2026-10-25 03:00 UTC: the Sun 37° under; no satellite under 1,500 km overhead or in the south is in the sunlight.
    static let night = SkyFixtures.aimEpoch
    /// 2026-10-25 20:00 UTC: the Sun 33° up.
    static let day = SkyFixtures.aimEpoch.addingTimeInterval(17 * 3_600)

    /// Measures as a light's might be: a plane's, by default (0.4°/s for 30 s at 20° up, straight and steady, a small sharp dot).
    static func measures(speed: Double = 0.4, duration: Double = 30, elevation: Double = 20, straightness: Double = 0.999, shape: SkyPathShape = .straight,
                         size: Double = 0.3, brightness: Double = 800, focus: Double = 0.6, blinks: Bool = false, strobe: (period: Double, strength: Double)? = nil,
                         seen: Double? = 1, wobble: Double? = 0.05, turns: Int? = 0, maxTurn: Double = 0) -> SkyMeasures {
        SkyMeasures(azimuth: 10, elevation: elevation, azimuthEnd: 10 + speed * duration, elevationEnd: elevation, duration: duration, speed: speed,
                    acceleration: 0, turnRate: 0, maxTurn: maxTurn, straightness: straightness, shape: shape, sizeDegrees: size, brightness: brightness,
                    blinks: blinks, blinkRate: blinks ? 1 : nil, focus: focus, strobePeriod: strobe?.period, strobeStrength: strobe.map(\.strength) ?? 0,
                    seenShare: seen, wobble: wobble, turns: turns)
    }

    static func sun(_ date: Date) -> Double { SunEphemeris.direction(at: date, observer: SkyFixtures.observer).elevation }

    @Test func theMadeUpTimesAreDarkAndLight() {
        #expect(Self.sun(Self.evening) < -6 && Self.sun(Self.evening) > -20)
        #expect(Self.sun(Self.night) < -30)
        #expect(Self.sun(Self.day) > 20)
    }

    // MARK: Meteors, bugs and birds (Task 11)

    @Test func rulesTellMeteorsBugsAndBirds() {
        let dark = Self.sun(Self.night), light = Self.sun(Self.day)
        // A meteor: 0.8 s, straight, 12°/s, at night.
        let meteor = Self.measures(speed: 12, duration: 0.8, size: 0.4)
        #expect(SkyRules.classify(meteor, streakBorn: true, sunElevation: dark) == .meteor)
        #expect(SkyRules.classify(meteor, streakBorn: false, sunElevation: dark) == .meteor, "three pictures or more")
        // Not in daylight (the owner's dusk birds were short, fast and straight): a bird then.
        #expect(SkyRules.classify(meteor, streakBorn: true, sunElevation: light) == .bird)
        // The overnight test's clear meteor (Oct 24, 9:28 PM) crossed 2.6°/s in the engine's degrees, for 0.4 s, a blurred streak 0.93° across.
        #expect(SkyRules.classify(Self.measures(speed: 2.6, duration: 0.4, size: 0.93, focus: 0.06), streakBorn: false, sunElevation: dark) == .meteor)
        // Too slow (a satellite's pace), too long, too crooked, blinking: no meteor.
        #expect(SkyRules.classify(Self.measures(speed: 1.2, duration: 0.8), streakBorn: true, sunElevation: dark) == nil)
        #expect(SkyRules.classify(Self.measures(speed: 12, duration: 2.4), streakBorn: true, sunElevation: dark) == nil)
        #expect(SkyRules.classify(Self.measures(speed: 12, duration: 0.8, straightness: 0.95), streakBorn: true, sunElevation: dark) == nil)
        #expect(SkyRules.classify(Self.measures(speed: 12, duration: 0.8, blinks: true), streakBorn: true, sunElevation: dark) == nil)
        // A bug: blurred and large, or blurred and turning sharply again and again.
        let large = Self.measures(speed: 6, duration: 2, straightness: 0.7, shape: .curved, size: 1.6, focus: 0.2)
        #expect(SkyRules.classify(large, streakBorn: false, sunElevation: dark) == .bug)
        let erratic = Self.measures(speed: 4, duration: 3, straightness: 0.5, shape: .sharpTurn, size: 0.5, focus: 0.3, turns: 4)
        #expect(SkyRules.classify(erratic, streakBorn: false, sunElevation: dark) == .bug)
        #expect(SkyRules.classify(Self.measures(speed: 4, duration: 3, straightness: 0.5, size: 0.5, focus: 0.5, turns: 4), streakBorn: false,
                                  sunElevation: dark) == nil, "sharp, not blurred: no bug")
        // A bird: by day, a bird's size and speed, in focus, curved or straight; the owner's dusk birds crossed up to 148°/s.
        let bird = Self.measures(speed: 20, duration: 2.5, straightness: 0.9, shape: .curved, size: 0.4, focus: 0.7)
        #expect(SkyRules.classify(bird, streakBorn: false, sunElevation: light) == .bird)
        #expect(SkyRules.classify(Self.measures(speed: 148, duration: 0.6, straightness: 0.95, shape: .curved, size: 0.59, focus: 0.39), streakBorn: false,
                                  sunElevation: -1.1) == .bird, "the owner's own bird at dusk")
        #expect(SkyRules.classify(bird, streakBorn: false, sunElevation: dark) == nil, "no bird in the dark")
        // By day the owner's birds are dark blobs: their focus reads low, and some are small.
        #expect(SkyRules.classify(Self.measures(speed: 16, duration: 1.4, size: 0.13, focus: 0.06), streakBorn: false, sunElevation: light) == .bird)
        #expect(SkyRules.classify(Self.measures(speed: 20, duration: 2.5, shape: .sharpTurn, size: 0.4, focus: 0.7), streakBorn: false,
                                  sunElevation: light) == nil, "a sharp turn is no bird's")
        // A plane-like track: none of them.
        #expect(SkyRules.classify(Self.measures(), streakBorn: false, sunElevation: dark) == nil)
        #expect(SkyRules.classify(Self.measures(), streakBorn: false, sunElevation: light) == nil)
    }

    @Test func aStraightDownStreakIsABugOnSilk() {
        let dark = Self.sun(Self.night)
        let streak = Self.measures(speed: 3, duration: 0.8, size: 0.8, focus: 0.1)
        let down = SkyRuleLight(measures: streak, streakBorn: false, samples: 4, sunElevation: dark, fromStraightDown: 4)
        #expect(SkyRules.verdict(down)?.label == .bug && SkyRules.verdict(down)?.detail == "Bug on silk: straight down in front of the lens")
        // Straight down comes first, as in the prototype: gravity fits better than a meteor, even a fast one.
        var faster = down
        faster.measures.speed = 6
        #expect(SkyRules.verdict(faster)?.label == .bug)
        // Not straight down: a meteor, a slow one too.
        var sideways = down
        sideways.fromStraightDown = 40
        #expect(SkyRules.verdict(sideways)?.label == .meteor)
        var fast = down
        fast.measures.speed = 12
        fast.fromStraightDown = 40
        #expect(SkyRules.verdict(fast)?.label == .meteor)
        var slow = sideways
        slow.measures.speed = 1.2
        #expect(SkyRules.verdict(slow) == nil, "too slow for a meteor, not straight down: unexplained")
    }

    @Test func aMeteorBeginsAloneInADarkSky() {
        let streak = Self.measures(speed: 12, duration: 0.8, size: 0.4)
        let alone = SkyRuleLight(measures: streak, streakBorn: true, samples: 2, sunElevation: Self.sun(Self.night))
        #expect(SkyRules.verdict(alone)?.label == .meteor)
        var together = alone
        together.beganWith = 2
        #expect(SkyRules.verdict(together) == nil, "two lights beginning in one picture are no meteor")
        var change = alone
        change.afterCameraChange = true
        #expect(SkyRules.verdict(change) == nil)
        #expect(SkyRules.doubt(change) == "Began as the camera changed its picture")
        var dusk = alone
        dusk.sunElevation = -4
        #expect(SkyRules.verdict(dusk)?.label == .bird, "in a bright sky a streak like that is a bird")
        // Another light began within a second of it: no meteor.
        var near = alone
        near.beganNear = 2
        #expect(SkyRules.verdict(near) == nil)
        // No meteor crosses that fast so low: on the horizon a meteor is a thousand kilometres away.
        #expect(SkyRules.meteorFastest(Self.measures(elevation: 0)) < 6 && SkyRules.meteorFastest(Self.measures(elevation: 90)) > 50)
        var low = alone
        low.measures = Self.measures(speed: 30, duration: 0.8, elevation: 3, size: 0.4)
        #expect(SkyRules.verdict(low) == nil)
        low.measures.speed = 5
        #expect(SkyRules.verdict(low)?.label == .meteor)
    }

    // MARK: Probable planes and satellites (the prototype's)

    /// A light along `path` through `model`, seen five times a second from `start`: its flux from `flux` (0: not seen that picture, a miss).
    static func track(_ path: SkyPath, model: SkyCameraModel = SkyFixtures.truthDual, start: Date, flux: (Int) -> Double) -> SkyTrack {
        var samples: [SkyTrackSample] = []
        var misses: [TimeInterval] = []
        for (index, point) in path.directions(rate: 5).enumerated() {
            let time = start.addingTimeInterval(point.time)
            let value = flux(index)
            guard value > 0 else {
                misses.append(point.time)
                continue
            }
            guard var sample = SkyFixtures.sample(at: time, since: start, direction: point.direction, through: model) else { continue }
            sample.flux = value
            samples.append(sample)
        }
        let first = samples.first?.time ?? 0, last = samples.last?.time ?? 0
        return SkyTrack(id: UUID(), samples: samples, streakBorn: false, misses: misses.filter { $0 > first && $0 < last })
    }

    /// A straight path in the left lens of the truth dual camera: up in the north-west, going east at `speed` °/s for `seconds`.
    static func path(speed: Double, seconds: Double) -> SkyPath {
        SkyPath(start: SkyDirection(azimuth: 300, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: seconds, speed: speed)])
    }

    @Test func aStrobeEveryOnePointTwoSecondsIsAProbablePlane() {
        // A plane's strobe: bright one picture in six (1.2 s at five a second), dimmer between; 30 s at 0.4°/s.
        let strobe = Self.track(Self.path(speed: 0.4, seconds: 30), start: Self.night) { $0 % 6 == 0 ? 600 : 120 }
        let m = SkyFixtures.measures(of: strobe, model: SkyFixtures.truthDual)
        #expect(abs((m.strobePeriod ?? 0) - 1.2) < 0.01 && (m.strobeStrength ?? 0) >= 0.3, "\(String(describing: m.strobePeriod)) \(String(describing: m.strobeStrength))")
        #expect(m.seenShare == 1)
        let light = SkyRuleLight(measures: m, samples: strobe.samples.count, sunElevation: Self.sun(Self.night), satelliteSunlit: true)
        #expect(SkyRules.verdict(light) == SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: it flashes every 1.2 s, like a plane’s strobe"))
        // Only its flashes show (a distant plane): seen one picture in six.
        let flashes = Self.track(Self.path(speed: 0.4, seconds: 30), start: Self.night) { $0 % 6 == 0 ? 600 : 0 }
        let sparse = SkyFixtures.measures(of: flashes, model: SkyFixtures.truthDual)
        #expect(abs((sparse.strobePeriod ?? 0) - 1.2) < 0.01 && abs((sparse.seenShare ?? 0) - 1.0 / 6) < 0.02)
        #expect(SkyRules.verdict(SkyRuleLight(measures: sparse, samples: flashes.samples.count, sunElevation: Self.sun(Self.evening)))?.label == .probablePlane)
        // The camera's 2 s keyframe pulse of a faint light is no strobe.
        let pulse = Self.track(Self.path(speed: 0.4, seconds: 30), start: Self.night) { $0 % 10 == 0 ? 600 : 120 }
        let pulsing = SkyFixtures.measures(of: pulse, model: SkyFixtures.truthDual)
        #expect(pulsing.strobePeriod == nil && pulsing.strobeStrength == 0)
        // A steady light has no strobe; a light followed for fewer than 20 pictures is too short to tell.
        let steady = SkyFixtures.measures(of: Self.track(Self.path(speed: 0.4, seconds: 30), start: Self.night) { _ in 300 }, model: SkyFixtures.truthDual)
        #expect(steady.strobePeriod == nil && steady.strobeStrength == 0)
        let short = SkyFixtures.measures(of: Self.track(Self.path(speed: 0.4, seconds: 3), start: Self.night) { $0 % 6 == 0 ? 600 : 120 },
                                         model: SkyFixtures.truthDual)
        #expect(short.strobePeriod == nil && short.strobeStrength == nil)
    }

    @Test func aSteadyStraightLightIsAProbableSatelliteWhereOneCanBeSunlit() {
        // 0.6°/s for 20 s, steady and straight.
        let steady = Self.track(Self.path(speed: 0.6, seconds: 20), start: Self.evening) { _ in 300 }
        let m = SkyFixtures.measures(of: steady, model: SkyFixtures.truthDual)
        #expect(m.straightness > 0.99 && (m.wobble ?? 9) < 1 && m.turns == 0 && m.seenShare == 1, "\(m)")
        // In the evening a satellite there is in the sunlight; three hours after sunset, high in the south, it is in the Earth's shadow (and
        // a steady light there a plane), but low in the north-west, toward the Sun, it can still catch the sunlight.
        #expect(SkyRules.satelliteCouldBeSunlit(SkyRules.halfway(m), at: Self.evening, observer: SkyFixtures.observer))
        #expect(!SkyRules.satelliteCouldBeSunlit(SkyDirection(azimuth: 180, elevation: 45), at: Self.night, observer: SkyFixtures.observer))
        #expect(!SkyRules.satelliteCouldBeSunlit(SkyDirection(azimuth: 0, elevation: 90), at: Self.night, observer: SkyFixtures.observer))
        #expect(SkyRules.satelliteCouldBeSunlit(SkyDirection(azimuth: 290, elevation: 10), at: Self.night, observer: SkyFixtures.observer))
        let evening = SkyRuleLight(measures: m, samples: steady.samples.count, sunElevation: Self.sun(Self.evening), satelliteSunlit: true)
        #expect(SkyRules.verdict(evening) == SkyRuleVerdict(label: .probableSatellite, detail: "Probable satellite: a steady light at a steady speed (no orbit check yet)"))
        var night = evening
        night.sunElevation = Self.sun(Self.night)
        night.satelliteSunlit = false
        #expect(SkyRules.verdict(night) == SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: a steady light where no satellite can catch the sunlight"))
        // By day a steady light is a plane; slower than a satellite at night, a distant plane.
        var day = evening
        day.sunElevation = Self.sun(Self.day)
        #expect(SkyRules.verdict(day)?.label == .probablePlane)
        var slow = evening
        slow.measures.speed = 0.1
        #expect(SkyRules.verdict(slow) == SkyRuleVerdict(label: .probablePlane, detail: "Probable plane: slow and steady, far away"))
        // A bright light's centroid wanders within its blob: up to half its size is still steady.
        var bright = evening
        bright.measures.wobble = 0.4
        bright.measures.sizeDegrees = 1
        #expect(SkyRules.verdict(bright)?.label == .probableSatellite)
        // Not steady: too short, crooked, ragged, or mostly unseen.
        for change in [{ (m: inout SkyMeasures) in m.duration = 4 }, { $0.straightness = 0.95 }, { $0.wobble = 0.5 }, { $0.seenShare = 0.3 }] {
            var light = evening
            change(&light.measures)
            #expect(SkyRules.verdict(light) == nil, "\(light.measures)")
        }
    }

    @Test func aMeteorIsNoSatellite() {
        // A short fast straight streak at night, where a satellite could be in the sunlight: a meteor, never a satellite.
        let streak = Self.track(Self.path(speed: 10, seconds: 1), start: Self.evening) { _ in 900 }
        let m = SkyFixtures.measures(of: streak, model: SkyFixtures.truthDual)
        #expect(m.speed > 9 && m.duration <= 1 && m.straightness >= 0.98)
        let light = SkyRuleLight(measures: m, samples: streak.samples.count, sunElevation: Self.sun(Self.evening), satelliteSunlit: true)
        #expect(SkyRules.verdict(light)?.label == .meteor)
        // And a satellite's steady crossing is no meteor.
        let pass = Self.track(Self.path(speed: 0.8, seconds: 12), start: Self.evening) { _ in 400 }
        let crossing = SkyRuleLight(measures: SkyFixtures.measures(of: pass, model: SkyFixtures.truthDual), samples: pass.samples.count,
                                    sunElevation: Self.sun(Self.evening), satelliteSunlit: true)
        #expect(SkyRules.verdict(crossing)?.label == .probableSatellite)
    }

    // MARK: Doubts

    @Test func lightsThatAreNoLightsAreDoubted() {
        let dark = Self.sun(Self.night)
        let fast = Self.measures(speed: 8, duration: 3, straightness: 0.96, shape: .curved)
        #expect(SkyRules.doubt(SkyRuleLight(measures: fast, sunElevation: dark)) == nil)
        #expect(SkyRules.doubt(SkyRuleLight(measures: fast, sunElevation: dark, beganWith: 13))
                == "Began with 12 other lights at the same moment: the camera changing its picture, most likely")
        #expect(SkyRules.doubt(SkyRuleLight(measures: fast, sunElevation: dark, beganWith: 2)) == nil, "two may be lights together")
        #expect(SkyRules.doubt(SkyRuleLight(measures: fast, sunElevation: dark, beganWith: 2, beganNear: 4))
                == "Began with 3 other lights at the same moment: the camera changing its picture, most likely", "within a second")
        #expect(SkyRules.doubt(SkyRuleLight(measures: Self.measures(speed: 9, duration: 10, straightness: 0.01, shape: .sharpTurn), sunElevation: dark))
                == "Went out and came back: a twinkling light, most likely")
        var ragged = fast
        ragged.wobble = 1.2
        #expect(SkyRules.doubt(SkyRuleLight(measures: ragged, sunElevation: dark, degreesPerPicture: 1.6)) == "A ragged path: noise, most likely")
        #expect(SkyRules.doubt(SkyRuleLight(measures: ragged, sunElevation: dark, degreesPerPicture: 6)) == nil, "a fast light's steps are long")
        #expect(SkyRules.doubt(SkyRuleLight(measures: Self.measures(speed: 170, duration: 1, size: 0.12), sunElevation: dark))
                == "Too fast and small to follow: noise, most likely")
        // Faster than a meteor can cross at its height (about 5°/s on the horizon): no light in the sky. On the owner's evening these were
        // tracks along the power lines and the skyline.
        #expect(SkyRules.doubt(SkyRuleLight(measures: Self.measures(speed: 12, duration: 1.6, elevation: 2, size: 0.4), sunElevation: dark))
                == "Faster than anything in the sky could cross there: close to the lens, or noise, most likely")
        #expect(SkyRules.doubt(SkyRuleLight(measures: Self.measures(speed: 12, duration: 1.6, elevation: 60, size: 0.4), sunElevation: dark)) == nil,
                "high up, a meteor crosses that fast")
    }

    // MARK: The unusual rule (Task 11)

    /// A baseline that learned `count` planes at about `speed` °/s (a little either way) at `elevation`.
    static func baseline(planes count: Int, speed: Double, elevation: Double = 5, satellites: Int = 0) -> SkyBaseline {
        var baseline = SkyBaseline()
        for index in 0..<count {
            let jitter = Double(index % 5 - 2) * 0.02
            baseline.learn(measures(speed: speed + jitter, elevation: elevation, size: 0.3, brightness: 800), label: .plane)
        }
        for _ in 0..<satellites { baseline.learn(measures(speed: 0.5, elevation: 40, size: 0.25, brightness: 500), label: .satellite) }
        return baseline
    }

    @Test func theUnusualRuleUsesTheLearnedBaseline() throws {
        let baseline = Self.baseline(planes: 40, speed: 0.8)
        let light = Self.measures(speed: 5, duration: 3, elevation: 5)
        #expect(baseline.unusual(light) == [.faster])
        let ratio = try #require(baseline.speedVsPlanes(light))
        #expect(abs(ratio - 6.25) < 0.1, "\(ratio)")
        // Larger and brighter than the planes there.
        #expect(baseline.unusual(Self.measures(speed: 0.8, elevation: 5, size: 0.5, brightness: 800)) == [.larger], "planes there are 0.3°")
        #expect(baseline.unusual(Self.measures(speed: 0.8, elevation: 5, size: 0.3, brightness: 1_500)) == [.brighter])
        // The probable ones teach nothing.
        var more = baseline
        more.learn(Self.measures(speed: 9), label: .probablePlane)
        more.learn(Self.measures(speed: 9), label: .unexplained)
        #expect(more == baseline)
    }

    @Test func withinTheBaselineIsNotUnusual() {
        // Planes here cross at about 2.5°/s: 3.2°/s is within them (the defaults would call it faster), and so is their size.
        let baseline = Self.baseline(planes: 40, speed: 2.5)
        #expect(baseline.unusual(Self.measures(speed: 3.2, duration: 10, elevation: 5)).isEmpty)
        #expect(SkyBaseline().unusual(Self.measures(speed: 3.2, duration: 10, elevation: 5)) == [.faster], "against the defaults")
        #expect(SkyBaseline().unusual(Self.measures(speed: 1, size: 1.2)) == [.larger], "the default size")
        #expect(SkyBaseline().unusual(Self.measures(speed: 1, size: 0.6)).isEmpty, "a bright plane's spread is not larger")
        #expect(SkyBaseline().speedVsPlanes(Self.measures(speed: 3)) == nil, "no planes, no ratio")
    }

    @Test func aBandWithFewSamplesUsesAllBands() throws {
        // Forty planes at 10–30° up, none at 0–10°: a light at 5° up is judged by all the bands.
        let baseline = Self.baseline(planes: 40, speed: 0.8, elevation: 20)
        #expect(baseline.unusual(Self.measures(speed: 5, elevation: 5)) == [.faster])
        #expect(abs(try #require(baseline.speedVsPlanes(Self.measures(speed: 4, elevation: 5))) - 5) < 0.1)
        // Twelve fast ones low down are a band of their own: the low light is judged by them.
        var mixed = baseline
        for _ in 0..<12 { mixed.learn(Self.measures(speed: 4, elevation: 5), label: .plane) }
        #expect(mixed.unusual(Self.measures(speed: 5, elevation: 5)).isEmpty)
        #expect(mixed.unusual(Self.measures(speed: 5, elevation: 20)) == [.faster])
    }

    @Test func aStopOrATurnCountsOnlyWhenTheShapeCanBeTrusted() {
        let trusted = Self.measures(speed: 1.2, duration: 6, straightness: 0.7, shape: .sharpTurn, turns: 1)
        #expect(SkyBaseline().unusual(trusted) == [.sharpTurn])
        #expect(SkyBaseline().unusual(Self.measures(speed: 1.2, duration: 6, shape: .suddenStop, turns: 0)) == [.suddenStop])
        // A slow, short, wiggly or ragged track's turns are its own wander.
        for shaky in [Self.measures(speed: 0.3, duration: 6, shape: .sharpTurn), Self.measures(speed: 1.2, duration: 1.5, shape: .sharpTurn),
                      Self.measures(speed: 1.2, duration: 6, shape: .sharpTurn, turns: 5), Self.measures(speed: 1.2, duration: 6, shape: .sharpTurn, wobble: 0.3)] {
            #expect(SkyBaseline().unusual(shaky).isEmpty, "\(shaky)")
        }
        for slow in [Self.measures(speed: 0.7, duration: 6, shape: .suddenStop), Self.measures(speed: 0.9, duration: 6, shape: .sharpTurn, turns: 1)] {
            #expect(SkyBaseline().unusual(slow).isEmpty, "a piece of a passing light settles on the noise as it fades")
        }
    }

    @Test func satellitesAreNeededWhenOrbitsAreLoaded() {
        let baseline = Self.baseline(planes: 30, speed: 0.8, satellites: 4)
        #expect(baseline.learning(orbitsLoaded: true) == SkyLearning(ready: false, planes: 30, satellites: 4))
        #expect(baseline.learning(orbitsLoaded: false) == SkyLearning(ready: true, planes: 30, satellites: 4))
        #expect(Self.baseline(planes: 30, speed: 0.8, satellites: 10).learning(orbitsLoaded: true).ready)
        #expect(!Self.baseline(planes: 29, speed: 0.8).learning(orbitsLoaded: false).ready)
    }

    @Test func theBaselineKeepsFiveHundredOfEachKindInEachBand() throws {
        var baseline = SkyBaseline()
        for index in 0..<520 { baseline.learn(Self.measures(speed: Double(index) / 100, elevation: 50), label: .plane) }
        #expect(baseline.planeCount == 500 && baseline.planes[2].first?.speed == 0.2, "the oldest went")
        let data = try JSONEncoder().encode(baseline)
        #expect(try JSONDecoder().decode(SkyBaseline.self, from: data) == baseline)
        #expect(try JSONDecoder().decode(SkyBaseline.self, from: Data("{\"v\":7,\"planes\":\"no\"}".utf8)) == SkyBaseline(), "a broken file is nothing learned")
    }

    // MARK: The alert gate (Task 11)

    static func entry(_ id: String, at date: Date, candidate: Bool = true) -> SkyEntry {
        SkyEntry(id: id, camera: SkyDetectorRig.camera, kind: .track, start: date, end: date.addingTimeInterval(3), path: [], measures: measures(speed: 5),
                 label: .unexplained, unusual: candidate ? [.faster] : [], candidate: candidate)
    }

    @Test func nothingAlertsWhileLearning() {
        let learning = Self.baseline(planes: 29, speed: 0.8).learning(orbitsLoaded: false)
        let light = Self.measures(speed: 5, elevation: 5)
        let unusual = Self.baseline(planes: 29, speed: 0.8).unusual(light)
        var entry = Self.entry("a", at: Self.night)
        entry.unusual = unusual
        entry.candidate = !unusual.isEmpty
        #expect(entry.candidate, "a candidate is logged even while learning")
        var gate = SkyAlertGate()
        #expect(gate.consider(entry, at: Self.night, learning: learning, skyVisible: true) == .none("learning"))
    }

    @Test func repeatsWithinTheWindowAreOneAlert() {
        let ready = SkyLearning(ready: true, planes: 30, satellites: 0)
        var gate = SkyAlertGate()
        let t = Self.night
        #expect(gate.consider(Self.entry("first", at: t), at: t, learning: ready, skyVisible: true) == .alert)
        #expect(gate.consider(Self.entry("second", at: t.addingTimeInterval(120)), at: t.addingTimeInterval(120), learning: ready, skyVisible: nil)
                == .join(entryID: "first"))
        #expect(gate.consider(Self.entry("third", at: t.addingTimeInterval(301)), at: t.addingTimeInterval(301), learning: ready, skyVisible: true) == .alert)
        // Another camera's gate is its own.
        var other = SkyAlertGate()
        #expect(other.consider(Self.entry("elsewhere", at: t.addingTimeInterval(130)), at: t.addingTimeInterval(130), learning: ready, skyVisible: true) == .alert)
        #expect(gate.consider(Self.entry("fourth", at: t.addingTimeInterval(400)), at: t.addingTimeInterval(400), learning: ready, skyVisible: true)
                == .join(entryID: "third"))
        // Not a candidate: nothing.
        #expect(gate.consider(Self.entry("plain", at: t.addingTimeInterval(900), candidate: false), at: t.addingTimeInterval(900), learning: ready,
                              skyVisible: true) == .none("not a candidate"))
    }

    @Test func cloudyHoursNeverAlert() {
        let ready = SkyLearning(ready: true, planes: 30, satellites: 0)
        var gate = SkyAlertGate()
        #expect(gate.consider(Self.entry("a", at: Self.night), at: Self.night, learning: ready, skyVisible: false) == .none("sky not visible"))
        #expect(gate.consider(Self.entry("b", at: Self.night), at: Self.night.addingTimeInterval(1), learning: ready, skyVisible: true) == .alert,
                "the cloudy one raised nothing to join")
    }

    // MARK: The guide

    @Test func theUnexplainedAreRankedWithTheirReasons() {
        let defaults = SkyBaseline()
        func assess(_ m: SkyMeasures, baseline: SkyBaseline = defaults, doubt: String? = nil) -> SkyGuide.Assessment {
            let unusual = doubt == nil ? baseline.unusual(m) : []
            return SkyGuide.assess(m, unusual: unusual, speedVsPlanes: baseline.speedVsPlanes(m), learned: baseline.isLearned, doubt: doubt)
        }
        // Fast: high, against typical planes before learning, against this camera's planes after.
        #expect(assess(Self.measures(speed: 6, duration: 3)) == SkyGuide.Assessment(priority: .high, reasons: ["Fast across the sky (about 3× typical planes)"]))
        let learned = Self.baseline(planes: 40, speed: 0.8)
        #expect(assess(Self.measures(speed: 5, duration: 3, elevation: 5), baseline: learned)
                == SkyGuide.Assessment(priority: .high, reasons: ["Fast across the sky (about 6× a plane at that height)"]))
        // Larger, a stop, a turn: high, every reason given.
        #expect(assess(Self.measures(speed: 4, duration: 6, straightness: 0.8, shape: .sharpTurn, size: 1.3, turns: 1))
                == SkyGuide.Assessment(priority: .high, reasons: ["Fast across the sky (about 2× typical planes)", "Looks larger than typical planes",
                                                                  "Turned sharply"]))
        #expect(assess(Self.measures(speed: 1.2, duration: 6, shape: .suddenStop)) == SkyGuide.Assessment(priority: .high, reasons: ["Stopped suddenly"]))
        #expect(assess(Self.measures(speed: 0.7, duration: 6, shape: .suddenStop)).priority == .low, "a slow light's stop is its fading")
        // Only brighter: medium.
        #expect(assess(Self.measures(speed: 0.8, elevation: 5, brightness: 2_000), baseline: learned)
                == SkyGuide.Assessment(priority: .medium, reasons: ["Looks brighter than planes and satellites here"]))
        // A long, low, steady light that is neither a plane's nor a satellite's: medium.
        #expect(assess(Self.measures(speed: 0.3, duration: 40, elevation: 6, straightness: 0.9, shape: .curved))
                == SkyGuide.Assessment(priority: .medium, reasons: ["Long, low and steady, but not like a plane or a satellite"]))
        // …but one that blinks is not steady: on the owner's camera every long, low light the rules left was a distant plane whose lights blinked.
        #expect(assess(Self.measures(speed: 0.3, duration: 40, elevation: 6, straightness: 0.9, shape: .curved, blinks: true))
                == SkyGuide.Assessment(priority: .low, reasons: ["Nothing unusual about it"]))
        // Low: short, nothing unusual, or doubted (the doubt is the reason, and nothing about it is unusual).
        #expect(assess(Self.measures(speed: 0.8, duration: 3)) == SkyGuide.Assessment(priority: .low, reasons: ["Too short to tell a plane from a satellite"]))
        // A light that appeared and stayed on one spot for seconds (the overnight test's strangest): medium.
        #expect(assess(Self.measures(speed: 0.1, duration: 3)) == SkyGuide.Assessment(priority: .medium, reasons: ["Appeared and stayed on one spot for seconds"]))
        #expect(assess(Self.measures(speed: 0.5, duration: 0.6, straightness: 0.9)) == SkyGuide.Assessment(priority: .low, reasons: ["Too short to tell what it was"]))
        #expect(assess(Self.measures(speed: 0.5, duration: 12, elevation: 40, straightness: 0.9, shape: .curved))
                == SkyGuide.Assessment(priority: .low, reasons: ["Nothing unusual about it"]))
        #expect(assess(Self.measures(speed: 40, duration: 2), doubt: "A ragged path: noise, most likely")
                == SkyGuide.Assessment(priority: .low, reasons: ["A ragged path: noise, most likely"]))
        #expect(SkyGuide.times(6.24) == "6×" && SkyGuide.times(2.4) == "2.5×" && SkyGuide.times(1.9) == "2×")
    }

    // MARK: Lights that moved together

    /// An unexplained light the guide ranked: from `start` (seconds after the night's time) for `duration`, from `from` toward `bearing`
    /// (degrees from up the sky, through east) at `speed` °/s.
    static func ranked(_ id: String, start: Double, duration: Double = 20, from: SkyDirection, bearing: Double, speed: Double,
                       priority: SkyPriority = .low) -> SkyEntry {
        let path = SkyPath(start: from, bearing: bearing * Double.pi / 180, legs: [SkyPath.Leg(duration: duration, speed: speed)])
        let end = path.direction(at: duration)
        var m = measures(speed: speed, duration: duration)
        m.azimuth = from.azimuth
        m.elevation = from.elevation
        m.azimuthEnd = end.azimuth
        m.elevationEnd = end.elevation
        let begins = Self.night.addingTimeInterval(start)
        return SkyEntry(id: id, camera: SkyDetectorRig.camera, kind: .track, start: begins, end: begins.addingTimeInterval(duration), path: [],
                        measures: m, label: .unexplained, priority: priority, reasons: ["Nothing unusual about it"])
    }

    @Test func lightsMovingTogetherAreAGroup() {
        // Two lights crossing together, 3° apart, the same way at about the same speed: a group, both high, the reason first.
        let a = Self.ranked("a", start: 0, from: SkyDirection(azimuth: 300, elevation: 30), bearing: 90, speed: 0.6)
        let b = Self.ranked("b", start: 4, from: SkyDirection(azimuth: 300, elevation: 33), bearing: 92, speed: 0.65)
        let lone = Self.ranked("c", start: 600, from: SkyDirection(azimuth: 10, elevation: 50), bearing: 180, speed: 0.6)
        let marked = SkyFormations.mark([lone, b, a])
        let byID = Dictionary(uniqueKeysWithValues: marked.map { ($0.id, $0) })
        #expect(byID["a"]?.group == "g-a" && byID["b"]?.group == "g-a" && byID["c"]?.group == nil)
        #expect(byID["a"]?.priority == .high && byID["a"]?.reasons == ["Several lights moving together", "Nothing unusual about it"])
        #expect(byID["c"]?.priority == .low)
        // Three: one group of three.
        let c = Self.ranked("d", start: 8, from: SkyDirection(azimuth: 298, elevation: 27), bearing: 88, speed: 0.58)
        let three = SkyFormations.mark([a, b, c])
        #expect(Set(three.compactMap(\.group)) == ["g-a"] && three.allSatisfy { $0.group == "g-a" })
    }

    @Test func lightsGoingDifferentWaysOrNotTogetherAreNoGroup() {
        let a = Self.ranked("a", start: 0, from: SkyDirection(azimuth: 300, elevation: 30), bearing: 90, speed: 0.6)
        // Another way (45° off), another speed (twice), one after the other (not seen together), the same light twice (0.2° away), begun in
        // the same picture, doubted, explained, or never ranked (logged before the guide): none of them with `a`.
        let away = Self.ranked("b", start: 4, from: SkyDirection(azimuth: 300, elevation: 33), bearing: 135, speed: 0.6)
        let faster = Self.ranked("c", start: 4, from: SkyDirection(azimuth: 300, elevation: 33), bearing: 90, speed: 1.2)
        let later = Self.ranked("d", start: 25, from: SkyDirection(azimuth: 300, elevation: 33), bearing: 90, speed: 0.6)
        let twice = Self.ranked("e", start: 2, from: SkyDirection(azimuth: 301.4, elevation: 30.1), bearing: 90, speed: 0.6)
        var same = Self.ranked("f", start: 0, from: SkyDirection(azimuth: 300, elevation: 36), bearing: 90, speed: 0.6)
        same.start = a.start
        var doubted = Self.ranked("g", start: 3, from: SkyDirection(azimuth: 300, elevation: 26), bearing: 90, speed: 0.6)
        doubted.doubtful = true
        var explained = Self.ranked("h", start: 3, from: SkyDirection(azimuth: 300, elevation: 27), bearing: 90, speed: 0.6)
        explained.label = .probableSatellite
        var old = Self.ranked("i", start: 3, from: SkyDirection(azimuth: 300, elevation: 24), bearing: 90, speed: 0.6)
        old.priority = nil
        for other in [away, faster, later, twice, same, doubted, explained, old] {
            #expect(SkyFormations.mark([a, other]).allSatisfy { $0.group == nil }, "\(other.id)")
        }
        // A person's word that one was a bird takes it out of the group.
        let b = Self.ranked("b", start: 4, from: SkyDirection(azimuth: 300, elevation: 33), bearing: 92, speed: 0.65)
        var bird = b
        bird.correction = .bird
        #expect(SkyFormations.mark([a, b]).allSatisfy { $0.group == "g-a" })
        #expect(SkyFormations.mark([a, bird]).allSatisfy { $0.group == nil })
    }

    // MARK: In the detector

    static let card = SkyDetectorSettings(enabled: true, facing: 330, tilt: 15)
    static var cardModel: SkyCameraModel { SkyCameraModel.initial(facing: 330, tilt: 15, pictureWidth: 4256, pictureHeight: 1888) }

    /// A light the card's model sees: up in the north-north-west, going east at `speed` °/s for `seconds`, its flux from `flux`.
    static func light(at start: Date, speed: Double, seconds: Double, flux: (Int) -> Double = { _ in 300 }) -> SkyTrack {
        track(SkyPath(start: SkyDirection(azimuth: 330, elevation: 30), bearing: Double.pi / 2, legs: [SkyPath.Leg(duration: seconds, speed: speed)]),
              model: cardModel, start: start, flux: flux)
    }

    @Test func theRulesComeAfterTheFlightsAndExplainWhatTheyCan() async throws {
        let rig = try SkyDetectorRig(settings: Self.card, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // A strobe at night, with no aircraft: a probable plane, by the rules.
        let strobe = Self.light(at: Self.night, speed: 0.4, seconds: 30) { $0 % 6 == 0 ? 600 : 120 }
        let strobing = await rig.detector.classify(strobe, measures: TrackMeasurer.measure(strobe, model: Self.cardModel, analysisWidth: 1920, pictureWidth: 4256))
        #expect(strobing.label == .probablePlane && strobing.by == .rule && strobing.detail == "Probable plane: it flashes every 1.2 s, like a plane’s strobe")
        #expect(strobing.priority == nil && strobing.reasons.isEmpty && !strobing.candidate, "the guide is for the unexplained")
        // A steady straight light in the evening, where a satellite can be in the sunlight: a probable satellite.
        let pass = Self.light(at: Self.evening, speed: 0.6, seconds: 20)
        let passing = await rig.detector.classify(pass, measures: TrackMeasurer.measure(pass, model: Self.cardModel, analysisWidth: 1920, pictureWidth: 4256))
        #expect(passing.label == .probableSatellite && passing.by == .rule)
        // A crooked slow light: unexplained, ranked, and not a candidate.
        let crooked = Self.track(SkyPath(start: SkyDirection(azimuth: 330, elevation: 30), bearing: Double.pi / 2,
                                         legs: [SkyPath.Leg(duration: 12, speed: 0.6, turnRate: 12)]), model: Self.cardModel, start: Self.night) { _ in 300 }
        let unknown = await rig.detector.classify(crooked, measures: TrackMeasurer.measure(crooked, model: Self.cardModel, analysisWidth: 1920, pictureWidth: 4256))
        #expect(unknown.label == .unexplained && unknown.by == nil && unknown.priority == .low && !unknown.reasons.isEmpty && !unknown.candidate,
                "\(unknown.label) \(String(describing: unknown.priority)) \(unknown.reasons)")
        await rig.detector.stop()
    }

    @Test func planesAndBugsNeverAlert() async throws {
        let rig = try SkyDetectorRig(settings: Self.card, pictureWidth: 4256, pictureHeight: 1888)
        defer { rig.remove() }
        await rig.detector.start()
        // A matched plane, with measures that would be unusual for a light nothing explains.
        let flight = SkyFixtures.Flight()
        await rig.flights.add(flight.reports(from: Self.night.addingTimeInterval(-10), to: Self.night.addingTimeInterval(30)))
        var random = SkyRandom(seed: 3)
        let plane = try #require(SkyFixtures.track(of: flight, through: Self.cardModel, from: Self.night.addingTimeInterval(1), seconds: 10, using: &random))
        var odd = TrackMeasurer.measure(plane, model: Self.cardModel, analysisWidth: 1920, pictureWidth: 4256)
        odd.sizeDegrees = 3
        let matched = await rig.detector.classify(plane, measures: odd)
        #expect(matched.by == .flight && !matched.candidate && matched.unusual.isEmpty && matched.priority == nil)
        // A bug by the rules: blurred, large and fast.
        let bug = Self.light(at: Self.night, speed: 6, seconds: 2)
        var blurred = TrackMeasurer.measure(bug, model: Self.cardModel, analysisWidth: 1920, pictureWidth: 4256)
        blurred.focus = 0.1
        blurred.sizeDegrees = 2
        blurred.straightness = 0.6
        blurred.shape = .curved
        let close = await rig.detector.classify(bug, measures: blurred)
        #expect(close.label == .bug && close.by == .rule && !close.candidate && close.unusual.isEmpty)
        // The same light not blurred: unexplained, fast and large, a candidate.
        var sharp = blurred
        sharp.focus = 0.6
        let odder = await rig.detector.classify(bug, measures: sharp)
        #expect(odder.label == .unexplained && odder.candidate && odder.unusual == [.faster, .larger] && odder.priority == .high)
        await rig.detector.stop()
    }

    @Test func theBaselineIsKeptOverARestartAndANewCard() async throws {
        // Twelve planes matched with a good aim (as `SkyDetectorTests.matchesImproveTheAim`): learnt, and kept in baseline.json over a restart and a
        // new card (what the box learned of this sky is not the aim: Ruling S25).
        let card = SkyDetectorSettings(enabled: true, facing: 315, tilt: 25)
        let model = SkyCameraModel.initial(facing: 315, tilt: 25, pictureWidth: 1920, pictureHeight: 1080)
        let rig = try SkyDetectorRig(settings: card, pictureWidth: 1920, pictureHeight: 1080)
        defer { rig.remove() }
        await rig.detector.start()
        var random = SkyRandom(seed: 12)
        for index in 0..<12 {
            let pass = SkyDetectorTests.pass(index, at: Self.night.addingTimeInterval(Double(index) * 60), seenBy: model, using: &random)
            await rig.flights.add(pass.reports)
            rig.clock.set(pass.track.samples.last?.wallClock ?? Self.night)
            _ = await rig.detector.classify(pass.track, measures: TrackMeasurer.measure(pass.track, model: model, analysisWidth: 1920, pictureWidth: 1920))
        }
        let learnt = await rig.detector.status.learning.planes
        #expect(learnt > 0 && learnt < 12, "the matches with a good aim: \(learnt)")
        await rig.detector.stop()
        let file = rig.data.url.appending(path: "sky/\(SkyDetectorRig.camera.uuidString)/baseline.json")
        let data = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode(SkyBaseline.self, from: data).planeCount == learnt)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("40.0") && !text.contains("-100"), "no place in it")
        let again = rig.again()
        await again.start()
        #expect(await again.status.learning.planes == learnt)
        await again.update(SkyDetectorSettings(enabled: true, facing: 200, tilt: 25))
        await again.settle()
        let moved = await again.status
        #expect(moved.aim.quality == .rough && moved.learning.planes == learnt)
        await again.stop()
        #expect(try JSONDecoder().decode(SkyBaseline.self, from: Data(contentsOf: file)).planeCount == learnt)
    }
}
