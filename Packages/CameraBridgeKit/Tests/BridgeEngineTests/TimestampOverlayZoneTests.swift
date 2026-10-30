import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// The overlay drawn on transcoded pictures (Apple Home's live view and recordings) tells the time in the bridge's zone
/// (`BridgeSettings.timeZone`), not the process's: Camera Bridge OS runs in UTC, so a Phoenix bridge showed 7 hours ahead.
@Suite struct TimestampOverlayZoneTests {
    static let on = TimestampOverlaySettings(enabled: true, showCameraName: false, showDate: false, showSeconds: true, use24Hour: true)

    @Test func theOverlayTellsTheTimeInTheBridgesZone() async throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let control = TimestampOverlayControl(settings: Self.on, cameraName: "Driveway")
        let provider = control.provider(for: MediaHub())
        // A picture of now (the hub's clock tells a picture far from now by the current time). A zone that is neither the Mac's nor UTC.
        let picture = Date()
        let words = try BridgeTime.$taskZone.withValue(tokyo) {
            try #require(provider.current).text(for: picture, locale: Locale(identifier: "en_US_POSIX"))
        }
        func hour(_ zone: TimeZone) -> String { String(format: "%02d", Calendar(identifier: .gregorian).dateComponents(in: zone, from: picture).hour ?? -1) }
        #expect(words.time.hasPrefix(hour(tokyo) + ":"), "\(words.time)")
        #expect(!words.time.hasPrefix(hour(.current) + ":") || hour(.current) == hour(tokyo), "told in the process's zone or UTC: \(words.time)")
    }

    @Test func anOverlayKeepsTheZoneItWasMadeWith() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let overlay = TimestampOverlay(settings: Self.on, cameraName: "", timeZone: tokyo)
        let words = overlay.text(for: Date(timeIntervalSince1970: 1_793_034_000), locale: Locale(identifier: "en_US_POSIX"))
        #expect(words.time == "02:00:00", "\(words.time)")
    }
}
