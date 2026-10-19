#if canImport(Darwin)
import BridgeSupport
@testable import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The Reolink doorbell on the box (Oct 18): its ONVIF account signs in and reads, but answers "Time from the bridge"'s `SetNTP` with a
/// `NotAuthorized` fault. Camera Bridge took that for a wrong password: the step said "the camera refused the login", ONVIF's logins paused
/// for 2 minutes, the setup stopped and "Watch its internet" did not run. A change the account may not make is the camera's answer about
/// that change alone (owner decision, 2026-10-18): the step says so (use an administrator account), nothing is paused, and every step after
/// it still runs (Clean picture here, and Watch); any other refusal still stops the steps after it. A loopback fake, never a real camera;
/// the doorbell stands for one at 192.168.77.21 on the bridge's 192.168.77.0/24.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraSetupNotPermittedTests {
    /// The IPCamera Web family's API stopped for want of privilege (532374, met at a sign-in in the middle of a step) is a change the account
    /// may not make, so the run goes on; any other reason it stopped (no credentials, a refused sign-in) is not.
    @Test func theIPCameraWebFamilysNoPrivilegeIsNotPermitted() {
        #expect(BridgeEngine.refusal(IPCamWebUnavailable.noPrivilege).notPermitted)
        #expect(!BridgeEngine.refusal(IPCamWebUnavailable.noCredentials).notPermitted)
        #expect(!BridgeEngine.refusal(IPCamWebUnavailable.paused).notPermitted)
        #expect(BridgeEngine.refusal(CameraAdapterError.notPermitted("set mobile")).notPermitted)
        #expect(!BridgeEngine.refusal(CameraAdapterError.unauthorized).notPermitted)
    }

    /// An ONVIF device service that answers every read to anyone (it checks no password), refuses its clock and time servers with a
    /// `NotAuthorized` fault (or `clockFault`), keeps the DNS servers it is sent, and draws its own date and time (an OSD element it lets
    /// be deleted and created again). Its network interface `eth0` has the camera's address (192.168.77.21/24, gateway 192.168.77.1,
    /// a made-up hardware address), from DHCP until `SetNetworkInterfaces` fixes it.
    final class FakeDoorbell: Sendable {
        struct DNS: Sendable, Equatable {
            var fromDHCP = true
            var manual: [String] = []
        }

        let port: UInt16
        let dns = Box(DNS())
        /// The fault `SetNTP` and `SetSystemDateAndTime` answer: "NotAuthorized" (the account may not), or another (the camera's own refusal).
        let clockFault = Box("NotAuthorized")
        /// The tokens of its text OSD elements (each shows the date and time).
        let osds = Box(["OSD_DateTime"])
        /// Body element names of every SOAP request, in order.
        let actions = Box<[String]>([])
        /// The zone it reports (the bridge's, so its time zone is already right).
        let zone: String
        /// Its address comes from DHCP (`SetNetworkInterfaces` with DHCP false fixes it as sent).
        let addressFromDHCP = Box(true)
        /// While its address comes from DHCP, `SetDNS` is answered OK and changes nothing: a DNS set by hand that does not stay.
        let dnsOnlyWithFixedAddress = Box(false)
        /// `SetNetworkInterfaces` is answered with an `InvalidArgVal` fault (a body it does not take), always.
        let refuseNetworkInterfaces = Box(false)
        /// `SetNetworkInterfaces` is applied and answered 200 with a body that is not its answer, always.
        let unreadableNetworkInterfaces = Box(false)
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init(zone: String) async throws {
            self.zone = zone
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
            ONVIFLoginGuard.shared.clear(host: host)
        }

        var host: String { "127.0.0.1:\(port)" }
        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(port), onvifPort: Int(port)) }

        func stop() {
            listener.close()
            task.withLock { $0?.cancel() }
            ONVIFLoginGuard.shared.clear(host: host)
        }

        private func serve(_ connection: any TCPConnection) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while true {
                guard let data = try? await connection.receive(maximumLength: 65_536), let requests = try? parser.feed(data) else { return }
                for (head, body) in requests {
                    let (status, text) = head.method == "POST" ? answer(String(decoding: body, as: UTF8.self)) : (404, "")
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders([("Content-Type", "application/soap+xml; charset=utf-8")]),
                                                       body: Data(text.utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        private func envelope(_ body: String) -> (Int, String) {
            (200, "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
                + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Body>\(body)</s:Body></s:Envelope>")
        }

        private func fault(_ subcode: String) -> (Int, String) {
            (400, "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:ter=\"http://www.onvif.org/ver10/error\"><s:Body><s:Fault>"
                + "<s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:\(subcode)</s:Value></s:Subcode></s:Code>"
                + "<s:Reason><s:Text xml:lang=\"en\">\(subcode == "NotAuthorized" ? "Sender not Authorized" : "not supported")</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>")
        }

        /// The SOAP body's first element's local name.
        static func action(_ body: String) -> String? {
            guard let range = body.range(of: "Body>") else { return nil }
            return body[range.upperBound...].firstMatch(of: /<(?:[A-Za-z0-9]+:)?([A-Za-z0-9]+)/).map { String($0.output.1) }
        }

        private static func address(_ server: String) -> String {
            "<tt:Type>IPv4</tt:Type><tt:IPv4Address>\(server)</tt:IPv4Address>"
        }

        private func answer(_ body: String) -> (Int, String) {
            guard let action = Self.action(body) else { return (400, "") }
            actions.update { $0.append(action) }
            switch action {
            case "GetSystemDateAndTime":
                return envelope("<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType>"
                    + "<tt:DaylightSavings>false</tt:DaylightSavings><tt:TimeZone><tt:TZ>\(zone)</tt:TZ></tt:TimeZone></tds:SystemDateAndTime>"
                    + "</tds:GetSystemDateAndTimeResponse>")
            case "GetDeviceInformation":
                return envelope("<tds:GetDeviceInformationResponse><tds:Manufacturer>Reolink</tds:Manufacturer><tds:Model>Video Doorbell WiFi</tds:Model>"
                    + "<tds:FirmwareVersion>1.0</tds:FirmwareVersion><tds:SerialNumber>1</tds:SerialNumber><tds:HardwareId>1</tds:HardwareId></tds:GetDeviceInformationResponse>")
            case "GetProfiles":
                return envelope("<trt:GetProfilesResponse></trt:GetProfilesResponse>")
            case "GetNTP":
                return envelope("<tds:GetNTPResponse><tds:NTPInformation><tt:FromDHCP>false</tt:FromDHCP><tt:NTPManual><tt:Type>DNS</tt:Type>"
                    + "<tt:DNSname>pool.ntp.org</tt:DNSname></tt:NTPManual></tds:NTPInformation></tds:GetNTPResponse>")
            case "SetNTP", "SetSystemDateAndTime":
                return fault(clockFault.value)   // NotAuthorized: the account may not change the clock, what the doorbell answers
            case "GetOSDs":
                let elements = osds.value.map { token in
                    "<trt:OSDs token=\"\(token)\"><tt:VideoSourceConfigurationToken>vsc</tt:VideoSourceConfigurationToken><tt:Type>Text</tt:Type>"
                        + "<tt:Position><tt:Type>UpperLeft</tt:Type></tt:Position><tt:TextString><tt:Type>DateAndTime</tt:Type></tt:TextString></trt:OSDs>"
                }.joined()
                return envelope("<trt:GetOSDsResponse>\(elements)</trt:GetOSDsResponse>")
            case "DeleteOSD":
                let token = body.firstMatch(of: /<trt:OSDToken>([^<]*)<\/trt:OSDToken>/).map { String($0.output.1) }
                osds.update { $0.removeAll { $0 == token } }
                return envelope("<trt:DeleteOSDResponse/>")
            case "CreateOSD":
                osds.update { $0.append("OSD_Created") }
                return envelope("<trt:CreateOSDResponse><trt:OSDToken>OSD_Created</trt:OSDToken></trt:CreateOSDResponse>")
            case "GetDNS":
                let state = dns.value
                let servers = state.fromDHCP ? ["192.168.77.1"].map { "<tt:DNSFromDHCP>\(Self.address($0))</tt:DNSFromDHCP>" }.joined()
                    : state.manual.map { "<tt:DNSManual>\(Self.address($0))</tt:DNSManual>" }.joined()
                return envelope("<tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>\(state.fromDHCP)</tt:FromDHCP>\(servers)</tds:DNSInformation></tds:GetDNSResponse>")
            case "GetNetworkInterfaces":
                let address = "<tt:Address>\(CameraSetupNotPermittedTests.cameraAddress)</tt:Address><tt:PrefixLength>24</tt:PrefixLength>"
                let config = addressFromDHCP.value ? "<tt:FromDHCP>\(address)</tt:FromDHCP><tt:DHCP>true</tt:DHCP>" : "<tt:Manual>\(address)</tt:Manual><tt:DHCP>false</tt:DHCP>"
                return envelope("<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token=\"eth0\"><tt:Enabled>true</tt:Enabled><tt:Info>"
                    + "<tt:HwAddress>02:00:00:00:00:21</tt:HwAddress></tt:Info><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Config>\(config)</tt:Config></tt:IPv4>"
                    + "</tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>")
            case "GetNetworkDefaultGateway":
                return envelope("<tds:GetNetworkDefaultGatewayResponse><tds:NetworkGateway><tt:IPv4Address>192.168.77.1</tt:IPv4Address></tds:NetworkGateway>"
                    + "</tds:GetNetworkDefaultGatewayResponse>")
            case "SetNetworkInterfaces":
                guard !refuseNetworkInterfaces.value, body.contains("<tds:InterfaceToken>eth0</tds:InterfaceToken>"),
                      body.contains("<tt:Address>\(CameraSetupNotPermittedTests.cameraAddress)</tt:Address>") || body.contains("<tt:DHCP>true</tt:DHCP>") else {
                    return fault("InvalidArgVal")
                }
                addressFromDHCP.set(body.contains("<tt:DHCP>true</tt:DHCP>"))
                if unreadableNetworkInterfaces.value { return envelope("<tds:Unexpected/>") }
                return envelope("<tds:SetNetworkInterfacesResponse><tds:RebootNeeded>false</tds:RebootNeeded></tds:SetNetworkInterfacesResponse>")
            case "SetNetworkDefaultGateway":
                return envelope("<tds:SetNetworkDefaultGatewayResponse/>")
            case "SetDNS":
                if dnsOnlyWithFixedAddress.value, addressFromDHCP.value { return envelope("<tds:SetDNSResponse/>") }
                let fromDHCP = body.contains("<tds:FromDHCP>true</tds:FromDHCP>")
                let servers = body.matches(of: /<tt:IPv4Address>([^<]*)<\/tt:IPv4Address>/).map { String($0.output.1) }.filter { !$0.isEmpty }
                dns.set(DNS(fromDHCP: fromDHCP, manual: servers))
                return envelope("<tds:SetDNSResponse/>")
            default:
                return fault("ActionNotSupported")
            }
        }
    }

    nonisolated static let cameraAddress = "192.168.77.21"
    nonisolated static let bridgeAddress = "192.168.77.2"

    private static func tuning() -> EngineTuning {
        var tuning = EngineTuning.testing
        tuning.interfaceAddresses = {
            [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
             InterfaceAddress(interface: "en0", address: bridgeAddress, prefixLength: 24)]
        }
        tuning.guardCameraAddress = { camera in camera.endpoint.host == "127.0.0.1" ? cameraAddress : BridgeEngine.guardAddress(camera.endpoint.host) }
        tuning.guardSyncRetry = .milliseconds(20)
        tuning.guardPollInterval = .seconds(600)
        return tuning
    }

    private func setUp() async throws -> (EngineFixture, InternetGuardEngineTests.FakeGuard, FakeDoorbell, CameraConfiguration) {
        let box = InternetGuardEngineTests.FakeGuard()
        let fixture = try await EngineFixture(tuning: Self.tuning(), servesTime: true, adjust: { box.install(&$0) })
        let zone = PosixTimeZone.string(for: fixture.engine.settings.timeZone ?? TimeZone.current.identifier) ?? "UTC0"
        let camera = try await FakeDoorbell(zone: zone)
        var configuration = CameraConfiguration(name: "Doorbell", kind: .doorbell, vendor: .onvif, endpoint: camera.endpoint, username: "family")
        configuration.isEnabled = false   // no stream: only the settings are tried
        try await fixture.engine.addCamera(configuration, password: "pa55")
        return (fixture, box, camera, configuration)
    }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }

    @Test func aTimeSourceTheAccountMayNotChangeSaysSoAndTheStepsAfterItStillRun() async throws {
        let (fixture, box, camera, configuration) = try await setUp()
        defer { camera.stop(); fixture.directory.remove() }

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        #expect(preview.steps.first { $0.id == .cleanPicture }?.status == .willChange, "it draws its own date and time")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0) })
        #expect(steps[.timeSource]?.status == .refused)
        #expect(steps[.timeSource]?.detail == "the account Camera Bridge uses may not change this; use an administrator account in the camera’s settings")
        #expect(report.stoppedAt == nil, "a change the account may not make stops nothing")
        #expect(steps[.cleanPicture]?.status == .done, "the step after it still ran: \(steps[.cleanPicture]?.detail ?? "")")
        #expect(camera.osds.value.isEmpty && camera.actions.value.contains("DeleteOSD"))
        #expect(ONVIFLoginGuard.shared.pause(host: camera.host) == nil, "no login pause: the password is right")

        let watch = try #require(steps[.internetWatch])
        #expect(watch.status == .done, "\(watch.detail ?? "")")
        #expect(camera.dns.value == FakeDoorbell.DNS(fromDHCP: false, manual: [Self.bridgeAddress, Self.bridgeAddress]), "the bridge in both slots")
        #expect(stored(fixture, configuration.id)?.setupState?.watchedServer == Self.bridgeAddress)
        #expect(await fixture.waitFor { box.last == [GuardedCamera(address: Self.cameraAddress, level: .watch)] })
        #expect(camera.actions.value.filter { $0 == "SetNTP" }.count == 1, "asked once")
    }

    /// Any other refusal of the time source (the camera's own answer, here a value it would not take) still stops the steps after it that
    /// would change something; Watch runs after it, as after any answer of the camera.
    @Test func anotherRefusalStillStopsTheStepsAfterIt() async throws {
        let (fixture, _, camera, configuration) = try await setUp()
        defer { camera.stop(); fixture.directory.remove() }
        camera.clockFault.set("InvalidArgVal")
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0) })
        #expect(steps[.timeSource]?.status == .refused && steps[.timeSource]?.detail != CameraAdapterError.notPermittedReason)
        #expect(report.stoppedAt == .timeSource)
        #expect(steps[.cleanPicture]?.status == .notRun && camera.osds.value == ["OSD_DateTime"])
        #expect(steps[.internetWatch]?.status == .done)
    }

    /// Restore on such a camera: the time source it never took is refused in the same words (nothing was changed), the DNS comes back, and
    /// still nothing is paused.
    @Test func restoringAStepTheAccountMayNotChangeSaysSoToo() async throws {
        let (fixture, _, camera, configuration) = try await setUp()
        defer { camera.stop(); fixture.directory.remove() }
        _ = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        let steps = Dictionary(uniqueKeysWithValues: restored.steps.map { ($0.id, $0) })
        #expect(steps[.internetWatch]?.status == .restored)
        #expect(camera.dns.value.fromDHCP, "its DNS from the router again")
        #expect(steps[.timeSource]?.status == .refused)
        #expect(steps[.timeSource]?.detail == CameraAdapterError.notPermittedReason)
        #expect(steps[.cleanPicture]?.status == .restored && camera.osds.value.count == 1, "the labels it took off come back")
        #expect(ONVIFLoginGuard.shared.pause(host: camera.host) == nil)
    }
}
#endif
