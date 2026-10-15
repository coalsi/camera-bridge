import Foundation
import Testing
@testable import CameraAdapters

/// A time zone as cameras take it (ONVIF `SetSystemDateAndTime` wants a POSIX TZ string).
@Suite struct PosixTimeZoneTests {
    @Test func comesFromTheSystemsZoneFile() {
        #expect(PosixTimeZone.string(for: "America/Phoenix") == "MST7", "Arizona: no daylight saving")
        #expect(PosixTimeZone.string(for: "America/Denver")?.hasPrefix("MST7MDT,") == true)
        #expect(PosixTimeZone.string(for: "UTC") == "UTC0")
        #expect(PosixTimeZone.string(for: "Not/AZone") == nil)
        #expect(PosixTimeZone.string(for: "../../etc/passwd") == nil)
    }

    @Test func knowsWhetherAZoneHasDaylightSaving() {
        #expect(!PosixTimeZone.hasDaylightSaving("MST7"))
        #expect(!PosixTimeZone.hasDaylightSaving("UTC0"))
        #expect(!PosixTimeZone.hasDaylightSaving("<-03>3"))
        #expect(PosixTimeZone.hasDaylightSaving("MST7MDT,M3.2.0,M11.1.0"))
        #expect(PosixTimeZone.hasDaylightSaving("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0"))
    }
}
