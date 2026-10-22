import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCamera
import HAPCore
import HDS
import MediaCore
import Synchronization

/// The still Apple Home gets for a camera that is turned off (`MediaCodecs.cameraOffJPEG`): one JPEG per (name, size) asked for, made once
/// and kept (the newest few; Home asks for a handful of sizes). Safe to call from any thread.
final class CameraOffStill: Sendable {
    /// The sizes (and names) kept.
    static let capacity = 8

    private struct Key: Hashable {
        var name: String
        var width: Int
        var height: Int
    }

    /// Draws the picture (name, width, height); the codecs' `cameraOffJPEG`.
    typealias Make = @Sendable (_ cameraName: String, _ width: Int, _ height: Int) throws -> Data

    private let make: Make
    private let cache = Mutex<[(key: Key, jpeg: Data)]>([])

    init(make: @escaping Make) { self.make = make }

    convenience init(codecs: any MediaCodecs) {
        self.init { try codecs.cameraOffJPEG(cameraName: $0, width: $1, height: $2) }
    }

    /// The picture at exactly `width` × `height` (clamped to 16…4096), made on the first request of that size.
    func jpeg(cameraName: String, width: Int, height: Int) throws -> Data {
        let key = Key(name: cameraName, width: min(max(width, 16), 4_096), height: min(max(height, 16), 4_096))
        if let kept = cache.withLock({ $0.first { $0.key == key }?.jpeg }) { return kept }
        let made = try make(key.name, key.width, key.height)
        cache.withLock { kept in
            kept.removeAll { $0.key == key }
            kept.append((key, made))
            if kept.count > Self.capacity { kept.removeFirst(kept.count - Self.capacity) }
        }
        return made
    }
}

/// The camera's current name, shared with the delegate (a `Mutex` cannot be passed around by itself).
final class NameBox: Sendable {
    let value: Mutex<String>
    init(_ name: String) { value = Mutex(name) }
}

/// A camera that is turned off (`CameraConfiguration.isEnabled == false`) as Apple Home sees it. The camera is not contacted: no ingest, no
/// events, no recording, no AI. Only the HomeKit accessory stays up, on the camera's own port and in its own HAP store, so Home keeps the
/// camera (its room, its automations, its pairing) and shows:
/// - snapshots: the "Camera off" still (`CameraOffStill`) at the size Home asks for;
/// - live view: unavailable, the way an offline camera's is (`setStreamingAvailable(false)`; a request that comes anyway fails cleanly). The
///   still is not streamed as video: that needs the whole RTP pipeline for a picture that does not move;
/// - sensors: quiet. The controller is never registered on the event router, so no motion or doorbell reaches it, and its sensor status is
///   not active;
/// - HomeKit Secure Video: nothing is recorded (the recording delegate refuses every stream).
/// Turning the camera back on stops this and starts the camera's `CameraRuntime`, which brings the same accessory up again.
actor CameraOffAccessory {
    struct Dependencies: Sendable {
        var environment: BridgeEnvironment
        var tuning: EngineTuning
        var onChange: @Sendable () -> Void
    }

    private struct Stack: Sendable {
        var controller: CameraController
        var server: AccessoryServer
        var dataStream: DataStreamServer
        var events: AsyncStream<AccessoryServerEvent>
    }

    nonisolated let id: UUID
    nonisolated let configuration: CameraConfiguration
    private let dependencies: Dependencies
    private let store: FileHAPStore
    private let still: CameraOffStill
    private let name: NameBox
    private let log: Log
    private var stack: Stack?
    private var events: Task<Void, Never>?

    init(configuration: CameraConfiguration, dependencies: Dependencies) {
        id = configuration.id
        self.configuration = configuration
        self.dependencies = dependencies
        name = NameBox(configuration.name)
        log = Log(category: "Camera", cameraID: configuration.id)
        still = CameraOffStill(codecs: dependencies.environment.codecs)
        store = HAPStorage.store(for: configuration.id, dataDirectory: dependencies.environment.dataDirectory,
                                 secrets: dependencies.environment.platform.secrets)
    }

    /// The HAP port the accessory listens on (nil before `start`).
    var hapPort: UInt16? { get async { await stack?.server.port } }

    var controller: CameraController? { stack?.controller }

    /// Brings the accessory up on `port` (or the next free one, never in `reserved`) and returns the port.
    @discardableResult
    func start(port: UInt16, reserved: Set<UInt16>) async throws -> UInt16 {
        if let stack { return await stack.server.port ?? port }
        log.info("\(configuration.name) is turned off: only its HomeKit accessory runs, showing a \"Camera off\" picture")
        let environment = dependencies.environment
        let aspect = (try? AccessoryOptions.frozenAspect(in: store)) ?? .wide
        let size = AccessoryOptions.sourceSize(in: store)
        let controllerConfiguration = AccessoryOptions.controllerConfiguration(for: configuration, aspect: aspect, sourceWidth: size?.width,
                                                                                sourceHeight: size?.height, talkback: false)
        let delegate = Delegate(still: still, name: name)
        let bound = try await PortAllocator.bind(from: port, avoiding: reserved) { @Sendable [self] candidate in
            try await makeStack(port: candidate, configuration: controllerConfiguration, delegate: delegate)
        }
        stack = bound.value
        let serverEvents = bound.value.events
        let onChange = dependencies.onChange
        events = Task { for await _ in serverEvents { onChange() } }
        dependencies.onChange()
        return bound.port
    }

    func stop() async {
        events?.cancel()
        events = nil
        guard let stack else { return }
        self.stack = nil
        await stack.server.stop()
        await stack.dataStream.stop()
        dependencies.onChange()
    }

    /// The camera was renamed: later snapshots carry the new name.
    nonisolated func rename(_ newName: String) { name.value.withLock { $0 = newName } }

    private nonisolated func makeStack(port: UInt16, configuration controllerConfiguration: CameraControllerConfiguration,
                                       delegate: Delegate) async throws -> Stack {
        let environment = dependencies.environment
        let info = AccessoryOptions.accessoryInfo(for: configuration)
        let accessory = Accessory(info: info, category: configuration.kind == .doorbell ? .videoDoorbell : .ipCamera)
        let cameraID = configuration.id
        let dataStream = DataStreamServer(transport: environment.platform.transport, loopbackOnly: environment.loopbackOnly,
                                          log: Log(category: "HDS", cameraID: cameraID))
        let controller = CameraController(configuration: controllerConfiguration, streamingDelegate: delegate, recordingDelegate: delegate,
                                          dataStreamServer: dataStream, timings: dependencies.tuning.controller,
                                          log: Log(category: "camera", cameraID: cameraID))
        let server = AccessoryServer(accessory: accessory,
                                     configuration: AccessoryServerConfiguration(port: port, advertise: environment.advertise, serviceName: info.name,
                                                                                 loopbackOnly: environment.loopbackOnly),
                                     store: store, transport: environment.platform.transport, advertiser: environment.platform.advertiser,
                                     log: Log(category: "hap", cameraID: cameraID))
        await controller.install(on: accessory, server: server)
        let events = server.events
        do {
            try await server.start()
        } catch {
            await dataStream.stop()
            throw error
        }
        controller.setStreamingAvailable(false)
        controller.setSensorStatus(active: false, fault: false, tampered: false)
        return Stack(controller: controller, server: server, dataStream: dataStream, events: events)
    }

    /// The streaming and recording delegates of the off camera.
    final class Delegate: CameraStreamingDelegate, CameraRecordingDelegate {
        struct CameraOff: Error, CustomStringConvertible {
            var description: String { "the camera is turned off" }
        }

        private let still: CameraOffStill
        private let name: NameBox

        init(still: CameraOffStill, name: NameBox) {
            self.still = still
            self.name = name
        }

        func snapshot(_ request: SnapshotRequest) async throws -> Data {
            try still.jpeg(cameraName: name.value.withLock { $0 }, width: request.width, height: request.height)
        }

        func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse { throw CameraOff() }
        func handleStreamRequest(_ request: StreamRequest) async throws {
            if case .stop = request { return }
            throw CameraOff()
        }

        func updateRecordingActive(_ active: Bool) async {}
        func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async {}
        func updateRecordingAudioActive(_ active: Bool) async {}
        func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error> { throw CameraOff() }
        func acknowledgeStream(streamID: Int) async {}
        func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async {}
    }
}
