import Foundation
import MediaCore

/// The engine's one handle on the NVR: `BridgeEngine` calls these methods at its hook points and nothing else of the NVR (the hooks are the
/// only NVR code in BridgeEngine.swift). The store (task T02) and the recorders (task T01) are behind it. Final after the first NVR commit:
/// later tasks fill `ArchiveStore` and `RecorderHost`, not this file.
final class NVRCoordinator: Sendable {
    let store: ArchiveStore
    let recorders: RecorderHost
    /// What `BridgeEngine.archive` returns: the store, or the preview engine's synthetic archive.
    let reader: any ArchiveReading

    /// `previewArchive`: a preview engine's synthetic archive (never started, nothing records).
    init(environment: BridgeEnvironment, signal: ChangeSignal, previewArchive: (any ArchiveReading)? = nil) {
        let store = ArchiveStore(environment: environment, signal: signal)
        self.store = store
        recorders = RecorderHost(target: store, environment: environment, signal: signal)
        reader = previewArchive ?? store
    }

    /// Engine start. Returns at once whatever the drive does (the store loads in the background; recorders attach through `attach`
    /// and wait for `isReady`): the daemon awaits `engine.start()` before it listens and says READY.
    func start(settings: BridgeSettings) {
        store.start(settings: settings)
    }

    /// Engine stop or pause: recorders are detached first (`detachAll`), then this stops the store.
    func stop() async {
        await store.stop()
    }

    func settingsChanged(from old: BridgeSettings, to new: BridgeSettings) async {
        guard old.nvrFolder != new.nvrFolder || old.nvrKeepDays != new.nvrKeepDays || old.nvrMaxSizeGB != new.nvrMaxSizeGB else { return }
        await store.settingsChanged(from: old, to: new)
    }

    /// A runtime started (or was added) for `camera`. Does nothing unless Record is on.
    func attach(_ camera: CameraConfiguration, hub: MediaHub) async {
        guard camera.nvrEnabled else { return }
        await recorders.attach(camera, hub: hub)
    }

    func detach(_ cameraID: UUID) async {
        await recorders.detach(cameraID)
    }

    func detachAll() async {
        await recorders.detachAll()
    }

    /// `setNVR` changed `camera` while its runtime runs: Record on starts a recorder, off stops it, and a changed sound switch replaces it
    /// (stop, then a new recorder on the same hub).
    func apply(_ camera: CameraConfiguration, previous: CameraConfiguration, hub: MediaHub) async {
        if !camera.nvrEnabled {
            await recorders.detach(camera.id)
        } else if !previous.nvrEnabled || previous.nvrRecordSound != camera.nvrRecordSound {
            await recorders.detach(camera.id)
            await recorders.attach(camera, hub: hub)
        }
    }

    /// `CameraStatus.nvr` for `camera`. `folderChosen`: `BridgeSettings.nvrFolder != nil`.
    func status(for camera: CameraConfiguration, folderChosen: Bool) -> CameraArchiveStatus {
        guard camera.nvrEnabled else { return CameraArchiveStatus() }
        guard folderChosen else { return CameraArchiveStatus(state: .paused(.noFolder)) }
        return recorders.status(for: camera.id) ?? CameraArchiveStatus(state: .waiting("waiting for the camera"))
    }

    func storageStatus() -> ArchiveStorageStatus? {
        store.storageStatus
    }
}
