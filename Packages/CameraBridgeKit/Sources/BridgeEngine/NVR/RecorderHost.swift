import Foundation
import MediaCore
import Synchronization

/// The recorders of the cameras that have Record on, one `CameraArchiveRecorder` each (Mac spec 5). `NVRCoordinator` calls `attach` when a camera's
/// runtime starts (or Record turns on, or the sound switch changes), `detach` when it stops. A camera has at most one recorder: attaching again
/// replaces the old one (which is stopped first, so its file is closed before the new recorder replays the hub's newest group).
final class RecorderHost: Sendable {
    private let target: any ArchiveWriteTarget
    private let environment: BridgeEnvironment
    private let signal: ChangeSignal
    private let tuning: RecorderTuning
    private let recorders = Mutex<[UUID: CameraArchiveRecorder]>([:])
    /// One serial disk queue per camera, kept for the life of the host: a recorder that replaces another (the sound switch) queues its file behind
    /// everything the old one still has to do, so two files of one camera are never created at the same moment.
    private let queues = Mutex<[UUID: DispatchQueue]>([:])

    init(target: any ArchiveWriteTarget, environment: BridgeEnvironment, signal: ChangeSignal, tuning: RecorderTuning = .standard) {
        self.target = target
        self.environment = environment
        self.signal = signal
        self.tuning = tuning
    }

    /// Starts a recorder for `camera` on `hub` (its main stream). The caller has checked `camera.nvrEnabled`. Returns when the recorder has looked
    /// at the store and, if recording is possible, subscribed; the first file opens at the first keyframe once the store is ready. Does no disk I/O.
    func attach(_ camera: CameraConfiguration, hub: MediaHub) async {
        await detach(camera.id)
        let queue = queues.withLock { queues in
            if let existing = queues[camera.id] { return existing }
            let created = DispatchQueue(label: "CameraBridge.NVR.writer.\(camera.id.uuidString.prefix(8))", qos: .utility)
            queues[camera.id] = created
            return created
        }
        let recorder = CameraArchiveRecorder(camera: camera, hub: hub, target: target, codecs: environment.codecs,
                                             naming: environment.archivePolicy?.directoryNaming ?? .cameraName, signal: signal, tuning: tuning,
                                             writeQueue: queue)
        recorders.withLock { $0[camera.id] = recorder }
        await recorder.start()
        signal.notify()
    }

    /// Flushes and closes the camera's file and stops its recorder, within 3 s. A camera without a recorder is ignored.
    func detach(_ cameraID: UUID) async {
        guard let recorder = recorders.withLock({ $0.removeValue(forKey: cameraID) }) else { return }
        await recorder.stop()
        signal.notify()
    }

    func detachAll() async {
        let all = recorders.withLock { state -> [CameraArchiveRecorder] in
            defer { state.removeAll() }
            return Array(state.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for recorder in all { group.addTask { await recorder.stop() } }
        }
        signal.notify()
    }

    /// The camera's recorder, nil without one (tests feed it and wait on it).
    func recorder(for cameraID: UUID) -> CameraArchiveRecorder? {
        recorders.withLock { $0[cameraID] }
    }

    /// The recorder's status; nil when the camera has no recorder.
    func status(for cameraID: UUID) -> CameraArchiveStatus? {
        recorders.withLock { $0[cameraID] }?.status
    }
}
