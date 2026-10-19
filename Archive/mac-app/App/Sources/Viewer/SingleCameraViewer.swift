import AVFoundation
import AppKit
import BridgeEngine
import SwiftUI

/// One camera in the manager's detail column (the sidebar and the banners stay usable): the control bar, the picture, and the timeline below it.
/// Live video on top of a scrubbable timeline of what was recorded. The picture is the main stream (or the quality the person chose), sound on request
/// (muted at first), with a snapshot button, a link to the camera's page and Esc to leave. Scrub or play and the same renderer shows the recording;
/// Go Live comes back to the live picture, with no blank frame in between. Stops when the window cannot be seen.
struct SingleCameraViewer: View {
    let model: AppModel
    let cameraID: UUID
    @State private var panel: NVRPanelModel
    @AppStorage("viewerQuality") private var quality: LiveQuality = .main
    private let activity = WindowActivity.shared
    private let store = SnapshotStore.shared

    init(model: AppModel, cameraID: UUID) {
        self.model = model
        self.cameraID = cameraID
        let session = NVRSession(archive: model.archive, clock: PlaybackClock(), makeSink: { LiveVideoRenderer() }, now: { ProcessInfo.processInfo.systemUptime },
                                 sleep: CellPlayback.systemSleep, liveOpener: model.liveVideoOpener, liveStream: .main)
        session.wantsAudio = true   // before the cell is made: the feed then reads the camera's sound
        _panel = State(initialValue: NVRPanelModel(archive: model.archive, session: session, defaults: model.preferences, clipExport: model.clipExport))
    }

    var body: some View {
        let status = model.status(for: cameraID)
        let session = panel.session
        let cell = session.cell(for: cameraID)
        VStack(spacing: 0) {
            controls(status: status, cell: cell)
            stage(status: status, cell: cell)
            NVRTimelinePanel(panel: panel) {
                RecordSwitch(model: model, cameraID: cameraID, status: status)
            }
        }
        .background(Brand.canvas)
        .background { shortcuts }
        .onAppear {
            // The extents first (a time outside the recordings is brought inside), then the clock, then the cell: it opens live or on the still.
            panel.setCameras([cameraID])
            panel.setClipCameras([cameraID])
            panel.apply(model.expandedStart)
            session.setCameras([cameraID])
            #if DEBUG
            // `-demoUnmute YES` (UI review): the viewer starts with the sound on.
            if UserDefaults.standard.string(forKey: "demoUnmute")?.uppercased() == "YES" { session.isMuted = false }
            #endif
        }
        .onDisappear { session.stopAll() }
        .onChange(of: activity.isVisible, initial: true) { _, visible in
            if visible { session.resume() } else { session.suspend() }
        }
        .onChange(of: quality, initial: true) { _, quality in cell?.feed?.stream = quality.stream }
        .onChange(of: cell?.feed != nil) { _, _ in cell?.feed?.stream = quality.stream }
        .task {
            // About twice a second: extents, the viewport at the live edge, fresh activity.
            while !Task.isCancelled {
                panel.refresh(storagePause: model.nvrStorage?.pause)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .animation(.easeOut(duration: 0.2), value: cell?.coverage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(status?.name ?? "") viewer"))
    }

    // MARK: Stage

    private func stage(status: CameraStatus?, cell: NVRCell?) -> some View {
        ZStack {
            Color.black
            if let cell {
                if cell.owner == .live, !cell.showsPicture {
                    // The snapshot fills in until the first live picture; never under a recording (it would be a picture of the wrong time).
                    if let image = store.image(for: cameraID) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else if let status {
                        SnapshotPlaceholder(kind: status.kind, glyphSize: 80)
                    }
                }
                LiveVideoView(renderer: cell.sink as? LiveVideoRenderer, gravity: .resizeAspect)
                    .opacity(cell.showsPicture && !LiveVideoView.showsStillsInstead ? 1 : 0)
                NVRStateOverlay(state: tileState(status: status, cell: cell), tryAgain: { panel.session.seek(by: 0) }, goLive: { panel.goLive() }, jump: jumpToNext)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func tileState(status: CameraStatus?, cell: NVRCell) -> NVRTileState {
        let overlay = status.map { LiveOverlay.current(connection: $0.connection, phase: cell.feed?.phase ?? .stopped, isWanted: cell.feed?.isWanted ?? false) } ?? .none
        return NVRTileState.make(coverage: cell.coverage, showsPicture: cell.showsPicture, recording: status?.nvr.state ?? .off, overlay: overlay,
                                 requested: panel.session.clock.isLive ? nil : panel.session.position)
    }

    private func jumpToNext() {
        guard case .noRecording(let next?, _)? = panel.session.cell(for: cameraID)?.coverage else { return }
        panel.session.beginScrub()
        panel.session.scrub(to: next)
        panel.session.endScrub()
    }

    // MARK: Controls

    /// The control bar. At the width of the detail column the camera's address and the stream caption go first when it gets tight.
    private func controls(status: CameraStatus?, cell: NVRCell?) -> some View {
        ViewThatFits(in: .horizontal) {
            controlBar(status: status, cell: cell, showsDetails: true)
            controlBar(status: status, cell: cell, showsDetails: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Brand.sidebar)
    }

    private func controlBar(status: CameraStatus?, cell: NVRCell?, showsDetails: Bool) -> some View {
        let feed = cell?.feed
        return HStack(spacing: 10) {
            LiveIconButton(systemImage: "xmark", label: "Close Viewer") { model.closeExpandedCamera() }
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.name ?? "")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if showsDetails, let address = model.configuration(for: cameraID)?.displayAddress {
                    Text(address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.leading, 4)
            if cell?.owner == .live, feed?.phase == .live { LiveChip().transition(.opacity) }
            RecChip(state: status?.nvr.state ?? .off)
            Spacer(minLength: 12)
            if showsDetails, let status, cell?.owner == .live, let caption = LiveQuality.caption(stream: feed?.activeStream, status: status) {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
            LiveQualityMenu(quality: $quality)
            LiveIconButton(systemImage: panel.session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: panel.session.isMuted ? "Turn Sound On" : "Mute") {
                panel.session.isMuted.toggle()
            }
            LiveIconButton(systemImage: "camera.fill", label: "Save Snapshot…") { Task { await saveSnapshot(cell: cell) } }
            Button {
                model.openCameraPage(cameraID)
            } label: {
                Label(showsDetails ? "Open Camera Settings" : "Camera Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
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
    }

    /// Hidden buttons, next to Esc: Space plays and pauses, the arrows step 1 s (Shift 10 s, Option 1 min), L goes live.
    private var shortcuts: some View {
        ZStack {
            Button("Close Viewer") { if panel.isChoosingClip { panel.cancelClip() } else { model.closeExpandedCamera() } }.keyboardShortcut(.cancelAction)
            Button("Save Clip") { panel.beginClip() }.keyboardShortcut("c", modifiers: [])
            Button("Export Clip") { Task { await panel.exportClip() } }.keyboardShortcut(.return, modifiers: []).disabled(!panel.isChoosingClip)
            Button("Play or Pause") { panel.session.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Go Live") { panel.goLive() }.keyboardShortcut("l", modifiers: [])
            ForEach(Self.steps, id: \.title) { step in
                Button(step.title) { panel.session.seek(by: step.seconds) }.keyboardShortcut(step.key, modifiers: step.modifiers)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private static let steps: [(title: String, seconds: TimeInterval, key: KeyEquivalent, modifiers: EventModifiers)] = [
        ("Back 1 s", -1, .leftArrow, []), ("Forward 1 s", 1, .rightArrow, []),
        ("Back 10 s", -10, .leftArrow, .shift), ("Forward 10 s", 10, .rightArrow, .shift),
        ("Back 1 min", -60, .leftArrow, .option), ("Forward 1 min", 60, .rightArrow, .option),
    ]

    /// The picture on screen as a JPEG in a save panel (Downloads first); before the first picture, the last snapshot.
    private func saveSnapshot(cell: NVRCell?) async {
        var data: Data?
        if let renderer = cell?.sink as? LiveVideoRenderer, let picture = renderer.displayedPicture() {
            data = SnapshotSaver.jpegData(from: picture)
        } else if let image = store.image(for: cameraID) {
            data = SnapshotSaver.jpegData(from: image)
        }
        guard let data else {
            model.message = AppMessage(title: String(localized: "No Picture Yet"), detail: String(localized: "Wait for the camera’s picture to appear, then try again."))
            return
        }
        let name = SnapshotFileName.make(cameraName: model.status(for: cameraID)?.name ?? "", date: panel.session.clock.isLive ? .now : panel.session.position)
        do {
            _ = try await SnapshotSaver.save(data, suggestedName: name)
        } catch {
            model.message = AppMessage(title: String(localized: "Couldn’t Save the Picture"), detail: error.localizedDescription)
        }
    }
}
