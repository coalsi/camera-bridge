import Foundation
import Synchronization
import Testing
@testable import MediaCore

/// The overlay's words (system locale, Home-app style "Fri, Oct 2  7:42:15 PM") and where its time comes from.
@Suite struct TimestampOverlayTextTests {
    /// Friday 2 October 2026, 19:42:15 UTC.
    static let moment = Date(timeIntervalSince1970: 1_790_970_135)
    static let utc = TimeZone(identifier: "UTC")!
    static let us = Locale(identifier: "en_US")

    private func settings(date: Bool = true, seconds: Bool = true, name: Bool = false, h24: Bool = false) -> TimestampOverlaySettings {
        TimestampOverlaySettings(enabled: true, position: .topRight, showCameraName: name, showDate: date, showSeconds: seconds, use24Hour: h24, size: .medium)
    }

    @Test func twelveHourTextHasWeekdayMonthDayAndAmPm() {
        let text = TimestampOverlayText.make(at: Self.moment, settings: settings(), cameraName: "Porch", locale: Self.us, timeZone: Self.utc)
        #expect(text == TimestampOverlayText(name: nil, date: "Fri, Oct 2", time: "7:42:15 PM"))
    }

    @Test func twentyFourHourTextHasNoMarker() {
        let text = TimestampOverlayText.make(at: Self.moment, settings: settings(h24: true), locale: Self.us, timeZone: Self.utc)
        #expect(text.time == "19:42:15")
    }

    @Test func secondsAndDateAreOptional() {
        let noSeconds = TimestampOverlayText.make(at: Self.moment, settings: settings(date: false, seconds: false), locale: Self.us, timeZone: Self.utc)
        #expect(noSeconds == TimestampOverlayText(name: nil, date: nil, time: "7:42 PM"))
        let h24 = TimestampOverlayText.make(at: Self.moment, settings: settings(seconds: false, h24: true), locale: Self.us, timeZone: Self.utc)
        #expect(h24.time == "19:42")
    }

    /// The overlay is drawn on every picture; the words (cached per second) must follow the second, the settings, the
    /// locale and the time zone, never serve another one's.
    @Test func theCachedWordsFollowTheSecondTheSettingsTheLocaleAndTheZone() {
        let make = { (at: Date, s: TimestampOverlaySettings, name: String, locale: Locale, zone: TimeZone) in
            TimestampOverlayText.make(at: at, settings: s, cameraName: name, locale: locale, timeZone: zone)
        }
        let first = make(Self.moment, settings(), "Porch", Self.us, Self.utc)
        #expect(make(Self.moment.addingTimeInterval(0.4), settings(), "Porch", Self.us, Self.utc) == first, "same second: same words")
        #expect(make(Self.moment.addingTimeInterval(1), settings(), "Porch", Self.us, Self.utc).time == "7:42:16 PM")
        #expect(make(Self.moment, settings(seconds: false), "Porch", Self.us, Self.utc).time == "7:42 PM")
        #expect(make(Self.moment, settings(name: true), "Porch", Self.us, Self.utc).name == "Porch")
        #expect(make(Self.moment, settings(name: true), "Garden", Self.us, Self.utc).name == "Garden")
        #expect(make(Self.moment, settings(), "Porch", Self.us, TimeZone(identifier: "Asia/Tokyo")!).time == "4:42:15 AM")
        #expect(make(Self.moment, settings(h24: true), "Porch", Self.us, Self.utc).time == "19:42:15")
        #expect(make(Self.moment, settings(), "Porch", Self.us, Self.utc) == first)
    }

    @Test func theTimeZoneIsTheMacs() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let text = TimestampOverlayText.make(at: Self.moment, settings: settings(), locale: Self.us, timeZone: tokyo)
        #expect(text.date == "Sat, Oct 3" && text.time == "4:42:15 AM")
    }

    @Test func theLocaleDecidesTheDatePatternAndWords() {
        let german = TimestampOverlayText.make(at: Self.moment, settings: settings(h24: true), locale: Locale(identifier: "de_DE"), timeZone: Self.utc)
        #expect(german.date == "Fr. 2. Okt." && german.time == "19:42:15")
        let british = TimestampOverlayText.make(at: Self.moment, settings: settings(h24: true), locale: Locale(identifier: "en_GB"), timeZone: Self.utc)
        #expect(british.date == "Fri 2 Oct" && british.time == "19:42:15")
    }

    @Test func theCameraNameAppearsOnlyWhenAskedForAndIsCut() {
        #expect(TimestampOverlayText.make(at: Self.moment, settings: settings(name: false), cameraName: "Porch", locale: Self.us, timeZone: Self.utc).name == nil)
        #expect(TimestampOverlayText.make(at: Self.moment, settings: settings(name: true), cameraName: "  Porch ", locale: Self.us, timeZone: Self.utc).name == "Porch")
        #expect(TimestampOverlayText.make(at: Self.moment, settings: settings(name: true), cameraName: "   ", locale: Self.us, timeZone: Self.utc).name == nil)
        let long = String(repeating: "A", count: 60)
        let cut = TimestampOverlayText.make(at: Self.moment, settings: settings(name: true), cameraName: long, locale: Self.us, timeZone: Self.utc).name
        #expect(cut?.count == TimestampOverlayText.maximumNameLength && cut?.hasSuffix("…") == true)
    }

    @Test func systemClockStyleFollowsTheRegion() {
        #expect(!TimestampOverlayText.uses24Hour(locale: Self.us))
        #expect(TimestampOverlayText.uses24Hour(locale: Locale(identifier: "de_DE")))
        #expect(TimestampOverlayText.uses24Hour(locale: Locale(identifier: "en_GB")))
    }

    // MARK: Clocks

    @Test func clocksTurnPictureTimeIntoDisplayTime() {
        let wall = Date(timeIntervalSince1970: 1_000_000)
        #expect(PictureWallClock().displayTime(for: wall) == wall)
        #expect(FixedOverlayClock(Self.moment).displayTime(for: wall) == Self.moment)
        let offset = OffsetOverlayClock(offset: { 1.25 }, now: { wall.addingTimeInterval(2) })
        #expect(offset.displayTime(for: wall) == wall.addingTimeInterval(1.25))
        // A picture with no usable time (hours away from now) shows the Mac's now.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OffsetOverlayClock(offset: { 0 }, now: { now }).displayTime(for: Date(timeIntervalSince1970: 5)) == now)
    }

    @Test func theOverlayTextUsesItsClock() {
        let overlay = TimestampOverlay(settings: settings(), cameraName: "Porch", clock: FixedOverlayClock(Self.moment))
        #expect(overlay.text(for: Date(timeIntervalSince1970: 0), locale: Self.us, timeZone: Self.utc).time == "7:42:15 PM")
        #expect(StaticTimestampOverlay(overlay).current?.cameraName == "Porch" && StaticTimestampOverlay(nil).current == nil)
    }
}

/// `MediaHub.wallClockOffset`: how far a source's `wallClock` is from the Mac's arrival time.
@Suite struct MediaHubWallClockOffsetTests {
    private let format = VideoFormat(codec: .h264, width: 640, height: 360, parameterSets: [Data([0x67, 1]), Data([0x68, 2])])

    private func frame(_ index: Int, wallClock: Date) -> MediaSample {
        .video(EncodedVideoFrame(format: format, nalUnits: [Data([index == 0 ? 0x65 : 0x41, UInt8(truncatingIfNeeded: index)])], isKeyframe: index == 0,
                                 pts: MediaTime(value: Int64(index * 3_000), timescale: 90_000), wallClock: wallClock))
    }

    @Test func aCameraClockThatRunsAheadIsMeasuredAndCorrected() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let hub = MediaHub(now: { ContinuousClock.now }, wallNow: { now.withLock { $0 } })
        #expect(hub.wallClockOffset == 0, "nothing measured yet")
        // The camera's clock is 1.5 s ahead of the Mac's; packets take 20–60 ms to arrive.
        for index in 0..<60 {
            let arrival = now.withLock { value -> Date in
                value = value.addingTimeInterval(1.0 / 30)
                return value
            }
            let delay = 0.02 + Double(index % 5) * 0.01
            await hub.ingest(frame(index, wallClock: arrival.addingTimeInterval(1.5 - delay)))
        }
        #expect(abs(hub.wallClockOffset - (-1.5 + 0.02)) < 0.001, "the shortest delay is kept: \(hub.wallClockOffset)")
    }

    @Test func aSourceWhoseWallClockIsArrivalTimeNeedsNoCorrection() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let hub = MediaHub(now: { ContinuousClock.now }, wallNow: { now.withLock { $0 } })
        for index in 0..<30 {
            now.withLock { $0 = $0.addingTimeInterval(1.0 / 30) }
            await hub.ingest(frame(index, wallClock: now.withLock { $0 }))
        }
        #expect(hub.wallClockOffset == 0)
    }

    @Test func framesWithNoUsableTimeAreIgnoredAndADiscontinuityMeasuresAgain() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let hub = MediaHub(now: { ContinuousClock.now }, wallNow: { now.withLock { $0 } })
        await hub.ingest(frame(0, wallClock: Date(timeIntervalSince1970: 100)))   // decades off: not a usable time
        #expect(hub.wallClockOffset == 0)
        await hub.ingest(frame(1, wallClock: now.withLock { $0.addingTimeInterval(-2) }))
        #expect(hub.wallClockOffset == 2)
        await hub.discontinuity()
        await hub.ingest(frame(0, wallClock: now.withLock { $0.addingTimeInterval(-0.5) }))
        #expect(hub.wallClockOffset == 0.5)
    }
}

