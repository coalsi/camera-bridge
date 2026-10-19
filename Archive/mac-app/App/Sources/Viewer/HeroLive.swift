import AVFoundation
import AppKit
import BridgeEngine
import SwiftUI

/// The camera page hero's live view: holds the page's one feed, made when first asked for (it holds no stream until the
/// person presses play).
@MainActor
@Observable
final class HeroLiveState {
    @ObservationIgnored private var feed: LiveFeed?

    /// The feed for `cameraID`, made on first use: the main stream (or the chosen quality), muted.
    func feed(for cameraID: UUID, model: AppModel) -> LiveFeed {
        if let feed { return feed }
        let created = LiveFeed(cameraID: cameraID, stream: .automatic, wantsAudio: true, sink: LiveVideoRenderer(), open: model.liveVideoOpener)
        feed = created
        return created
    }

    /// Playing (or connecting): the snapshot's "Updated" label gives way to the LIVE chip.
    var isPlaying: Bool { feed?.isWanted ?? false }

    func stop() { feed?.stop() }
}

/// The live picture of the hero, over its snapshot and under its scrims, chips and controls. Aspect-fitted (the hero follows the
/// snapshot's shape), transparent until the first picture arrives.
struct HeroLiveVideo: View {
    let live: HeroLiveState
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus

    var body: some View {
        let feed = live.feed(for: cameraID, model: model)
        ZStack {
            if feed.hasPicture, !LiveVideoView.showsStillsInstead { Color.black }
            LiveVideoView(feed: feed, gravity: .resizeAspect)
                .opacity(feed.hasPicture && !LiveVideoView.showsStillsInstead ? 1 : 0)
            if feed.isWanted, status.connection == .online {
                LiveOverlayView(overlay: LiveOverlay.current(connection: status.connection, phase: feed.phase, isWanted: true))
            }
        }
        .animation(.easeOut(duration: 0.2), value: feed.hasPicture)
    }
}

/// The play button over the snapshot, and, while it plays, the LIVE chip, the quality menu, mute, the single-camera viewer
/// and stop. Playback ends when the page goes away, and is suspended while the window cannot be seen.
struct HeroLiveControls: View {
    let live: HeroLiveState
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus
    @AppStorage("heroQuality") private var quality: LiveQuality = .automatic
    private let activity = WindowActivity.shared

    var body: some View {
        let feed = live.feed(for: cameraID, model: model)
        ZStack {
            if !feed.isWanted, status.connection == .online {
                LiveIconButton(systemImage: "play.fill", label: "Play Live View", size: 68, isProminent: true) { feed.isWanted = true }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if feed.phase == .live { LiveChip().padding(16).transition(.opacity) }
        }
        .overlay(alignment: .bottomTrailing) {
            if feed.isWanted {
                HStack(spacing: 8) {
                    LiveQualityMenu(quality: $quality)
                    LiveIconButton(systemImage: feed.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   label: feed.isMuted ? "Turn Sound On" : "Mute", size: 34) { feed.isMuted.toggle() }
                    LiveIconButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Open Viewer", size: 34) {
                        feed.stop()
                        model.expandCamera(cameraID)
                    }
                    LiveIconButton(systemImage: "stop.fill", label: "Stop Live View", size: 34) { feed.stop() }
                }
                .padding(16)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: feed.isWanted)
        .onGeometryChange(for: Int.self, of: { Int($0.size.width * (NSScreen.main?.backingScaleFactor ?? 2)) }) { feed.displayWidth = $0 }
        .onChange(of: activity.isVisible, initial: true) { _, visible in feed.isSuspended = !visible }
        .onChange(of: quality, initial: true) { _, quality in feed.stream = quality.stream }
        .onDisappear { live.stop() }
        #if DEBUG
        // `-demoHeroLive YES` (UI review): the camera page starts playing by itself.
        .task {
            guard UserDefaults.standard.string(forKey: "demoHeroLive")?.uppercased() == "YES" else { return }
            try? await Task.sleep(for: .seconds(1))
            feed.isWanted = true
        }
        #endif
    }
}
