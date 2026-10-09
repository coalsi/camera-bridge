import BridgeEngine
import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import HAP
import HAPCamera
import HAPCore
import HDS
import MediaCore
import RTP
import RTSP
import TestSupport
import Testing
#if os(macOS)
import CoreMedia
import CoreVideo
import PlatformApple
#endif

// Compile-time mirror of docs/superpowers/plans/2026-09-30-camerabridge-contracts.md.
// The functions below are never executed: they only have to type-check, so any rename, label change, type change,
// or lost async/throws in a contract symbol breaks this test target. Update it together with docs/CONTRACT_CHANGES.md.

@Test func contractSurfaceTypeChecks() {
    // Referencing the functions keeps them from being flagged as unused; they are never called.
    var checks: [@Sendable () async throws -> Void] = [
        bridgeSupportSurface, hapCoreSurface, hapSurface, hdsSurface, hapCameraSurface, mediaCoreSurface, fmp4Surface,
        rtpSurface, rtspSurface, cameraAdaptersSurface,
    ]
    #if os(macOS)
    checks.append(platformAppleSurface)
    #expect(checks.count == 11)
    #else
    #expect(checks.count == 10)
    #endif
}

// MARK: - Protocol conformances (requirements must match exactly)

private final class SurfaceSink: LogSink { func record(_ entry: LogEntry) {} }

private final class SurfaceSession: HAPSessionHandle {
    var id: UUID { UUID() }
    var controllerID: String { "" }
    var isAdmin: Bool { true }
    var sharedSecret: Data { Data() }
    var localAddress: String { "" }
    var remoteAddress: String { "" }
    var isIPv6: Bool { false }
    func onClose(_ handler: @escaping @Sendable () -> Void) {}
}

private final class SurfaceHAPStore: HAPStore, SecretStore {
    func loadIdentity() throws -> HAPIdentity? { nil }
    func saveIdentity(_ identity: HAPIdentity) throws {}
    func loadState() throws -> HAPPersistentState? { nil }
    func saveState(_ state: HAPPersistentState) throws {}
    func deleteAll() throws {}
    func read(account: String) throws -> Data? { nil }
    func write(_ data: Data?, account: String) throws {}
}

private final class SurfaceConnection: TCPConnection {
    var id: UUID { UUID() }
    var localAddress: String { "" }
    var remoteAddress: String { "" }
    var isIPv6: Bool { false }
    func receive(maximumLength: Int) async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() {}
}

private final class SurfaceListener: TCPListener {
    var port: UInt16 { 0 }
    var connections: AsyncStream<any TCPConnection> { AsyncStream { $0.finish() } }
    func close() {}
}

private final class SurfaceTransport: NetworkTransport {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { SurfaceListener() }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { SurfaceConnection() }
}

private final class SurfaceAdvertisedService: AdvertisedService {
    func updateTXT(_ txt: [String: String]) async throws {}
    var failures: AsyncStream<TransportError> { AsyncStream { $0.finish() } }
    func cancel() {}
}

private struct SurfaceAdvertiser: ServiceAdvertiser {
    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService { SurfaceAdvertisedService() }
}

private struct SurfaceNetworkChanges: NetworkChangeMonitoring {
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Implements exactly the contract's requirements: a requirement added to a contract protocol needs a default
/// implementation (`endBackgroundActivity()`), or conformers written to the contract stop compiling.
private struct SurfacePower: PowerManaging {
    func beginBackgroundActivity(reason: String) {}
    func setKeepSystemAwake(_ awake: Bool, reason: String) {}
}

private struct SurfaceDecodedFrame: DecodedVideoFrame {
    var width: Int { 0 }
    var height: Int { 0 }
    var pts: MediaTime { .seconds(0) }
    func grayThumbnail(maxWidth: Int) -> GrayImage? { nil }
}

private final class SurfaceDecoder: VideoDecoding {
    func decode(_ frame: EncodedVideoFrame) async throws -> (any DecodedVideoFrame)? { SurfaceDecodedFrame() }
    func invalidate() {}
}

private final class SurfaceEncoder: VideoEncoding {
    func encode(_ frame: any DecodedVideoFrame, wallClock: Date, forceKeyframe: Bool) async throws -> [EncodedVideoFrame] { [] }
    func invalidate() {}
}

private final class SurfaceTranscoder: VideoTranscoding {
    func transcode(_ frame: EncodedVideoFrame) async throws -> [EncodedVideoFrame] { [] }
    func requestKeyframe() {}
    func updateBitrate(kbps: Int) {}
    func invalidate() {}
}

private final class SurfaceAudioTranscoder: AudioTranscoding {
    var outputFormat: AudioFormat { AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1) }
    func transcode(_ frame: EncodedAudioFrame) throws -> [EncodedAudioFrame] { [] }
    func flush() throws -> [EncodedAudioFrame] { [] }
}

private struct SurfaceCodecs: MediaCodecs {
    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { SurfaceDecoder() }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { SurfaceEncoder() }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { SurfaceTranscoder() }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { SurfaceAudioTranscoder() }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { Data() }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { jpeg }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] { [] }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                             audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource { SurfaceSource() }
}

private final class SurfaceStreaming: CameraStreamingDelegate {
    func snapshot(_ request: SnapshotRequest) async throws -> Data { Data() }
    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        let srtp = SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: Data(), masterSalt: Data())
        return PrepareStreamResponse(accessoryAddress: "", videoPort: 0, audioPort: 0, videoSSRC: 0, audioSSRC: 0, videoSRTP: srtp, audioSRTP: srtp)
    }
    func handleStreamRequest(_ request: StreamRequest) async throws {}
}

private final class SurfaceRecording: CameraRecordingDelegate {
    func updateRecordingActive(_ active: Bool) async {}
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async {}
    func updateRecordingAudioActive(_ active: Bool) async {}
    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error> { AsyncThrowingStream { $0.finish() } }
    func acknowledgeStream(streamID: Int) async {}
    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async {}
}

private final class SurfaceSource: MediaSource {
    var displayName: String { "" }
    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> { AsyncThrowingStream { $0.finish() } }
    func stop() async {}
}

private struct SurfaceEvents: CameraEventSource {
    func events() -> AsyncStream<CameraEvent> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private struct SurfaceTalkback: TalkbackSink {
    var inputFormat: AudioFormat { AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1) }
    func open() async throws {}
    func send(_ frame: EncodedAudioFrame) async throws {}
    func close() async {}
}

private struct SurfaceDriver: CameraDriver {
    var vendor: CameraVendor { .rtsp }
    func probe() async throws -> CameraProbeResult {
        CameraProbeResult(vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "")
    }
    func makeEventSource() -> (any CameraEventSource)? { SurfaceEvents() }
    func snapshot() async throws -> Data? { nil }
    func makeTalkbackSink() -> (any TalkbackSink)? { SurfaceTalkback() }
}

// MARK: - BridgeSupport

@Sendable private func bridgeSupportSurface() async throws {
    let _: [LogLevel] = LogLevel.allCases
    let entry = LogEntry(level: .info, category: "", message: "")
    let _: (UUID, Date, LogLevel, String, String, UUID?) = (entry.id, entry.date, entry.level, entry.category, entry.message, entry.cameraID)
    LogHub.addSink(SurfaceSink())
    let sinkToken: LogSinkToken = LogHub.addSink(SurfaceSink())
    LogHub.removeSink(sinkToken)
    LogHub.removeAllSinks()
    LogHub.minimumLevel = LogHub.minimumLevel
    let log = Log(category: "", cameraID: nil)
    log.debug(""); log.info(""); log.notice(""); log.warning(""); log.error("")
    let _: String = Redact.url(URL(filePath: "/"))
    let _: String = Redact.string("")
    var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), multiplier: 2, jitter: 0.2)
    let _: Duration = backoff.next()
    backoff.reset()
    var credentials = HTTPCredentials(username: "", password: "")
    credentials.username = credentials.password
    if var challenge = DigestChallenge.parse("") {
        challenge.realm = ""; challenge.nonce = ""; challenge.opaque = nil; challenge.algorithm = "MD5"; challenge.qop = []; challenge.stale = false
        var authenticator = DigestAuthenticator(credentials: credentials)
        let _: String = authenticator.authorization(for: challenge, method: "GET", uri: "/")
    }
    let _: String = BasicAuth.header(credentials)
    let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(10), allowSelfSignedTLS: true)
    let request = URLRequest(url: URL(filePath: "/"))
    let _: (Data, HTTPURLResponse) = try await client.data(for: request)
    let (_, body): (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) = try await client.stream(for: request)
    for try await _ in body {}
    client.invalidate()
    var headers = HTTPHeaders([("A", "B")])
    headers["A"] = nil
    headers.add("A", "B")
    let _: String? = headers["a"]
    let _: IndexingIterator<[(name: String, value: String)]> = headers.makeIterator()
    var requestHead = HTTPRequestHead(method: "GET", target: "/", version: "HTTP/1.1", headers: headers)
    requestHead.method = requestHead.target
    let _: (String, [URLQueryItem]) = (requestHead.path, requestHead.queryItems)
    var responseHead = HTTPResponseHead(version: "HTTP/1.1", status: 200, reason: "OK", headers: headers)
    responseHead.status = 204
    var parser = HTTPRequestParser(maxBodySize: 1 << 20)
    let _: [(head: HTTPRequestHead, body: Data)] = try parser.feed(Data())
    let _: Data = HTTPSerializer.response(status: 200, reason: nil, headers: headers, body: Data(), version: "HTTP/1.1")
    let _: Data = HTTPSerializer.request(requestHead, body: Data())
    let _: Data? = Data(hex: "")
    let _: String = Data().hexString
    var reader = ByteReader(Data())
    let _: (Int, Bool) = (reader.remaining, reader.isAtEnd)
    let _: UInt8 = try reader.readUInt8()
    let _: (UInt16, UInt16, UInt32) = (try reader.readUInt16BE(), try reader.readUInt16LE(), try reader.readUInt24BE())
    let _: (UInt32, UInt32, UInt64, UInt64) = (try reader.readUInt32BE(), try reader.readUInt32LE(), try reader.readUInt64BE(), try reader.readUInt64LE())
    let _: Data = try reader.readBytes(0)
    try reader.skip(0)
    var writer = ByteWriter()
    writer.write(UInt8(0)); writer.writeUInt16BE(0); writer.writeUInt16LE(0); writer.writeUInt24BE(0); writer.writeUInt32BE(0)
    writer.writeUInt32LE(0); writer.writeUInt64BE(0); writer.writeUInt64LE(0); writer.write(Data())
    let _: Data = writer.data
    let _: ByteError = .truncated(needed: 1, available: 0)
    let _: UInt64 = NTPTime.timestamp(for: Date())
    let _: Date = NTPTime.date(from: 0)
    let broadcaster = AsyncBroadcaster<Int>(bufferingNewest: 64)
    let _: AsyncStream<Int> = broadcaster.subscribe()
    broadcaster.yield(1)
    broadcaster.finish()
    let _: Int = broadcaster.subscriberCount

    // Platform service protocols
    let transport: any NetworkTransport = SurfaceTransport()
    let listener: any TCPListener = try await transport.listen(port: 0, loopbackOnly: true)
    let _: (UInt16, AsyncStream<any TCPConnection>) = (listener.port, listener.connections)
    listener.close()
    let connection: any TCPConnection = try await transport.connect(host: "127.0.0.1", port: 1, timeout: .seconds(1))
    let _: (UUID, String, String, Bool) = (connection.id, connection.localAddress, connection.remoteAddress, connection.isIPv6)
    let _: Data? = try await connection.receive(maximumLength: 1)
    try await connection.send(Data())
    connection.close()
    let _: [TransportError] = [.localNetworkDenied, .connectionRefused, .timedOut, .closed, .addressInUse, .failed("")]
    var advertisement = ServiceAdvertisement(name: "", type: "_hap._tcp", port: 0, txt: [:])
    advertisement.name = advertisement.type; advertisement.port = 1; advertisement.txt = ["c#": "1"]
    let advertisers: [any ServiceAdvertiser] = [NullServiceAdvertiser(), SurfaceAdvertiser()]
    let advertised: any AdvertisedService = try await advertisers[0].advertise(advertisement)
    try await advertised.updateTXT([:])
    let _: AsyncStream<TransportError> = advertised.failures
    advertised.cancel()
    let secrets: any SecretStore = InMemorySecretStore()
    let _: Data? = try secrets.read(account: "")
    try secrets.write(nil, account: "")
    let changes: any NetworkChangeMonitoring = NullNetworkChangeMonitor()
    let _: AsyncStream<Void> = changes.changes
    let power: any PowerManaging = NullPowerManager()
    power.beginBackgroundActivity(reason: "")
    power.endBackgroundActivity()
    power.setKeepSystemAwake(false, reason: "")
    var services = PlatformServices(transport: transport, advertiser: SurfaceAdvertiser(), secrets: secrets, networkChanges: SurfaceNetworkChanges(),
                                    power: SurfacePower())
    services.transport = SurfaceTransport(); services.advertiser = NullServiceAdvertiser(); services.secrets = SurfaceHAPStore()
    services.networkChanges = changes; services.power = power
    let _: (any NetworkTransport, any ServiceAdvertiser, any SecretStore, any NetworkChangeMonitoring, any PowerManaging) =
        (services.transport, services.advertiser, services.secrets, services.networkChanges, services.power)
}

// MARK: - HAPCore

@Sendable private func hapCoreSurface() async throws {
    var item = TLV8.Item(1, Data())
    item.type = 2; item.value = Data()
    let _: Data = TLV8.encode([item])
    let _: [TLV8.Item] = try TLV8.decode(Data())
    let _: [[TLV8.Item]] = TLV8.splitList([item], separator: 0xFF)
    let _: [TLV8Error] = [.truncated, .missing(1), .invalidLength(1)]
    var builder = TLVBuilder()
    builder.add(1, Data()); builder.add(1, uint8: 0); builder.add(1, uint16LE: 0); builder.add(1, uint32LE: 0); builder.add(1, uint64LE: 0)
    builder.add(1, float32LE: 0); builder.add(1, string: ""); builder.add(1, tlv: TLVBuilder()); builder.addSeparator()
    let _: ([TLV8.Item], Data) = (builder.items, builder.data)
    let reader = try TLVReader(Data())
    let other = TLVReader(items: [])
    let _: [TLV8.Item] = other.items
    let _: (Data?, [Data], UInt8?, UInt16?, UInt32?) = (reader.data(1), reader.all(1), reader.uint8(1), reader.uint16LE(1), reader.uint32LE(1))
    let _: (UInt64?, Float?, String?) = (reader.uint64LE(1), reader.float32LE(1), reader.string(1))
    let _: TLVReader? = try reader.nested(1)
    let _: Data = try reader.require(1)
    let _: Data = HAPCrypto.hkdfSHA512(inputKey: Data(), salt: "", info: "", outputByteCount: 32)
    let _: Data = HAPCrypto.hkdfSHA512(inputKey: Data(), salt: Data(), info: "", outputByteCount: 32)
    let _: (Data, Data) = (HAPCrypto.nonce(label: "PS-Msg05"), HAPCrypto.nonce(counter: 0))
    let _: Data = try HAPCrypto.chachaSeal(Data(), key: Data(), nonce: Data(), aad: Data())
    let _: Data = try HAPCrypto.chachaOpen(Data(), key: Data(), nonce: Data(), aad: Data())
    let server = SRPServer(username: "Pair-Setup", password: "", salt: nil, privateValue: nil)
    let _: (Data, Data, Data?) = (server.salt, server.publicKey, server.sessionKey)
    try server.setClientPublicKey(Data())
    let _: Data = try server.verifyClientProof(Data())
    let client = try SRPClient(username: "Pair-Setup", password: "", salt: Data(), serverPublicKey: Data(), privateValue: nil)
    let _: (Data, Data, Data, Bool) = (client.publicKey, client.proof, client.sessionKey, client.verifyServerProof(Data()))
    let _: [SRPError] = [.invalidPublicKey, .proofMismatch, .notReady]
    let deviceID: DeviceID = DeviceID("") ?? DeviceID.random()
    let _: String = deviceID.description
    let code: SetupCode = SetupCode("") ?? SetupCode.random()
    let _: (String, String, Bool, String) = (code.digits, code.formatted, code.isTrivial, code.description)
    let _: [AccessoryCategory] = [.other, .bridge, .sensor, .ipCamera, .videoDoorbell]
    let _: String = SetupPayload.uri(code: code, setupID: "", category: .ipCamera)
    let _: String = SetupPayload.setupHash(setupID: "", deviceID: deviceID)
    let _: String = SetupPayload.randomSetupID()
    let key = HAPLongTermKey()
    let restored = try HAPLongTermKey(rawRepresentation: key.rawRepresentation)
    let _: Data = restored.publicKey
    let _: Data = try key.signature(for: Data())
    let _: Bool = HAPLongTermKey.isValidSignature(Data(), for: Data(), publicKey: Data())
}

// MARK: - HAP

@Sendable private func hapSurface() async throws {
    let _: [HAPFormat] = [.bool, .uint8, .uint16, .uint32, .uint64, .int, .float, .string, .tlv8, .data]
    let permissions: HAPPermissions = [.pairedRead, .pairedWrite, .events, .additionalAuthorization, .timedWrite, .hidden, .writeResponse]
    let _: (UInt8, [String]) = (permissions.rawValue, permissions.jsonStrings)
    let _: [HAPUnit] = [.celsius, .percentage, .arcdegrees, .lux, .seconds]
    let value: HAPValue = .null
    let _: [HAPValue] = [.bool(true), .int(0), .uint(0), .float(0), .string(""), .data(Data())]
    let _: (Bool?, Int64?, Double?, String?, Data?) = (value.boolValue, value.intValue, value.doubleValue, value.stringValue, value.dataValue)
    let _: [HAPStatus] = [.success, .insufficientPrivileges, .serviceCommunicationFailure, .resourceBusy, .readOnly, .writeOnly,
                          .notificationNotSupported, .outOfResource, .operationTimedOut, .resourceDoesNotExist, .invalidValue,
                          .insufficientAuthorization, .notAllowedInCurrentState]
    let type = CharacteristicType(uuid: "22", name: "", format: .bool, permissions: permissions, unit: nil, minValue: nil, maxValue: nil,
                                  minStep: nil, validValues: nil, maxLength: nil)
    let _: (String, String, HAPFormat, HAPPermissions, HAPUnit?) = (type.uuid, type.name, type.format, type.permissions, type.unit)
    let _: (Double?, Double?, Double?, [Int]?, Int?, String) = (type.minValue, type.maxValue, type.minStep, type.validValues, type.maxLength, type.fullUUID)
    let _: [CharacteristicType] = [
        .motionDetected, .programmableSwitchEvent, .setupEndpoints, .selectedCameraRecordingConfiguration, .setupDataStreamTransport,
        .supportedDataStreamTransportConfiguration, .homeKitCameraActive, .recordingAudioActive, .statusActive, .statusFault, .statusTampered,
        .occupancyDetected, .currentAmbientLightLevel, .currentTemperature, .currentRelativeHumidity, .contactSensorState, .on, .mute, .volume,
        .name, .configuredName, .identify, .manufacturer, .model, .serialNumber, .firmwareRevision, .hardwareRevision, .version, .active,
        .streamingStatus, .supportedVideoStreamConfiguration, .supportedAudioStreamConfiguration, .supportedRTPConfiguration,
        .selectedRTPStreamConfiguration, .supportedCameraRecordingConfiguration, .supportedVideoRecordingConfiguration,
        .supportedAudioRecordingConfiguration, .eventSnapshotsActive, .cameraOperatingModeIndicator, .manuallyDisabled, .nightVision,
        .periodicSnapshotsActive, .thirdPartyCameraActive, .diagonalFieldOfView, .videoAnalysisActive, .statusLowBattery, .batteryLevel, .chargingState,
    ]
    let serviceType = ServiceType(uuid: "85", name: "", required: [type], optional: [])
    let _: (String, String, [CharacteristicType], [CharacteristicType]) = (serviceType.uuid, serviceType.name, serviceType.required, serviceType.optional)
    let _: [ServiceType] = [
        .accessoryInformation, .protocolInformation, .cameraRTPStreamManagement, .cameraRecordingManagement, .cameraOperatingMode,
        .dataStreamTransportManagement, .microphone, .speaker, .doorbell, .statelessProgrammableSwitch, .motionSensor, .occupancySensor,
        .lightSensor, .temperatureSensor, .humiditySensor, .contactSensor, .battery, .switch,
    ]
    let context = HAPRequestContext(session: SurfaceSession())
    let _: any HAPSessionHandle = context.session

    let characteristic = Characteristic(type, value: nil)
    let _: (CharacteristicType, UInt64, HAPValue) = (characteristic.type, characteristic.iid, characteristic.value)
    characteristic.validValuesOverride = characteristic.validValuesOverride
    characteristic.minValueOverride = characteristic.minValueOverride
    characteristic.maxValueOverride = characteristic.maxValueOverride
    characteristic.update(.bool(true), origin: nil)
    characteristic.sendEvent(.null)
    characteristic.onRead { (_: HAPRequestContext?) async throws(HAPStatus) -> HAPValue in .null }
    characteristic.onWrite { (_: HAPValue, _: HAPRequestContext) async throws(HAPStatus) -> HAPValue? in nil }
    let token: ObserverToken = characteristic.addObserver { (_: HAPValue, _: UUID?) in }
    characteristic.removeObserver(token)

    let service = Service(serviceType, name: nil, subtype: nil)
    let _: (ServiceType, String?, UInt64, [Characteristic]) = (service.type, service.subtype, service.iid, service.characteristics)
    service.isPrimary = service.isHidden
    service.isHidden = false
    let _: [Service] = service.linkedServices
    service.characteristic(type)
    let _: Characteristic? = service.existingCharacteristic(type)
    service.addLinkedService(service)

    var info = AccessoryInfo(name: "", manufacturer: "", model: "", serialNumber: "", firmwareRevision: "", hardwareRevision: nil)
    info.hardwareRevision = info.name
    var resource = HAPResourceRequest(type: "image", width: 0, height: 0, aid: nil, reason: nil)
    resource.reason = resource.width
    let accessory = Accessory(info: info, category: .ipCamera)
    let _: (AccessoryCategory, AccessoryInfo, UInt64, [Service], [Accessory], Service) =
        (accessory.category, accessory.info, accessory.aid, accessory.services, accessory.bridgedAccessories, accessory.informationService)
    accessory.addService(service)
    accessory.removeService(service)
    accessory.addBridgedAccessory(accessory)
    accessory.removeBridgedAccessory(accessory)
    accessory.onIdentify {}
    accessory.onResourceRequest { (_: HAPResourceRequest, _: HAPRequestContext) async throws(HAPStatus) -> Data in Data() }
    accessory.setReachable(true)

    var pairing = Pairing(identifier: "", publicKey: Data(), isAdmin: true)
    pairing.isAdmin = false
    var identity = HAPIdentity.generate()
    identity.setupID = ""
    let _: (DeviceID, Data, SetupCode) = (identity.deviceID, identity.longTermKey, identity.setupCode)
    var state = HAPPersistentState()
    state.pairings = [pairing]; state.configNumber = 1; state.configHash = ""; state.iids = [:]; state.nextIID = 2; state.aids = [:]
    state.nextAID = 2; state.extras = [:]
    let stores: [any HAPStore] = [InMemoryHAPStore(), FileHAPStore(directory: URL(filePath: "/"), secretStore: InMemorySecretStore(), account: "hap.x"),
                                  SurfaceHAPStore()]
    let _: [any HAPSecretStore] = [InMemorySecretStore(), SurfaceHAPStore()]

    var configuration = AccessoryServerConfiguration(port: 0, advertise: true, serviceName: "", loopbackOnly: false)
    configuration.port = 1; configuration.advertise = false; configuration.serviceName = ""; configuration.loopbackOnly = true
    let _: [AccessoryServerEvent] = [.listening(port: 0), .advertising, .advertisingFailed(message: "", localNetworkDenied: true),
                                     .paired(controllerID: ""), .unpaired, .sessionsChanged(count: 0)]
    let server = AccessoryServer(accessory: accessory, configuration: configuration, store: stores[0], transport: SurfaceTransport(),
                                 advertiser: NullServiceAdvertiser())
    try await server.start()
    await server.stop()
    let _: AsyncStream<AccessoryServerEvent> = server.events
    let _: (UInt16?, Bool, Int) = (await server.port, await server.isPaired, await server.sessionCount)
    let _: SetupCode = try await server.setupCode
    let _: String = try await server.setupURI
    let _: DeviceID = try await server.deviceID
    try await server.resetPairings()
    await server.configurationDidChange()
    try await server.store(extra: nil, forKey: "")
    let _: Data? = await server.extra(forKey: "")
}

// MARK: - HDS

@Sendable private func hdsSurface() async throws {
    var dictionary = HDSDictionary([("a", .null)])
    dictionary["a"] = .bool(true)
    let _: HDSValue? = dictionary["a"]
    let _: [(String, HDSValue)] = dictionary.pairs
    let _: [HDSValue] = [.null, .bool(true), .int(0), .float(0), .string(""), .data(Data()), .uuid(UUID()), .date(Date()),
                         .array([]), .dictionary(dictionary)]
    let _: Data = try HDSCodec.encode(.null)
    let _: HDSValue = try HDSCodec.decode(Data())
    let _: [HDSStatus] = [.success, .outOfMemory, .timeout, .headerError, .payloadError, .missingProtocol, .protocolSpecificError]
    let _: [HDSProtocolReason] = [.normal, .notAllowed, .busy, .cancelled, .unsupported, .unexpectedFailure, .timeout, .badData,
                                  .protocolError, .invalidConfiguration]
    var message = HDSMessage(kind: .event, protocolName: "dataSend", topic: "data", body: dictionary)
    message.kind = .request(id: 1)
    message.kind = .response(id: 1, status: .success)
    let _: (String, String, HDSDictionary) = (message.protocolName, message.topic, message.body)
    let keys: (accessoryToController: Data, controllerToAccessory: Data) =
        HDSFrameCodec.deriveKeys(sharedSecret: Data(), controllerKeySalt: Data(), accessoryKeySalt: Data())
    let _: Data = try HDSFrameCodec.encodePayload(message)
    let _: HDSMessage = try HDSFrameCodec.decodePayload(Data())
    let _: Data = try HDSFrameCodec.sealFrame(Data(), key: keys.accessoryToController, counter: 0)
    let _: Data = try HDSFrameCodec.openFrame(header: Data(), body: Data(), key: keys.controllerToAccessory, counter: 0)
    let server = DataStreamServer(transport: SurfaceTransport(), loopbackOnly: true)
    let prepared: (port: UInt16, accessoryKeySalt: Data) = try await server.prepareSession(controllerKeySalt: Data(), session: SurfaceSession())
    _ = prepared
    await server.setHandler(protocol: "dataSend") { (request: HDSMessage, connection: DataStreamConnection) async in
        let _: (UUID, UUID, Bool) = (connection.id, connection.hapSessionID, connection.isClosed)
        try? await connection.sendEvent(protocol: "dataSend", topic: "data", body: HDSDictionary())
        try? await connection.sendResponse(to: request, status: .success, body: HDSDictionary())
        let _: HDSMessage? = try? await connection.sendRequest(protocol: "dataSend", topic: "open", body: HDSDictionary(), timeout: .seconds(10))
        connection.onClose {}
        await connection.close()
    }
    await server.stop()
    let _: Int = await server.connectionCount
}

// MARK: - HAPCamera

@Sendable private func hapCameraSurface() async throws {
    let _: [H264Profile] = H264Profile.allCases
    let _: [H264Level] = H264Level.allCases
    var resolution = VideoResolution(1920, 1080, 30)
    resolution.fps = resolution.width + resolution.height
    let _: [StreamingAudioCodec] = [.pcmu, .pcma, .aacELD, .opus, .msbc, .amr, .amrWB]
    let _: Int = StreamingSampleRate.khz24.hertz
    let _: [RecordingAudioCodec] = [.aacLC, .aacELD]
    let _: Int = RecordingSampleRate.khz44_1.hertz
    let _: [SRTPCryptoSuite] = [.aesCm128HmacSha1_80, .aesCm256HmacSha1_80, .none]
    let srtp = SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: Data(), masterSalt: Data())
    let _: (SRTPCryptoSuite, Data, Data) = (srtp.suite, srtp.masterKey, srtp.masterSalt)
    let streaming = CameraStreamingOptions(resolutions: [resolution], profiles: [.main], levels: [.level3_1], audioCodecs: [(.opus, [.khz16, .khz24])],
                                           twoWayAudio: true, cryptoSuites: [.aesCm128HmacSha1_80])
    let _: ([VideoResolution], [H264Profile], [H264Level], Bool, [SRTPCryptoSuite]) =
        (streaming.resolutions, streaming.profiles, streaming.levels, streaming.twoWayAudio, streaming.cryptoSuites)
    let _: [(codec: StreamingAudioCodec, sampleRates: [StreamingSampleRate])] = streaming.audioCodecs
    let recording = CameraRecordingOptions(prebufferLengthMs: 4000, fragmentLengthMs: 4000, resolutions: [resolution], profiles: [.high],
                                           levels: [.level4_0], audioCodec: .aacLC, audioSampleRates: [.khz32], audioChannels: 1)
    let _: (Int, Int, [VideoResolution], [H264Profile], [H264Level], RecordingAudioCodec, [RecordingSampleRate], Int) =
        (recording.prebufferLengthMs, recording.fragmentLengthMs, recording.resolutions, recording.profiles, recording.levels,
         recording.audioCodec, recording.audioSampleRates, recording.audioChannels)
    let selected = CameraRecordingConfiguration(prebufferLengthMs: 4000, eventTriggers: RecordingEventTrigger.motion | RecordingEventTrigger.doorbell,
                                                fragmentLengthMs: 4000, videoProfile: .main, videoLevel: .level4_0, videoBitrateKbps: 2000,
                                                iFrameIntervalMs: 4000, resolution: resolution, audioCodec: .aacLC, audioChannels: 1,
                                                audioSampleRate: .khz32, audioMaxBitrateKbps: 24)
    let _: (Int, UInt64, Int, H264Profile, H264Level, Int, Int, VideoResolution) =
        (selected.prebufferLengthMs, selected.eventTriggers, selected.fragmentLengthMs, selected.videoProfile, selected.videoLevel,
         selected.videoBitrateKbps, selected.iFrameIntervalMs, selected.resolution)
    let _: (RecordingAudioCodec, Int, RecordingSampleRate, Int) = (selected.audioCodec, selected.audioChannels, selected.audioSampleRate, selected.audioMaxBitrateKbps)
    let snapshot = SnapshotRequest(width: 640, height: 360, reason: .event)
    let _: (Int, Int, SnapshotReason?) = (snapshot.width, snapshot.height, snapshot.reason)
    let prepare = PrepareStreamRequest(sessionID: UUID(), controllerAddress: "", isIPv6: false, controllerVideoPort: 0, controllerAudioPort: 0,
                                       videoSRTP: srtp, audioSRTP: srtp, localAddress: "")
    let _: (UUID, String, Bool, UInt16, UInt16, SRTPParameters, SRTPParameters, String) =
        (prepare.sessionID, prepare.controllerAddress, prepare.isIPv6, prepare.controllerVideoPort, prepare.controllerAudioPort,
         prepare.videoSRTP, prepare.audioSRTP, prepare.localAddress)
    let response = try await SurfaceStreaming().prepareStream(prepare)
    let _: (String, UInt16, UInt16, UInt32, UInt32, SRTPParameters, SRTPParameters) =
        (response.accessoryAddress, response.videoPort, response.audioPort, response.videoSSRC, response.audioSSRC, response.videoSRTP, response.audioSRTP)
    let video = SelectedVideoParameters(profile: .main, level: .level3_1, resolution: resolution, payloadType: 99, controllerSSRC: 0,
                                        maxBitrateKbps: 299, rtcpIntervalSeconds: 0.5, mtu: 1378)
    let _: (H264Profile, H264Level, VideoResolution, UInt8, UInt32, Int, Double, Int) =
        (video.profile, video.level, video.resolution, video.payloadType, video.controllerSSRC, video.maxBitrateKbps, video.rtcpIntervalSeconds, video.mtu)
    let audio = SelectedAudioParameters(codec: .opus, channels: 1, sampleRate: .khz24, packetTimeMs: 20, payloadType: 110, controllerSSRC: 0,
                                        maxBitrateKbps: 24, rtcpIntervalSeconds: 5, comfortNoisePayloadType: 13)
    let _: (StreamingAudioCodec, Int, StreamingSampleRate, Int, UInt8, UInt32, Int, Double, UInt8?) =
        (audio.codec, audio.channels, audio.sampleRate, audio.packetTimeMs, audio.payloadType, audio.controllerSSRC, audio.maxBitrateKbps,
         audio.rtcpIntervalSeconds, audio.comfortNoisePayloadType)
    let _: [StreamRequest] = [.start(sessionID: UUID(), video: video, audio: audio), .reconfigure(sessionID: UUID(), video: video), .stop(sessionID: UUID())]
    let packet = RecordingPacket(data: Data(), isLast: true)
    let _: (Data, Bool) = (packet.data, packet.isLast)
    let operating = CameraOperatingState(homeKitCameraActive: true, eventSnapshotsActive: true, periodicSnapshotsActive: true, recordingActive: true,
                                         recordingAudioActive: true, nightVision: nil, indicatorEnabled: nil)
    let _: (Bool, Bool, Bool, Bool, Bool, Bool?, Bool?) =
        (operating.homeKitCameraActive, operating.eventSnapshotsActive, operating.periodicSnapshotsActive, operating.recordingActive,
         operating.recordingAudioActive, operating.nightVision, operating.indicatorEnabled)
    let configuration = CameraControllerConfiguration(streamCount: 2, streaming: streaming, recording: recording, isDoorbell: true,
                                                      supportsNightVisionControl: false, supportsIndicatorControl: false)
    let _: (Int, CameraStreamingOptions, CameraRecordingOptions?, Bool, Bool, Bool) =
        (configuration.streamCount, configuration.streaming, configuration.recording, configuration.isDoorbell,
         configuration.supportsNightVisionControl, configuration.supportsIndicatorControl)
    let controller = CameraController(configuration: configuration, streamingDelegate: SurfaceStreaming(), recordingDelegate: SurfaceRecording(),
                                      dataStreamServer: DataStreamServer(transport: SurfaceTransport()))
    let accessory = Accessory(info: AccessoryInfo(name: "", manufacturer: "", model: "", serialNumber: "", firmwareRevision: ""), category: .videoDoorbell)
    await controller.install(on: accessory, server: AccessoryServer(accessory: accessory, configuration: AccessoryServerConfiguration(serviceName: ""),
                                                                     store: InMemoryHAPStore(), transport: SurfaceTransport(),
                                                                     advertiser: SurfaceAdvertiser()))
    controller.setMotionDetected(true)
    controller.ringDoorbell()
    controller.setStreamingAvailable(true)
    controller.setSensorStatus(active: true, fault: false, tampered: false)
    let _: (CameraOperatingState, AsyncStream<CameraOperatingState>, Service?, Int, Int) =
        (controller.operatingState, controller.operatingStateChanges, controller.motionService, controller.activeRecordingStreams, controller.activeLiveStreams)
}

// MARK: - MediaCore

@Sendable private func mediaCoreSurface() async throws {
    let _: [VideoCodec] = [.h264, .hevc]
    let _: [AudioCodec] = [.aac, .aacELD, .opus, .pcmu, .pcma, .linearPCM]
    var time = MediaTime(value: 0, timescale: 90_000)
    time.value = 1; time.timescale = 90_000
    let _: MediaTime = .seconds(1, timescale: 90_000)
    let _: (Double, MediaTime, MediaTime, MediaTime, Bool) = (time.seconds, time.converted(to: 48_000), time - time, time + time, time < time)
    var format = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [], profile: 0, profileCompatibility: 0, level: 0)
    format.parameterSets = []
    let _: (VideoCodec, Int, Int, UInt8, UInt8, UInt8) = (format.codec, format.width, format.height, format.profile, format.profileCompatibility, format.level)
    let _: VideoFormat? = VideoFormat.h264(sps: Data(), pps: Data())
    let _: VideoFormat? = VideoFormat.hevc(vps: Data(), sps: Data(), pps: Data())
    var audioFormat = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1, audioSpecificConfig: nil)
    audioFormat.audioSpecificConfig = Data()
    let _: (AudioCodec, Int, Int, Int) = (audioFormat.codec, audioFormat.sampleRate, audioFormat.channels, audioFormat.samplesPerFrame)
    let _: AudioFormat = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
    let videoFrame = EncodedVideoFrame(format: format, nalUnits: [], isKeyframe: true, pts: time, dts: nil, wallClock: Date())
    let _: (VideoFormat, [Data], Bool, MediaTime, MediaTime?, Date, Data, Data) =
        (videoFrame.format, videoFrame.nalUnits, videoFrame.isKeyframe, videoFrame.pts, videoFrame.dts, videoFrame.wallClock,
         videoFrame.lengthPrefixedData, videoFrame.annexBData)
    let audioFrame = EncodedAudioFrame(format: audioFormat, data: Data(), pts: time, sampleCount: 1024, wallClock: Date())
    let _: (AudioFormat, Data, MediaTime, Int, Date) = (audioFrame.format, audioFrame.data, audioFrame.pts, audioFrame.sampleCount, audioFrame.wallClock)
    let sample: MediaSample = .video(videoFrame)
    let _: Date = MediaSample.audio(audioFrame).wallClock
    let source: any MediaSource = SurfaceSource()
    let _: String = source.displayName
    let _: AsyncThrowingStream<MediaSample, any Error> = try await source.samples()
    await source.stop()
    let info = StreamInfo(url: URL(filePath: "/"), videoCodec: .h264, width: 1, height: 1, fps: 1, audioCodec: .aac, audioSampleRate: 1, audioChannels: 1)
    let _: (URL, VideoCodec?, Int?, Int?, Double?, AudioCodec?, Int?, Int?) =
        (info.url, info.videoCodec, info.width, info.height, info.fps, info.audioCodec, info.audioSampleRate, info.audioChannels)
    let _: [Data] = NALUnits.splitAnnexB(Data()) + NALUnits.splitLengthPrefixed(Data(), lengthSize: 4)
    let _: (UInt8, UInt8, Data) = (NALUnits.h264Type(Data()), NALUnits.hevcType(Data()), NALUnits.removeEmulationPrevention(Data()))
    if let sps = H264SPS.parse(Data()) {
        let _: (UInt8, UInt8, UInt8, Int, Int, Double?) = (sps.profileIDC, sps.constraintFlags, sps.levelIDC, sps.width, sps.height, sps.frameRate)
    }
    if let sps = HEVCSPS.parse(Data()) {
        let _: (Int, Int, UInt8, UInt8) = (sps.width, sps.height, sps.generalProfileIDC, sps.generalLevelIDC)
    }
    let _: [SubscriptionStart] = [.live, .nextKeyframe, .prebuffer(.seconds(4))]
    let hub = MediaHub(retention: .seconds(12))
    await hub.ingest(sample)
    let subscription: MediaSubscription = await hub.subscribe(from: .prebuffer(.seconds(4)), bufferLimit: 900)
    let _: AsyncStream<MediaSample> = subscription.samples
    subscription.cancel()
    let _: (VideoFormat?, AudioFormat?, EncodedVideoFrame?, Double?, Duration?, Int) =
        (await hub.videoFormat, await hub.audioFormat, await hub.lastKeyframe, await hub.measuredFrameRate, await hub.measuredGOPDuration, await hub.subscriberCount)
    await hub.discontinuity()
    var settings = VideoEncoderSettings(width: 1280, height: 720, fps: 30, bitrateKbps: 1000, profile: .main, level: .level4_0,
                                        keyframeInterval: .seconds(4), realtime: true)
    settings.profile = .high; settings.level = .auto
    let _: [VideoEncoderSettings.EncoderProfile] = [.baseline, .main, .high]
    let _: [VideoEncoderSettings.EncoderLevel] = [.level3_1, .level3_2, .level4_0, .level4_1, .level5_1, .auto]
    var audioSettings = AudioEncoderSettings(codec: .opus, sampleRate: 24_000, channels: 1, bitrate: nil)
    audioSettings.bitrate = 24_000
    var gray = GrayImage(width: 1, height: 1, pixels: [0])
    gray.pixels = [gray.pixels[0]]
    let _: (Int, Int) = (gray.width, gray.height)
    let codecs: any MediaCodecs = SurfaceCodecs()
    let decoder: any VideoDecoding = try codecs.makeVideoDecoder(format: format)
    let picture: (any DecodedVideoFrame)? = try await decoder.decode(videoFrame)
    decoder.invalidate()
    let encoder: any VideoEncoding = try codecs.makeVideoEncoder(settings: settings)
    if let picture {
        let _: (Int, Int, MediaTime, GrayImage?) = (picture.width, picture.height, picture.pts, picture.grayThumbnail(maxWidth: 320))
        let _: [EncodedVideoFrame] = try await encoder.encode(picture, wallClock: Date(), forceKeyframe: false)
        let _: Data = try codecs.jpeg(from: picture, maxWidth: nil, maxHeight: nil, quality: 0.8)
    }
    encoder.invalidate()
    let transcoder: any VideoTranscoding = try codecs.makeVideoTranscoder(output: settings)
    let _: [EncodedVideoFrame] = try await transcoder.transcode(videoFrame)
    transcoder.requestKeyframe()
    transcoder.updateBitrate(kbps: 1000)
    transcoder.invalidate()
    let audioTranscoder: any AudioTranscoding = try codecs.makeAudioTranscoder(input: audioFormat, output: audioSettings)
    let _: AudioFormat = audioTranscoder.outputFormat
    let _: [EncodedAudioFrame] = try audioTranscoder.transcode(audioFrame) + audioTranscoder.flush()
    let _: Data = try codecs.resizeJPEG(Data(), maxWidth: nil, maxHeight: nil)
    let _: [EncodedAudioFrame] = try codecs.silentAACFrames(duration: .seconds(1), sampleRate: 32_000, channels: 1, startPTS: time, wallClock: Date())
    let _: any MediaSource = codecs.makeSyntheticSource(displayName: "Demo Camera", width: 1280, height: 720, fps: 30, keyframeInterval: .seconds(2),
                                                        audio: .aac, audioSampleRate: 16_000)
    let _: Data = try await codecs.jpeg(fromKeyframe: videoFrame, maxWidth: nil, maxHeight: nil)
    let _: ([Int16], Data, [Int16], Data) = (G711.decodeMuLaw(Data()), G711.encodeMuLaw([]), G711.decodeALaw(Data()), G711.encodeALaw([]))
    let _: [MediaCodecError] = [.unsupported(""), .sessionFailed(0), .noFrame]
}

// MARK: - FMP4

@Sendable private func fmp4Surface() async throws {
    let format = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [])
    var configuration = FMP4Configuration(video: format, audio: nil, videoTimescale: 90_000, writeProducerReferenceTime: false)
    configuration.audio = AudioFormat(codec: .aac, sampleRate: 32_000, channels: 1)
    let _: (VideoFormat, Int32, Bool) = (configuration.video, configuration.videoTimescale, configuration.writeProducerReferenceTime)
    var muxer = try FMP4Muxer(configuration: configuration)
    let _: Data = muxer.initializationSegment()
    let _: Data = try muxer.fragment(video: [], audio: [])
    var fragmenter = GOPFragmenter(targetDuration: .seconds(4))
    let frame = EncodedVideoFrame(format: format, nalUnits: [], isKeyframe: true, pts: .seconds(0), wallClock: Date())
    let _: [(video: [EncodedVideoFrame], audio: [EncodedAudioFrame])] = fragmenter.push(.video(frame))
    let _: (video: [EncodedVideoFrame], audio: [EncodedAudioFrame])? = fragmenter.flush()
    let boxes: [MP4Box] = try MP4BoxReader.parse(Data())
    if let box = boxes.first { let _: (String, Int, Int, [MP4Box]) = (box.type, box.offset, box.size, box.children) }
}

// MARK: - RTP

@Sendable private func rtpSurface() async throws {
    var packet = RTPPacket(marker: false, payloadType: 99, sequenceNumber: 0, timestamp: 0, ssrc: 0, payload: Data())
    packet.csrcs = []; packet.extensionProfile = nil; packet.extensionData = nil; packet.marker = true
    let _: (UInt8, UInt16, UInt32, UInt32, Data) = (packet.payloadType, packet.sequenceNumber, packet.timestamp, packet.ssrc, packet.payload)
    let _: RTPPacket = try RTPPacket(parsing: packet.serialized())
    let _: Bool = RTPPacket.isRTCP(Data())
    let _: [RTCPPacket] = [.senderReport(ssrc: 0, ntp: 0, rtpTimestamp: 0, packetCount: 0, octetCount: 0), .receiverReport(ssrc: 0), .bye(ssrcs: []),
                           .pictureLossIndication(senderSSRC: 0, mediaSSRC: 0), .fullIntraRequest(senderSSRC: 0, mediaSSRC: 0), .other(type: 0)]
    let _: [RTCPPacket] = try RTCPPacket.parseCompound(Data())
    let _: Data = RTCPPacket.bye(ssrcs: []).serialized()
    let format = VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [])
    var h264 = H264Packetizer(payloadType: 99, ssrc: 0, maxPacketSize: 1200, initialSequence: 0)
    let _: [RTPPacket] = h264.packetize(EncodedVideoFrame(format: format, nalUnits: [], isKeyframe: true, pts: .seconds(0), wallClock: Date()), rtpTimestamp: 0)
    var audio = AudioPacketizer(codec: .opus, payloadType: 110, ssrc: 0, initialSequence: 0)
    let audioFrame = EncodedAudioFrame(format: AudioFormat(codec: .opus, sampleRate: 24_000, channels: 1), data: Data(), pts: .seconds(0), sampleCount: 480,
                                       wallClock: Date())
    let _: RTPPacket = audio.packetize(audioFrame, rtpTimestamp: 0)
    var srtp = try SRTPContext(masterKey: Data(), masterSalt: Data())
    let _: Data = try srtp.protectRTP(Data())
    let _: Data = try srtp.unprotectRTP(Data())
    let _: Data = try srtp.protectRTCP(Data())
    let _: Data = try srtp.unprotectRTCP(Data())
    let _: [SRTPError] = [.authenticationFailed, .malformed, .replay]
    var address = SocketAddress(host: "127.0.0.1", port: 0)
    address.port = 1; address.host = "::1"
    let _: String = address.description
    let socket = try UDPSocket.bind(host: nil, port: 0, ipv6: false)
    let _: UInt16 = socket.localPort
    try socket.send(Data(), to: address)
    let _: AsyncStream<(data: Data, from: SocketAddress)> = socket.datagrams
    socket.close()
    var videoParameters = LiveVideoParameters(payloadType: 99, ssrc: 0, srtpKey: Data(), srtpSalt: Data(), maxPacketSize: 1200, rtcpInterval: .milliseconds(500))
    videoParameters.srtp = (key: Data(), salt: Data())
    let _: (UInt8, UInt32, Int, Duration) = (videoParameters.payloadType, videoParameters.ssrc, videoParameters.maxPacketSize, videoParameters.rtcpInterval)
    let audioParameters = LiveAudioParameters(codec: .opus, payloadType: 110, ssrc: 0, srtpKey: Data(), srtpSalt: Data(), rtpClockRate: 24_000,
                                              packetTime: .milliseconds(20), rtcpInterval: .milliseconds(500))
    let _: (AudioCodec, UInt8, UInt32, (key: Data, salt: Data), Int, Duration, Duration) =
        (audioParameters.codec, audioParameters.payloadType, audioParameters.ssrc, audioParameters.srtp, audioParameters.rtpClockRate,
         audioParameters.packetTime, audioParameters.rtcpInterval)
    let _: [LiveStreamEndReason] = [.stopped, .controllerTimeout, .socketError(""), .sourceEnded]
    let session = LiveStreamSession(controller: address, videoPort: 0, audioPort: 0, videoSocket: socket, audioSocket: nil, video: videoParameters,
                                    audio: audioParameters, controllerTimeout: .seconds(30))
    await session.start(video: AsyncStream { $0.finish() }, audio: nil)
    await session.stop()
    let _: (AsyncStream<EncodedAudioFrame>, AsyncStream<Void>) = (session.returnAudio, session.keyframeRequests)
    let _: LiveStreamEndReason = await session.waitForEnd()
}

// MARK: - RTSP

@Sendable private func rtspSurface() async throws {
    var configuration = RTSPConfiguration(url: URL(filePath: "/"), credentials: nil, requestBackchannel: false, timeout: .seconds(10), userAgent: "CameraBridge/1.0")
    configuration.credentials = HTTPCredentials(username: "", password: "")
    let _: (URL, Bool, Duration, String) = (configuration.url, configuration.requestBackchannel, configuration.timeout, configuration.userAgent)
    let track = RTSPTrack(kind: .backchannel, control: "", payloadType: 0, encoding: "PCMU", clockRate: 8000, channels: 1, fmtp: [:])
    let _: [RTSPTrack.Kind] = [.video, .audio, .backchannel]
    let _: (String, UInt8, String, Int, Int, [String: String]) = (track.control, track.payloadType, track.encoding, track.clockRate, track.channels, track.fmtp)
    let client = RTSPClient(configuration: configuration, transport: SurfaceTransport())
    let info: RTSPSessionInfo = try await client.connect()
    let _: ([RTSPTrack], VideoFormat?, AudioFormat?, AudioFormat?) = (info.tracks, info.videoFormat, info.audioFormat, info.backchannelFormat)
    let _: AsyncThrowingStream<MediaSample, any Error> = try await client.play()
    try await client.sendBackchannel(EncodedAudioFrame(format: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1), data: Data(),
                                                       pts: .seconds(0), sampleCount: 160, wallClock: Date()))
    await client.close()
    let _: [RTSPError] = [.unauthorized, .notFound, .badStatus(0), .protocolError(""), .timeout, .noVideoTrack, .unsupportedCodec("")]
    let _: [any MediaSource] = [RTSPMediaSource(configuration: configuration, displayName: "", transport: SurfaceTransport()),
                                HTTPFLVMediaSource(url: URL(filePath: "/"), credentials: nil, displayName: "")]
    let sdp = try SDPSession.parse("")
    if let media = sdp.media.first {
        let _: (String, Int, [UInt8], [(String, String?)], String?) = (media.type, media.port, media.formats, media.attributes, media.direction)
    }
}

// MARK: - CameraAdapters

@Sendable private func cameraAdaptersSurface() async throws {
    let _: [CameraVendor] = CameraVendor.allCases
    let _: [DetectedObjectKind] = DetectedObjectKind.allCases
    let _: [CameraEvent] = [.motion(true), .object(.person, true), .doorbellPressed, .tamper(true), .dayNight(isNight: true),
                            .digitalInput(id: "", active: true), .temperature(celsius: 0), .humidity(percent: 0), .audioAlarm(true),
                            .eventChannel(connected: true), .authenticationFailed]
    let _: [CameraEventKind] = CameraEventKind.allCases
    var endpoint = CameraEndpoint(host: "", httpPort: 80, rtspPort: 554, onvifPort: nil, useHTTPS: false)
    endpoint.onvifPort = endpoint.httpPort
    let _: (String, Int, Bool) = (endpoint.host, endpoint.rtspPort, endpoint.useHTTPS)
    let driver: any CameraDriver = SurfaceDriver()
    let result = try await driver.probe()
    let _: (CameraVendor, String, String, String, String, StreamInfo?, StreamInfo?) =
        (result.vendor, result.manufacturer, result.model, result.serialNumber, result.firmware, result.mainStream, result.subStream)
    let capabilities = result.capabilities
    let _: (Set<CameraEventKind>, Bool, Bool, Bool, Bool, Bool) = (capabilities.events, capabilities.twoWayAudio, capabilities.isDoorbell,
                                                                   capabilities.snapshotAPI, capabilities.nightVisionControl, capabilities.indicatorControl)
    let _: CameraVendor = driver.vendor
    let _: Data? = try await driver.snapshot()
    if let events = driver.makeEventSource() {
        let _: AsyncStream<CameraEvent> = events.events()
        await events.stop()
    }
    if let talkback = driver.makeTalkbackSink() {
        let _: AudioFormat = talkback.inputFormat
        try await talkback.open()
        await talkback.close()
    }
    let made: any CameraDriver = CameraDrivers.make(vendor: .hikvision, endpoint: endpoint, credentials: nil, mainStreamURL: nil, subStreamURL: nil,
                                                    transport: SurfaceTransport())
    _ = made
    let _: CameraVendor? = await CameraDrivers.detectVendor(endpoint: endpoint, credentials: nil)
    let discovered: [DiscoveredCamera] = await ONVIFDiscovery.discover(timeout: .seconds(3))
    if let camera = discovered.first { let _: (String, String?, String?, [URL]) = (camera.host, camera.name, camera.hardware, camera.xAddrs) }
    let detector = SoftMotionDetector(sensitivity: 0.5, analysisWidth: 320)
    let _: Bool? = await detector.process(GrayImage(width: 320, height: 180, pixels: []), at: Date())
    let _: any Actor = detector
    let webhook = WebhookServer(port: 0, token: "", loopbackOnly: true, transport: SurfaceTransport())
    try await webhook.start()
    await webhook.stop()
    let _: AsyncStream<(cameraID: UUID, event: CameraEvent)> = webhook.events
}

// MARK: - PlatformApple (macOS only)

#if os(macOS)
@Sendable private func platformAppleSurface() async throws {
    let transport: any NetworkTransport = AppleNetworkTransport()
    let advertiser: any ServiceAdvertiser = DNSSDServiceAdvertiser()
    let secrets: any SecretStore = KeychainSecretStore(service: "com.coreysilvia.CameraBridge")
    let changes: any NetworkChangeMonitoring = NWPathNetworkChangeMonitor()
    let power: any PowerManaging = ApplePowerManager()
    let codecs: any MediaCodecs = AppleMediaCodecs()
    _ = (transport, advertiser, secrets, changes, power, codecs, KeychainSecretStore())
    var pixelBufferOut: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixelBufferOut)
    if let pixelBuffer = pixelBufferOut {
        let frame = PixelBufferFrame(pixelBuffer: pixelBuffer, pts: .seconds(0))
        let _: (CVPixelBuffer, MediaTime) = (frame.pixelBuffer, frame.pts)
        let _: any DecodedVideoFrame = frame
    }
    let _: CMVideoFormatDescription = try VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: []).makeFormatDescription()
    let _: CMAudioFormatDescription = try AudioFormat.aacLC(sampleRate: 32_000, channels: 1).makeFormatDescription()
    let _: PlatformServices = ApplePlatform.services()
}
#endif

// MARK: - BridgeEngine

@MainActor private func bridgeEngineSurface() async throws {
    let _: [CameraKind] = CameraKind.allCases
    let _: [MotionSource] = MotionSource.allCases
    var sensors = SensorOptions()
    sensors.person = true; sensors.vehicle = true; sensors.animal = true; sensors.package = true
    sensors.dayNight = true; sensors.digitalInputs = true; sensors.temperature = true; sensors.humidity = true
    var camera = CameraConfiguration(id: UUID(), name: "", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: ""), username: "")
    camera.mainStreamURL = nil; camera.subStreamURL = nil; camera.motionSource = .softMotion; camera.motionSensitivity = 0.5
    camera.motionHoldSeconds = 20; camera.sensors = sensors; camera.audioEnabled = true; camera.twoWayAudio = true; camera.hapPort = 0
    camera.isEnabled = true; camera.manufacturer = ""; camera.model = ""; camera.serialNumber = ""; camera.firmware = ""; camera.capabilities = nil
    let _: (UUID, String, CameraKind, CameraVendor, CameraEndpoint, String) = (camera.id, camera.name, camera.kind, camera.vendor, camera.endpoint, camera.username)
    var settings = BridgeSettings()
    settings.webhookEnabled = true; settings.webhookPort = 0; settings.webhookToken = ""; settings.keepMacAwake = true
    settings.sensorsBridgePort = 0; settings.logLevel = .debug; settings.basePort = 0
    let credentials = CredentialStore(secrets: InMemorySecretStore())
    let _: String? = try credentials.password(for: UUID())
    try credentials.setPassword(nil, for: UUID())
    let _: [ConnectionState] = [.idle, .connecting, .online, .offline(""), .disabled]
    let status = CameraStatus(id: UUID(), name: "", kind: .camera, vendor: .demo)
    let _: (UUID, String, CameraKind, CameraVendor, ConnectionState, Bool, String?, Bool, String, String, UInt16?) =
        (status.id, status.name, status.kind, status.vendor, status.connection, status.eventChannelConnected, status.videoSummary, status.isPaired,
         status.setupCode, status.setupURI, status.hapPort)
    let _: (Bool, Bool, Bool, Int, String?, Date?, String?) =
        (status.motionActive, status.recordingEnabled, status.recordingNow, status.liveViewers, status.lastEvent, status.lastEventDate, status.lastError)
    let bridgeStatus = SensorsBridgeStatus(isPaired: false, setupCode: "", setupURI: "", accessoryCount: 0)
    let _: (Bool, String, String, Int) = (bridgeStatus.isPaired, bridgeStatus.setupCode, bridgeStatus.setupURI, bridgeStatus.accessoryCount)
    let _: [EngineState] = [.stopped, .starting, .running, .paused, .failed("")]
    let _: [LocalNetworkAccess] = [.unknown, .granted, .denied]
    var environment = BridgeEnvironment(dataDirectory: URL(filePath: "/"),
                                        platform: PlatformServices(transport: SurfaceTransport(), advertiser: SurfaceAdvertiser(), secrets: SurfaceHAPStore(),
                                                                   networkChanges: SurfaceNetworkChanges(), power: SurfacePower()),
                                        codecs: SurfaceCodecs(), loopbackOnly: true, advertise: false)
    #if canImport(Darwin)   // the PlatformApple-backed factories
    environment = BridgeEnvironment.live()
    environment = .testing(directory: URL(filePath: "/"))
    #endif
    let _: (URL, PlatformServices, any MediaCodecs, Bool, Bool) =
        (environment.dataDirectory, environment.platform, environment.codecs, environment.loopbackOnly, environment.advertise)
    let engine = BridgeEngine(environment: environment)
    let _: BridgeEngine = BridgeEngine.preview()
    let _: (EngineState, [CameraStatus], [CameraConfiguration], SensorsBridgeStatus?, LocalNetworkAccess, [LogEntry], BridgeSettings) =
        (engine.state, engine.cameras, engine.configurations, engine.sensorsBridge, engine.localNetworkAccess, engine.recentLogs, engine.settings)
    await engine.start()
    await engine.stop()
    await engine.pause()
    await engine.resume()
    try await engine.updateSettings(settings)
    try await engine.addCamera(camera, password: nil)
    try await engine.updateCamera(camera, password: nil)
    await engine.removeCamera(id: camera.id)
    try await engine.resetPairing(cameraID: camera.id)
    try await engine.resetSensorsBridgePairing()
    let _: CameraProbeResult = try await engine.probeCamera(vendor: nil, endpoint: camera.endpoint, username: "", password: "", mainStreamURL: nil, subStreamURL: nil)
    let _: [DiscoveredCamera] = await engine.discoverCameras()
    let _: Data? = await engine.snapshot(cameraID: camera.id)
    let _: LocalNetworkAccess = await engine.checkLocalNetworkAccess(host: nil)
    await engine.triggerTestMotion(cameraID: camera.id)
    await engine.systemDidWake()
}

@MainActor @Test func bridgeEngineSurfaceTypeChecks() {
    let check: @MainActor () async throws -> Void = bridgeEngineSurface
    _ = check
}
