import AppKit
import BridgeEngine
import CameraAdapters
import SwiftUI

extension CameraTab {
    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .streams: "Streams"
        case .recording: "Recording"
        case .motion: "Motion & Events"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .streams: "dot.radiowaves.left.and.right"
        case .recording: "record.circle"
        case .motion: "figure.walk.motion"
        case .advanced: "gearshape"
        }
    }
}

extension SourceStreamInfo {
    /// "H.264 3840×2160" (frame rate in `detail`).
    var shortSummary: String { "\(codec == "h264" ? "H.264" : "H.265") \(width)×\(height)" }
}

/// The dashboard above the tabs. Narrow: one column (hero, actions, six stat tiles). Wide: two columns, the hero and its
/// action buttons on the left, four stat tiles in a two-column grid and the Apple Home summary on the right. The stat
/// tiles and the Apple Home card take the page somewhere (`navigate`: the tab, the open checklist, a scroll to it); the
/// buttons act (Optimize and Camera Settings present sheets, Open Web Page opens the browser, Test Motion fires).
struct CameraDashboard: View {
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus
    let configuration: CameraConfiguration
    let readiness: ReadinessState
    var isWide = false
    @Binding var tab: CameraTab
    @Binding var showingCameraSettings: Bool
    let navigate: (CameraPageDestination) -> Void

    var body: some View {
        VStack(spacing: 20) {
            if isWide {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        CameraHero(model: model, cameraID: cameraID, status: status, configuration: configuration)
                        CameraProblems(status: status, configuration: configuration)
                        CameraActionRow(model: model, cameraID: cameraID, configuration: configuration, readiness: readiness,
                                        showingCameraSettings: $showingCameraSettings)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        CameraStatTiles(status: status, configuration: configuration, readiness: readiness, navigate: navigate,
                                        layout: .twoColumns)
                        AppleHomeSummary(status: status, configuration: configuration, readiness: readiness,
                                         navigate: navigate)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                CameraHero(model: model, cameraID: cameraID, status: status, configuration: configuration)
                CameraProblems(status: status, configuration: configuration)
                CameraActionRow(model: model, cameraID: cameraID, configuration: configuration, readiness: readiness,
                                showingCameraSettings: $showingCameraSettings)
                CameraStatTiles(status: status, configuration: configuration, readiness: readiness, navigate: navigate,
                                layout: .adaptive)
            }
            BrandTabBar(tabs: CameraTab.allCases, selection: $tab, title: \.title, symbol: \.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Hero

/// A large snapshot in the camera's own aspect ratio, with status chips and the name, IP address and model on a dark
/// scrim. Refreshes every 10 s while the window is on screen (the sidebar thumbnail shares the same fetch).
private struct CameraHero: View {
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus
    let configuration: CameraConfiguration
    private let store = SnapshotStore.shared
    @State private var width: CGFloat = 0
    /// Live view: the play button over the picture (`HeroLive`).
    @State private var live = HeroLiveState()

    /// The hero follows the picture's aspect ratio (16:9 until the first snapshot arrives), at full width, at most
    /// 380 pt tall: a taller picture is cropped top and bottom rather than shrunk.
    private func height(ratio: CGFloat) -> CGFloat? {
        width > 0 ? min(width / min(max(ratio, 1.2), 2.4), 380) : nil
    }

    var body: some View {
        let image = store.image(for: cameraID)
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 16.0 / 9.0
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height(ratio: ratio) ?? 300)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).clipped()
                } else {
                    SnapshotPlaceholder(kind: status.kind, glyphSize: 64)
                }
            }
            .overlay { HeroLiveVideo(live: live, model: model, cameraID: cameraID, status: status) }
            // Scrims keep the chips (top) and the name (bottom) legible over any picture, including the camera's own
            // on-screen timestamp.
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0), .init(color: .black.opacity(0.78), location: 0.5),
                                       .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) { identity.padding(22) }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    StatusPill(state: CameraPillState(status), onImage: true)
                    if status.recordingNow && status.motionActive { StatusPill(state: .motion, onImage: true) }
                    if status.isPaired {
                        Label("In Apple Home", systemImage: "house.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                if let updated = store.updatedAt[cameraID], !live.isPlaying {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Updated \(StatusText.timeAgo(updated, now: context.date))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                    }
                    .padding(16)
                }
            }
            .overlay { HeroLiveControls(live: live, model: model, cameraID: cameraID, status: status) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Brand.border, lineWidth: 1) }
            .task(id: cameraID) {
                await store.keepFresh(cameraID: cameraID, model: model, interval: SnapshotRefreshPolicy.heroInterval,
                                     minimumInterval: SnapshotRefreshPolicy.heroMinimumInterval)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(status.name), \(configuration.displayAddress), \(CameraPillState(status).plainTitle)"))
            .accessibilityAddTraits(.isImage)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(status.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label {
                    Text(configuration.displayAddress)
                        .font(.system(size: 14, design: .monospaced))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "network")
                }
                .foregroundStyle(.white.opacity(0.92))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6)
    }

    private var subtitle: String {
        [StatusText.kind(status.kind), configuration.model.isEmpty ? StatusText.vendor(status.vendor) : configuration.model]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Problems belong with the connection they explain.
private struct CameraProblems: View {
    let status: CameraStatus
    let configuration: CameraConfiguration

    var body: some View {
        let notice = CameraConnectionEditor.unsupportedStreamNotice(for: configuration)
        if status.lastError != nil || status.subStreamProblem != nil || status.homeKitNote != nil || notice != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let error = status.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.recording)
                }
                if let problem = status.subStreamProblem {
                    Label(String(localized: "Sub stream offline (\(problem)); the main stream is used instead"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.warning)
                }
                if let note = status.homeKitNote {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(note, systemImage: "house.fill").foregroundStyle(Brand.warning)
                        Text("Camera Bridge has announced this camera to Home again. If Home still doesn’t respond, check that your Home hub (an Apple TV or HomePod) is on and on the same network as this Mac.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandSurface(radius: 16)
        }
    }
}

// MARK: - Actions

private struct CameraActionRow: View {
    let model: AppModel
    let cameraID: UUID
    let configuration: CameraConfiguration
    let readiness: ReadinessState
    @Binding var showingCameraSettings: Bool

    private var hasCameraAccess: Bool { configuration.hasCameraInterface }
    private var testBlocker: PairingBlocker? { model.testMotionBlocker(for: cameraID) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) {
                HStack(spacing: 10) { optimize; settings }
                HStack(spacing: 10) { web; test }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        optimize
        settings
        web
        test
    }

    @ViewBuilder private var optimize: some View {
        if hasCameraAccess {
            Button { readiness.showingOptimizeSheet = true } label: {
                Label("Optimize for HomeKit", systemImage: "wand.and.stars").fixedSize().frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.primary, large: true))
            .disabled(!readiness.canAct)
            .help(readiness.canAct ? "Apply the camera settings HomeKit Secure Video needs" : "Nothing to optimize right now")
        }
    }

    @ViewBuilder private var settings: some View {
        if hasCameraAccess {
            Button { showingCameraSettings = true } label: {
                Label("Camera Settings", systemImage: "slider.horizontal.3").fixedSize().frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.secondary, large: true))
            .help("Video and image settings, read from the camera")
        }
    }

    @ViewBuilder private var web: some View {
        if hasCameraAccess {
            Button {
                let endpoint = configuration.endpoint
                if let url = URL(string: "\(endpoint.useHTTPS ? "https" : "http")://\(endpoint.host):\(endpoint.httpPort)/") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open Web Page", systemImage: "safari").fixedSize().frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.secondary, large: true))
            .help("Open the camera’s own web page in your browser")
        }
    }

    private var test: some View {
        Button { Task { await model.triggerTestMotion(cameraID: cameraID) } } label: {
            Label("Test Motion", systemImage: "figure.walk.motion").fixedSize().frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(.secondary, large: true))
        .disabled(testBlocker != nil)
        .help(testBlocker.map(StatusText.testMotionUnavailable) ?? StatusText.testMotionExplanation)
    }
}

// MARK: - Stat tiles

private struct CameraStatTiles: View {
    let status: CameraStatus
    let configuration: CameraConfiguration
    let readiness: ReadinessState
    let navigate: (CameraPageDestination) -> Void
    var layout: Layout = .adaptive
    @State private var width: CGFloat = 800

    enum Layout {
        /// Six tiles in 6, 3 or 2 columns by width, never a lone tile on the last row.
        case adaptive
        /// Wide dashboard: the Apple Home tiles live in `AppleHomeSummary`, so four tiles in two columns.
        case twoColumns
    }

    private var columnCount: Int {
        layout == .twoColumns ? 2 : (width >= 1_140 ? 6 : (width >= 620 ? 3 : 2))
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
            if layout == .adaptive {
                StatTile(title: "Apple Home",
                         value: status.isPaired ? String(localized: "Added") : String(localized: "Not added"),
                         detail: status.isPaired ? String(localized: "Paired with Apple Home") : String(localized: "Show the QR code to add it"),
                         systemImage: "house.fill", tint: status.isPaired ? Brand.live : Brand.amber,
                         accessibilityHint: "Shows the Apple Home pairing") { navigate(.pairing) }

                if configuration.hasCameraInterface {
                    readinessTile
                }
            }

            StatTile(title: "Streams", value: status.mainStreamInfo?.shortSummary ?? String(localized: "No picture yet"),
                     detail: streamsDetail, systemImage: "dot.radiowaves.left.and.right",
                     accessibilityHint: "Shows the stream settings") { navigate(.streams) }

            StatTile(title: "Recording", value: recordingValue, detail: recordingDetail, systemImage: "record.circle",
                     tint: status.recordingNow ? Brand.recording : Brand.amber,
                     accessibilityHint: "Shows the recording settings") { navigate(.recording) }

            StatTile(title: "Live View", value: StatusText.viewersValue(status), detail: StatusText.viewersDetail(status),
                     systemImage: "eye.fill", tint: status.liveViewers + status.appViewers > 0 ? Brand.live : Brand.amber,
                     accessibilityHint: "Shows the live view settings") { navigate(.liveView) }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatTile(title: "Motion",
                         value: status.lastEventDate.map { StatusText.timeAgo($0, now: context.date) } ?? String(localized: "No events yet"),
                         detail: status.lastEvent ?? String(localized: "Waiting for the first one"),
                         systemImage: "figure.walk.motion", tint: status.motionActive ? Brand.warning : Brand.amber,
                         accessibilityHint: "Shows motion settings and recent events") { navigate(.motion) }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var readinessTile: some View {
        let report = readiness.report
        return StatTile(title: "HomeKit Readiness",
                        value: report.map { "\($0.score)%" } ?? (readiness.isLoading ? String(localized: "Checking…") : String(localized: "Unavailable")),
                        detail: report?.summary ?? readiness.loadError,
                        systemImage: "checkmark.seal.fill", action: { navigate(.readinessChecklist) },
                        accessibilityHint: "Opens the readiness checklist", hasAccessory: report != nil) {
            ScoreRing(score: report?.score ?? 0)
        }
    }

    private var streamsDetail: String? {
        if let sub = status.subStreamInfo { return String(localized: "Sub · \(sub.shortSummary)") }
        return status.mainStreamInfo.flatMap { info in info.fps.map { String(localized: "\(Int($0.rounded())) fps · no sub stream") } }
    }

    private var recordingValue: String {
        if status.recordingNow { return String(localized: "Recording now") }
        return status.recordingEnabled ? String(localized: "On") : String(localized: "Off")
    }

    private var recordingDetail: String {
        if let session = status.recordingSession {
            return session.usesSubStream ? String(localized: "Sub stream") : String(localized: "Main stream")
        }
        if status.recordingNow { return String(localized: "In progress") }
        return status.recordingEnabled ? String(localized: "Waiting for motion") : String(localized: "Turn on in the Home app")
    }
}

// MARK: - Apple Home summary (wide dashboard)

/// Pairing and HomeKit readiness in one card: stands in for the two Apple Home tiles on the wide dashboard.
private struct AppleHomeSummary: View {
    let status: CameraStatus
    let configuration: CameraConfiguration
    let readiness: ReadinessState
    let navigate: (CameraPageDestination) -> Void

    /// A paired camera with a readiness checklist (the demo camera has none).
    private var showsChecklist: Bool { status.isPaired && configuration.hasCameraInterface }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill").foregroundStyle(Brand.amber).accessibilityHidden(true)
                Text("Apple Home").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                pairingChip
            }
            if configuration.hasCameraInterface {
                Divider().overlay(Brand.border)
                HStack(spacing: 14) {
                    if let report = readiness.report {
                        ScoreRing(score: report.score)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(report.score)% ready for HomeKit Secure Video").font(.system(size: 14, weight: .semibold))
                            Text(report.summary).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if readiness.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Checking HomeKit readiness…").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.warning).accessibilityHidden(true)
                        Text(readiness.loadError ?? String(localized: "Unavailable")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                // Paired: the readiness checklist, opened. Not paired: the QR code. (The Overview tab is usually the one already
                // showing, so the tab alone changes nothing: the button also opens the checklist and scrolls to it.)
                Button { navigate(showsChecklist ? .readinessChecklist : .pairing) } label: {
                    Label(showsChecklist ? "View Checklist" : (status.isPaired ? "Show Pairing" : "Show QR Code"),
                          systemImage: showsChecklist ? "checklist" : "qrcode")
                }
                .buttonStyle(.brand(.secondary))
                .help(showsChecklist ? "Opens the HomeKit readiness checklist" : "Shows the Apple Home pairing for this camera")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandSurface(radius: 18)
    }

    private var pairingChip: some View {
        let paired = status.isPaired
        let tint = paired ? Brand.live : Brand.warning
        let title = paired ? String(localized: "Added") : String(localized: "Not added")
        let symbol = paired ? "checkmark.circle.fill" : "plus.circle"
        return Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay { Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1) }
    }
}
