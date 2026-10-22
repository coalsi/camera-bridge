#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The cameras' security checks through the engine: on demand (rate-limited), after a runtime starts, daily and after "Set up for Camera
/// Bridge", the result on the camera's status, the cloud-dependent models, and the Internet guard's evidence. The camera's readings and the
/// RTSP check are replaced by recording fakes (the readers themselves: CameraAdaptersTests); never a real camera or address.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraSecurityEngineTests {
    /// What the checks asked: the cameras read (with the credentials they were given) and the addresses the RTSP check was sent to.
    final class Asked: Sendable {
        let readings = Box<[(camera: UUID, credentials: HTTPCredentials?)]>([])
        let probes = Box<[URL]>([])
        let evidence = Box<GuardEvidence?>(nil)
        /// Answers for the next readings, first first (nil: the camera did not answer); then `findings`.
        let answers = Box<[[RemoteAccessFinding]?]>([])
        let findings = Box<[RemoteAccessFinding]>([
            RemoteAccessFinding(feature: .cloud, state: .off, service: "Hik-Connect", canChange: true),
            RemoteAccessFinding(feature: .upnp, state: .off, canChange: true),
            RemoteAccessFinding(feature: .ddns, state: .absent),
        ])

        func install(_ tuning: inout EngineTuning) {
            tuning.securityReading = { [self] camera, credentials in
                readings.update { $0.append((camera.id, credentials)) }
                let next = answers.update { answers -> [RemoteAccessFinding]?? in
                    guard !answers.isEmpty else { return .none }
                    return .some(answers.removeFirst())
                }
                if let next { return next }
                return findings.value
            }
            tuning.rtspAccessProbe = { [self] url in
                probes.update { $0.append(url) }
                return .off
            }
            tuning.guardEvidence = { [self] _ in evidence.value }
        }
    }

    private func fixture(_ asked: Asked, modify: (inout EngineTuning) -> Void = { _ in }) async throws -> EngineFixture {
        var tuning = EngineTuning.testing
        asked.install(&tuning)
        modify(&tuning)
        return try await EngineFixture(tuning: tuning)
    }

    private func camera(vendor: CameraVendor = .hikvision, main: String? = "rtsp://admin:pa55@192.0.2.20:554/Streaming/Channels/101",
                        sub: String? = "rtsp://192.0.2.20:554/Streaming/Channels/102", enabled: Bool = false) -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: vendor, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "admin")
        camera.mainStreamURL = main.flatMap(URL.init(string:))
        camera.subStreamURL = sub.flatMap(URL.init(string:))
        camera.isEnabled = enabled
        return camera
    }

    @Test func aCheckOnDemandIsShownOnTheCameraAndRateLimited() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked)
        defer { fixture.directory.remove() }
        let camera = camera()
        try await fixture.engine.addCamera(camera, password: "pa55")
        #expect(fixture.status(camera.id)?.security == nil, "absent until the first check")

        let security = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(security.level == .green, "everything off, but no guard on this bridge")
        #expect(fixture.status(camera.id)?.security == security)
        #expect(asked.readings.value.map(\.camera) == [camera.id])
        #expect(asked.readings.value.first?.credentials == HTTPCredentials(username: "admin", password: "pa55"), "the camera's own login, for its API")
        #expect(asked.probes.value == [URL(string: "rtsp://192.0.2.20:554/Streaming/Channels/102")!], "one RTSP check, of the sub stream")
        #expect(security.findings.first { $0.feature == .unauthenticatedVideo }?.state == .off)

        do {
            _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
            Issue.record("a second check within a minute")
        } catch let tooSoon as CameraSecurityCheckTooSoon {
            #expect((1...60).contains(tooSoon.retryAfterSeconds))
        }
        #expect(asked.readings.value.count == 1 && asked.probes.value.count == 1, "nothing more was asked")
    }

    @Test func theRTSPCheckUsesTheMainStreamWithoutCredentials() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked)
        defer { fixture.directory.remove() }
        let camera = camera(vendor: .rtsp, main: "rtsp://admin:pa55@192.0.2.21:8554/live", sub: nil)
        try await fixture.engine.addCamera(camera, password: "pa55")
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(asked.probes.value == [URL(string: "rtsp://192.0.2.21:8554/live")!])
    }

    @Test func aCloudDependentCameraIsRedWithoutAskingIt() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked)
        defer { fixture.directory.remove() }
        var camera = CameraConfiguration(name: "Pan", kind: .camera, vendor: .go2rtc, endpoint: CameraEndpoint(host: "localhost"), username: "")
        camera.integration = IntegrationSettings(service: .wyze, details: [IntegrationSettings.Key.wyzeModel: "HL_PAN4"])
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "wyze://192.0.2.30?uid=TEST")
        let security = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(security.level == .red && security.findings.first?.service == "Wyze")
        #expect(asked.readings.value.isEmpty && asked.probes.value.isEmpty, "not asked: it works only through Wyze's cloud")
    }

    @Test func theDemoCameraAndUnknownCamerasAreNotChecked() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked)
        defer { fixture.directory.remove() }
        let demo = EngineFixture.demoCamera()
        try await fixture.engine.addCamera(demo, password: nil)
        await #expect(throws: EngineError.invalidSettings("Camera Bridge doesn’t check the demo camera")) {
            _ = try await fixture.engine.checkCameraSecurity(cameraID: demo.id)
        }
        await #expect(throws: EngineError.unknownCamera) { _ = try await fixture.engine.checkCameraSecurity(cameraID: UUID()) }
        #expect(asked.readings.value.isEmpty)
    }

    @Test func theGuardsEvidenceMakesItGoldAndANewOneIsAssessedWithoutAskingTheCamera() async throws {
        let asked = Asked()
        asked.evidence.set(GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, localLookups: 2, watchedFor: 2 * 86_400))
        let fixture = try await fixture(asked)
        defer { fixture.directory.remove() }
        let camera = camera()
        try await fixture.engine.addCamera(camera, password: "pa55")
        let gold = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(gold.level == .gold)

        asked.evidence.set(GuardEvidence(watched: true, outsideLookups24h: 4, lastLookupNames: ["p2p.example.com"], available: true, watchedFor: 2 * 86_400))
        await fixture.engine.guardEvidenceChanged()
        let security = try #require(fixture.status(camera.id)?.security)
        #expect(security.level == .gold, "blocked attempts do not lower the level")
        #expect(security.checkedAt == gold.checkedAt, "the time of the camera's readings, not of the guard's report")
        #expect(security.findings.first { $0.feature == .internetGuard }?.sentence.contains("4 attempts to reach the internet in the last 24 hours (p2p.example.com)") == true)
        #expect(asked.readings.value.count == 1 && asked.probes.value.count == 1, "the camera was not asked again")
    }

    @Test func checksRunAfterARuntimeStartsAndDaily() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked) { tuning in
            tuning.securityChecks = true
            tuning.securityCheckDelay = .milliseconds(50)
            tuning.securityCheckInterval = .milliseconds(400)
        }
        let camera = camera(vendor: .rtsp, main: "rtsp://127.0.0.1:1/none", sub: nil, enabled: true)   // nothing answers there
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.security != nil }, "checked after its runtime started")
        #expect(await fixture.waitFor(.seconds(10)) { asked.readings.value.count >= 2 }, "and again at the next interval")

        await fixture.engine.removeCamera(id: camera.id)
        let count = asked.readings.value.count
        try await Task.sleep(for: .milliseconds(600))
        #expect(asked.readings.value.count <= count + 1, "a removed camera is not checked again (one may have been under way)")
        await fixture.tearDown()
    }

    @Test func aCheckFollowsTheSetupAndItsRestore() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked) { tuning in
            tuning.securityChecks = true
            tuning.securityCheckDelay = .seconds(600)   // only the setup's own checks
            tuning.securityCheckFreshness = .zero
        }
        let web = try await IPCWebSetupEngineTests.FakeWebCamera()
        defer { web.stop() }
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .onvif, endpoint: web.endpoint, username: "admin")
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        await fixture.engine.start()

        _ = try await fixture.engine.applyCameraSetup(cameraID: camera.id)
        #expect(await fixture.waitFor(.seconds(10)) { asked.readings.value.count == 1 }, "checked right after the setup ran")
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.security != nil })
        _ = try await fixture.engine.restoreCameraSetup(cameraID: camera.id)
        #expect(await fixture.waitFor(.seconds(10)) { asked.readings.value.count == 2 }, "and after it was restored")
        await fixture.tearDown()
    }

    /// A camera that stops answering during a check keeps the readings of its last one (an all-unknown result would say less, not more), and
    /// is tried again soon, not a day later.
    @Test func aCameraThatDoesNotAnswerKeepsItsLastReadingsAndIsTriedAgainSoon() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked) { tuning in
            tuning.securityChecks = true
            tuning.securityCheckDelay = .seconds(600)
            tuning.securityCheckCooldown = .zero
            tuning.securityCheckRetry = .milliseconds(100)
        }
        let camera = camera()
        try await fixture.engine.addCamera(camera, password: "pa55")
        await fixture.engine.start()
        let first = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(first.level == .green)

        asked.answers.set([nil])
        await #expect(throws: CameraOfflineError.self) { _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id) }
        #expect(fixture.status(camera.id)?.security == first, "the last readings stay, with their time")
        asked.findings.set([RemoteAccessFinding(feature: .cloud, state: .on, linked: true, service: "Hik-Connect", canChange: true)])
        #expect(await fixture.waitFor(.seconds(10)) { fixture.status(camera.id)?.security?.level == .red }, "tried again soon")
        #expect(asked.readings.value.count == 3)
        await fixture.tearDown()
    }

    @Test func noCheckIsScheduledInTests() async throws {
        let asked = Asked()
        let fixture = try await fixture(asked) { $0.securityCheckDelay = .milliseconds(10) }
        let camera = camera(vendor: .rtsp, main: "rtsp://127.0.0.1:1/none", sub: nil, enabled: true)
        try await fixture.engine.addCamera(camera, password: nil)
        await fixture.engine.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.readings.value.isEmpty && fixture.status(camera.id)?.security == nil, "EngineTuning.testing turns scheduled checks off")
        await fixture.tearDown()
    }
}
#endif
