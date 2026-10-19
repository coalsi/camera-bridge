#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
@testable import CameraAdapters

/// A loopback Hikvision camera for "Set up for Camera Bridge": the ISAPI documents the setup reads and writes, in the shape a
/// DS-2CD2387G2 answers them (Digest-protected, ver20 namespace), with the camera's ways of saying no: a refusal in a `ResponseStatus`
/// (`statusCode` 4 or 6 with a `subStatusCode`), an HTTP 403 (an account without the right), `statusCode` 7 ("Reboot Required": taken,
/// applied after a restart), a 404 for a resource the model does not have, and a write answered OK that changes nothing. `PUT` replaces the
/// stored document; `PUT /ISAPI/System/reboot` (no document) is answered OK and counted.
final class FakeSetupCamera: Sendable {
    static let ns = "xmlns=\"http://www.hikvision.com/ver20/XMLSchema\""

    static let time = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Time version="2.0" \(ns)>
    <timeMode>NTP</timeMode>
    <localTime>2026-10-16T09:12:44-07:00</localTime>
    <timeZone>CST+8:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone>
    </Time>
    """

    static let ntpServer = """
    <?xml version="1.0" encoding="UTF-8"?>
    <NTPServer version="2.0" \(ns)>
    <id>1</id>
    <addressingFormatType>hostname</addressingFormatType>
    <hostName>time.windows.com</hostName>
    <portNo>123</portNo>
    <synchronizeInterval>1440</synchronizeInterval>
    </NTPServer>
    """

    static let networkCapabilities = """
    <?xml version="1.0" encoding="UTF-8"?>
    <NetworkCap version="2.0" \(ns)>
    <isSupportWireless>false</isSupportWireless>
    <isSupportUPnP>true</isSupportUPnP>
    <isSupportEZVIZ>true</isSupportEZVIZ>
    <isSupportIPFilter>true</isSupportIPFilter>
    </NetworkCap>
    """

    static let upnp = """
    <?xml version="1.0" encoding="UTF-8"?>
    <UPnP version="2.0" \(ns)>
    <enabled>true</enabled>
    <name>DS-2CD2387G2 - J12345678</name>
    </UPnP>
    """

    /// Hik-Connect: `verificationCode` is the camera's own secret (it encrypts its video in the maker's app); the setup must never keep it.
    static let verificationCode = "QWERTY"
    static let cloud = """
    <?xml version="1.0" encoding="UTF-8"?>
    <EZVIZ version="2.0" \(ns)>
    <enabled>true</enabled>
    <registerStatus>true</registerStatus>
    <redirect>true</redirect>
    <serverAddress><addressingFormatType>hostname</addressingFormatType><hostName>litedev.hik-connect.com</hostName></serverAddress>
    <verificationCode>\(verificationCode)</verificationCode>
    <offlineStatus>none</offlineStatus>
    </EZVIZ>
    """

    /// The first network interface's addresses (`/ISAPI/System/Network/interfaces/1/ipAddress`) in the ISAPI 2.0 schema's shape, not yet
    /// checked against a real camera's answer: the camera's own address and gateway come before the DNS servers, each an `ipAddress` too.
    /// A fixed address (`static`) unless a test says otherwise, as a Hikvision ships; `dynamic` is DHCP. The camera's own address is
    /// `address` (192.168.77.30 by default), with `subnetMask` and `gateway`.
    static func ipAddress(addressing: String = "static", primaryDNS: String = "8.8.8.8", secondaryDNS: String? = "1.1.1.1", address: String = "192.168.77.30",
                          subnetMask: String = "255.255.255.0", gateway: String = "192.168.77.1") -> String {
        let secondary = secondaryDNS.map { "<SecondaryDNS>\n<ipAddress>\($0)</ipAddress>\n</SecondaryDNS>\n" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <IPAddress version="2.0" \(ns)>
        <ipVersion>dual</ipVersion>
        <addressingType>\(addressing)</addressingType>
        <ipAddress>\(address)</ipAddress>
        <subnetMask>\(subnetMask)</subnetMask>
        <ipv6Address>::</ipv6Address>
        <bitMask>0</bitMask>
        <DefaultGateway>
        <ipAddress>\(gateway)</ipAddress>
        <ipv6Address>::</ipv6Address>
        </DefaultGateway>
        <PrimaryDNS>
        <ipAddress>\(primaryDNS)</ipAddress>
        </PrimaryDNS>
        \(secondary)<Ipv6Mode>
        <ipV6AddressingType>ra</ipV6AddressingType>
        <ipv6AddressList><v6Address><id>1</id><type>ra</type><address>::</address><bitMask>0</bitMask></v6Address></ipv6AddressList>
        </Ipv6Mode>
        </IPAddress>
        """
    }

    /// The camera's hardware address (made up).
    static let hardwareAddress = "02:00:00:00:00:30"

    /// The first network interface (`/ISAPI/System/Network/interfaces/1`) in the ISAPI 2.0 schema's shape: its addresses, then its link with
    /// the hardware address (`MACAddress`).
    static func networkInterface(mac: String = hardwareAddress) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <NetworkInterface version="2.0" \(ns)>
        <id>1</id>
        <IPAddress version="2.0" \(ns)><ipVersion>dual</ipVersion><addressingType>dynamic</addressingType><ipAddress>192.168.77.30</ipAddress></IPAddress>
        <Link version="2.0" \(ns)><MACAddress>\(mac)</MACAddress><autoNegotiation>true</autoNegotiation><speed>0</speed><duplex>full</duplex><MTU>1500</MTU></Link>
        </NetworkInterface>
        """
    }

    static func overlays(on: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VideoOverlay version="2.0" \(ns)>
        <normalizedScreenSize><normalizedScreenWidth>704</normalizedScreenWidth><normalizedScreenHeight>576</normalizedScreenHeight></normalizedScreenSize>
        <TextOverlayList size="4"><TextOverlay><id>1</id><enabled>\(on)</enabled><positionX>16</positionX><positionY>64</positionY><displayText>Gate</displayText></TextOverlay></TextOverlayList>
        <DateTimeOverlay><enabled>\(on)</enabled><positionX>0</positionX><positionY>544</positionY><dateStyle>MM-DD-YYYY</dateStyle><timeStyle>24hour</timeStyle><displayWeek>true</displayWeek></DateTimeOverlay>
        <channelNameOverlay><enabled>\(on)</enabled><positionX>512</positionX><positionY>64</positionY></channelNameOverlay>
        </VideoOverlay>
        """
    }

    /// A streaming channel: H.265 with H.265+ on and a long keyframe interval (what a new camera often ships with).
    static func channel(id: String, codec: String = "H.265", width: Int = 3840, height: Int = 2160, gov: Int = 50, smartCodec: Bool = true) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <StreamingChannel version="2.0" \(ns)>
        <id>\(id)</id><channelName>Gate</channelName><enabled>true</enabled>
        <Video><enabled>true</enabled><videoInputChannelID>1</videoInputChannelID><videoCodecType>\(codec)</videoCodecType>\
        <videoResolutionWidth>\(width)</videoResolutionWidth><videoResolutionHeight>\(height)</videoResolutionHeight>\
        <videoQualityControlType>VBR</videoQualityControlType><vbrUpperCap>4096</vbrUpperCap><maxFrameRate>2000</maxFrameRate>\
        <GovLength>\(gov)</GovLength><SmartCodec><enabled>\(smartCodec)</enabled></SmartCodec></Video>
        </StreamingChannel>
        """
    }

    static func status(_ code: Int, _ words: String, sub: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ResponseStatus version="2.0" \(ns)>
        <requestURL>/ISAPI</requestURL><statusCode>\(code)</statusCode><statusString>\(words)</statusString><subStatusCode>\(sub)</subStatusCode>
        </ResponseStatus>
        """
    }

    let server: MockHTTPServer
    /// Path → document.
    let documents: Box<[String: String]>
    /// Paths whose `PUT` is refused (`ResponseStatus` 6 "Invalid Content", `badParameters`, HTTP 400).
    let refusePUT = Box<Set<String>>([])
    /// Paths whose `PUT` is answered HTTP 403, with a `ResponseStatus` 4 ("Invalid Operation") whose `subStatusCode` is the value
    /// (`lowPrivilege`: the account may not; `notSupport`), or with no status document for "".
    let forbidPUT = Box<[String: String]>([:])
    /// Paths whose `PUT` is taken with `statusCode` 7 ("Reboot Required").
    let rebootRequired = Box<Set<String>>([])
    /// Paths whose `PUT` is answered OK and changes nothing.
    let ignorePUT = Box<Set<String>>([])
    /// Paths whose document is gone after a `PUT` (the answer is OK).
    let vanishAfterPUT = Box<Set<String>>([])
    /// An address document `PUT` takes its `PrimaryDNS` only, its `SecondaryDNS` stays as it was (the answer is OK).
    let keepSecondaryDNS = Box(false)
    /// Every `PUT`, in order: path and body.
    let puts = Box<[(path: String, body: String)]>([])

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(server.port)) }
    var credentials: HTTPCredentials { HTTPCredentials(username: "admin", password: "pa55") }

    private init(server: MockHTTPServer, documents: Box<[String: String]>) {
        self.server = server
        self.documents = documents
    }

    static func defaultDocuments() -> [String: String] {
        [
            HikvisionISAPI.timePath: time,
            HikvisionISAPI.ntpServerPath: ntpServer,
            HikvisionISAPI.networkCapabilitiesPath: networkCapabilities,
            "/ISAPI/System/Network/UPnP": upnp,
            "/ISAPI/System/Network/EZVIZ": cloud,
            HikvisionISAPI.ipAddressPath: ipAddress(),
            HikvisionISAPI.interfacePath: networkInterface(),
            "/ISAPI/System/Video/inputs/channels/1/overlays": overlays(on: true),
            "/ISAPI/Streaming/channels/101": channel(id: "101"),
            "/ISAPI/Streaming/channels/102": channel(id: "102", codec: "H.264", width: 640, height: 480, gov: 50, smartCodec: false),
        ]
    }

    static func start(documents: [String: String] = defaultDocuments()) async throws -> FakeSetupCamera {
        let holder = Box<FakeSetupCamera?>(nil)
        let store = Box(documents)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return camera.handle(request)
        }
        let camera = FakeSetupCamera(server: server, documents: store)
        holder.set(camera)
        return camera
    }

    func stop() { server.stop() }

    func puts(to path: String) -> [String] { puts.value.filter { $0.path == path }.map(\.body) }

    /// Where ISAPI restarts the camera.
    static let rebootPath = "/ISAPI/System/reboot"

    /// How many times the camera was asked to restart.
    var restarts: Int { puts(to: Self.rebootPath).count }

    private func handle(_ request: MockRequest) -> MockResponse {
        guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge() }
        let path = request.path
        switch request.method {
        case "GET":
            guard let document = documents.value[path] else { return .xml(Self.status(4, "Invalid Operation", sub: "notSupport"), status: 404) }
            return .xml(document)
        case "PUT":
            puts.update { $0.append((path, request.bodyText)) }
            if let sub = forbidPUT.value[path] { return sub.isEmpty ? .status(403) : .xml(Self.status(4, "Invalid Operation", sub: sub), status: 403) }
            if path == Self.rebootPath { return .xml(Self.status(1, "OK", sub: "ok")) }
            guard documents.value[path] != nil else { return .xml(Self.status(4, "Invalid Operation", sub: "notSupport"), status: 404) }
            if refusePUT.value.contains(path) { return .xml(Self.status(6, "Invalid Content", sub: "badParameters"), status: 400) }
            if path == HikvisionISAPI.ipAddressPath, keepSecondaryDNS.value, let old = documents.value[path].flatMap(HikvisionISAPI.dnsServers(in:)),
               let sent = HikvisionISAPI.dnsServers(in: request.bodyText), let secondary = old.slots.dropFirst().first {
                documents.update { $0[path] = Self.ipAddress(addressing: old.addressingType ?? "static", primaryDNS: sent.slots[0], secondaryDNS: secondary) }
            } else if !ignorePUT.value.contains(path) {
                documents.update { $0[path] = request.bodyText }
            }
            if vanishAfterPUT.value.contains(path) { documents.update { $0[path] = nil } }
            if rebootRequired.value.contains(path) { return .xml(Self.status(7, "Reboot Required", sub: "rebootRequired")) }
            return .xml(Self.status(1, "OK", sub: "ok"))
        default:
            return .status(405)
        }
    }
}
#endif
