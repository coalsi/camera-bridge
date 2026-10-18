import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeEngine

/// Patio New (Oct 18, on the box): one refused web sign-in paused the camera's logins for 2 minutes, and the setup page said "The camera
/// locked logins after too many wrong passwords; Camera Bridge will try again after 4:19 PM". The camera had locked nothing (the pause is
/// Camera Bridge's own), and 4:19 PM was the box's UTC: the bridge's time zone is America/Phoenix, where it was 9:19 AM.
@Suite struct LoginPauseTextTests {
    private static let until = Date(timeIntervalSince1970: 1_792_340_377)   // 2026-10-18T16:19:37Z
    private static let phoenix = TimeZone(identifier: "America/Phoenix")!
    private static let utc = TimeZone(identifier: "UTC")!

    private func reason(_ error: CameraAdapterError, in zone: TimeZone) -> String {
        BridgeTime.$taskZone.withValue(zone) { BridgeEngine.readableReason(error) }
    }

    @Test func cameraBridgesOwnPauseSaysTheCameraRefusedThePassword() {
        let clock = BridgeTime.clock(Self.until, in: Self.phoenix)
        let text = reason(.loginsPaused(until: Self.until), in: Self.phoenix)
        #expect(text == "the camera refused the username or password Camera Bridge has, so Camera Bridge waits until \(clock) before it logs in "
                + "again, so the camera doesn’t lock the account")
        #expect(!text.contains("locked"))
    }

    @Test func theCamerasOwnLockSaysSo() {
        let clock = BridgeTime.clock(Self.until, in: Self.phoenix)
        #expect(reason(.lockedOut(until: Self.until), in: Self.phoenix)
                == "the camera locked its logins after too many wrong passwords; Camera Bridge waits until \(clock) before it tries again")
    }

    /// The time is the bridge's, whatever the process's zone is (UTC on the box, where 16:19:37Z read "4:19 PM").
    @Test func theTimeIsInTheBridgesZone() {
        let phoenix = BridgeTime.clock(Self.until, in: Self.phoenix), utc = BridgeTime.clock(Self.until, in: Self.utc)
        #expect(phoenix != utc)
        for error in [CameraAdapterError.loginsPaused(until: Self.until), .lockedOut(until: Self.until)] {
            let text = reason(error, in: Self.phoenix)
            #expect(text.contains(phoenix) && !text.contains(utc), "\(text)")
            #expect(reason(error, in: Self.utc).contains(utc))
        }
    }

    /// The bridge's zone is taken when the engine loads its configuration (it used to be applied only when settings were saved, so after every
    /// restart the times were the box's UTC), and the process's own zone is left as it is at launch: the recorder names its folders in it.
    @MainActor @Test func theEngineTakesTheBridgesZoneWhenItLoadsItsConfiguration() throws {
        let directory = try TemporaryDirectory()
        defer {
            BridgeTime.use(nil)
            directory.remove()
        }
        var settings = BridgeSettings()
        settings.timeZone = "Pacific/Chatham"   // +12:45: no test machine runs in it
        try ConfigurationStore(directory: directory.url).save(BridgeConfiguration(settings: settings))
        let process = TimeZone.current.identifier
        let engine = BridgeEngine(environment: .inert(directory: directory.url))
        #expect(engine.settings.timeZone == "Pacific/Chatham")
        #expect(BridgeTime.zone.identifier == "Pacific/Chatham")
        #expect(TimeZone.current.identifier == process, "the process's zone is not changed at launch")
    }
}
