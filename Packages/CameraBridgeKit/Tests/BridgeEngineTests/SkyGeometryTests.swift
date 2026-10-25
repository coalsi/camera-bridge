import Foundation
import Testing
@testable import BridgeEngine

/// Sky geometry (`SkyMath`), the Sun (`SunEphemeris`) and the nights (`SkyNight`): against Meeus's worked examples ("Astronomical
/// Algorithms", 2nd ed.), an independent sunrise and sunset calculation (NOAA's equations) and the made-up location.
@Suite struct SkyGeometryTests {
    static let chicago = TimeZone(identifier: "America/Chicago")!

    /// A UTC date from its parts.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        local(year, month, day, hour, minute, second, in: TimeZone(secondsFromGMT: 0)!)
    }

    /// A date from its parts on the clock of `zone`.
    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func separationAndHorizontalAreRight() {
        let north = SkyDirection(azimuth: 0, elevation: 0)
        #expect(abs(SkyMath.separation(north, SkyDirection(azimuth: 90, elevation: 0)) - 90) <= 1e-9)
        #expect(SkyMath.separation(north, north) == 0)
        #expect(abs(SkyMath.separation(north, SkyDirection(azimuth: 180, elevation: 0)) - 180) <= 1e-9)
        #expect(abs(SkyMath.separation(SkyDirection(azimuth: 359.5, elevation: 0), SkyDirection(azimuth: 0.5, elevation: 0)) - 1) <= 1e-9,
                "across north")
        #expect(abs(SkyMath.separation(SkyDirection(azimuth: 123, elevation: 90), SkyDirection(azimuth: 0, elevation: 45)) - 45) <= 1e-9,
                "the zenith has no azimuth")
        #expect(abs(SkyMath.separation(SkyDirection(azimuth: 10, elevation: 30), SkyDirection(azimuth: 10.000_01, elevation: 30))
                    - 0.000_01 * cos(30 * Double.pi / 180)) <= 1e-12, "small angles keep their digits")

        // Meeus examples 12.a and 12.b: the mean sidereal time at Greenwich on 1987 April 10 at 0h and at 19h21m UT.
        #expect(abs(SkyMath.greenwichSiderealDegrees(Self.utc(1987, 4, 10)) - 197.693195) <= 1e-6)
        #expect(abs(SkyMath.greenwichSiderealDegrees(Self.utc(1987, 4, 10, 19, 21)) - 128.737_873_4) <= 1e-6)
        #expect(SkyMath.julianDate(Self.utc(2000, 1, 1, 12)) == 2_451_545.0)

        // Meeus example 13.b: Venus from the US Naval Observatory at 19h21m UT, azimuth 68.0337° from the south (248.0337° from the north) and
        // altitude 15.1249°. Meeus uses the apparent sidereal time, this the mean one: they differ by 0.001°.
        let usno = SkyObserver(latitude: 38 + 55 / 60.0 + 17 / 3600.0, longitude: -(77 + 3 / 60.0 + 56 / 3600.0), heightMeters: 0)
        let venus = SkyMath.horizontal(rightAscension: (23 + 9 / 60.0 + 16.641 / 3600) * 15, declination: -(6 + 43 / 60.0 + 11.61 / 3600),
                                       at: Self.utc(1987, 4, 10, 19, 21), observer: usno)
        #expect(abs(venus.azimuth - 248.0337) <= 0.005, "\(venus)")
        #expect(abs(venus.elevation - 15.1249) <= 0.005, "\(venus)")

        // A Polaris-like star (0.74° from the pole) stays at the latitude's height, within 0.8°, and about north, all day.
        for hour in stride(from: 0, to: 24, by: 3) {
            let star = SkyMath.horizontal(rightAscension: 37.95, declination: 89.26, at: Self.utc(2026, 10, 25, hour),
                                          observer: SkyFixtures.observer)
            #expect(abs(star.elevation - SkyFixtures.observer.latitude) <= 0.8, "\(hour)h: \(star)")
            #expect(SkyFixtures.azimuthDifference(star.azimuth, 0) <= 1, "\(hour)h: \(star)")
            #expect(star.azimuth >= 0 && star.azimuth < 360)
        }
    }

    @Test func anObserverNeverShowsItsLocation() {
        // The location stays on the box: printed, interpolated, debug-printed, dumped, or inside a collection or an error, an observer says
        // only that it is hidden.
        let observer = SkyObserver(latitude: 12.345_6, longitude: -65.432_1, heightMeters: 789.25)
        struct Failure: Error { var observer: SkyObserver }
        var dumped = "", dumpedFailure = ""
        dump(observer, to: &dumped)
        dump(Failure(observer: observer), to: &dumpedFailure)
        let texts = [String(describing: observer), "\(observer)", String(reflecting: observer), dumped, dumpedFailure, "\([observer])",
                     "\(Optional(observer) as Any)", String(describing: Failure(observer: observer))]
        #expect(String(describing: observer) == "SkyObserver(location hidden)")
        for text in texts {
            #expect(text.contains("location hidden"), "\(text)")
            // Each forbidden number has a decimal mark, which a dumped type's hex address never contains.
            for digits in ["12.3", "65.4", "789.2", "12,3", "65,4", "789,2"] {
                #expect(!text.contains(digits), "\(text)")
            }
        }
        // The numbers themselves are all there for the maths.
        #expect(observer.latitude == 12.345_6 && observer.longitude == -65.432_1 && observer.heightMeters == 789.25)
    }

    @Test func aPlaneAboveIsAtTheRightDirection() {
        // 10 km north along the ground (the WGS84 meridian's radius of curvature at 40°), at 10,000 m.
        let observer = SkyFixtures.observer
        let a = 6_378_137.0, e2 = (1 / 298.257223563) * (2 - 1 / 298.257223563), sinLatitude = sin(40 * Double.pi / 180)
        let meridianRadius = a * (1 - e2) / pow(1 - e2 * sinLatitude * sinLatitude, 1.5)
        let north = observer.latitude + 10_000 / meridianRadius * 180 / .pi
        let plane = SkyMath.direction(from: observer, toLatitude: north, longitude: observer.longitude, altitudeMeters: 10_000)
        #expect(SkyFixtures.azimuthDifference(plane.direction.azimuth, 0) <= 0.01, "\(plane)")
        #expect(abs(plane.direction.elevation - 44.9) <= 0.2, "\(plane)")
        // The Earth's curve lowers it below the flat 45° (by about 0.07°), and the range is a little over 10 km × √2.
        #expect(abs(plane.direction.elevation - 44.932) <= 0.002, "\(plane)")
        #expect(abs(plane.rangeMeters - 14_147.7) <= 1, "\(plane)")

        // ECEF: on the equator at the prime meridian, and at the pole (WGS84's radii).
        let origin = SkyMath.ecef(latitude: 0, longitude: 0, altitudeMeters: 0)
        #expect(abs(origin.x - a) <= 1e-6 && abs(origin.y) <= 1e-6 && abs(origin.z) <= 1e-6)
        let pole = SkyMath.ecef(latitude: 90, longitude: 0, altitudeMeters: 100)
        #expect(abs(pole.z - (6_356_752.314_245 + 100)) <= 1e-3 && abs(pole.x) <= 1e-6)

        // Straight up, and due east on the horizon of a high place: east of an observer 1 km up, at the same height, 1 km away.
        let above = SkyMath.direction(from: observer, toLatitude: observer.latitude, longitude: observer.longitude, altitudeMeters: 5_000)
        #expect(abs(above.direction.elevation - 90) <= 1e-6 && abs(above.rangeMeters - 5_000) <= 1e-6)
        let high = SkyObserver(latitude: 40, longitude: -100, heightMeters: 1_000)
        let east = SkyMath.direction(from: high, toLatitude: 40, longitude: -100 + 0.011_7, altitudeMeters: 1_000)
        #expect(abs(east.direction.azimuth - 90) <= 0.01 && east.direction.elevation < 0 && east.direction.elevation > -0.01, "\(east)")
    }

    @Test func sunMatchesMeeusExample() {
        // Meeus example 25.a: 1992 October 13.0 TD (JDE 2448908.5), apparent right ascension 198.38083°, declination −7.78507°.
        let date = Self.utc(1992, 10, 13)
        #expect(SkyMath.julianDate(date) == 2_448_908.5)
        let sun = SunEphemeris.equatorial(at: date)
        #expect(abs(sun.rightAscension - 198.38) <= 0.01, "\(sun)")
        #expect(abs(sun.declination - -7.785) <= 0.01, "\(sun)")
        #expect(abs(sun.rightAscension - 198.380_83) <= 0.000_5 && abs(sun.declination - -7.785_07) <= 0.000_5, "the example's own digits")

        #expect(SunEphemeris.horizonElevation == -0.833)
        #expect(SunEphemeris.darkElevation == -6.0)

        // At the made-up location on 31 October 2026 at NOAA's sunset (23:38:32 UTC): on the horizon line, in the west-south-west.
        let sunset = SunEphemeris.direction(at: Self.utc(2026, 10, 31, 23, 38, 32), observer: SkyFixtures.observer)
        #expect(abs(sunset.elevation - SunEphemeris.horizonElevation) <= 0.02, "\(sunset)")
        #expect(sunset.azimuth > 245 && sunset.azimuth < 260, "\(sunset)")
        // At the June solstice's local noon (about 18:41:40 UTC at 100° W) it is due south, 90 − 40 + 23.44 degrees up.
        let noon = SunEphemeris.direction(at: Self.utc(2026, 6, 21, 18, 41, 40), observer: SkyFixtures.observer)
        #expect(abs(noon.elevation - 73.44) <= 0.05, "\(noon)")
        #expect(abs(noon.azimuth - 180) <= 1.5, "\(noon)")
    }

    @Test func nightWindowsAcrossMidnightDSTAndPolarDays() throws {
        let zone = Self.chicago
        let observer = SkyFixtures.observer

        // The night the clocks go back (2:00 CDT on 1 November 2026 is 1:00 CST, 07:00 UTC) is one window, named after the evening it starts.
        let window = SkyNight.window(named: "2026-10-31", observer: observer, zone: zone)
        #expect(window.name == "2026-10-31")
        let sunset = try #require(window.sunset)
        let sunrise = try #require(window.sunrise)
        // NOAA's equations: sunset 23:38:32 UTC (18:38 CDT), sunrise 13:09:12 UTC (07:09 CST).
        #expect(abs(sunset.timeIntervalSince(Self.utc(2026, 10, 31, 23, 38, 32))) <= 30, "\(sunset)")
        #expect(abs(sunrise.timeIntervalSince(Self.utc(2026, 11, 1, 13, 9, 12))) <= 30, "\(sunrise)")
        #expect(sunrise.timeIntervalSince(sunset) > 12 * 3600)
        #expect(sunset < Self.utc(2026, 11, 1, 7) && Self.utc(2026, 11, 1, 7) < sunrise, "the change is inside the night")
        #expect(zone.secondsFromGMT(for: sunset) == -5 * 3600 && zone.secondsFromGMT(for: sunrise) == -6 * 3600, "sunset on CDT, sunrise on CST")
        #expect(SkyNight.span(window, view: .night, zone: zone) == sunset...sunrise)
        #expect(SunEphemeris.direction(at: sunset, observer: observer).elevation < SunEphemeris.horizonElevation)
        #expect(SunEphemeris.direction(at: sunset.addingTimeInterval(-1), observer: observer).elevation >= SunEphemeris.horizonElevation)

        // 02:00 local on 1 November (CST by then, 08:00 UTC) is in the night that began the evening before, and so are both 1:30s.
        let twoAM = Self.local(2026, 11, 1, 2, in: zone)
        #expect(twoAM == Self.utc(2026, 11, 1, 8))
        #expect(SkyNight.name(containing: twoAM, observer: observer, zone: zone) == "2026-10-31")
        for date in [Self.utc(2026, 11, 1, 6, 30), Self.utc(2026, 11, 1, 7, 30), sunset, sunrise] {
            #expect(SkyNight.name(containing: date, observer: observer, zone: zone) == "2026-10-31", "\(date)")
        }
        // In the day after, the latest night is the one that ended that morning; after the next sunset, it is the next night.
        #expect(SkyNight.name(containing: Self.local(2026, 11, 1, 12, in: zone), observer: observer, zone: zone) == "2026-10-31")
        let next = SkyNight.window(named: "2026-11-01", observer: observer, zone: zone)
        let nextSunset = try #require(next.sunset)
        #expect(abs(nextSunset.timeIntervalSince(Self.utc(2026, 11, 1, 23, 37, 21))) <= 30, "\(nextSunset)")
        #expect(SkyNight.name(containing: nextSunset.addingTimeInterval(60), observer: observer, zone: zone) == "2026-11-01")
        #expect(SkyNight.name(containing: Self.local(2026, 10, 31, 12, in: zone), observer: observer, zone: zone) == "2026-10-30")

        // Every 20 minutes for three days around the change, the name is a night that began at or before the moment, and the moment is in
        // it or after its sunrise and before the next sunset.
        var date = Self.utc(2026, 10, 30, 12)
        while date < Self.utc(2026, 11, 2, 12) {
            let name = SkyNight.name(containing: date, observer: observer, zone: zone)
            let night = SkyNight.window(named: name, observer: observer, zone: zone)
            let start = try #require(night.sunset, "\(date) → \(name)")
            let end = try #require(night.sunrise, "\(date) → \(name)")
            #expect(start <= date, "\(date) → \(name)")
            if date > end {
                let following = SkyNight.window(named: SkyNight.dayName(end, zone: zone), observer: observer, zone: zone)
                #expect(following.sunset.map { $0 > date } == true, "\(date) → \(name)")
            }
            date = date.addingTimeInterval(20 * 60)
        }

        // The day view is the local day the night is named after: 24 hours, and 25 on the day the clocks go back.
        #expect(SkyNight.span(window, view: .day, zone: zone) == Self.local(2026, 10, 31, 0, in: zone)...Self.local(2026, 11, 1, 0, in: zone))
        let longDay = SkyNight.span(next, view: .day, zone: zone)
        #expect(longDay.upperBound.timeIntervalSince(longDay.lowerBound) == 25 * 3600)

        // The night the clocks go forward (2:00 CST on 8 March 2026 is 3:00 CDT, 08:00 UTC) is one window too: the sunset on CST, the sunrise
        // on CDT. NOAA's equations: sunset 00:38:33 UTC (18:38 CST on the 7th), sunrise 13:02:22 UTC (08:02 CDT). The day of the change is 23 h.
        let spring = SkyNight.window(named: "2026-03-07", observer: observer, zone: zone)
        let springSunset = try #require(spring.sunset)
        let springSunrise = try #require(spring.sunrise)
        #expect(abs(springSunset.timeIntervalSince(Self.utc(2026, 3, 8, 0, 38, 33))) <= 30, "\(springSunset)")
        #expect(abs(springSunrise.timeIntervalSince(Self.utc(2026, 3, 8, 13, 2, 22))) <= 30, "\(springSunrise)")
        #expect(springSunset < Self.utc(2026, 3, 8, 8) && Self.utc(2026, 3, 8, 8) < springSunrise, "the change is inside the night")
        #expect(zone.secondsFromGMT(for: springSunset) == -6 * 3600 && zone.secondsFromGMT(for: springSunrise) == -5 * 3600)
        #expect(SkyNight.name(containing: Self.local(2026, 3, 8, 3, 30, in: zone), observer: observer, zone: zone) == "2026-03-07")
        #expect(SkyNight.name(containing: Self.local(2026, 3, 8, 12, in: zone), observer: observer, zone: zone) == "2026-03-07")
        let shortDay = SkyNight.span(SkyNight.window(named: "2026-03-08", observer: observer, zone: zone), view: .day, zone: zone)
        #expect(shortDay.upperBound.timeIntervalSince(shortDay.lowerBound) == 23 * 3600)
        #expect(SkyNight.span(spring, view: .day, zone: zone).upperBound == shortDay.lowerBound)

        // 78° N at the June solstice: the midnight sun. No sunset, no sunrise; the day view is the local day and the night is empty.
        let farNorth = SkyObserver(latitude: 78, longitude: -100, heightMeters: 0)
        let midnightSun = SkyNight.window(named: "2026-06-21", observer: farNorth, zone: zone)
        #expect(midnightSun == SkyNightWindow(name: "2026-06-21", sunset: nil, sunrise: nil))
        #expect(SkyNight.span(midnightSun, view: .day, zone: zone) == Self.local(2026, 6, 21, 0, in: zone)...Self.local(2026, 6, 22, 0, in: zone))
        let noNight = SkyNight.span(midnightSun, view: .night, zone: zone)
        #expect(noNight.lowerBound == noNight.upperBound)
        #expect(SkyNight.name(containing: Self.local(2026, 6, 21, 12, in: zone), observer: farNorth, zone: zone) == "2026-06-21")
        // And the polar night: the Sun never rises, so it never sets either.
        #expect(SkyNight.window(named: "2026-12-21", observer: farNorth, zone: zone).sunset == nil)

        // Never traps: every day of a year at 78° N (the midnight sun, the polar night and the days between), at 40° N and on the equator
        // (where every day has its sunset and sunrise), and every week near the South Pole.
        let places: [(SkyObserver, TimeZone, Int)] = [
            (farNorth, zone, 1), (observer, zone, 1), (SkyObserver(latitude: 0, longitude: 30, heightMeters: 0), TimeZone(secondsFromGMT: 0)!, 1),
            (SkyObserver(latitude: -89.9, longitude: 166, heightMeters: 2_800), TimeZone(identifier: "Pacific/Auckland")!, 7),
        ]
        for (place, placeZone, step) in places {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = placeZone
            var day = Self.local(2026, 1, 1, 12, in: placeZone)
            var nights = 0
            while day < Self.local(2027, 1, 1, 0, in: placeZone) {
                let name = SkyNight.dayName(day, zone: placeZone)
                let here = "\(place.latitude)° \(name)"
                let night = SkyNight.window(named: name, observer: place, zone: placeZone)
                let nightSpan = SkyNight.span(night, view: .night, zone: placeZone)
                let daySpan = SkyNight.span(night, view: .day, zone: placeZone)
                #expect(daySpan.contains(day), "\(here)")
                if let set = night.sunset {
                    nights += 1
                    #expect(SkyNight.dayName(set, zone: placeZone) == name && nightSpan.lowerBound == set, "\(here)")
                    if let rise = night.sunrise { #expect(rise > set && nightSpan.upperBound == rise, "\(here)") }
                    else { #expect(nightSpan.upperBound == daySpan.upperBound, "\(here)") }
                } else {
                    #expect(night.sunrise == nil && nightSpan.lowerBound == nightSpan.upperBound, "\(here)")
                }
                if abs(place.latitude) < 50 { #expect(night.sunset != nil && night.sunrise != nil, "\(here)") }
                for moment in [day, daySpan.lowerBound.addingTimeInterval(60)] {
                    let named = SkyNight.name(containing: moment, observer: place, zone: placeZone)
                    #expect(SkyNight.localDay(named: named, zone: placeZone) != nil, "\(here): \(moment) → \(named)")
                }
                day = calendar.date(byAdding: .day, value: step, to: day)!
            }
            // At 78° N about a third of the year has a night: NOAA's equations give a sunset on 127 days of 2026 there (the midnight sun from
            // about 18 April to 23 August, the polar night from about 27 October to 13 February).
            if place.latitude == 78 { #expect(nights >= 117 && nights <= 137, "\(nights) nights at 78° N") }
        }

        // Names that are not dates have no night, and still a span; a date the calendar cannot place names no night either.
        for bad in ["not a night", "2026-02-30", "2026-13-01", "", "2026-1-01", "2026-+1-01"] {
            let none = SkyNight.window(named: bad, observer: observer, zone: zone)
            #expect(none == SkyNightWindow(name: bad, sunset: nil, sunrise: nil), "\(bad)")
            let span = SkyNight.span(none, view: .night, zone: zone)
            #expect(span.lowerBound == span.upperBound, "\(bad)")
            _ = SkyNight.span(none, view: .day, zone: zone)
        }
        for unplaceable in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 1e300), Date.distantFuture.addingTimeInterval(1e15)] {
            #expect(SkyNight.name(containing: unplaceable, observer: observer, zone: zone) == "0000-00-00")
            let odd = SkyNightWindow(name: "odd", sunset: unplaceable, sunrise: unplaceable)
            for span in [SkyNight.span(odd, view: .night, zone: zone), SkyNight.span(odd, view: .day, zone: zone)] {
                #expect(span.lowerBound.timeIntervalSince1970.isFinite && span.lowerBound == span.upperBound, "\(unplaceable)")
            }
        }
    }
}
