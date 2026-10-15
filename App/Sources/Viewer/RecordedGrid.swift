import AVFoundation
import BridgeEngine
import SwiftUI

/// The Overview's recorded view: while the timeline is away from live, the cameras of a page of up to nine show the recording at the playhead on one
/// shared clock (drag the timeline and the tiles show that moment, rest and they sharpen, let go and they play). A tile opens the camera's viewer at
/// that time; cameras that are offline still show their recordings.
struct RecordedGrid: View {
    let model: AppModel
    let page: NVRPageModel

    var body: some View {
        VStack(spacing: 0) {
            if page.pageCount > 1 { pager }
            GeometryReader { proxy in
                let cameras = page.pageCameras
                let fit = NVRGrid.fit(count: cameras.count, available: CGSize(width: max(1, proxy.size.width - 56), height: max(1, proxy.size.height - 20)))
                VStack(spacing: NVRGrid.spacing) {
                    ForEach(0..<fit.rows, id: \.self) { row in
                        HStack(spacing: NVRGrid.spacing) {
                            ForEach(cameras.dropFirst(row * fit.columns).prefix(fit.columns)) { status in
                                NVRTile(model: model, page: page, status: status)
                                    .frame(width: fit.tileSize.width, height: fit.tileSize.height)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 10)
        }
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { page.previousPage() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Circle()) }
                .buttonStyle(.plain).glass(in: Circle(), interactive: true).disabled(!page.canGoBack)
                .accessibilityLabel(Text("Previous Page"))
            Text("Page \(page.page + 1) of \(page.pageCount)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Button { page.nextPage() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Circle()) }
                .buttonStyle(.plain).glass(in: Circle(), interactive: true).disabled(!page.canGoForward)
                .accessibilityLabel(Text("Next Page"))
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 4)
    }
}

/// One camera of the page: its picture (live or recorded), its name, its Record state and what it has to say; a click opens the viewer there.
private struct NVRTile: View {
    let model: AppModel
    let page: NVRPageModel
    let status: CameraStatus
    @State private var isHovering = false

    var body: some View {
        let cell = page.session.cell(for: status.id)
        ZStack {
            Color.black
            if let cell {
                LiveVideoView(renderer: cell.sink as? LiveVideoRenderer, gravity: .resizeAspect)
                    .opacity(cell.showsPicture && !LiveVideoView.showsStillsInstead ? 1 : 0)
                NVRStateOverlay(state: state(cell), compact: true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(status.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glass(in: Capsule())
                .padding(6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) { RecChip(state: status.nvr.state, compact: true).padding(6).allowsHitTesting(false) }
        .overlay(alignment: .topLeading) {
            if cell?.owner == .live, cell?.feed?.phase == .live { LiveChip().padding(6).allowsHitTesting(false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isHovering ? Brand.amber : Brand.border, lineWidth: isHovering ? 2 : 1) }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
            if hovering { page.hovered = status.id } else if page.hovered == status.id { page.hovered = nil }
        }
        .opacity(page.panel.isChoosingClip && !page.panel.includesInClip(status.id) ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) { if page.panel.isChoosingClip { ClipCheck(included: page.panel.includesInClip(status.id)).padding(8).allowsHitTesting(false) } }
        .onTapGesture {
            if page.panel.isChoosingClip { page.panel.toggleClipCamera(status.id) } else { model.expandCamera(status.id, start: page.start(forTile: status.id)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(status.name) picture"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open Viewer")) { model.expandCamera(status.id, start: page.start(forTile: status.id)) }
        .accessibilityValue(Text(page.panel.isChoosingClip ? (page.panel.includesInClip(status.id) ? "Included in the clip" : "Left out of the clip") : RecChip.help(status.nvr.state)))
        .help(page.panel.isChoosingClip ? "Include \(status.name) in the clip, or leave it out" : "Open \(status.name)")
    }

    private func state(_ cell: NVRCell) -> NVRTileState {
        let overlay = LiveOverlay.current(connection: status.connection, phase: cell.feed?.phase ?? .stopped, isWanted: cell.feed?.isWanted ?? false)
        return NVRTileState.make(coverage: cell.coverage, showsPicture: cell.showsPicture, recording: status.nvr.state, overlay: overlay,
                                 requested: page.session.clock.isLive ? nil : page.session.position)
    }
}

/// An always-visible check on a tile while a clip is being chosen: an amber check when the camera is in it, an empty circle when it is left out.
struct ClipCheck: View {
    let included: Bool

    var body: some View {
        Image(systemName: included ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(included ? Brand.amber : Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 2)
    }
}
