import BridgeEngine
import SwiftUI

/// The manager's own sidebar: brand header, the Overview card, a card per camera (live thumbnail, name, IP address, status
/// pill), the Sensors section (the published sensors under the camera that provides them) and, at the bottom, Add Camera,
/// Diagnostics and Settings. Cards are buttons (keyboard and VoiceOver); up/down arrows move the selection while the list
/// has focus.
struct ManagerSidebar: View {
    @Bindable var model: AppModel

    /// Selection order: the Overview, the cameras, then the Sensors page (Diagnostics is the button below).
    private var order: [ManagerSelection] { [.overview] + model.engine.cameras.map { .camera($0.id) } + [.sensorsBridge] }

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    OverviewSidebarCard(cameras: model.engine.cameras, isSelected: model.selection == .overview) { model.selection = .overview }
                    SidebarSectionTitle(title: "Cameras", count: model.engine.cameras.count)
                        .padding(.top, 10)
                    if model.engine.cameras.isEmpty {
                        Text("No cameras yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(model.engine.cameras) { camera in
                        let address = model.configuration(for: camera.id)?.displayAddress
                        CameraCard(model: model, status: camera, address: address, isSelected: model.selection == .camera(camera.id)) {
                            model.selection = .camera(camera.id)
                        }
                    }
                    SensorsSidebarSection(model: model)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Button {
                    model.showAddCamera()
                } label: {
                    Label("Add Camera", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, large: true))
                .help("Add Camera")

                Button {
                    model.selection = .diagnostics
                } label: {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.brand(model.selection == .diagnostics ? .primary : .secondary, large: true, square: true))
                .help("Diagnostics")
                .accessibilityLabel(Text("Diagnostics"))
                .accessibilityAddTraits(model.selection == .diagnostics ? .isSelected : [])

                Button {
                    model.showSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.brand(.secondary, large: true, square: true))
                .help("Settings (⌘,)")
                .accessibilityLabel(Text("Settings"))
            }
            .padding(14)
        }
        .background(Brand.sidebar)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        model.selection = SidebarNavigation.next(from: model.selection, offset: offset, order: order)
        return .handled
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Camera Bridge")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SidebarSectionTitle: View {
    let title: LocalizedStringKey
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct CameraCard: View {
    let model: AppModel
    let status: CameraStatus
    let address: String?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let pill = CameraPillState(status)
        Button(action: select) {
            HStack(spacing: 12) {
                CameraThumbnail(model: model, cameraID: status.id, kind: status.kind)
                    .frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(status.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    if let address {
                        Text(address)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // One line, always: the roomy pills when they fit, else trimmed ones (a long word like "Recording"
                    // next to the viewer count), and the viewer count alone gives way last.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            StatusPill(state: pill)
                            if status.liveViewers > 0 { ViewerPill(count: status.liveViewers) }
                        }
                        HStack(spacing: 4) {
                            StatusPill(state: pill, compact: true)
                            if status.liveViewers > 0 { ViewerPill(count: status.liveViewers, compact: true) }
                        }
                        StatusPill(state: pill, compact: true)
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .brandSurface(radius: 18, highlighted: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([status.name, address, pill.plainTitle,
                                  status.liveViewers > 0 ? (status.liveViewers == 1 ? String(localized: "1 viewer") : String(localized: "\(status.liveViewers) viewers")) : nil]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Latest snapshot in a fixed 16:9 box (the frame the caller gives it is always 16:9): aspect-filled, so a wider
/// panorama or a taller picture is cropped rather than overflowing, then clipped and rounded. Refreshed every
/// 45 s while the row and the window are on screen. Cameras without a picture (offline, or the sample-data engine) show a solid tile
/// with the camera's glyph.
struct CameraThumbnail: View {
    let model: AppModel
    let cameraID: UUID
    let kind: CameraKind
    private let store = SnapshotStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // The clear base fixes the layout size at 16:9; the picture lives in an overlay so its fill size never
        // reaches the layout, and the clip crops whatever is outside the box.
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image = store.image(for: cameraID) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    SnapshotPlaceholder(kind: kind, glyphSize: 20)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
            .contentShape(shape)
            .task(id: cameraID) {
                await store.keepFresh(cameraID: cameraID, model: model, interval: SnapshotRefreshPolicy.thumbnailInterval,
                                     minimumInterval: SnapshotRefreshPolicy.thumbnailMinimumInterval)
            }
            .accessibilityHidden(true)
    }
}

/// Fallback for a missing picture: a solid dark tile with the camera glyph in amber.
struct SnapshotPlaceholder: View {
    let kind: CameraKind
    var glyphSize: CGFloat = 40

    var body: some View {
        ZStack {
            Color(hex: 0x232326)
            Image(systemName: kind == .doorbell ? "video.doorbell.fill" : "video.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(Brand.amber)
                .opacity(0.9)
        }
    }
}
