#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import HAPCore
import HDS
import Testing
@testable import HAP
@testable import HAPCamera
import TestSupport

/// A `CameraController` installed on an accessory whose `AccessoryServer` is not started: characteristic handlers are
/// driven directly (`handleWrite` / `handleRead`, as the server would after validation), and `DataStreamServer` listens
/// on 127.0.0.1 for the HDS tests.
struct CameraHarness {
    let accessory: Accessory
    let server: AccessoryServer
    let store: InMemoryHAPStore
    let controller: CameraController
    let streaming: FakeStreamingDelegate
    let recording: FakeRecordingDelegate
    let dataStreamServer: DataStreamServer
    let configuration: CameraControllerConfiguration

    static let info = AccessoryInfo(name: "Driveway", manufacturer: "CameraBridge", model: "Test", serialNumber: "CAM-1", firmwareRevision: "1.0")

    static let streamingOptions = CameraStreamingOptions(resolutions: [VideoResolution(1920, 1080, 30), VideoResolution(1280, 720, 30),
                                                                       VideoResolution(320, 240, 15)],
                                                         twoWayAudio: true)
    static let recordingOptions = CameraRecordingOptions(resolutions: [VideoResolution(1280, 720, 30), VideoResolution(1920, 1080, 30)])

    static func make(isDoorbell: Bool = false, recordingOptions: CameraRecordingOptions? = CameraHarness.recordingOptions,
                     twoWayAudio: Bool = true, nightVision: Bool = false, indicator: Bool = false, streamCount: Int = 2,
                     withRecordingDelegate: Bool = true, store: InMemoryHAPStore = InMemoryHAPStore(),
                     timings: CameraControllerTimings = .standard,
                     streaming: FakeStreamingDelegate = FakeStreamingDelegate(),
                     recording: FakeRecordingDelegate = FakeRecordingDelegate(),
                     dataStreamTransport: (any NetworkTransport)? = nil) async -> CameraHarness {
        var streamingOptions = Self.streamingOptions
        streamingOptions.twoWayAudio = twoWayAudio
        let configuration = CameraControllerConfiguration(streamCount: streamCount, streaming: streamingOptions, recording: recordingOptions,
                                                          isDoorbell: isDoorbell, supportsNightVisionControl: nightVision,
                                                          supportsIndicatorControl: indicator)
        let transport = PlatformNetworkTransport()
        let accessory = Accessory(info: info, category: isDoorbell ? .videoDoorbell : .ipCamera)
        let server = AccessoryServer(accessory: accessory, configuration: AccessoryServerConfiguration(port: 0, advertise: false,
                                                                                                        serviceName: "Driveway", loopbackOnly: true),
                                     store: store, transport: transport, advertiser: NullServiceAdvertiser())
        let dataStreamServer = DataStreamServer(transport: dataStreamTransport ?? transport, loopbackOnly: true)
        let controller = CameraController(configuration: configuration, streamingDelegate: streaming,
                                          recordingDelegate: withRecordingDelegate ? recording : nil,
                                          dataStreamServer: dataStreamServer, timings: timings)
        await controller.install(on: accessory, server: server)
        return CameraHarness(accessory: accessory, server: server, store: store, controller: controller, streaming: streaming,
                             recording: recording, dataStreamServer: dataStreamServer, configuration: configuration)
    }

    /// A store with one admin pairing: the camera's saved state is restored only while the accessory is paired.
    static func pairedStore() throws -> InMemoryHAPStore {
        let store = InMemoryHAPStore()
        var state = HAPPersistentState()
        state.pairings = [Pairing(identifier: UUID().uuidString, publicKey: Data(repeating: 0x42, count: 32), isAdmin: true)]
        try store.saveState(state)
        return store
    }

    func services(_ type: ServiceType) -> [Service] { accessory.services.filter { $0.type == type } }
    func service(_ type: ServiceType) -> Service? { services(type).first }

    var streamServices: [Service] { services(.cameraRTPStreamManagement) }

    /// The stream services' managers, in index order (test hooks).
    var streamManagements: [RTPStreamManagement] { controller.streamManagements }

    func characteristic(_ service: ServiceType, _ type: CharacteristicType) throws -> Characteristic {
        guard let found = self.service(service)?.existingCharacteristic(type) else { throw FixtureError(description: "missing \(type.name)") }
        return found
    }

    func stop() async {
        await dataStreamServer.stop()
    }
}

extension Characteristic {
    /// A controller write as the server performs it after validation.
    @discardableResult
    func write(_ value: HAPValue, as session: FakeHAPSession) async throws(HAPStatus) -> HAPValue? {
        try await handleWrite(value, context: session.context)
    }

    func read(as session: FakeHAPSession?) async throws(HAPStatus) -> HAPValue {
        try await handleRead(context: session?.context)
    }

    func readData(as session: FakeHAPSession?) async throws -> Data {
        guard let data = try await read(as: session).dataValue else { throw FixtureError(description: "\(type.name) is not data") }
        return data
    }
}

/// Runs `body` and returns the `HAPStatus` it throws (nil if it succeeds; any other error is a test failure).
func hapStatus(_ body: () async throws -> Void) async -> HAPStatus? {
    do {
        try await body()
        return nil
    } catch let status as HAPStatus {
        return status
    } catch {
        Issue.record("expected a HAPStatus, got \(error)")
        return nil
    }
}

enum CameraRequests {
    static let srtp = SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: Data((0..<16).map { UInt8($0) }),
                                     masterSalt: Data((0..<14).map { UInt8(100 + $0) }))

    static func setupEndpoints(id: UUID = UUID(), address: String = "192.168.1.20", isIPv6: Bool = false) -> CameraTLV.SetupEndpointsRequest {
        CameraTLV.SetupEndpointsRequest(sessionID: id, controllerAddress: address, isIPv6: isIPv6, videoPort: 51_000, audioPort: 51_002,
                                        videoSRTP: srtp, audioSRTP: srtp)
    }

    static let video = SelectedVideoParameters(profile: .main, level: .level4_0, resolution: VideoResolution(1280, 720, 30), payloadType: 99,
                                               controllerSSRC: 0xAAAA_0001, maxBitrateKbps: 299, rtcpIntervalSeconds: 0.5, mtu: 1378)
    static let audio = SelectedAudioParameters(codec: .opus, channels: 1, sampleRate: .khz24, packetTimeMs: 20, payloadType: 110,
                                               controllerSSRC: 0xAAAA_0002, maxBitrateKbps: 24, rtcpIntervalSeconds: 0.5,
                                               comfortNoisePayloadType: 13)

    static func selected(_ id: UUID, _ command: CameraTLV.SessionCommand, video: SelectedVideoParameters? = CameraRequests.video,
                         audio: SelectedAudioParameters? = CameraRequests.audio) -> Data {
        CameraTLV.SelectedRTPStreamConfiguration(sessionID: id, command: command, video: video, audio: audio).encoded
    }

    static let recordingSelection = CameraRecordingConfiguration(prebufferLengthMs: 4000, eventTriggers: RecordingEventTrigger.motion,
                                                                 fragmentLengthMs: 4000, videoProfile: .main, videoLevel: .level4_0,
                                                                 videoBitrateKbps: 2000, iFrameIntervalMs: 4000,
                                                                 resolution: VideoResolution(1920, 1080, 30), audioCodec: .aacLC,
                                                                 audioChannels: 1, audioSampleRate: .khz32, audioMaxBitrateKbps: 64)
}
#endif
