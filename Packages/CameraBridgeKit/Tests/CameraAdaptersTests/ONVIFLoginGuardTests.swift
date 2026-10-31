import BridgeSupport
import Foundation
import Testing
import TestSupport
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

    /// Patio New: one refused web sign-in paused ONVIF for 2 minutes, and the page said the camera "locked logins after too many wrong
    /// passwords". The camera had locked nothing: the pause is Camera Bridge's own, and its error says so.
    @Test func aRefusedLoginIsCameraBridgesOwnPauseNotTheCamerasLock() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        guardian.recordRejection(host: "192.0.2.212:80", now: now)
        let pause = guardian.pause(host: "192.0.2.212:80", now: now.addingTimeInterval(1))
        #expect(pause == ONVIFLoginGuard.Pause(until: now.addingTimeInterval(120), cause: .refused))
        #expect(pause?.error == .loginsPaused(until: now.addingTimeInterval(120)))
        #expect(guardian.pause(host: "192.0.2.212:80", now: now.addingTimeInterval(121)) == nil)
    }

    @Test func aLockoutIsTheCamerasOwn() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = guardian.recordLockout(host: "cam", now: now)
        #expect(guardian.pause(host: "cam", now: now) == ONVIFLoginGuard.Pause(until: until, cause: .cameraLocked))
        #expect(guardian.pause(host: "cam", now: now)?.error == .lockedOut(until: until))
        // DoorBird blocks the address for a minute after wrong credentials: a lock of the camera's, as short as Camera Bridge's own pause.
        let short = guardian.recordLockout(host: "doorbird", now: now, for: ONVIFLoginGuard.rejectionPause)
        #expect(short == now.addingTimeInterval(120))
        #expect(guardian.pause(host: "doorbird", now: now)?.error == .lockedOut(until: short))
    }

    /// A refusal that comes in while the camera's lock lasts (a request that was already on its way) never shortens the lock or recasts it as
    /// Camera Bridge's pause; once the lock is over, what is left of the pause is Camera Bridge's own.
    @Test func aRefusalDuringALockNeitherShortensNorRecastsIt() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = guardian.recordLockout(host: "cam", now: now)
        guardian.recordRejection(host: "cam", now: now.addingTimeInterval(60))
        #expect(guardian.pause(host: "cam", now: now.addingTimeInterval(61)) == ONVIFLoginGuard.Pause(until: until, cause: .cameraLocked))

        let lock = guardian.recordLockout(host: "doorbird", now: now, for: 60)
        guardian.recordRejection(host: "doorbird", now: now.addingTimeInterval(30))
        #expect(lock == now.addingTimeInterval(60))
        #expect(guardian.pause(host: "doorbird", now: now.addingTimeInterval(31))
                == ONVIFLoginGuard.Pause(until: now.addingTimeInterval(150), cause: .cameraLocked), "the camera's lock, as long as the pause lasts")
        #expect(guardian.pause(host: "doorbird", now: now.addingTimeInterval(61))
                == ONVIFLoginGuard.Pause(until: now.addingTimeInterval(150), cause: .refused), "the lock is over: Camera Bridge's own pause")
    }

    /// One account behind two ports (a web API and ONVIF): the longest pause of them, and a lock of the camera's on either is the reason.
    @Test func severalKeysGiveTheLongestPauseAndTheCamerasLockFirst() {
        let guardian = ONVIFLoginGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(guardian.pause(hosts: ["cam:80", "cam:8000"], now: now) == nil)
        guardian.recordRejection(host: "cam:8000", now: now)
        #expect(guardian.pause(hosts: ["cam:80", "cam:8000"], now: now)?.error == .loginsPaused(until: now.addingTimeInterval(120)))
        let lock = guardian.recordLockout(host: "cam:80", now: now, for: 60)
        #expect(guardian.pause(hosts: ["cam:80", "cam:8000"], now: now) == ONVIFLoginGuard.Pause(until: now.addingTimeInterval(120), cause: .cameraLocked))
        #expect(lock < now.addingTimeInterval(120))
        #expect(guardian.pause(hosts: [], now: now) == nil)
    }

    @Test func clearForgetsBoth() {
        let guardian = ONVIFLoginGuard()
        let now = Date()
        guardian.recordRejection(host: "cam", now: now)
        guardian.recordLockout(host: "cam", now: now)
        guardian.clear(host: "cam")
        #expect(guardian.pause(host: "cam") == nil && guardian.blockedUntil(host: "cam") == nil)
    }

    @Test func bothPausesAreLoginRefusalsThatStopAConfigurationChain() {
        let until = Date(timeIntervalSince1970: 1_000_000)
        #expect(CameraAdapterError.loginsPaused(until: until).isLoginRefusal)
        #expect(CameraAdapterError.lockedOut(until: until).isLoginRefusal)
        #expect(CameraConfigFailure.from(CameraAdapterError.loginsPaused(until: until)) == .loginsPaused(until: until))
        #expect(CameraConfigFailure.from(CameraAdapterError.lockedOut(until: until)) == .lockedOut(until: until))
        #expect(CameraConfigFailure.loginsPaused(until: until).stopsChain)
        #expect(CameraConfigFailure.loginsPaused(until: until).summary == "logins paused")
        #expect(CameraConfigFailure.lockedOut(until: until).summary == "logins locked")
    }
}

#if os(macOS) || os(Linux)
/// The pause as a client meets it: a client whose own login the camera refused reports that refusal on its next calls (nothing more is
/// sent); any other client meets Camera Bridge's pause.
@Suite(.timeLimit(.minutes(1))) struct ONVIFLoginPauseClientTests {
    @Test func theRefusedClientReportsItsRefusalAndOthersMeetThePause() async throws {
        let camera = try await MockONVIFCamera.start()
        let host = "127.0.0.1:\(camera.server.port)"
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.rejectCredentials.set(true)
        let url = try #require(ONVIFClient.deviceServiceURL(for: camera.endpoint))
        let wrong = HTTPCredentials(username: "admin", password: "wrong")
        let refused = ONVIFClient(deviceServiceURL: url, credentials: wrong)
        await #expect(throws: CameraAdapterError.unauthorized) { try await refused.deviceInformation() }
        let sent = camera.server.requests.count
        await #expect(throws: CameraAdapterError.unauthorized) { try await refused.capabilities() }
        let other = ONVIFClient(deviceServiceURL: url, credentials: wrong)
        await #expect { try await other.deviceInformation() } throws: { error in
            if case CameraAdapterError.loginsPaused = error { true } else { false }
        }
        #expect(camera.server.requests.count == sent, "nothing is sent while the logins are paused")
    }
}

/// Review Oct 31 (adapters F3): the driver's long-lived client measured the camera's clock once. After the camera's clock moved (Camera
/// Bridge's own "Time from the bridge", or a drift), every WS-Security `Created` it sent was off, the camera answered `NotAuthorized`, and
/// that counted as a wrong password: logins paused for 2 minutes and the event channel stopped. The clock is measured again every 10 minutes,
/// and before a refusal counts; a real wrong password still costs exactly one attempt.
@Suite(.timeLimit(.minutes(1))) struct ONVIFClockStepTests {
    private func started() async throws -> (MockONVIFCamera, URL, String) {
        let camera = try await MockONVIFCamera.start(clockOffset: 600)   // ten minutes fast
        camera.createdTolerance.set(300)
        let host = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: host)
        return (camera, try #require(ONVIFClient.deviceServiceURL(for: camera.endpoint)), host)
    }

    private func count(_ camera: MockONVIFCamera, _ action: String) -> Int { camera.actions.value.filter { $0 == action }.count }

    @Test func aCameraWhoseClockWasSetIsAskedForItsTimeBeforeTheRefusalCounts() async throws {
        let (camera, url, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        let now = Box(Date())
        let client = ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                 now: { now.value })
        _ = try await client.systemDateAndTime()
        _ = try await client.deviceInformation()
        // The camera's clock is set right (ten minutes back) a while later.
        camera.clockShift.set(-600)
        now.set(now.value.addingTimeInterval(120))
        _ = try await client.deviceInformation()
        #expect(count(camera, "GetSystemDateAndTime") == 2, "asked once more, before the refusal counted")
        #expect(count(camera, "GetDeviceInformation") == 3, "and the call was made again with the camera's time")
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil, "no wrong password: nothing pauses")
    }

    @Test func aWrongPasswordStillCostsOneAttempt() async throws {
        let (camera, url, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        let now = Box(Date())
        let client = ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: "wrong"), now: { now.value })
        _ = try await client.systemDateAndTime()
        now.set(now.value.addingTimeInterval(120))
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.deviceInformation() }
        #expect(count(camera, "GetDeviceInformation") == 1, "the clock did not move: no second attempt")
        #expect(ONVIFLoginGuard.shared.pause(host: host) != nil)
    }

    @Test func theDriversClientKeepsTheCameraClockInStep() async throws {
        let (camera, url, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        let now = Box(Date())
        let client = ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                 keepsClockInStep: true, now: { now.value })
        _ = try await client.deviceInformation()
        #expect(camera.actions.value.prefix(2) == ["GetSystemDateAndTime", "GetDeviceInformation"], "its first call measures the clock")
        _ = try await client.deviceInformation()
        #expect(count(camera, "GetSystemDateAndTime") == 1)
        now.set(now.value.addingTimeInterval(11 * 60))
        _ = try await client.deviceInformation()
        #expect(count(camera, "GetSystemDateAndTime") == 2, "measured again after ten minutes")
    }
}
#endif
