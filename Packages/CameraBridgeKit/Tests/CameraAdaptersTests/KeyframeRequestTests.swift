// Loopback mock cameras (PlatformApple transport): macOS only.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// `CameraDriver.requestKeyframe` (audit 2 F6): a live view that starts inside a camera's long GOP asks the camera for a keyframe
/// through the adapters. One request per need, never retried, nothing that could cost a login (Hikvision locks the account after
/// a few failed ones): spacing per camera, a camera without the call is not asked again, a rejected login pauses the camera's logins.
@Suite(.serialized, .timeLimit(.minutes(1))) struct KeyframeRequestTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")

    private func hikvision(_ camera: MockHikvisionCamera, spacing: Duration = .seconds(60), credentials: HTTPCredentials? = nil) -> (HikvisionDriver, CameraKeyframeGuard) {
        let guardian = CameraKeyframeGuard(spacing: spacing)
        let driver = HikvisionDriver(endpoint: camera.endpoint, credentials: credentials ?? self.credentials, mainStreamURL: nil, subStreamURL: nil,
                                     transport: PlatformNetworkTransport(), keyframeGuard: guardian)
        return (driver, guardian)
    }

    private func forgetLogins(_ endpoint: CameraEndpoint) {
        ONVIFLoginGuard.shared.clear(host: "\(endpoint.host):\(endpoint.httpPort)")
    }

    // MARK: Hikvision

    @Test func hikvisionAsksOnceForTheMainChannelAndOnceForTheSub() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer { camera.stop() }
        let (driver, _) = hikvision(camera)
        try await driver.requestKeyframe(subStream: false)
        #expect(camera.keyFrameRequests.value == ["101"])
        try await driver.requestKeyframe(subStream: false)
        #expect(camera.keyFrameRequests.value == ["101"], "a second request to the same stream within the spacing sends nothing")
        try await driver.requestKeyframe(subStream: true)
        #expect(camera.keyFrameRequests.value == ["101", "102"], "the sub stream is its own channel")
    }

    @Test func hikvisionRequestsKeepTheirSpacingThenGoOutAgain() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer { camera.stop() }
        let (driver, _) = hikvision(camera, spacing: .milliseconds(150))
        try await driver.requestKeyframe(subStream: false)
        try await driver.requestKeyframe(subStream: false)
        try await Task.sleep(for: .milliseconds(250))
        try await driver.requestKeyframe(subStream: false)
        #expect(camera.keyFrameRequests.value == ["101", "101"])
    }

    @Test func hikvisionNvrChannelsAreAskedByTheirOwnNumber() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer { camera.stop() }
        let driver = HikvisionDriver(endpoint: camera.endpoint, credentials: credentials,
                                     mainStreamURL: URL(string: "rtsp://127.0.0.1:554/ISAPI/Streaming/channels/401"), subStreamURL: nil,
                                     transport: PlatformNetworkTransport(), keyframeGuard: CameraKeyframeGuard(spacing: .seconds(60)))
        try await driver.requestKeyframe(subStream: true)
        #expect(camera.keyFrameRequests.value == ["402"])
    }

    /// The one thing that must never happen: another failed login. A rejected login is one attempt, not repeated, and pauses every
    /// login to that camera (ONVIF's too), so the next ask fails at once without sending anything.
    @Test func aRejectedLoginIsNotRepeatedAndPausesTheCamera() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer {
            camera.stop()
            forgetLogins(camera.endpoint)
        }
        let (driver, _) = hikvision(camera, spacing: .zero, credentials: HTTPCredentials(username: "nobody", password: "x"))
        await #expect(throws: CameraAdapterError.unauthorized) { try await driver.requestKeyframe(subStream: false) }
        let sent = camera.server.requests.count
        #expect(camera.keyFrameRequests.value.isEmpty, "the camera never saw a request it accepted")
        for _ in 0..<5 {
            await #expect(throws: CameraAdapterError.self) { try await driver.requestKeyframe(subStream: false) }
        }
        #expect(camera.server.requests.count == sent, "nothing more was sent: \(camera.server.requests.count - sent) extra requests")
        let paused = ONVIFLoginGuard.shared.blockedUntil(host: "\(camera.endpoint.host):\(camera.endpoint.httpPort)")
        #expect(paused != nil, "the camera's logins are paused")
    }

    @Test func aPausedLoginIsRespectedWithoutSendingAnything() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer {
            camera.stop()
            forgetLogins(camera.endpoint)
        }
        ONVIFLoginGuard.shared.recordLockout(host: "\(camera.endpoint.host):\(camera.endpoint.httpPort)")
        let (driver, _) = hikvision(camera, spacing: .zero)
        await #expect { try await driver.requestKeyframe(subStream: false) } throws: { error in
            if case CameraAdapterError.lockedOut = error { true } else { false }
        }
        #expect(camera.server.requests.isEmpty)
    }

    @Test func aCameraWithoutTheCallIsNotAskedAgain() async throws {
        let camera = try await MockHikvisionCamera.start()
        forgetLogins(camera.endpoint)
        defer { camera.stop() }
        camera.keyFrameStatus.set(404)
        let (driver, _) = hikvision(camera, spacing: .zero)
        await #expect { try await driver.requestKeyframe(subStream: false) } throws: { error in
            if case CameraAdapterError.unsupported = error { true } else { false }
        }
        camera.keyFrameStatus.set(200)   // even if it learned the call meanwhile: the answer was remembered
        await #expect(throws: CameraAdapterError.self) { try await driver.requestKeyframe(subStream: false) }
        #expect(camera.keyFrameRequests.value == ["101"], "one request, never another")
    }

    @Test func otherCamerasHaveNoKeyframeRequestAndSayWhy() async throws {
        let demo = DemoCameraDriver()
        await #expect { try await demo.requestKeyframe(subStream: false) } throws: { error in
            if case CameraAdapterError.unsupported = error { true } else { false }
        }
    }

    // MARK: ONVIF

    @Test func onvifSetsASynchronizationPointOnTheMainAndSubProfiles() async throws {
        let camera = try await MockONVIFCamera.start()
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        defer {
            camera.stop()
            ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        }
        let guardian = CameraKeyframeGuard(spacing: .seconds(60))
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                 mainStreamURL: nil, subStreamURL: nil, transport: PlatformNetworkTransport(), keyframeGuard: guardian)
        try await driver.requestKeyframe(subStream: false)
        #expect(camera.synchronizationPoints.value == ["000"], "the main (largest) profile")
        let listings = camera.actions.value.filter { $0 == "GetProfiles" }.count
        try await driver.requestKeyframe(subStream: true)
        #expect(camera.synchronizationPoints.value == ["000", "001"])
        #expect(camera.actions.value.filter { $0 == "GetProfiles" }.count == listings, "the profiles are listed once")
        try await driver.requestKeyframe(subStream: true)
        #expect(camera.synchronizationPoints.value.count == 2, "within the spacing nothing is sent")
    }

    @Test func onvifRejectedCredentialsAreNotRetried() async throws {
        let camera = try await MockONVIFCamera.start()
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        defer {
            camera.stop()
            ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        }
        camera.rejectCredentials.set(true)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "wrong"), mainStreamURL: nil, subStreamURL: nil,
                                 transport: PlatformNetworkTransport(), keyframeGuard: CameraKeyframeGuard(spacing: .zero))
        // The first refused login throws as `.unauthorized` or, when the profile listing's follow-up calls meet the pause it set, `.lockedOut`.
        await #expect { try await driver.requestKeyframe(subStream: false) } throws: { error in (error as? CameraAdapterError)?.isLoginRefusal == true }
        let sent = camera.server.requests.count
        for _ in 0..<3 { await #expect(throws: CameraAdapterError.self) { try await driver.requestKeyframe(subStream: false) } }
        #expect(camera.server.requests.count == sent, "the paused login sends nothing")
        #expect(camera.synchronizationPoints.value.isEmpty)
    }

    @Test func onvifCameraThatDoesNotKnowSetSynchronizationPointIsNotAskedAgain() async throws {
        let camera = try await MockONVIFCamera.start()
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        defer {
            camera.stop()
            ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)")
        }
        camera.refuseSynchronizationPoint.set(true)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                 mainStreamURL: nil, subStreamURL: nil, transport: PlatformNetworkTransport(), keyframeGuard: CameraKeyframeGuard(spacing: .zero))
        await #expect { try await driver.requestKeyframe(subStream: false) } throws: { error in
            if case CameraAdapterError.unsupported = error { true } else { false }
        }
        await #expect(throws: CameraAdapterError.self) { try await driver.requestKeyframe(subStream: false) }
        #expect(camera.synchronizationPoints.value == ["000"], "asked once")
    }
}
#endif
