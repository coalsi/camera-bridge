import AVFoundation
import AppKit
import BridgeEngine
import SwiftUI

/// One camera live, filling the manager window: the main stream (or the quality the person chose), sound on request (muted at
/// first), a snapshot button that saves a JPEG, a link to the camera's page and Esc to leave. The picture is fitted with bars
/// in the app's dark colour; the snapshot fills in until the first live picture. Stops when the window cannot be seen.
struct SingleCameraViewer: View {
    let model: AppModel
    let cameraID: UUID
    @State private var feed: LiveFeed
    @AppStorage("viewerQuality") private var quality: LiveQuality = .main
    private let activity = WindowActivity.shared
    private let store = SnapshotStore.shared

    init(model: AppModel, cameraID: UUID) {
        self.model = model
        self.cameraID = cameraID
        // The viewer is large: `displayWidth` keeps the main stream under `.automatic`.
        _feed = State(initialValue: LiveFeed(cameraID: cameraID, stream: .main, wantsAudio: true, displayWidth: 3_000, sink: LiveVideoRenderer(),
                                             open: model.liveVideoOpener))
    }

    var body: some View {
        let status = model.status(for: cameraID)
        ZStack {
            Brand.canvas
            if let image = store.image(for: cameraID) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let status {
                SnapshotPlaceholder(kind: status.kind, glyphSize: 80)
            }
            LiveVideoView(feed: feed, gravity: .resizeAspect)
                .opacity(feed.hasPicture && !LiveVideoView.showsStillsInstead ? 1 : 0)
            if let status {
                LiveOverlayView(overlay: LiveOverlay.current(connection: status.connection, phase: feed.phase, isWanted: feed.isWanted))
            }
        }
        .overlay(alignment: .top) { controls(status: status) }
        .background {
            // Esc leaves the viewer.
            Button("Close Viewer") { model.closeExpandedCamera() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.2), value: feed.phase)
        .onAppear {
            feed.isWanted = true
            #if DEBUG
            // `-demoUnmute YES` (UI review): the viewer starts with the sound on.
            if UserDefaults.standard.string(forKey: "demoUnmute")?.uppercased() == "YES" { feed.isMuted = false }
            #endif
        }
        .onDisappear { feed.stop() }
        .onChange(of: activity.isVisible, initial: true) { _, visible in feed.isSuspended = !visible }
        .onChange(of: quality, initial: true) { _, quality in feed.stream = quality.stream }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(status?.name ?? "") live view"))
    }

    private func controls(status: CameraStatus?) -> some View {
        HStack(spacing: 10) {
            LiveIconButton(systemImage: "xmark", label: "Close Viewer") { model.closeExpandedCamera() }
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.name ?? "")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let address = model.configuration(for: cameraID)?.displayAddress {
                    Text(address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.leading, 4)
            if feed.phase == .live { LiveChip().transition(.opacity) }
            Spacer(minLength: 12)
            if let status, let caption = LiveQuality.caption(stream: feed.activeStream, status: status) {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            LiveQualityMenu(quality: $quality)
            LiveIconButton(systemImage: feed.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: feed.isMuted ? "Turn Sound On" : "Mute") {
                feed.isMuted.toggle()
            }
            LiveIconButton(systemImage: "camera.fill", label: "Save Snapshot…") { Task { await saveSnapshot() } }
            Button {
                model.openCameraPage(cameraID)
            } label: {
                Label("Open Camera Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glass(in: Capsule(), interactive: true)
            LiveIconButton(systemImage: "arrow.up.left.and.arrow.down.right.square", label: "Full Screen") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(alignment: .top) {
            // Keeps the controls legible over any picture.
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    /// The picture on screen as a JPEG in a save panel (Downloads first); before the first live picture, the last snapshot.
    private func saveSnapshot() async {
        var data: Data?
        if let renderer = feed.sink as? LiveVideoRenderer, let picture = renderer.displayedPicture() {
            data = SnapshotSaver.jpegData(from: picture)
        } else if let image = store.image(for: cameraID) {
            data = SnapshotSaver.jpegData(from: image)
        }
        guard let data else {
            model.message = AppMessage(title: String(localized: "No Picture Yet"), detail: String(localized: "Wait for the camera’s picture to appear, then try again."))
            return
        }
        let name = SnapshotFileName.make(cameraName: model.status(for: cameraID)?.name ?? "", date: .now)
        do {
            _ = try await SnapshotSaver.save(data, suggestedName: name)
        } catch {
            model.message = AppMessage(title: String(localized: "Couldn’t Save the Picture"), detail: error.localizedDescription)
        }
    }
}
