import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// What the page says about paused logins (a setup preview that met the pause, Patio New on Oct 18): Camera Bridge's own pause after a
/// refused login says what to check; the camera's own lock says nothing to do but wait. Each in two zones (Phoenix and UTC), so a time worded
/// in the process's zone fails on any machine, not only where the process runs in UTC.
@Suite struct LoginPauseErrorTextTests {
    private static let until = Date(timeIntervalSince1970: 1_792_340_377)   // 2026-10-18T16:19:37Z
    private static let zones = [TimeZone(identifier: "America/Phoenix")!, TimeZone(identifier: "UTC")!]

    @Test func cameraBridgesOwnPauseSaysToCheckTheUsernameAndPassword() {
        #expect(Set(Self.zones.map { BridgeTime.clock(Self.until, in: $0) }).count == 2)
        for zone in Self.zones {
            let clock = BridgeTime.clock(Self.until, in: zone)
            let text = BridgeTime.$taskZone.withValue(zone) { ErrorText.describe(CameraAdapterError.loginsPaused(until: Self.until)) }
            #expect(text == "The camera refused the username or password Camera Bridge has, so Camera Bridge waits until \(clock) before it logs in "
                    + "again, so the camera doesn’t lock the account. Check the camera’s username and password in Camera Bridge.", "\(zone.identifier)")
        }
    }

    @Test func theCamerasOwnLockSaysToWait() {
        for zone in Self.zones {
            let clock = BridgeTime.clock(Self.until, in: zone)
            let text = BridgeTime.$taskZone.withValue(zone) { ErrorText.describe(CameraAdapterError.lockedOut(until: Self.until)) }
            #expect(text == "The camera locked its logins after too many wrong passwords; Camera Bridge waits until \(clock) before it tries again.",
                    "\(zone.identifier)")
        }
    }

    /// The Reolink doorbell refused its ONVIF account a change it had just signed in for: nothing to wait for, and no password to check.
    @Test func aChangeTheAccountMayNotMakeSaysToUseAnAdministratorAccount() {
        #expect(ErrorText.describe(CameraAdapterError.notPermitted("SetNTP"))
                == "The account Camera Bridge uses may not change this; use an administrator account in the camera’s settings.")
    }
}
