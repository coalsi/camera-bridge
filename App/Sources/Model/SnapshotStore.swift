import AppKit
import BridgeEngine
import Foundation
import Observation

/// Latest snapshot per camera, shared by the sidebar thumbnails and the camera hero so one fetch serves both. Views
/// ask for a refresh on a timer while visible (`refresh` ignores calls made sooner than `minimumInterval` after the
/// last successful fetch), so a busy camera is not polled by every row at once.
///
/// Fetching is not free: from a camera whose snapshot API does not answer, a picture is a decoded keyframe of its video
/// stream. The timers therefore run only while the manager window can be seen (`WindowActivity`): nothing is fetched
/// while it is hidden, minimised or covered, and a window that is on screen with another app in front is refreshed rarely
/// (`SnapshotRefreshPolicy`). A window that becomes visible again refreshes at once.
@MainActor
@Observable
final class SnapshotStore {
    static let shared = SnapshotStore()

    private(set) var images: [UUID: NSImage] = [:]
    private(set) var updatedAt: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []

    func image(for id: UUID) -> NSImage? { images[id] }

    /// Fetches the camera's snapshot unless one arrived less than `minimumInterval` seconds ago. A failed fetch keeps
    /// the last good picture.
    func refresh(cameraID: UUID, model: AppModel, minimumInterval: TimeInterval = 8) async {
        #if DEBUG
        // `-demoImages <folder>`: real pictures for the sample cameras (`driveway.jpg`, `front-door.jpg`, …: the camera's name in lower case with dashes).
        if let folder = UserDefaults.standard.string(forKey: "demoImages") {
            if images[cameraID] == nil {
                let name = model.engine.cameras.first { $0.id == cameraID }?.name.lowercased().replacingOccurrences(of: " ", with: "-") ?? ""
                if let image = NSImage(contentsOf: URL(fileURLWithPath: folder).appending(path: "\(name).jpg")) {
                    images[cameraID] = image
                    updatedAt[cameraID] = .now
                }
            }
            return
        }
        // `-previewSnapshots YES`: synthetic pictures in different aspect ratios (UI review of thumbnail and hero cropping).
        if UserDefaults.standard.bool(forKey: "previewSnapshots") {
            if let last = updatedAt[cameraID], Date.now.timeIntervalSince(last) < minimumInterval { return }
            images[cameraID] = Self.syntheticPicture(seed: model.engine.cameras.firstIndex { $0.id == cameraID } ?? 0)
            updatedAt[cameraID] = .now
            return
        }
        #endif
        await refresh(cameraID: cameraID, minimumInterval: minimumInterval) { await model.engine.snapshot(cameraID: cameraID) }
    }

    /// `refresh` with the fetch given (the picture's JPEG, nil when there is none).
    func refresh(cameraID: UUID, minimumInterval: TimeInterval, fetch: () async -> Data?) async {
        if let last = updatedAt[cameraID], Date.now.timeIntervalSince(last) < minimumInterval { return }
        guard inFlight.insert(cameraID).inserted else { return }
        defer { inFlight.remove(cameraID) }
        let data = await fetch()
        guard !Task.isCancelled, let decoded = data.flatMap({ NSImage(data: $0) }) else { return }
        images[cameraID] = decoded
        updatedAt[cameraID] = .now
    }

    /// Refreshes every `interval` while the calling task lives and the window can be seen (the first fetch happens at once).
    func keepFresh(cameraID: UUID, model: AppModel, interval: Duration, minimumInterval: TimeInterval,
                   activity: WindowActivity = .shared) async {
        await keepFresh(interval: interval, activity: activity) { [self] in
            await refresh(cameraID: cameraID, model: model, minimumInterval: minimumInterval)
        }
    }

    /// Runs `refresh` now and then every `interval` (`SnapshotRefreshPolicy.wait`) while the task lives, but only while
    /// `activity` says somebody can see the window: a hidden window waits (without polling) until it is visible again, then
    /// refreshes at once.
    func keepFresh(interval: Duration, activity: WindowActivity, refresh: () async -> Void) async {
        while !Task.isCancelled {
            await activity.waitUntilVisible()
            if Task.isCancelled { return }
            await refresh()
            guard let wait = SnapshotRefreshPolicy.wait(base: interval, state: activity.state) else { continue }
            try? await Task.sleep(for: wait)
        }
    }

    #if DEBUG
    /// A panorama (4256x1888), a 4:3 picture or a 16:9 one, with a camera-style timestamp in the top-left corner.
    private static func syntheticPicture(seed: Int) -> NSImage {
        let sizes = [NSSize(width: 4256, height: 1888), NSSize(width: 1600, height: 1200), NSSize(width: 1920, height: 1080)]
        let size = sizes[seed % sizes.count]
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.25, green: 0.38, blue: 0.5, alpha: 1), NSColor(calibratedRed: 0.1, green: 0.14, blue: 0.1, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(x: size.width * 0.1, y: 0, width: size.width * 0.12, height: size.height * 0.45).fill()
        NSRect(x: size.width * 0.7, y: 0, width: size.width * 0.2, height: size.height * 0.3).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size.height * 0.05, weight: .bold), .foregroundColor: NSColor.white]
        NSAttributedString(string: "06:29:30", attributes: attributes).draw(at: NSPoint(x: size.width * 0.02, y: size.height * 0.92))
        NSAttributedString(string: "CAM 1", attributes: attributes).draw(at: NSPoint(x: size.width * 0.02, y: size.height * 0.04))
        image.unlockFocus()
        return image
    }
    #endif
}
