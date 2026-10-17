#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The internet guard in the engine (docs/superpowers/specs/2026-10-17-internet-guard-design.md, stage 1, Watch): the "Watch its internet"
/// step of Set up for Camera Bridge (offered, previewed, applied with read-back, restored), the list of watched cameras kept in step with the
/// box (at start, after the step, on removal and address changes, tried again after a refusal), the box's report as the security levels'
/// evidence, and the day's notice. The box is a fake (`FakeGuard`); the camera is the loopback fake Hikvision of `CameraSetupEngineTests`,
/// standing for one at 192.168.77.21 on the bridge's 192.168.77.0/24. Never a real camera or address.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InternetGuardEngineTests {
    struct Refused: Error, CustomStringConvertible {
        var description: String { "The system couldn’t change the internet guard." }
    }

    /// Camera Bridge OS's side: every list the engine sent, refusals the test turns on, and the report it gives.
    final class FakeGuard: Sendable {
        let lists = Box<[[GuardedCamera]]>([])
        /// The next this many changes are refused.
        let refusals = Box(0)
        let report = Box<GuardReport?>(nil)

        func install(_ environment: inout BridgeEnvironment) {
            environment.hasInternetGuard = true
            environment.setGuardedCameras = { [self] cameras in
                lists.update { $0.append(cameras) }
                let refuse = refusals.update { count -> Bool in
                    guard count > 0 else { return false }
                    count -= 1
                    return true
                }
                if refuse { throw Refused() }
            }
            environment.guardReport = { [self] in report.value }
        }

        var last: [GuardedCamera]? { lists.value.last }
    }

    nonisolated static let cameraAddress = "192.168.77.21"
    nonisolated static let bridgeAddress = "192.168.77.2"
    static let ipAddressPath = "/ISAPI/System/Network/interfaces/1/ipAddress"
    static let now = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    static func ipAddress(primary: String = "8.8.8.8", secondary: String = "1.1.1.1") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><IPAddress version=\"2.0\" \(CameraSetupEngineTests.FakeHikvision.ns)><ipVersion>v4</ipVersion>"
            + "<addressingType>dynamic</addressingType><ipAddress>\(cameraAddress)</ipAddress><subnetMask>255.255.255.0</subnetMask>"
            + "<DefaultGateway><ipAddress>192.168.77.1</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>\(primary)</ipAddress></PrimaryDNS>"
            + "<SecondaryDNS><ipAddress>\(secondary)</ipAddress></SecondaryDNS></IPAddress>"
    }

    /// The bridge's address on the cameras' network (a test can move it).
    nonisolated static let currentBridgeAddress = Box(bridgeAddress)

    private static func tuning(cameraAddress: String = cameraAddress, bridge: Box<String>? = nil) -> EngineTuning {
        var tuning = EngineTuning.testing
        tuning.interfaceAddresses = {
            [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
             InterfaceAddress(interface: "en0", address: bridge?.value ?? bridgeAddress, prefixLength: 24)]
        }
        // The loopback fake stands for a camera on the bridge's network.
        tuning.guardCameraAddress = { camera in camera.endpoint.host == "127.0.0.1" ? cameraAddress : BridgeEngine.guardAddress(camera.endpoint.host) }
        tuning.guardSyncRetry = .milliseconds(20)
        tuning.guardPollInterval = .seconds(600)   // the tests poll by hand
        return tuning
    }

    private func fixture(guarded: FakeGuard?, tuning: EngineTuning = InternetGuardEngineTests.tuning(),
                         directory: TemporaryDirectory? = nil) async throws -> EngineFixture {
        try await EngineFixture(tuning: tuning, directory: directory, adjust: { environment in guarded?.install(&environment) })
    }

    private func setupCamera(_ fixture: EngineFixture) async throws -> (CameraSetupEngineTests.FakeHikvision, CameraConfiguration) {
        let camera = try await CameraSetupEngineTests.FakeHikvision()
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress() }
        var configuration = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "admin")
        configuration.isEnabled = false   // no stream: only the settings are tried
        try await fixture.engine.addCamera(configuration, password: "pa55")
        return (camera, configuration)
    }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }

    /// A camera at `host` whose Watch is done, as a finished setup leaves it.
    private func watchedCamera(_ fixture: EngineFixture, host: String, name: String) async throws -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: host), username: "admin")
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        await fixture.engine.changeConfiguration(camera.id) { configuration in
            configuration.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                          internetWatch: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8"]))
            configuration.setupState = CameraSetupState(started: Self.now, applied: Self.now, steps: [.init(id: .internetWatch, status: .done)])
        }
        return try #require(stored(fixture, camera.id))
    }

    // MARK: The step

    @Test func theStepIsNotOfferedWithoutTheGuardOrOffTheBridgesNetwork() async throws {
        let mac = try await fixture(guarded: nil)
        defer { mac.directory.remove() }
        let (camera, configuration) = try await setupCamera(mac)
        defer { camera.stop() }
        let preview = try await mac.engine.cameraSetupPreview(cameraID: configuration.id)
        let step = try #require(preview.steps.first { $0.id == .internetWatch })
        #expect(step.status == .notOffered && step.detail == "Camera Bridge OS watches cameras’ internet; this bridge does not.")
        #expect(step.title == "Watch its internet")
        #expect(preview.steps.map(\.id) == CameraSetupStepID.allCases)

        let elsewhere = try await fixture(guarded: FakeGuard(), tuning: Self.tuning(cameraAddress: "192.168.78.21"))
        defer { elsewhere.directory.remove() }
        let (other, otherConfiguration) = try await setupCamera(elsewhere)
        defer { other.stop() }
        let away = try #require(try await elsewhere.engine.cameraSetupPreview(cameraID: otherConfiguration.id).steps.first { $0.id == .internetWatch })
        #expect(away.status == .notOffered && away.detail == "Camera Bridge can watch only cameras on its own local network.")
        #expect(!camera.puts.value.contains(Self.ipAddressPath) && !other.puts.value.contains(Self.ipAddressPath))
    }

    @Test func thePreviewShowsTheCamerasDNSAgainstTheBridge() async throws {
        let fixture = try await fixture(guarded: FakeGuard())
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let step = try #require(preview.steps.first { $0.id == .internetWatch })
        #expect(step.status == .willChange)
        #expect(step.changes == [CameraSetupChange(label: "DNS", now: "8.8.8.8 and 1.1.1.1", after: "the bridge (192.168.77.2)")])
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "a preview never writes")
    }

    @Test func aRunWatchesTheCameraAndRestoreGivesItsDNSBack() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == nil)
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .done, "on by default, like Cloud off")
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress))
        let saved = try #require(stored(fixture, configuration.id))
        #expect(saved.setupBackup?.internetWatch == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))
        #expect(saved.setupState?.steps.first { $0.id == .internetWatch }?.status == .done)
        #expect(BridgeEngine.internetWatchDone(saved))
        let watched = [GuardedCamera(address: Self.cameraAddress, level: .watch)]
        #expect(await fixture.waitFor { box.last == watched }, "the box watches it once the step is done")

        let again = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(again.steps.first { $0.id == .internetWatch }?.status == .alreadyRight)
        #expect(stored(fixture, configuration.id)?.setupBackup?.internetWatch?.servers == ["8.8.8.8", "1.1.1.1"], "the original servers stay saved")

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.first { $0.id == .internetWatch }?.status == .restored)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(), "the camera's own servers are back")
        #expect(await fixture.waitFor { box.last == [] }, "and the box no longer watches it")
        #expect(stored(fixture, configuration.id).map(BridgeEngine.internetWatchDone) == false)
    }

    @Test func aPartialRestoreThatGaveTheDNSBackStopsTheWatch() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(await fixture.waitFor { box.last?.count == 1 })

        camera.refusePUT.update { $0.insert("/ISAPI/System/Network/UPnP") }   // one step stays changed
        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.canRestore && restored.steps.first { $0.id == .upnp }?.status == .refused)
        let saved = try #require(stored(fixture, configuration.id))
        #expect(saved.setupBackup?.internetWatch == nil && saved.setupState?.steps.first { $0.id == .internetWatch }?.status == .restored)
        #expect(await fixture.waitFor { box.last == [] })
    }

    /// Watch has not been tried on many cameras yet: a camera that refuses it still gets every other step (Watch comes last).
    @Test func aRefusedWatchStopsNoOtherStep() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.refusePUT.update { $0.insert(Self.ipAddressPath) }
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == .internetWatch)
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .refused)
        for id in [CameraSetupStepID.upnp, .cloud] { #expect(report.steps.first { $0.id == id }?.status == .done, "\(id)") }
        #expect(!report.steps.contains { $0.status == .notRun })
        #expect(CameraSetupStepID.allCases.last == .internetWatch, "and Restore puts the camera's DNS back first")
    }

    @Test func aRefusedListIsTriedAgainAndNeverHoldsTheSetup() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        await fixture.engine.start()
        #expect(await fixture.waitFor { box.last == [] })   // nothing watched yet
        box.refusals.set(2)
        let before = box.lists.value.count

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .done, "the setup does not wait for the box")
        let watched = [GuardedCamera(address: Self.cameraAddress, level: .watch)]
        #expect(await fixture.waitFor { box.lists.value.count >= before + 3 && box.last == watched }, "refused twice, then taken")
        try await Task.sleep(for: .milliseconds(200))
        #expect(box.lists.value.count == before + 3, "nothing more once the box has it")
        #expect(await fixture.waitFor { fixture.engine.recentLogs.contains { $0.message.hasPrefix("The internet guard's list could not be changed") } })
        await fixture.tearDown()
    }

    // MARK: The list

    @Test func theListFollowsStartRemovalAndAddressChanges() async throws {
        let first = FakeGuard()
        let fixture = try await fixture(guarded: first)
        defer { fixture.directory.remove() }
        let north = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        let south = try await watchedCamera(fixture, host: "192.168.77.22", name: "South")
        _ = try await watchedCamera(fixture, host: "192.0.2.30", name: "Elsewhere")   // not an address on a home network
        let both = [GuardedCamera(address: "192.168.77.21", level: .watch), GuardedCamera(address: "192.168.77.22", level: .watch)]
        #expect(await fixture.waitFor { first.last == both })

        // A new engine on the same configuration: the box is told the whole list when it starts.
        let box = FakeGuard()
        var environment = BridgeEnvironment.testing(directory: fixture.directory.url)
        box.install(&environment)
        let engine = BridgeEngine(environment: environment, tuning: Self.tuning())
        #expect(box.lists.value.isEmpty, "nothing is sent before it starts")
        await engine.start()
        #expect(await eventually { box.last == both })

        var moved = try #require(engine.configurations.first { $0.id == south.id })
        moved.endpoint.host = "192.168.77.23"
        try await engine.updateCamera(moved, password: nil)
        let afterMove = [GuardedCamera(address: "192.168.77.21", level: .watch), GuardedCamera(address: "192.168.77.23", level: .watch)]
        #expect(await eventually { box.last == afterMove })

        await engine.removeCamera(id: north.id)
        #expect(await eventually { box.last == [GuardedCamera(address: "192.168.77.23", level: .watch)] })
        let sent = box.lists.value.count
        var renamed = try #require(engine.configurations.first { $0.id == south.id })
        renamed.name = "South gate"
        try await engine.updateCamera(renamed, password: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.lists.value.count == sent, "a change that leaves the list as it is sends nothing")
        await engine.stop()
    }

    /// The box's job can end with an older list (a request that came while the last one ran): when its report shows other cameras than the
    /// list it took, the list is sent again.
    @Test func theListIsSentAgainWhenTheBoxReportsAnother() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        _ = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        let watched = [GuardedCamera(address: "192.168.77.21", level: .watch)]
        #expect(await fixture.waitFor { box.last == watched })
        let sent = box.lists.value.count
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.lists.value.count == sent, "the box has it")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.30", level: .watch, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(await fixture.waitFor { box.lists.value.count == sent + 1 && box.last == watched })
    }

    /// Removing a watched camera gives it its own DNS servers back first: the box stops answering it, and its backup goes with it.
    @Test func removingAWatchedCameraGivesItsDNSBack() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        tuning.restoresWatchOnRemoval = true
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress))
        await fixture.engine.removeCamera(id: configuration.id)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(), "the camera asks its own servers again")
        #expect(fixture.engine.configurations.isEmpty)
        #expect(await fixture.waitFor { box.last == [] })
    }

    // MARK: The evidence

    private func report(_ cameras: [GuardReport.Camera], updatedAt: Date = Date(), todayStart: Date? = nil) -> GuardReport {
        GuardReport(available: true, running: true, updatedAt: updatedAt, timeZone: "UTC", todayStart: todayStart ?? Calendar.current.startOfDay(for: Date()),
                    cameras: cameras)
    }

    /// Everything the camera says is off, its video locked, and (`dns`) its DNS servers as the check reads them: the bridge's by default.
    private func everythingOff(_ tuning: inout EngineTuning, dns: [String]? = [bridgeAddress]) {
        tuning.securityReading = { _, _ in
            [RemoteAccessFinding(feature: .cloud, state: .off, service: "Hik-Connect", canChange: true),
             RemoteAccessFinding(feature: .upnp, state: .off, canChange: true), RemoteAccessFinding(feature: .ddns, state: .absent)]
        }
        tuning.rtspAccessProbe = { _ in .off }
        tuning.securityDNS = { _, _ in
            dns.map { CameraDNSReading(servers: $0, fromDHCP: false, method: .hikvisionISAPI,
                                       backup: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: $0)) }
        }
        tuning.securityCheckCooldown = .zero
    }

    private static let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)

    @Test func aWatchedQuietCameraIsGoldAndOneThatKeepsTryingIsYellow() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.twoDaysAgo, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()

        let gold = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(gold.level == .gold)
        #expect(gold.internetGuard == CameraGuardActivity(watched: true, today: 0, last24h: 0, names: []))

        let seen = Date().addingTimeInterval(-600)
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.twoDaysAgo, today: 5, last24h: 7, names: [
            GuardReport.Lookup(name: "dev.hik-connect.com", count: 6, first: seen, last: seen),
            GuardReport.Lookup(name: "a1b2c3d4e5f6.p2p.example.com", count: 1, first: seen, last: seen),
        ])]))
        await fixture.engine.pollGuardReport()
        let yellow = try #require(fixture.status(camera.id)?.security)
        #expect(yellow.level == .yellow, "checked again from the box's report, without asking the camera")
        #expect(yellow.checkedAt == gold.checkedAt, "the camera's readings are as old as they were")
        #expect(yellow.findings.first?.sentence.contains("7 lookups of internet names in the last 24 hours (dev.hik-connect.com, *.p2p.example.com)") == true)
        #expect(yellow.internetGuard?.today == 5 && yellow.internetGuard?.last24h == 7)
        #expect(yellow.internetGuard?.names.map(\.name) == ["dev.hik-connect.com", "*.p2p.example.com"], "a name that looks like a camera's id is not shown")

        // The box stops reporting (its collector is down): what it saw is no longer evidence.
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])],
                              updatedAt: Date().addingTimeInterval(-3600)))
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(camera.id)?.security?.level == .green)
    }

    /// Watch reports a camera at once; gold waits for a full day of watching without a lookup, and then needs no new check.
    @Test func aFreshlyWatchedCameraIsGreenUntilADayHasPassed() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Date().addingTimeInterval(-60), today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        let fresh = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(fresh.level == .green)
        #expect(fresh.findings.first { $0.feature == .internetGuard }?.sentence.hasPrefix("The Internet guard has watched it for less than an hour") == true)
        #expect(fresh.internetGuard?.watched == true)

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Date().addingTimeInterval(-25 * 3600), today: 0, last24h: 0,
                                                  names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(camera.id)?.security?.level == .gold)
        #expect(fixture.status(camera.id)?.security?.checkedAt == fresh.checkedAt)
    }

    /// Gold rests on the camera asking the bridge, read again at each check: a camera that took its router's DNS back (DHCP), or a bridge
    /// that moved to another address, is not watched.
    @Test func aCameraThatNoLongerAsksTheBridgeIsNotWatched() async throws {
        let box = FakeGuard()
        let bridge = Box(Self.bridgeAddress)
        var tuning = Self.tuning(bridge: bridge)
        everythingOff(&tuning)
        tuning.securityDNS = nil   // the camera's own answer, through ISAPI
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        box.report.set(report([GuardReport.Camera(address: Self.cameraAddress, level: .watch, since: Self.twoDaysAgo, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(try await fixture.engine.checkCameraSecurity(cameraID: configuration.id).level == .gold)

        bridge.set("192.168.77.3")   // the router gave the bridge another address
        await fixture.engine.pollGuardReport()
        let moved = try #require(fixture.status(configuration.id)?.security)
        #expect(moved.level == .green && moved.internetGuard?.watched == false)
        #expect(moved.findings.first { $0.feature == .internetGuard }?.sentence.hasPrefix("The camera no longer asks Camera Bridge for its lookups") == true)
        bridge.set(Self.bridgeAddress)
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(configuration.id)?.security?.level == .gold)

        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress() }   // a DHCP renewal gave it the router's servers
        let renewed = try await fixture.engine.checkCameraSecurity(cameraID: configuration.id)
        #expect(renewed.level == .green && renewed.internetGuard?.watched == false)
    }

    @Test func aCameraTheBoxDoesNotWatchIsGreenAtBest() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.25"), username: "admin")
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        // The box still lists it (an old list), but its Watch is not done here.
        box.report.set(report([GuardReport.Camera(address: "192.168.77.25", level: .watch, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        let security = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(security.level == .green)
        #expect(security.findings.first { $0.feature == .internetGuard }?.sentence == "The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.")
        #expect(security.internetGuard?.watched == false)

        let mac = try await self.fixture(guarded: nil, tuning: tuning)
        defer { mac.directory.remove() }
        try await mac.engine.addCamera(camera, password: "pa55")
        let there = try await mac.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(there.level == .green && there.internetGuard == nil, "no guard on this bridge: green is the best")
    }

    // MARK: The notice

    @Test func theDaysNoticeCountsWhatWasBlocked() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        tuning.guardNoticeRefresh = .seconds(3600)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let north = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        _ = try await watchedCamera(fixture, host: "192.168.77.22", name: "South")
        let today = Calendar.current.startOfDay(for: Date())

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardNotice == nil, "nothing was blocked")

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 4, last24h: 4, names: []),
                               GuardReport.Camera(address: "192.168.77.22", level: .watch, today: 3, last24h: 9, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        let notice = try #require(fixture.engine.internetGuardNotice)
        #expect(notice.sentence == "Internet guard blocked 7 lookups from 2 cameras today.")
        #expect(notice.cameraID == north.id && notice.cameraName == "North", "the camera page of the one that tried most")

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 40, last24h: 40, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardNotice == notice, "once a day: its figures change at most every hour")

        let tomorrow = today.addingTimeInterval(86_400)
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 40, names: [])], todayStart: tomorrow))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardNotice == nil, "a new day without anything blocked has none")
    }
}
#endif
