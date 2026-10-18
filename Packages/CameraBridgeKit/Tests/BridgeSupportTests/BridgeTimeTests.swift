import Foundation
import Testing
@testable import BridgeSupport

/// Patio New (Oct 18): Camera Bridge's login pause ended at 16:19:37 UTC, and the page said "after 4:19 PM". The box runs in UTC; the bridge's
/// time zone (its settings) is America/Phoenix, where that is 9:19 AM.
@Suite struct BridgeTimeTests {
    private static let until = Date(timeIntervalSince1970: 1_792_340_377)   // 2026-10-18T16:19:37Z
    private static let english = Locale(identifier: "en_US")
    private static let phoenix = TimeZone(identifier: "America/Phoenix")!
    private static let utc = TimeZone(identifier: "UTC")!

    /// ICU puts a narrow no-break space before AM/PM.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func aClockTimeIsInTheZoneItIsGiven() {
        #expect(Self.until == (try? Date("2026-10-18T16:19:37Z", strategy: .iso8601)))
        #expect(plain(BridgeTime.clock(Self.until, in: Self.phoenix, locale: Self.english)) == "9:19 AM")
        #expect(plain(BridgeTime.clock(Self.until, in: Self.utc, locale: Self.english)) == "4:19 PM")
    }

    /// Without a zone of its own, a clock time is in the bridge's (`zone`), whatever the process's is.
    @Test func aClockTimeIsInTheBridgesZoneNotTheProcesss() {
        BridgeTime.$taskZone.withValue(Self.phoenix) {
            #expect(BridgeTime.zone == Self.phoenix)
            #expect(plain(BridgeTime.clock(Self.until, locale: Self.english)) == "9:19 AM")
        }
        BridgeTime.$taskZone.withValue(Self.utc) {
            #expect(plain(BridgeTime.clock(Self.until, locale: Self.english)) == "4:19 PM")
        }
    }

    @Test func onlyAZoneTheSystemKnowsIsTaken() {
        #expect(BridgeTime.zone(named: "America/Phoenix") == Self.phoenix)
        #expect(BridgeTime.zone(named: "Mars/Olympus_Mons") == nil)
        #expect(BridgeTime.zone(named: "") == nil)
        #expect(BridgeTime.zone(named: nil) == nil)
    }
}
