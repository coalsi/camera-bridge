#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Testing
@testable import HAP

extension HAPServerTimings {
    /// Short handler/debounce/retry timings for tests; event coalescing keeps the real 250 ms.
    static let fastTests = HAPServerTimings(handlerWarning: .milliseconds(100), handlerTimeout: .milliseconds(300),
                                            resourceWarning: .milliseconds(100), resourceTimeout: .milliseconds(300),
                                            eventCoalescing: .milliseconds(250), configurationDebounce: .milliseconds(20),
                                            advertisementDebounce: .milliseconds(20), listenerRetryDelay: .milliseconds(50),
                                            listenerRetryMaximumDelay: .milliseconds(200), advertisingRetryDelay: .milliseconds(50),
                                            advertisingRetryMaximumDelay: .milliseconds(200))

    /// `fastTests` with some fields changed.
    static func fast(_ change: (inout HAPServerTimings) -> Void) -> HAPServerTimings {
        var timings = HAPServerTimings.fastTests
        change(&timings)
        return timings
    }
}

/// The services of `TestAccessories.sensorHub()`, for iid lookups.
struct SensorHub {
    let accessory: Accessory
    let motion: Service
    let light: Service
    let contact: Service
    let doorbell: Service
    let recording: Service
    let dataStream: Service

    var motionDetected: Characteristic { motion.characteristic(.motionDetected) }
    var lightOn: Characteristic { light.characteristic(.on) }
    var contactState: Characteristic { contact.characteristic(.contactSensorState) }
    var switchEvent: Characteristic { doorbell.characteristic(.programmableSwitchEvent) }
    var recordingAudioActive: Characteristic { recording.characteristic(.recordingAudioActive) }
    var setupDataStream: Characteristic { dataStream.characteristic(.setupDataStreamTransport) }
}

enum TestAccessories {
    static let info = AccessoryInfo(name: "Test Hub", manufacturer: "CameraBridge", model: "CB-Test", serialNumber: "SN-0001",
                                    firmwareRevision: "1.0.0")

    /// A sensor accessory covering the characteristic kinds the server tests need.
    static func sensorHub(category: AccessoryCategory = .sensor) -> SensorHub {
        let accessory = Accessory(info: info, category: category)
        let motion = accessory.addService(Service(.motionSensor, name: "Motion"))
        let light = accessory.addService(Service(.switch, name: "Light", subtype: "light"))
        let contact = accessory.addService(Service(.contactSensor, name: "Door"))
        let doorbell = accessory.addService(Service(.doorbell, name: "Bell"))
        let recording = accessory.addService(Service(.cameraRecordingManagement))
        recording.characteristic(.recordingAudioActive)
        let dataStream = accessory.addService(Service(.dataStreamTransportManagement))
        dataStream.characteristic(.version).update(.string("1.0"))
        return SensorHub(accessory: accessory, motion: motion, light: light, contact: contact, doorbell: doorbell,
                         recording: recording, dataStream: dataStream)
    }
}

struct RunningServer {
    let accessory: Accessory
    let server: AccessoryServer
    let store: any HAPStore
    let advertiser: RecordingAdvertiser
    let port: UInt16
    let setupCode: String
    /// What pair-setup M6 would have told a controller about the accessory.
    let accessoryPairing: HAPTestClient.Pairing

    /// A new admin controller, paired through the server's test hook (same state, event and TXT effects as pair-setup
    /// M5) and then pair-verified. Skips the 3072-bit SRP exchange, which dominates test time (and times out under
    /// ThreadSanitizer); tests of pair-setup itself use `pairedClientViaSetup()` or `HAPTestClient.pairSetup`.
    func pairedClient() async throws -> HAPTestClient {
        let controllerID = UUID().uuidString
        let key = HAPLongTermKey()
        await server.addPairingForTesting(controllerID: controllerID, publicKey: key.publicKey)
        let client = try await HAPTestClient.connect(port: port, controllerID: controllerID, longTermKey: key, pairing: accessoryPairing)
        try await client.pairVerify()
        return client
    }

    /// Connects, pairs with a real pair-setup M1–M6 and verifies a new controller.
    func pairedClientViaSetup() async throws -> HAPTestClient {
        let client = try await HAPTestClient.connect(port: port)
        try await client.pairSetup(code: setupCode)
        try await client.pairVerify()
        return client
    }

    /// A second verified connection for an already paired controller identity.
    func verifiedConnection(like client: HAPTestClient) async throws -> HAPTestClient {
        let other = try await client.reconnect(port: port)
        try await other.pairVerify()
        return other
    }

    func stop() async {
        await server.stop()
    }
}

func startServer(accessory: Accessory, store: any HAPStore = InMemoryHAPStore(), advertiser: RecordingAdvertiser = RecordingAdvertiser(),
                 timings: HAPServerTimings = .fastTests, advertise: Bool = true,
                 transport: any NetworkTransport = AppleNetworkTransport()) async throws -> RunningServer {
    let configuration = AccessoryServerConfiguration(port: 0, advertise: advertise, serviceName: "CameraBridge Test", loopbackOnly: true)
    let server = AccessoryServer(accessory: accessory, configuration: configuration, store: store, transport: transport,
                                 advertiser: advertiser)
    await server.setTimings(timings)
    try await server.start()
    let port = try #require(await server.port)
    let code = try await server.setupCode.formatted
    let identity = try #require(try store.loadIdentity())
    let pairing = HAPTestClient.Pairing(accessoryPairingID: identity.deviceID.description,
                                        accessoryLongTermPublicKey: try HAPLongTermKey(rawRepresentation: identity.longTermKey).publicKey)
    return RunningServer(accessory: accessory, server: server, store: store, advertiser: advertiser, port: port, setupCode: code,
                         accessoryPairing: pairing)
}

/// `{"aid":…,"iid":…,…}` item for PUT /characteristics.
func writeItem(_ aid: UInt64, _ characteristic: Characteristic, value: HAPJSON? = nil, ev: Bool? = nil, r: Bool? = nil) -> HAPJSON {
    var pairs: [(String, HAPJSON)] = [("aid", .int(Int64(aid))), ("iid", .int(Int64(characteristic.iid)))]
    if let value { pairs.append(("value", value)) }
    if let ev { pairs.append(("ev", .bool(ev))) }
    if let r { pairs.append(("r", .bool(r))) }
    return .object(HAPJSONObject(pairs))
}

/// Types a JSON literal (`hapJSON(["a": 1])`).
func hapJSON(_ value: HAPJSON) -> HAPJSON { value }

/// `base`, whose accepted connections report `zone` (a HAP connection over IPv6 link-local, without one on lo0's ::1).
final class ZonedTransport: NetworkTransport {
    let base: any NetworkTransport
    let zone: String

    init(base: any NetworkTransport, zone: String) {
        self.base = base
        self.zone = zone
    }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        ZonedListener(base: try await base.listen(port: port, loopbackOnly: loopbackOnly), zone: zone)
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await base.connect(host: host, port: port, timeout: timeout)
    }
}

final class ZonedListener: TCPListener {
    let base: any TCPListener
    let connections: AsyncStream<any TCPConnection>

    init(base: any TCPListener, zone: String) {
        self.base = base
        let (stream, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
        connections = stream
        let forward = Task {
            for await connection in base.connections { continuation.yield(ZonedConnection(base: connection, zone: zone)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in forward.cancel() }
    }

    var port: UInt16 { base.port }
    func close() { base.close() }
}

final class ZonedConnection: TCPConnection {
    let base: any TCPConnection
    let zone: String?

    init(base: any TCPConnection, zone: String) {
        self.base = base
        self.zone = zone
    }

    var id: UUID { base.id }
    var localAddress: String { base.localAddress }
    var remoteAddress: String { base.remoteAddress }
    var isIPv6: Bool { base.isIPv6 }
    func receive(maximumLength: Int) async throws -> Data? { try await base.receive(maximumLength: maximumLength) }
    func send(_ data: Data) async throws { try await base.send(data) }
    func close() { base.close() }
}
#endif
