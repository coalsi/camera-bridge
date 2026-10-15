import Foundation

/// What the single-camera viewer opens on: a time to show (nil: live) and whether it plays from there. The NVR page opens a tile at its shared
/// position this way; the viewer is re-created when the window changes, so `AppModel.expandedStart` outlives the view and is cleared only with the viewer.
nonisolated struct ViewerStart: Equatable, Sendable {
    var time: Date?
    var playing: Bool
}
