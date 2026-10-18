#if canImport(Darwin)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine
@testable import CameraAdapters

/// "Change it by hand" in the engine (`BridgeEngine.withManualHelp`): the camera's family (its vendor and maker, and the web API its address
/// showed in this run, remembered while the bridge runs), the bridge's own address on the camera's network for its DNS and its time, and the
/// bridge's time zone. Nothing here asks a camera.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraManualHelpEngineTests {
    nonisolated static let bridge = "192.168.77.2"

    private func fixture(guarded: Bool = true, servesTime: Bool = true) async throws -> EngineFixture {
        var tuning = EngineTuning.testing
        tuning.interfaceAddresses = {
            [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
             InterfaceAddress(interface: "en0", address: CameraManualHelpEngineTests.bridge, prefixLength: 24)]
        }
        return try await EngineFixture(tuning: tuning, servesTime: servesTime, configure: { $0.timeZone = "America/Phoenix" }, adjust: { environment in
            guard guarded else { return }
            environment.hasInternetGuard = true
            environment.setGuardedCameras = { _ in }
        })
    }

    private func add(_ fixture: EngineFixture, vendor: CameraVendor = .onvif, host: String = "192.168.77.21", port: Int = 80,
                     manufacturer: String = "") async throws -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Patio", kind: .camera, vendor: vendor, endpoint: CameraEndpoint(host: host, httpPort: port), username: "admin")
        camera.manufacturer = manufacturer
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        return camera
    }

    private static let failed = CameraSetupReport(steps: [
        CameraSetupStep(id: .timeZone, title: "Time zone", status: .refused, detail: "the camera kept its time zone (UTC)"),
        CameraSetupStep(id: .timeSource, title: "Time from the bridge", status: .refused, detail: "the camera refused the login"),
        CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .refused, detail: "the camera kept 8.8.8.8 as its other DNS server"),
        CameraSetupStep(id: .cloud, title: "Cloud off", status: .done),
    ], state: nil, canRestore: true)

    @Test func aReportsHelpUsesTheBridgesAddressOnTheCamerasNetworkAndItsTimeZone() async throws {
        let fixture = try await fixture()
        let camera = try await add(fixture, vendor: .reolink)
        let report = fixture.engine.withManualHelp(Self.failed, cameraID: camera.id)
        let zone = try #require(report.steps[0].manualHelp)
        #expect(zone.values.first?.label == "Time zone" && zone.values.first?.value.hasPrefix("America/Phoenix (UTC−7") == true)
        #expect(report.steps[1].manualHelp?.values.contains(.init(label: "NTP server", value: Self.bridge)) == true)
        let watch = try #require(report.steps[2].manualHelp)
        #expect(watch.values.contains(.init(label: "Preferred DNS server", value: Self.bridge)))
        #expect(watch.places.first?.app == "The Reolink app", "the family is the camera's")
        #expect(watch.why == "The camera didn’t take the change: the camera kept 8.8.8.8 as its other DNS server.", "why, in the step's own words")
        #expect(!(watch.router ?? "").contains("8.8.8.8") && watch.values.allSatisfy { !$0.value.contains("8.8.8.8") }, "what to set is the bridge's address")
        #expect(report.steps[3].manualHelp == nil)
        #expect(fixture.engine.withManualHelp(Self.failed, cameraID: UUID()) == Self.failed, "an unknown camera gets none")
    }

    @Test func withoutTheGuardOrTheTimeServiceThoseStepsHaveNoHelp() async throws {
        let fixture = try await fixture(guarded: false, servesTime: false)
        let camera = try await add(fixture, vendor: .hikvision)
        let report = fixture.engine.withManualHelp(Self.failed, cameraID: camera.id)
        #expect(report.steps[0].manualHelp != nil)
        #expect(report.steps[1].manualHelp == nil && report.steps[2].manualHelp == nil)
    }

    @Test func theWebAPIFamilyTheBridgeSawIsRememberedWhileItRuns() async throws {
        let fixture = try await fixture()
        let camera = try await add(fixture, port: 47_123)
        let key = IPCamWebLatch.key(camera.endpoint)
        IPCamWebLatch.shared.reset(key)
        defer { IPCamWebLatch.shared.reset(key) }
        #expect(fixture.engine.cameraFamily(camera) == .onvif)
        IPCamWebLatch.shared.markFamily(key)
        #expect(fixture.engine.cameraFamily(camera) == .ipcamWeb)
        let report = fixture.engine.withManualHelp(Self.failed, cameraID: camera.id)
        #expect(report.steps[2].manualHelp?.places.first?.path == ["Configuration", "Network", "IP Address"])
        IPCamWebLatch.shared.reset(key)   // the camera started again in the bridge: its page is asked again later
        #expect(fixture.engine.cameraFamily(camera) == .ipcamWeb, "the help does not change while the bridge asks again")
    }

    @Test func theSecurityCardsFindingsGetHelpWhereTheSetupCantChangeThem() async throws {
        let fixture = try await fixture()
        let camera = try await add(fixture, vendor: .reolink)
        let notWatched = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        let security = CameraSecurity.assess([RemoteAccessFinding(feature: .upnp, state: .on), RemoteAccessFinding(feature: .cloud, state: .off)],
                                             internetGuard: notWatched, checkedAt: Date())
        let helped = fixture.engine.withManualHelp(security, cameraID: camera.id)
        #expect(helped.findings.first { $0.feature == .internetGuard }?.manualHelp?.values.contains(.init(label: "Preferred DNS server", value: Self.bridge)) == true)
        #expect(helped.findings.first { $0.feature == .upnp }?.manualHelp != nil)
        #expect(helped.findings.first { $0.feature == .cloud }?.manualHelp == nil)
        #expect(helped.level == security.level && helped.findings.map(\.sentence) == security.findings.map(\.sentence))

        var status = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor)
        status.security = security
        let unchecked = CameraStatus(id: UUID(), name: "Other", kind: .camera, vendor: .onvif)
        let statuses = fixture.engine.withManualHelp([status, unchecked])
        #expect(statuses[0].security == helped, "the status the page gets carries the same help")
        #expect(statuses[1] == unchecked)
    }

    /// The guard's "point its DNS at Camera Bridge yourself" follows the camera's DNS as the engine last read it: none while the camera
    /// already asks the bridge (the box has not started watching it yet), the help once it asks other servers, and for a doorbell the cloud's
    /// note says its rings still come through Apple Home.
    @Test func theGuardsDNSHelpFollowsTheLastReading() async throws {
        let fixture = try await fixture()
        let camera = try await add(fixture, vendor: .reolink)
        let notWatched = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        let security = CameraSecurity.assess([RemoteAccessFinding(feature: .upnp, state: .off)], internetGuard: notWatched, checkedAt: Date())
        func reading(_ servers: [String]) -> CameraDNSCheck {
            .read(CameraDNSReading(servers: servers, fromDHCP: false, method: .reolinkAPI,
                                   backup: CameraDNSBackup(method: .reolinkAPI, fromDHCP: false, servers: servers)))
        }
        func guardHelp() -> CameraManualHelp? {
            fixture.engine.withManualHelp(security, cameraID: camera.id).findings.first { $0.feature == .internetGuard }?.manualHelp
        }
        #expect(guardHelp() != nil, "not read yet")
        fixture.engine.securityChecks.records[camera.id] = .init(readings: [], cloudModel: nil, dns: reading([Self.bridge, Self.bridge]),
                                                                 security: security, finished: .now)
        #expect(guardHelp() == nil, "it already asks the bridge")
        fixture.engine.securityChecks.records[camera.id]?.dns = reading(["192.168.77.1"])
        #expect(guardHelp()?.values.contains(.init(label: "Preferred DNS server", value: Self.bridge)) == true, "it asks the router")
        var status = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor)
        status.security = security
        fixture.engine.securityChecks.records[camera.id]?.dns = reading([Self.bridge])
        #expect(fixture.engine.withManualHelp([status])[0].security?.findings.first { $0.feature == .internetGuard }?.manualHelp == nil,
                "the statuses follow the same rule")

        var doorbell = CameraConfiguration(name: "Doorbell", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.168.77.31"),
                                           username: "admin")
        doorbell.isEnabled = false
        try await fixture.engine.addCamera(doorbell, password: "pa55")
        let failed = CameraSetupReport(steps: [CameraSetupStep(id: .cloud, title: "Cloud off", status: .refused)], state: nil, canRestore: true)
        #expect(fixture.engine.withManualHelp(failed, cameraID: doorbell.id).steps[0].manualHelp?.note?.contains("Doorbell rings") == true)
        #expect(fixture.engine.withManualHelp(failed, cameraID: camera.id).steps[0].manualHelp?.note?.contains("Doorbell rings") == false)
    }

    @Test func aCameraTheSetupDoesNotWorkWithGetsNoHelp() async throws {
        let fixture = try await fixture()
        let camera = try await add(fixture, vendor: .rtsp)
        let notWatched = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        let security = CameraSecurity.assess([RemoteAccessFinding(feature: .upnp, state: .on)], internetGuard: notWatched, checkedAt: Date())
        #expect(fixture.engine.withManualHelp(security, cameraID: camera.id) == security, "Camera Bridge can't read its DNS, so pointing it by hand would show nothing")
        #expect(fixture.engine.withManualHelp(Self.failed, cameraID: camera.id) == Self.failed)
    }
}
#endif
