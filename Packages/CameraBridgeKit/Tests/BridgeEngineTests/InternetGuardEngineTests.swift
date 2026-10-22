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

    /// The camera's address document: a fixed address (`static`, as a Hikvision ships) unless a test says DHCP (`dynamic`).
    static func ipAddress(primary: String = "8.8.8.8", secondary: String = "1.1.1.1", addressing: String = "static") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><IPAddress version=\"2.0\" \(CameraSetupEngineTests.FakeHikvision.ns)><ipVersion>v4</ipVersion>"
            + "<addressingType>\(addressing)</addressingType><ipAddress>\(cameraAddress)</ipAddress><subnetMask>255.255.255.0</subnetMask>"
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

    /// Every list the engine asked for has reached the box (none is being sent).
    private func settled(_ fixture: EngineFixture) async -> Bool { await fixture.waitFor { fixture.engine.internetGuard.sync == nil } }

    /// Whether any list the box was sent names the camera.
    private func everListed(_ box: FakeGuard, _ address: String = cameraAddress) -> Bool {
        box.lists.value.contains { list in list.contains { $0.address == address } }
    }

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
        #expect(saved.setupState?.watchedServer == Self.bridgeAddress, "the address its DNS was read back pointing at")
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

    /// A Hikvision on DHCP would give its DNS back to the router at the next renewal: the setup does not point it at the bridge, says why, and
    /// the box is never told to watch it.
    @Test func aDynamicHikvisionIsNotWatchedThroughTheSetup() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(addressing: "dynamic") }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let step = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(step.status == .notSupported)
        #expect(step.detail == "the camera takes its address from DHCP, so its DNS would go back to the router’s at the next renewal: choose “Fix its "
                + "address so the DNS stays”, or set it by hand with a fixed address")
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "no DNS that would not last is written")
        let saved = try #require(stored(fixture, configuration.id))
        #expect(saved.setupState?.watchedServer == nil && !BridgeEngine.internetWatchDone(saved))
        #expect(await settled(fixture))
        #expect(!everListed(box), "never on the box's list")
    }

    /// "Fix its address so the DNS stays" through the setup, on a Hikvision on DHCP: the preview offers it (off), with the camera's address,
    /// mask, gateway and hardware address; a run without it changes nothing; one with it keeps the address the preview showed, fixed, points
    /// the DNS at the bridge, saves the address it fixed before any change, says it in the result (for the router reservation) and the box
    /// watches the camera. Restore puts DHCP back. A preview's address the camera no longer has is refused, and nothing is written.
    @Test func theChoiceFixesAHikvisionsAddressThroughTheSetupAndRestorePutsDHCPBack() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        let interface = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><NetworkInterface version=\"2.0\" \(CameraSetupEngineTests.FakeHikvision.ns)><id>1</id>"
            + "<Link><MACAddress>02:00:00:00:00:21</MACAddress></Link></NetworkInterface>"
        camera.documents.update {
            $0[Self.ipAddressPath] = Self.ipAddress(addressing: "dynamic")
            $0["/ISAPI/System/Network/interfaces/1"] = interface
        }
        let keeps = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1", hardwareAddress: "02:00:00:00:00:21")

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let offered = try #require(preview.steps.first { $0.id == .internetWatch })
        #expect(offered.status == .notSupported && offered.fixAddress?.addressing == keeps)
        let plain = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(plain.steps.first { $0.id == .internetWatch }.map { $0.status == .notSupported && $0.fixAddress == nil && $0.fixedAddress == nil } == true)
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "off by default: nothing is written")

        let elsewhere = CameraAddressing(address: "192.168.77.40", subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let moved = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: elsewhere))
        let refused = try #require(moved.steps.first { $0.id == .internetWatch })
        #expect(refused.status == .refused && refused.detail == CameraSettingsService.addressChangedRefusal(elsewhere) && refused.fixedAddress == nil)
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "an address the preview did not show is never written")

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: keeps))
        let step = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(step.status == .done && step.fixedAddress == keeps && step.fixAddress == nil)
        #expect(step.changes.map(\.label) == ["Address", "DNS"])
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress, addressing: "static"),
                "the same address, mask and gateway, fixed")
        let saved = try #require(stored(fixture, configuration.id))
        var kept = keeps
        kept.hardwareAddress = nil
        #expect(saved.setupBackup?.internetWatch == CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: true, servers: ["8.8.8.8", "1.1.1.1"], fixedAddress: kept,
                                                                    fixedAddressMethod: .hikvisionISAPI))
        #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("02:00:00:00:00:21"), "the hardware address is not saved")
        #expect(saved.setupState?.watchedServer == Self.bridgeAddress)
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: Self.cameraAddress, level: .watch)] })

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.first { $0.id == .internetWatch }?.status == .restored)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(addressing: "dynamic"), "DHCP and its own DNS servers back")
        #expect(await fixture.waitFor { box.last == [] })
    }

    /// A run whose Watch step never runs (an earlier step's refused login held it) changed nothing about the camera's address: the backup
    /// keeps no fixed address from it, so Restore never puts DHCP back on a camera Camera Bridge did not fix.
    @Test func aFixWhoseWatchStepDidNotRunKeepsNoAddress() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(addressing: "dynamic") }
        camera.refuseLoginPUT.update { $0.insert("/ISAPI/System/Network/UPnP") }
        let shown = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: shown))
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .notRun)
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "the address is not written")
        let watch = stored(fixture, configuration.id)?.setupBackup?.internetWatch
        #expect(watch?.fixedAddress == nil && watch?.fixedAddressMethod == nil, "nothing about its address to put back")

        camera.refuseLoginPUT.update { $0.removeAll() }
        _ = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(!camera.puts.value.contains(Self.ipAddressPath), "Restore does not put DHCP back")
        #expect(camera.documents.value[Self.ipAddressPath]?.contains("<addressingType>dynamic</addressingType>") == true)
    }

    /// A camera whose DNS backup an earlier run saved another way (ONVIF) gets the address the choice fixes through ISAPI added to it, with
    /// that way: Restore puts DHCP back through ISAPI (its DNS servers, from DHCP, come back with the address) and the step is restored.
    @Test func restorePutsDHCPBackOverAnEarlierBackupReadAnotherWay() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(addressing: "dynamic") }
        await fixture.engine.changeConfiguration(configuration.id) { configuration in
            configuration.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                          internetWatch: CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        }
        let shown = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: shown))
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .done)
        #expect(stored(fixture, configuration.id)?.setupBackup?.internetWatch
                == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [], fixedAddress: shown, fixedAddressMethod: .hikvisionISAPI))

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.first { $0.id == .internetWatch }?.status == .restored)
        #expect(camera.documents.value[Self.ipAddressPath]?.contains("<addressingType>dynamic</addressingType>") == true, "DHCP back")
        #expect(stored(fixture, configuration.id)?.setupBackup?.internetWatch == nil)
    }

    /// An ONVIF camera on DHCP is offered the choice only once its last run refused its DNS set by hand (here: it does not stay while the
    /// address comes from DHCP). Chosen, with the address the preview showed (the page sends no interface: the camera's own is kept),
    /// `SetNetworkInterfaces` fixes its address as it is, and its DNS then stays.
    @Test func anONVIFCameraThatRefusedItsDNSIsOfferedTheChoiceNextTime() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let zone = PosixTimeZone.string(for: fixture.engine.settings.timeZone ?? TimeZone.current.identifier) ?? "UTC0"
        let camera = try await CameraSetupNotPermittedTests.FakeDoorbell(zone: zone)
        defer { camera.stop() }
        camera.dnsOnlyWithFixedAddress.set(true)
        var configuration = CameraConfiguration(name: "Porch", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")
        let watch = { (report: CameraSetupReport) in report.steps.first { $0.id == .internetWatch } }

        let first = try #require(watch(try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)))
        #expect(first.status == .willChange && first.fixAddress == nil, "first its DNS alone")
        await fixture.engine.changeConfiguration(configuration.id) { configuration in
            configuration.setupState = CameraSetupState(started: Self.now, applied: Self.now,
                                                        steps: [.init(id: .internetWatch, status: .refused, detail: "the camera kept its own DNS servers")])
        }
        let keeps = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1", hardwareAddress: "02:00:00:00:00:21",
                                     interface: "eth0")
        let offered = try #require(watch(try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)))
        #expect(offered.status == .willChange && offered.fixAddress?.addressing == keeps)
        #expect(!camera.actions.value.contains("SetNetworkInterfaces") && !camera.actions.value.contains("SetDNS"), "a preview writes nothing")

        let shown = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: shown))
        let step = try #require(watch(report))
        #expect(step.status == .done && step.fixedAddress == keeps, "\(step.detail ?? "")")
        #expect(!camera.addressFromDHCP.value && camera.dns.value == CameraSetupNotPermittedTests.FakeDoorbell.DNS(fromDHCP: false, manual: [Self.bridgeAddress, Self.bridgeAddress]))
        #expect(stored(fixture, configuration.id)?.setupBackup?.internetWatch?.fixedAddress
                == CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1", interface: "eth0"))
        #expect(stored(fixture, configuration.id)?.setupBackup?.internetWatch?.fixedAddressMethod == .onvifMinimal)
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: Self.cameraAddress, level: .watch)] })
    }

    /// A camera that refuses the fix's first write (`SetNetworkInterfaces` faulted) had nothing about its address changed: the run keeps no
    /// fixed address for it, Restore succeeds (the camera refusing the write again changes nothing there either) and the backup clears.
    @Test func aFixRefusedAtItsFirstWriteKeepsNoAddressAndRestoreClears() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let zone = PosixTimeZone.string(for: fixture.engine.settings.timeZone ?? TimeZone.current.identifier) ?? "UTC0"
        let camera = try await CameraSetupNotPermittedTests.FakeDoorbell(zone: zone)
        defer { camera.stop() }
        camera.dnsOnlyWithFixedAddress.set(true)
        camera.refuseNetworkInterfaces.set(true)
        var configuration = CameraConfiguration(name: "Porch", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")
        await fixture.engine.changeConfiguration(configuration.id) { configuration in
            configuration.setupState = CameraSetupState(started: Self.now, applied: Self.now,
                                                        steps: [.init(id: .internetWatch, status: .refused, detail: "the camera kept its own DNS servers")])
        }
        let shown = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: shown))
        let step = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(step.status == .refused && step.fixedAddress == nil, "\(step.detail ?? "")")
        let watch = try #require(stored(fixture, configuration.id)?.setupBackup?.internetWatch)
        #expect(watch.fixedAddress == nil && watch.fixedAddressMethod == nil, "nothing about its address to put back")
        #expect(camera.addressFromDHCP.value)

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.allSatisfy { $0.status == .restored }, "\(restored.steps.map { "\($0.id): \($0.detail ?? "")" })")
        #expect(stored(fixture, configuration.id)?.setupBackup == nil, "the backup clears")
    }

    /// A 2xx answer to the fix's first write that the client can't read may be one the camera applied (this one did): the run keeps the
    /// fixed address in the backup, and Restore puts DHCP back.
    @Test func anUnreadableAnswerToTheFixsFirstWriteKeepsTheFixedAddress() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let zone = PosixTimeZone.string(for: fixture.engine.settings.timeZone ?? TimeZone.current.identifier) ?? "UTC0"
        let camera = try await CameraSetupNotPermittedTests.FakeDoorbell(zone: zone)
        defer { camera.stop() }
        camera.dnsOnlyWithFixedAddress.set(true)
        camera.unreadableNetworkInterfaces.set(true)
        var configuration = CameraConfiguration(name: "Porch", kind: .camera, vendor: .onvif, endpoint: camera.endpoint, username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")
        await fixture.engine.changeConfiguration(configuration.id) { configuration in
            configuration.setupState = CameraSetupState(started: Self.now, applied: Self.now,
                                                        steps: [.init(id: .internetWatch, status: .refused, detail: "the camera kept its own DNS servers")])
        }
        let shown = CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id, options: CameraSetupOptions(fixAddress: true, shownAddress: shown))
        let step = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(step.status == .refused, "\(step.detail ?? "")")
        #expect(!camera.addressFromDHCP.value, "the camera took the fixed address")
        let watch = try #require(stored(fixture, configuration.id)?.setupBackup?.internetWatch)
        #expect(watch.fixedAddress == CameraAddressing(address: Self.cameraAddress, subnetMask: "255.255.255.0", gateway: "192.168.77.1", interface: "eth0"))
        #expect(watch.fixedAddressMethod == .onvifMinimal)

        camera.unreadableNetworkInterfaces.set(false)
        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.allSatisfy { $0.status == .restored }, "\(restored.steps.map { "\($0.id): \($0.detail ?? "")" })")
        #expect(camera.addressFromDHCP.value, "DHCP back")
    }

    /// The box's `since` lasts only while the camera is on its list: a run that takes the step again never drops a watched camera, also
    /// while it saves its first records, nor when it cannot read the camera's DNS this time.
    @Test func aWatchedCameraStaysListedThroughARerun() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let watched = [GuardedCamera(address: Self.cameraAddress, level: .watch)]
        #expect(await fixture.waitFor { box.last == watched })
        #expect(await settled(fixture))
        let before = box.lists.value.count

        let again = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(again.steps.first { $0.id == .internetWatch }?.status == .alreadyRight)
        camera.documents.update { $0[Self.ipAddressPath] = nil }   // the camera does not show its DNS servers this time
        let unread = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(unread.steps.first { $0.id == .internetWatch }?.status == .notSupported)
        #expect(await settled(fixture))
        #expect(box.lists.value.dropFirst(before).allSatisfy { $0 == watched }, "never a list without it")
        #expect(box.last == watched)
        #expect(stored(fixture, configuration.id)?.setupState?.watchedServer == Self.bridgeAddress, "a step it could not read keeps the watch")
    }

    /// A camera set up by a build before the watch had its own record: its record of the step says done or already right, and it stays
    /// watched (the box's `since` with it). A refused or not-run record with the DNS servers kept to give back is no longer a watch.
    @Test func aCameraSavedByAnOlderBuildIsWatchedByItsRecord() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let backup = CameraSetupBackup(version: 1, created: Self.now, internetWatch: CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        func older(_ status: String) throws -> CameraSetupState {
            let json = #"{"version":1,"started":814032990,"applied":814032991,"steps":[{"id":"cloud","status":"done","needsRestart":false},"#
                + #"{"id":"internetWatch","status":"\#(status)","detail":"via ONVIF","needsRestart":false}]}"#
            return try JSONDecoder().decode(CameraSetupState.self, from: Data(json.utf8))
        }
        var ids: [String: UUID] = [:]
        for (host, status) in [("192.168.77.21", "done"), ("192.168.77.22", "alreadyRight"), ("192.168.77.23", "refused"), ("192.168.77.24", "notRun")] {
            var camera = CameraConfiguration(name: status, kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: host), username: "admin")
            camera.isEnabled = false
            try await fixture.engine.addCamera(camera, password: "pa55")
            let state = try older(status)
            #expect(state.watchedServer == nil)
            await fixture.engine.changeConfiguration(camera.id) { configuration in
                configuration.setupBackup = backup
                configuration.setupState = state
            }
            ids[status] = camera.id
        }
        let watched = [GuardedCamera(address: "192.168.77.21", level: .watch), GuardedCamera(address: "192.168.77.22", level: .watch)]
        #expect(await fixture.waitFor { box.last == watched })
        #expect(await settled(fixture))
        #expect(!everListed(box, "192.168.77.23") && !everListed(box, "192.168.77.24"), "the kept servers are not a watch")
        #expect(stored(fixture, try #require(ids["refused"]))?.setupBackup?.internetWatch == backup.internetWatch, "kept for Restore and removal")
    }

    /// A camera an older build watched (its record of the step done, no `watchedServer`) stays on the box's list while a setup run takes the
    /// step again: the run carries the watch over from its first save (the box's `since` lasts only while the camera is listed), and its
    /// step's result gives the camera its `watchedServer`.
    @Test func aCameraSavedByAnOlderBuildStaysListedThroughARerun() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress) }
        let json = #"{"version":1,"started":814032990,"applied":814032991,"steps":[{"id":"cloud","status":"done","needsRestart":false},"#
            + #"{"id":"internetWatch","status":"done","detail":"via ISAPI","needsRestart":false}]}"#
        let state = try JSONDecoder().decode(CameraSetupState.self, from: Data(json.utf8))
        #expect(state.watchedServer == nil)
        await fixture.engine.changeConfiguration(configuration.id) { configuration in
            configuration.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                          internetWatch: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))
            configuration.setupState = state
        }
        let watched = [GuardedCamera(address: Self.cameraAddress, level: .watch)]
        #expect(await fixture.waitFor { box.last == watched })
        #expect(await settled(fixture))
        let before = box.lists.value.count

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .alreadyRight)
        #expect(await settled(fixture))
        #expect(box.lists.value.dropFirst(before).allSatisfy { $0 == watched }, "never a list without it")
        #expect(box.last == watched)
        #expect(stored(fixture, configuration.id)?.setupState?.watchedServer == Self.bridgeAddress)
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
        #expect(saved.setupState?.watchedServer == nil, "its DNS is its own again")
        #expect(await fixture.waitFor { box.last == [] })
    }

    /// Watch has not been tried on many cameras yet: a camera that refuses it still gets every other step (Watch comes last). It is never
    /// on the box's list: its DNS servers are kept to give back (saved before the step ran), but its DNS does not point at the bridge.
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

        let saved = try #require(stored(fixture, configuration.id))
        #expect(saved.setupBackup?.internetWatch?.servers == ["8.8.8.8", "1.1.1.1"], "kept for Restore and for its removal")
        #expect(saved.setupState?.watchedServer == nil && !BridgeEngine.internetWatchDone(saved))
        #expect(await settled(fixture))
        #expect(!everListed(box), "no list the box got names it")
    }

    /// A camera that refused an earlier step's login for the API the DNS step uses (ISAPI here) is not asked again: Watch does not run
    /// (another refused login counts towards the camera's lock), says why, and the camera is not listed.
    @Test func aRefusedLoginOnTheSameAPILeavesTheWatchNotRunAndUnlisted() async throws {
        for path in ["/ISAPI/System/Network/UPnP", "/ISAPI/System/Video/inputs/channels/1/overlays"] {
            let box = FakeGuard()
            let fixture = try await fixture(guarded: box)
            defer { fixture.directory.remove() }
            let (camera, configuration) = try await setupCamera(fixture)
            defer { camera.stop() }
            camera.refuseLoginPUT.update { $0.insert(path) }
            let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
            let stopped = try #require(report.stoppedAt, "\(path)")
            #expect(report.steps.first { $0.id == stopped }?.detail == "the camera refused the login", "\(path)")
            let watch = try #require(report.steps.first { $0.id == .internetWatch })
            #expect(watch.status == .notRun, "\(path)")
            #expect(watch.detail == "the camera refused the login at “\(BridgeEngine.cameraSetupTitle(stopped))”, so Camera Bridge did not try it: "
                    + "another refused login can lock the camera’s logins", "\(path)")
            #expect(!camera.puts.value.contains(Self.ipAddressPath), "\(path): the DNS is not written")
            let saved = try #require(stored(fixture, configuration.id))
            #expect(saved.setupState?.watchedServer == nil && !BridgeEngine.internetWatchDone(saved), "\(path)")
            #expect(await settled(fixture))
            #expect(!everListed(box), "\(path): no list the box got names it")
        }
    }

    /// A camera that stopped answering at an earlier step is not asked again for its DNS.
    @Test func aCameraThatStoppedAnsweringLeavesTheWatchNotRun() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.dropPUT.update { $0.insert("/ISAPI/System/Network/UPnP") }
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == .upnp)
        let watch = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(watch.status == .notRun)
        #expect(watch.detail == "the camera stopped answering at “UPnP off”, so Camera Bridge did not try it")
        #expect(!camera.puts.value.contains(Self.ipAddressPath))
        #expect(await settled(fixture))
        #expect(!everListed(box))
    }

    /// An earlier step the camera refuses for its own reasons (streams that "didn't stick", here an HTTP 403) stops the steps after it, but
    /// not Watch: the camera answers, and its DNS is another setting.
    @Test func aRefusedStreamsStepStillWatchesTheCamera() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.refusePUT.update { $0.insert("/ISAPI/Streaming/channels/101") }
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == .streams, "the run stopped at the streams")
        #expect(report.steps.first { $0.id == .streams }?.status == .refused)
        for id in [CameraSetupStepID.upnp, .cloud] { #expect(report.steps.first { $0.id == id }?.status == .notRun, "\(id)") }
        #expect(camera.documents.value["/ISAPI/System/Network/UPnP"] == CameraSetupEngineTests.FakeHikvision.originals["/ISAPI/System/Network/UPnP"])
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .done)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress))
        #expect(stored(fixture, configuration.id)?.setupState?.watchedServer == Self.bridgeAddress)
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: Self.cameraAddress, level: .watch)] })
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

    /// Two quiet days are gold only once the box has seen the camera ask it something (any name, local ones included: it counts those);
    /// a camera it never saw ask anything may have a DNS server of its own, and stays green, saying so.
    @Test func aWatchedQuietCameraIsGoldAndOneThatKeepsTryingIsYellow() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.twoDaysAgo, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        let silent = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(silent.level == .green, "two quiet days, but no lookup ever seen from it")
        #expect(silent.findings.first { $0.feature == .internetGuard }?.sentence == "No lookups seen yet; Camera Bridge can’t rule out a built-in DNS server.")

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.twoDaysAgo, today: 0, last24h: 0, names: [],
                                                  local: 2)]))
        await fixture.engine.pollGuardReport()
        let gold = try #require(fixture.status(camera.id)?.security)
        #expect(gold.level == .gold, "it asked the box names of the home network: it asks the box")
        #expect(gold.internetGuard == CameraGuardActivity(watched: true, today: 0, last24h: 0, names: []))

        let seen = Date().addingTimeInterval(-600)
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.twoDaysAgo, today: 5, last24h: 7, names: [
            GuardReport.Lookup(name: "dev.hik-connect.com", count: 6, first: seen, last: seen),
            GuardReport.Lookup(name: "a1b2c3d4e5f6.p2p.example.com", count: 1, first: seen, last: seen),
        ])]))
        await fixture.engine.pollGuardReport()
        let yellow = try #require(fixture.status(camera.id)?.security)
        #expect(yellow.level == .gold, "checked again from the box's report, without asking the camera; blocked attempts do not lower it")
        #expect(yellow.checkedAt == gold.checkedAt, "the camera's readings are as old as they were")
        #expect(yellow.findings.first { $0.feature == .internetGuard }?.sentence.contains("7 attempts to reach the internet in the last 24 hours (dev.hik-connect.com, *.p2p.example.com)") == true)
        #expect(yellow.internetGuard?.today == 5 && yellow.internetGuard?.last24h == 7 && yellow.internetGuard?.last7d == 7, "the 7-day total is every name’s count")
        #expect(yellow.internetGuard?.names.map(\.name) == ["dev.hik-connect.com", "*.p2p.example.com"], "a name that looks like a camera's id is not shown")

        // The box stops reporting (its collector is down): what it saw is no longer evidence.
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])],
                              updatedAt: Date().addingTimeInterval(-3600)))
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(camera.id)?.security?.level == .green)
    }

    /// Watch reports a camera at once; gold waits for a full day of watching without an internet lookup (the box having seen it ask a local
    /// name), and then needs no new check.
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
                                                  names: [], local: 1)]))
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
        box.report.set(report([GuardReport.Camera(address: Self.cameraAddress, level: .watch, since: Self.twoDaysAgo, today: 0, last24h: 0, names: [],
                                                  local: 5)]))
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

    /// A Watch the camera took "after it restarts" (ISAPI `statusCode` 7) still waits for the restart once the security check reads the
    /// bridge in its DNS: a camera can show the new servers at once and keep asking its old ones until it restarts. Only the person's restart
    /// (or a new run) ends the wait, so "Restart the camera now" stays offered and the restart is still taken.
    @Test func aWatchThatWaitsForItsRestartStillOffersTheRestartAfterTheCheck() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        tuning.securityDNS = nil   // the camera's own answer, through ISAPI
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        camera.rebootRequired.update { $0.insert(Self.ipAddressPath) }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let watch = try #require(report.steps.first { $0.id == .internetWatch })
        #expect(watch.status == .done && watch.needsRestart)
        #expect(camera.documents.value[Self.ipAddressPath] == Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress),
                "it shows the bridge already")
        _ = try await fixture.engine.checkCameraSecurity(cameraID: configuration.id)   // reads the bridge in its DNS
        let checked = try #require(stored(fixture, configuration.id))
        #expect(checked.setupState?.steps.first { $0.id == .internetWatch }?.needsRestart == true, "a reading is no proof it restarted")
        #expect(BridgeEngine.offersCameraRestart(checked))

        try await fixture.engine.restartCamera(id: configuration.id)
        #expect(camera.puts.value.filter { $0 == CameraSetupEngineTests.rebootPath }.count == 1)
        #expect(!BridgeEngine.offersCameraRestart(try #require(stored(fixture, configuration.id))), "restarted: nothing waits")
    }

    @Test func aCameraTheBoxDoesNotWatchIsGreenAtBest() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: ["192.168.77.1"])   // it asks the router
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        var camera = CameraConfiguration(name: "Yard", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.25"), username: "admin")
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        // The box still lists it (an old list), but its Watch is not done here and its DNS does not point at the bridge.
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

    // MARK: The camera's DNS, read

    /// What the cameras' DNS servers read as in these tests (the readers themselves: CameraAdaptersTests): `servers` (nil: the camera does not
    /// show them; the bridge's address twice by default), whether they come from DHCP, an error the next read throws, and every read, by
    /// camera name, with its time.
    final class DNSAnswers: Sendable {
        let servers = Box<[String]?>([InternetGuardEngineTests.bridgeAddress, InternetGuardEngineTests.bridgeAddress])
        let fromDHCP = Box(false)
        /// The reading says it does not know which servers DHCP gives (a Reolink on automatic DNS whose ONVIF did not say).
        let unknown = Box(false)
        /// Thrown by the next read only.
        let error = Box<CameraAdapterError?>(nil)
        let reads = Box<[(camera: String, at: ContinuousClock.Instant, date: Date)]>([])

        func install(_ tuning: inout EngineTuning) {
            tuning.securityDNS = { [self] camera, _ in
                reads.update { $0.append((camera.name, .now, Date())) }
                let thrown = error.update { value -> CameraAdapterError? in
                    defer { value = nil }
                    return value
                }
                if let thrown { throw thrown }
                let dhcp = fromDHCP.value
                if unknown.value {
                    return CameraDNSReading(servers: [], fromDHCP: true, method: .reolinkAPI,
                                            backup: CameraDNSBackup(method: .reolinkAPI, fromDHCP: true, servers: ["", ""]), serversUnknown: true)
                }
                return servers.value.map { servers in
                    CameraDNSReading(servers: servers, fromDHCP: dhcp, method: .onvifMinimal,
                                     backup: CameraDNSBackup(method: .onvifMinimal, fromDHCP: dhcp, servers: dhcp ? [] : servers))
                }
            }
        }

        func count(_ name: String) -> Int { reads.value.filter { $0.camera == name }.count }
        func times(_ name: String) -> [ContinuousClock.Instant] { reads.value.filter { $0.camera == name }.map(\.at) }
        func dates(_ name: String) -> [Date] { reads.value.filter { $0.camera == name }.map(\.date) }
    }

    /// A camera at `host` that was never set up (not running: only the readings are tried).
    private func plainCamera(_ fixture: EngineFixture, host: String, name: String) async throws -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: host), username: "admin")
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        return camera
    }

    /// A running camera on a loopback fake Hikvision (it answers, so it is reachable), standing for one at `address`.
    private func runningCamera(_ fixture: EngineFixture, _ fake: CameraSetupEngineTests.FakeHikvision, name: String) async throws -> CameraConfiguration {
        let camera = CameraConfiguration(name: name, kind: .camera, vendor: .hikvision,
                                         endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(fake.port), onvifPort: Int(fake.port)), username: "admin")
        try await fixture.engine.addCamera(camera, password: "pa55")
        return camera
    }

    /// A camera whose DNS was pointed at the bridge on the camera itself (no setup run; owner decision, 2026-10-18) is watched from the read
    /// that finds it: it joins the box's list then (the box's `since` starts there) and grows no setup record. Pointed elsewhere again, it
    /// leaves the list at the next read.
    @Test func aCameraPointedAtTheBridgeByHandJoinsTheListAndLeavesItWhenChangedBack() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.servers.set(["192.168.77.1"])   // the router's
        answers.install(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        await fixture.engine.start()   // the log reaches `recentLogs`
        let first = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(answers.count("Doorbell") == 1, "read although no setup watched it")
        #expect(first.internetGuard?.watched == false)
        #expect(await settled(fixture))
        #expect(!everListed(box, "192.168.77.25"))

        answers.servers.set([Self.bridgeAddress, Self.bridgeAddress])   // both DNS servers set to the bridge on the camera
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        let listed = [GuardedCamera(address: "192.168.77.25", level: .watch)]
        #expect(await fixture.waitFor { box.last == listed }, "it joins the list at the read that finds it")
        let saved = try #require(stored(fixture, camera.id))
        #expect(saved.setupState == nil, "no setup record: the page still says it is not set up")
        #expect(saved.dnsWatch == CameraDNSWatch(server: Self.bridgeAddress) && BridgeEngine.internetWatchDone(saved))
        #expect(await fixture.waitFor { fixture.engine.recentLogs.contains { $0.message == "Doorbell: its DNS points at Camera Bridge, so the Internet guard watches it" } })
        box.report.set(report([GuardReport.Camera(address: "192.168.77.25", level: .watch, since: Date(), today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(camera.id)?.security?.internetGuard?.watched == true)

        answers.servers.set(["192.168.77.1"])   // changed back on the camera
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(await fixture.waitFor { box.last == [] }, "it leaves the list")
        #expect(stored(fixture, camera.id)?.dnsWatch == nil)
        #expect(fixture.status(camera.id)?.security?.internetGuard?.watched == false)
        #expect(await fixture.waitFor {
            fixture.engine.recentLogs.contains { $0.message == "Doorbell: its DNS no longer points at Camera Bridge, so the Internet guard no longer watches it" }
        })
        await fixture.tearDown()
    }

    /// A read that gives nothing changes nothing (owner decision): the camera does not show its DNS servers this time, or it did not answer
    /// the read. The camera stays on the list and its level keeps the last reading.
    @Test func anUnreadableReadChangesNothing() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.install(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.25", level: .watch, since: Date(), today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(try await fixture.engine.checkCameraSecurity(cameraID: camera.id).internetGuard?.watched == true)
        let listed = [GuardedCamera(address: "192.168.77.25", level: .watch)]
        #expect(await fixture.waitFor { box.last == listed })

        for error in [nil, CameraAdapterError.httpStatus(500)] as [CameraAdapterError?] {
            if let error { answers.error.set(error) } else { answers.servers.set(nil) }
            let again = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
            #expect(again.internetGuard?.watched == true, "\(String(describing: error)): the last reading stands")
            #expect(again.findings.first { $0.feature == .internetGuard }?.sentence.contains("couldn’t read") == false)
            #expect(stored(fixture, camera.id)?.dnsWatch == CameraDNSWatch(server: Self.bridgeAddress))
        }
        #expect(answers.count("Doorbell") == 3)
        #expect(await settled(fixture))
        #expect(box.last == listed)
    }

    /// A camera on automatic DNS whose reading does not know which servers DHCP gives (a Reolink whose ONVIF timed out, refused or paused
    /// its login, or has no `GetDNS`: "servers unknown", not "no servers") is an unreadable read, which changes nothing (owner decision): a
    /// camera watched through its router's DHCP stays on the box's list with its watch and its last reading as evidence. A reading that knows
    /// DHCP gives no server ends the watch, as one of other servers does.
    @Test func aReadingWhoseServersAreUnknownChangesNothing() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.fromDHCP.set(true)
        answers.servers.set([Self.bridgeAddress])   // the router hands out the bridge
        answers.install(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.25", level: .watch, since: Date().addingTimeInterval(-7200), today: 0, last24h: 0,
                                                  names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(try await fixture.engine.checkCameraSecurity(cameraID: camera.id).internetGuard?.watched == true)
        let listed = [GuardedCamera(address: "192.168.77.25", level: .watch)]
        #expect(await fixture.waitFor { box.last == listed })
        #expect(await settled(fixture))
        let sent = box.lists.value.count

        answers.unknown.set(true)
        for _ in 0..<2 {
            let again = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
            #expect(again.internetGuard?.watched == true, "the last reading stands")
            #expect(again.findings.first { $0.feature == .internetGuard }?.sentence
                .hasSuffix("Its DNS servers come from your router, which can change them when it renews the camera’s address.") == true)
            #expect(stored(fixture, camera.id)?.dnsWatch == CameraDNSWatch(server: Self.bridgeAddress))
        }
        await fixture.engine.readGuardDNS(camera.id)   // the guard's own read too
        #expect(stored(fixture, camera.id)?.dnsWatch == CameraDNSWatch(server: Self.bridgeAddress))
        #expect(answers.count("Doorbell") == 4)
        #expect(await settled(fixture))
        #expect(box.last == listed && box.lists.value.dropFirst(sent).allSatisfy { $0 == listed }, "it never left the list")

        answers.unknown.set(false)
        answers.servers.set([])   // known: DHCP gives no server
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(await fixture.waitFor { box.last == [] })
        #expect(stored(fixture, camera.id)?.dnsWatch == nil)
    }

    /// A camera the setup watched whose DNS was changed back on the camera leaves the list at the next read (the setup's record of what it
    /// did, and the servers to give back, stay); pointed at the bridge again, it is back on it.
    @Test func aSetUpCameraChangedBackOnTheCameraLeavesTheListUntilPointedAgain() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        tuning.securityDNS = nil   // the camera's own answer, through ISAPI
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let watched = [GuardedCamera(address: Self.cameraAddress, level: .watch)]
        #expect(await fixture.waitFor { box.last == watched })

        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress() }   // its own servers again, set on the camera
        _ = try await fixture.engine.checkCameraSecurity(cameraID: configuration.id)
        #expect(await fixture.waitFor { box.last == [] }, "it leaves the list")
        let saved = try #require(stored(fixture, configuration.id))
        #expect(saved.setupState?.watchedServer == nil && !BridgeEngine.internetWatchDone(saved))
        #expect(saved.setupState?.steps.last { $0.id == .internetWatch }?.status == .done, "the setup's record of what it did stays")
        #expect(saved.setupBackup?.internetWatch?.servers == ["8.8.8.8", "1.1.1.1"], "and the servers to give back")

        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress) }
        _ = try await fixture.engine.checkCameraSecurity(cameraID: configuration.id)
        #expect(await fixture.waitFor { box.last == watched })
        #expect(stored(fixture, configuration.id)?.setupState?.watchedServer == Self.bridgeAddress)
    }

    /// A camera that works only through its maker's cloud (a Tapo) is red and never asked what it lets out, but its DNS is its own: it is
    /// read, and one pointed at the bridge is watched.
    @Test func aCloudDependentCameraHasItsDNSRead() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        let asked = Box(0)
        tuning.securityReading = { _, _ in
            asked.update { $0 += 1 }
            return []
        }
        tuning.rtspAccessProbe = { _ in .off }
        let answers = DNSAnswers()
        answers.install(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        var camera = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.168.77.44"), username: "admin")
        camera.manufacturer = "tp-link"
        camera.model = "C325WB"
        camera.isEnabled = false
        try await fixture.engine.addCamera(camera, password: "pa55")
        let security = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(security.level == .red && security.findings.first?.service == "TP-Link Tapo")
        #expect(asked.value == 0, "what it lets out is not asked: it works only through TP-Link's cloud")
        #expect(answers.count("Patio") == 1, "its DNS is read")
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: "192.168.77.44", level: .watch)] })
    }

    /// Every camera the guard can watch has its DNS read again every `guardDNSInterval` (30 min), by itself (what it lets out is not asked
    /// again) and one camera after the other, never all at once: a change made on the camera is seen at its next read, in its level too.
    @Test func theDNSIsReadAgainEveryIntervalOneCameraAfterTheOther() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let readings = Box(0)
        tuning.securityReading = { _, _ in
            readings.update { $0 += 1 }
            return []
        }
        let answers = DNSAnswers()
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)   // only the guard's own reads
        tuning.guardDNSInterval = .milliseconds(400)
        tuning.guardCameraAddress = { camera in camera.name == "North" ? "192.168.77.21" : "192.168.77.22" }
        let northCamera = try await CameraSetupEngineTests.FakeHikvision(), southCamera = try await CameraSetupEngineTests.FakeHikvision()
        defer {
            northCamera.stop()
            southCamera.stop()
        }
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let north = try await runningCamera(fixture, northCamera, name: "North")
        _ = try await runningCamera(fixture, southCamera, name: "South")
        await fixture.engine.start()
        let both = [GuardedCamera(address: "192.168.77.21", level: .watch), GuardedCamera(address: "192.168.77.22", level: .watch)]
        #expect(await fixture.waitFor(.seconds(20)) { answers.count("North") >= 3 && answers.count("South") >= 3 })
        #expect(await fixture.waitFor { box.last == both }, "both ask the bridge")
        let northTimes = answers.times("North"), southTimes = answers.times("South")
        #expect(zip(northTimes, northTimes.dropFirst()).allSatisfy { $1 - $0 >= .milliseconds(300) }, "once each interval")
        #expect(southTimes[0] - northTimes[0] >= .milliseconds(150), "one after the other")
        #expect(readings.value == 0, "only the DNS is read")

        _ = try await fixture.engine.checkCameraSecurity(cameraID: north.id)
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Date(), today: 0, last24h: 0, names: []),
                               GuardReport.Camera(address: "192.168.77.22", level: .watch, since: Date(), today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(fixture.status(north.id)?.security?.internetGuard?.watched == true)
        answers.servers.set(["192.168.77.1"])   // changed on the cameras
        #expect(await fixture.waitFor(.seconds(10)) { box.last == [] }, "seen at the next reads, with no check asked for")
        #expect(await fixture.waitFor { fixture.status(north.id)?.security?.internetGuard?.watched == false }, "the level rests on the newest read")
        await fixture.tearDown()
    }

    /// A camera that comes back online after it went offline (it may have just taken a network change) has its DNS read
    /// `guardDNSReconnectDelay` (2 min) later; its first time online is no return, and neither is a reconnect alone (a camera that streams
    /// on demand reconnects at every wake).
    @Test func aCameraBackOnlineIsReadAfterTheDelay() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        tuning.guardDNSReconnectDelay = .milliseconds(300)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        await fixture.engine.start()
        func seen(_ connection: ConnectionState) {
            var status = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor)
            status.connection = connection
            fixture.engine.noteGuardConnections([status])
        }
        seen(.connecting)
        seen(.online)
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] == nil, "its first time online is no return")
        seen(.connecting)
        seen(.online)
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] == nil, "a reconnect alone (an on-demand camera's wake) is no return")
        seen(.offline("the camera stopped answering"))
        seen(.connecting)
        seen(.online)
        let back = ContinuousClock.now
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] != nil)
        #expect(answers.count("Doorbell") == 0)
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Doorbell") == 1 })
        #expect(try #require(answers.times("Doorbell").first) - back >= .milliseconds(250))
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: "192.168.77.25", level: .watch)] })
        await fixture.tearDown()
    }

    /// A read that meets a login pause (Camera Bridge's own after the camera refused a login: the doorbell after its refused time step)
    /// reads nothing then; no read runs during the pause, also not on "Check again"; the DNS is read right after the pause ends.
    @Test func aReadThatMeetsALoginPauseIsDoneRightAfterItEnds() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        tuning.guardDNSPauseMargin = .milliseconds(50)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        await fixture.engine.start()
        let until = Date().addingTimeInterval(2)   // long enough for both checks under a full suite's load
        answers.error.set(.loginsPaused(until: until))
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(answers.count("Doorbell") == 1 && stored(fixture, camera.id)?.dnsWatch == nil, "nothing read, nothing changed")
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)   // "Check again" during the pause
        #expect(answers.count("Doorbell") == 1, "no read during the pause")
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Doorbell") == 2 }, "read again once it ends")
        #expect(try #require(answers.dates("Doorbell").last) >= until)
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: "192.168.77.25", level: .watch)] }, "the DNS set on the camera is seen")
        await fixture.tearDown()
    }

    /// A read whose login the camera refused is not repeated on the guard's own schedule (each would be another wrong password, and cameras
    /// lock the account after a few): the camera is read again when it is checked, and from then on on schedule again.
    @Test func aRefusedLoginStopsTheGuardsOwnReadsUntilOneWorks() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.error.set(.unauthorized)
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .milliseconds(300)
        let fake = try await CameraSetupEngineTests.FakeHikvision()
        defer { fake.stop() }
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await runningCamera(fixture, fake, name: "Gate")
        await fixture.engine.start()
        #expect(await fixture.waitFor(.seconds(20)) { answers.count("Gate") == 1 })
        try await Task.sleep(for: .milliseconds(1000))   // three of the loop's turns
        #expect(answers.count("Gate") == 1, "not read again on its own")
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(answers.count("Gate") >= 2, "the check reads it")
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Gate") >= 3 }, "a read that worked: on schedule again")
        await fixture.tearDown()
    }

    /// DNS the router gives (DHCP) that points only at the bridge is watched (owner decision, 2026-10-18), with a note that the router can
    /// change it (`CameraDNSReading.pointsAt` takes such a reading).
    @Test func aCameraOnTheRoutersDNSThatPointsAtTheBridgeIsWatchedWithANote() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.fromDHCP.set(true)
        answers.install(&tuning)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.25", level: .watch, since: Date().addingTimeInterval(-7200), today: 0, last24h: 0,
                                                  names: [])]))
        await fixture.engine.pollGuardReport()
        let given = CameraDNSReading(servers: [Self.bridgeAddress], fromDHCP: true, method: .onvifMinimal,
                                     backup: CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        #expect(given.pointsAt(Self.bridgeAddress))
        let security = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(security.internetGuard?.watched == true)
        #expect(security.findings.first { $0.feature == .internetGuard }?.sentence
            .hasSuffix("Its DNS servers come from your router, which can change them when it renews the camera’s address.") == true)
        #expect(await fixture.waitFor(.seconds(2)) { box.last == [GuardedCamera(address: "192.168.77.25", level: .watch)] })
    }

    /// The camera's connection as the status loop sees it (`refreshStatus` → `noteGuardConnections`): an enabled camera with no runtime
    /// running takes the event router's connection, as a running one's ingest sets it.
    private func connection(_ fixture: EngineFixture, _ id: UUID, _ state: ConnectionState) async {
        await fixture.engine.router.setStreamConnection(state, for: id)
        await fixture.engine.refreshStatus()
    }

    /// A camera back online after it went offline, seen through the status loop itself (`refreshStatus`), has its DNS read once,
    /// `guardDNSReconnectDelay` later.
    @Test func aReturnSeenByTheStatusLoopHasTheDNSReadAfterTheDelay() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        tuning.guardDNSReconnectDelay = .milliseconds(300)
        let fake = try await CameraSetupEngineTests.FakeHikvision()
        defer { fake.stop() }
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await runningCamera(fixture, fake, name: "Doorbell")
        await fixture.engine.start()
        await fixture.engine.stopRuntime(camera.id)   // the test sets its connection, as its ingest would
        #expect(fixture.engine.runtimes[camera.id] == nil)
        await connection(fixture, camera.id, .online)
        #expect(fixture.status(camera.id)?.connection == .online)
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] == nil, "its first time online is no return")
        await connection(fixture, camera.id, .offline("the camera stopped answering"))
        await connection(fixture, camera.id, .online)
        let back = ContinuousClock.now
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] != nil, "the status loop saw it come back")
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Doorbell") == 1 })
        #expect(try #require(answers.times("Doorbell").first) - back >= .milliseconds(250))
        try await Task.sleep(for: .milliseconds(400))
        #expect(answers.count("Doorbell") == 1, "once")
        await fixture.tearDown()
    }

    /// A camera whose stream keeps dropping (the Wi-Fi doorbell's) is not read at every return: the reads after a reconnect keep
    /// `guardDNSSpacing` between them (a Reolink's read is a login of its own), returns close together share one read, and a camera whose
    /// last read was refused for its login is not read on a return at all.
    @Test func aCameraThatKeepsDroppingIsReadAtMostOnceEachSpacing() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        let answers = DNSAnswers()
        answers.install(&tuning)
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        tuning.guardDNSReconnectDelay = .milliseconds(50)
        tuning.guardDNSSpacing = .milliseconds(800)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        await fixture.engine.start()
        func seen(_ connection: ConnectionState) {
            var status = CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor)
            status.connection = connection
            fixture.engine.noteGuardConnections([status])
        }
        // Online, dropped, back: one return, whatever the status loop (which sees this camera disabled) said in between.
        func flap() {
            seen(.online)
            seen(.offline("the camera stopped answering"))
            seen(.online)
        }
        flap()
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Doorbell") == 1 })
        let first = try #require(answers.times("Doorbell").first)
        flap()
        flap()
        flap()
        #expect(await fixture.waitFor(.seconds(10)) { answers.count("Doorbell") == 2 })
        let times = answers.times("Doorbell")
        #expect(times[1] - first >= .milliseconds(700), "no sooner than the spacing after the last read")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(answers.count("Doorbell") == 2, "the returns close together shared one read")

        answers.error.set(.unauthorized)
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(fixture.engine.internetGuard.loginRefused.contains(camera.id))
        let refused = answers.count("Doorbell")
        flap()
        #expect(fixture.engine.internetGuard.dnsDue[camera.id] == nil, "a refused login is not tried again on a return")
        try await Task.sleep(for: .milliseconds(1000))
        #expect(answers.count("Doorbell") == refused)
        await fixture.tearDown()
    }

    /// A security check whose DNS read falls inside a setup run (the check 60 s after a camera is added, during "Set up" right away) waits
    /// for the run to save what it changed; its reading is from before the run's Watch, so it is no evidence: the camera is read again, and
    /// the run's own check does not join the stale one. The evidence and the watch then rest on the camera as the run left it.
    @Test func aReadingTakenDuringASetupRunIsReadAgainAfterIt() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        tuning.securityDNS = nil   // the camera's own answer, through ISAPI
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        await fixture.engine.start()
        let id = configuration.id
        camera.holdPUT.set("/ISAPI/System/Video/inputs/channels/1/overlays")   // the run holds at Clean picture, before its Watch
        let run = Task { try await fixture.engine.applyCameraSetup(cameraID: id) }
        #expect(await fixture.waitFor { camera.held.value == 1 })
        let check = Task { try await fixture.engine.checkCameraSecurity(cameraID: id) }
        #expect(await fixture.waitFor { fixture.engine.operations.waiterCount >= 1 }, "the check's reading waits for the run")
        camera.release.set(true)
        let report = try await run.value
        #expect(report.steps.first { $0.id == .internetWatch }?.status == .done)
        _ = try? await check.value
        func asksBridge() -> Bool {
            guard case .read(let reading)? = fixture.engine.securityChecks.records[id]?.dns else { return false }
            return reading.pointsAt(Self.bridgeAddress)
        }
        #expect(await fixture.waitFor(.seconds(10)) { asksBridge() }, "the evidence is the camera after the run: \(String(describing: fixture.engine.securityChecks.records[id]?.dns))")
        #expect(stored(fixture, id)?.setupState?.watchedServer == Self.bridgeAddress)
        try await Task.sleep(for: .milliseconds(300))
        #expect(asksBridge(), "and stays so")
        await fixture.tearDown()
    }

    /// The same for Restore: a check that read the bridge before a full Restore gave the camera its DNS back waits for it, and then reads
    /// again: it does not watch the camera again (an older build's record, so the reading wanted to save the watch), and its evidence is
    /// the camera's own servers.
    @Test func aReadingTakenDuringARestoreIsReadAgainAfterIt() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        tuning.securityDNS = nil
        tuning.securityChecks = true
        tuning.securityCheckDelay = .seconds(600)
        tuning.guardDNSInterval = .seconds(3600)
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let (camera, configuration) = try await setupCamera(fixture)
        defer { camera.stop() }
        let id = configuration.id
        camera.documents.update { $0[Self.ipAddressPath] = Self.ipAddress(primary: Self.bridgeAddress, secondary: Self.bridgeAddress) }
        let older = #"{"version":1,"started":814032990,"applied":814032991,"steps":[{"id":"internetWatch","status":"done","needsRestart":false}]}"#
        let state = try JSONDecoder().decode(CameraSetupState.self, from: Data(older.utf8))
        await fixture.engine.changeConfiguration(id) { configuration in
            configuration.name = "Restored Gate"   // its own name in the log, which the other tests' engines share
            configuration.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                          internetWatch: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))
            configuration.setupState = state
        }
        await fixture.engine.start()
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: Self.cameraAddress, level: .watch)] })
        camera.holdPUT.set(Self.ipAddressPath)   // Restore holds at the DNS it gives back
        let restore = Task { try await fixture.engine.restoreCameraSetup(cameraID: id) }
        #expect(await fixture.waitFor { camera.held.value == 1 })
        let check = Task { try await fixture.engine.checkCameraSecurity(cameraID: id) }
        #expect(await fixture.waitFor { fixture.engine.operations.waiterCount >= 1 }, "the check's reading waits for the restore")
        camera.release.set(true)
        let report = try await restore.value
        #expect(report.steps.map(\.status) == [.restored] && !report.canRestore)
        _ = try? await check.value
        func asksOwn() -> Bool {
            guard case .read(let reading)? = fixture.engine.securityChecks.records[id]?.dns else { return false }
            return reading.servers == ["8.8.8.8", "1.1.1.1"]
        }
        #expect(await fixture.waitFor(.seconds(10)) { asksOwn() }, "\(String(describing: fixture.engine.securityChecks.records[id]?.dns))")
        let saved = try #require(stored(fixture, id))
        #expect(saved.setupState == nil && saved.dnsWatch == nil && !BridgeEngine.internetWatchDone(saved), "not watched again by the stale reading")
        #expect(await fixture.waitFor { box.last == [] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(stored(fixture, id)?.dnsWatch == nil && box.last == [])
        #expect(!fixture.engine.recentLogs.contains { $0.message == "Restored Gate: its DNS points at Camera Bridge, so the Internet guard watches it" },
                "the reading from before the restore never watched it again, not even for a moment")
        await fixture.tearDown()
    }

    /// The check right after a setup run or a restore (`scheduleSecurityCheck(fresh:)`, `runSecurityCheck(startedAfter:)`) waits for a check
    /// that began before it and then checks again, instead of taking that check's older readings; any other caller joins the check under way.
    @Test func aCheckAfterAnOperationDoesNotJoinOneThatBeganBefore() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning)
        let gate = Box(false)
        let reads = Box(0)
        tuning.securityDNS = { _, _ in
            reads.update { $0 += 1 }
            while !gate.value { try? await Task.sleep(for: .milliseconds(10)) }
            return CameraDNSReading(servers: [InternetGuardEngineTests.bridgeAddress], fromDHCP: false, method: .hikvisionISAPI,
                                    backup: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: [InternetGuardEngineTests.bridgeAddress]))
        }
        let fixture = try await fixture(guarded: box, tuning: tuning)
        defer { fixture.directory.remove() }
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        let first = Task { await fixture.engine.runSecurityCheck(camera) }
        #expect(await fixture.waitFor { reads.value == 1 })
        let joined = Task { await fixture.engine.runSecurityCheck(camera) }
        let after = ContinuousClock.now
        let fresh = Task { await fixture.engine.runSecurityCheck(camera, startedAfter: after) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.value == 1, "nothing new while the first one runs")
        gate.set(true)
        _ = await first.value
        _ = await joined.value
        _ = await fresh.value
        #expect(reads.value == 2, "the joining call took the first check, the fresh one ran its own")
    }

    /// A camera watched because its DNS was set on the camera has no servers of its own kept to give back: removing it says to change its
    /// DNS on the camera (the box stops answering it).
    @Test func removingACameraWatchedByItsOwnDNSSaysToChangeItOnTheCamera() async throws {
        let box = FakeGuard()
        var tuning = Self.tuning()
        everythingOff(&tuning, dns: nil)
        DNSAnswers().install(&tuning)
        tuning.restoresWatchOnRemoval = true
        let fixture = try await fixture(guarded: box, tuning: tuning)
        let camera = try await plainCamera(fixture, host: "192.168.77.25", name: "Doorbell")
        await fixture.engine.start()   // the log reaches `recentLogs`
        _ = try await fixture.engine.checkCameraSecurity(cameraID: camera.id)
        #expect(await fixture.waitFor { box.last?.count == 1 })
        await fixture.engine.removeCamera(id: camera.id)
        #expect(await fixture.waitFor { box.last == [] })
        #expect(await fixture.waitFor {
            fixture.engine.recentLogs.contains { $0.message.hasPrefix("Doorbell: its DNS still points at Camera Bridge (set on the camera)") }
        })
        await fixture.tearDown()
    }

    // MARK: Alerts

    @Test func aCameraSeenTryingIsOneAlertAndAQuietDayRaisesNothing() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box, tuning: Self.tuning())
        defer { fixture.directory.remove() }
        let north = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        _ = try await watchedCamera(fixture, host: "192.168.77.22", name: "South")
        let today = Calendar.current.startOfDay(for: Date())

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardAlerts.isEmpty, "nothing was blocked")

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 4, last24h: 4, names: []),
                               GuardReport.Camera(address: "192.168.77.22", level: .watch, today: 0, last24h: 0, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        let alerts = fixture.engine.internetGuardAlerts
        #expect(alerts.map(\.cameraID) == [north.id] && alerts.first?.kind == .firstTry)

        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 40, last24h: 40, names: [])], todayStart: today))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardAlerts == alerts, "more blocked attempts change nothing: no daily notice, no new alert")
    }

    @Test func aCameraThatStopsBeingWatchedIsOneWarningUntilWatchedAgain() async throws {
        let box = FakeGuard()
        let fixture = try await fixture(guarded: box, tuning: Self.tuning())
        defer { fixture.directory.remove() }
        let camera = try await watchedCamera(fixture, host: "192.168.77.21", name: "North")
        box.report.set(report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 0, last24h: 0, names: [])]))
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardAlerts.isEmpty)

        await fixture.engine.changeConfiguration(camera.id) { $0.setupState = nil }   // its DNS no longer asks the bridge
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardAlerts.map(\.kind) == [.stoppedAsking] && fixture.engine.internetGuardAlerts.first?.cameraID == camera.id)

        await fixture.engine.changeConfiguration(camera.id) { configuration in
            configuration.setupState = CameraSetupState(started: Self.now, applied: Self.now, steps: [.init(id: .internetWatch, status: .done)])
        }
        await fixture.engine.pollGuardReport()
        #expect(fixture.engine.internetGuardAlerts.isEmpty, "watched again")
    }
}
#endif
