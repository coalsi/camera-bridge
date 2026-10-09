import Foundation
import Testing
@testable import CameraAdapters

@Suite struct ONVIFLoginGuardTests {
    @Test func aRejectedLoginPausesThatHostOnlyBriefly() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        guardian.recordRejection(host: "192.0.2.212", now: now)
        #expect(guardian.blockedUntil(host: "192.0.2.212", now: now.addingTimeInterval(60)) != nil)
        #expect(guardian.blockedUntil(host: "192.0.2.212", now: now.addingTimeInterval(121)) == nil)
        #expect(guardian.blockedUntil(host: "192.0.2.41", now: now) == nil)
    }

    @Test func aLockoutPausesLoginsForThirtyMinutes() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = guardian.recordLockout(host: "cam", now: now)
        #expect(until == now.addingTimeInterval(30 * 60))
        #expect(guardian.blockedUntil(host: "cam", now: now.addingTimeInterval(29 * 60)) == until)
        #expect(guardian.blockedUntil(host: "cam", now: now.addingTimeInterval(31 * 60)) == nil)
    }
}
