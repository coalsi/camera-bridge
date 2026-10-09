import AVFoundation
import BridgeEngine
import SwiftUI

/// One camera on the Overview: a 16:9 picture (the snapshot, or the live sub stream cropped to fit) with its own play/pause
/// and expand buttons on hover, and below it the camera's name, address, status, viewers, last motion and recording state.
/// Double-clicking the picture opens the single-camera viewer; the info area opens the camera's page.
struct OverviewTile: View {
    let model: AppModel
    let overview: OverviewModel
    let status: CameraStatus
    /// What shows under the picture (a fixed layout shrinks it as the tiles get small).
    var density: OverviewGridMetrics.Density = .full
    /// The tile's width in a fixed layout; nil in Auto, where the grid decides.
    var fixedWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDropTarget = false
    private let store = SnapshotStore.shared

    private var radius: CGFloat { density == .full ? 18 : 14 }

    var body: some View {
        let feed = overview.feed(for: status.id)
        VStack(spacing: 0) {
            picture(feed: feed)
            switch density {
            case .full:
                OverviewTileInfo(model: model, status: status)
                    .frame(height: fixedWidth == nil ? nil : OverviewGridMetrics.fullInfoHeight, alignment: .top)
            case .compact:
                OverviewTileCompactInfo(model: model, status: status)
            case .hidden:
                EmptyView()
            }
        }
        .frame(width: fixedWidth)
        .brandSurface(radius: radius)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.amber, lineWidth: 3)
            }
        }
        .onScrollVisibilityChange(threshold: 0.3) { overview.setVisible(status.id, $0) }
        // Drag a tile onto another to reorder (the order is remembered).
        .draggable(status.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            overview.move(id, onto: status.id)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
    }

    private func picture(feed: LiveFeed) -> some View {
        let overlay = LiveOverlay.current(connection: status.connection, phase: feed.phase, isWanted: feed.isWanted)
        let canPlay = status.connection == .online
        let bottomRadius: CGFloat = density == .hidden ? radius : 0
        let controlSize: CGFloat = (fixedWidth ?? 400) < 220 ? 32 : 46
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
                                           topTrailingRadius: radius, style: .continuous)
        return Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                // The snapshot is the placeholder until the first live picture, and what stays when playback ends.
                if let image = store.image(for: status.id) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    SnapshotPlaceholder(kind: status.kind, glyphSize: (fixedWidth ?? 400) < 220 ? 22 : 34)
                }
            }
            .overlay {
                LiveVideoView(feed: feed, gravity: .resizeAspectFill)
                    .opacity(feed.hasPicture && !LiveVideoView.showsStillsInstead ? 1 : 0)
            }
            .overlay { LiveOverlayView(overlay: overlay, compact: true) }
            .overlay(alignment: .topLeading) {
                if feed.phase == .live { LiveChip().padding(10).transition(.opacity) }
            }
            .overlay(alignment: .bottomLeading) {
                // Without an info area the picture carries the name.
                if density == .hidden {
                    Text(status.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glass(in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Hover controls: play or pause this tile (over Play All), expand to the viewer.
                ZStack {
                    if canPlay {
                        LiveIconButton(systemImage: feed.isWanted ? "pause.fill" : "play.fill",
                                       label: feed.isWanted ? "Pause" : "Play", size: controlSize, isProminent: !feed.isWanted) {
                            overview.toggle(status.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    LiveIconButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Open Viewer", size: controlSize < 40 ? 24 : 30) {
                        model.expandCamera(status.id)
                    }
                    .padding(controlSize < 40 ? 6 : 10)
                }
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
            }
            .animation(.easeOut(duration: 0.2), value: feed.phase)
            .clipShape(shape)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .onTapGesture(count: 2) { model.expandCamera(status.id) }
            .task(id: feed.isWanted) {
                // A live tile needs no snapshots; a stopped one keeps its picture fresh (the sidebar shares the fetch).
                guard !feed.isWanted else { return }
                await store.keepFresh(cameraID: status.id, model: model, interval: SnapshotRefreshPolicy.thumbnailInterval,
                                     minimumInterval: SnapshotRefreshPolicy.thumbnailMinimumInterval)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(status.name) picture"))
            .accessibilityValue(Text(feed.isWanted ? "Playing" : "Snapshot"))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: Text(feed.isWanted ? "Pause" : "Play")) { if canPlay { overview.toggle(status.id) } }
            .accessibilityAction(named: Text("Open Viewer")) { model.expandCamera(status.id) }
    }
}

/// Below the picture: name and status pill, address and viewers, last motion and recording state. A button: opens the camera's page.
private struct OverviewTileInfo: View {
    let model: AppModel
    let status: CameraStatus

    var body: some View {
        let pill = CameraPillState(status)
        let address = model.configuration(for: status.id)?.displayAddress
        Button {
            model.openCameraPage(status.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(status.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusPill(state: pill)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    if let address {
                        Text(address)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if status.liveViewers > 0 { ViewerPill(count: status.liveViewers) }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(OverviewTileText.motionLine(status, now: context.date), systemImage: "figure.walk.motion")
                        RecordingLabel(status: status)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .labelStyle(TileLabelStyle())
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([status.name, address, pill.plainTitle, OverviewTileText.motionLine(status, now: .now),
                                  OverviewTileText.recordingLine(status)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("Opens the camera’s page"))
        .accessibilityAddTraits(.isButton)
        .help("Open \(status.name)")
    }
}

/// One line under a small tile's picture: a status dot, the name and the viewer count. A button: opens the camera's page.
private struct OverviewTileCompactInfo: View {
    let model: AppModel
    let status: CameraStatus

    var body: some View {
        let pill = CameraPillState(status)
        Button {
            model.openCameraPage(status.id)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(pill.tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if status.liveViewers > 0 { ViewerPill(count: status.liveViewers, compact: true) }
            }
            .padding(.horizontal, 12)
            .frame(height: OverviewGridMetrics.compactInfoHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([status.name, pill.plainTitle].joined(separator: ", ")))
        .accessibilityHint(Text("Opens the camera’s page"))
        .accessibilityAddTraits(.isButton)
        .help("Open \(status.name)")
    }
}

private struct RecordingLabel: View {
    let status: CameraStatus

    var body: some View {
        let recording = OverviewTileText.recording(status)
        Label(OverviewTileText.recordingLine(status), systemImage: recording == .recording ? "record.circle.fill" : "record.circle")
            .foregroundStyle(recording == .recording ? Brand.recording : .secondary)
    }
}

/// A small icon in a fixed-width column, then the text.
private struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 14)
            configuration.title.lineLimit(1)
        }
    }
}
