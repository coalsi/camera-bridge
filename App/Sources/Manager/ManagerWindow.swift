import BridgeEngine
import SwiftUI

/// Manager window: cameras and the Sensors Bridge in the sidebar; details on the right. App-wide preferences are in
/// the Settings window (⌘,), not here.
struct ManagerWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            ManagerSidebar(model: model)
                .frame(width: 304)
            Rectangle()
                .fill(Brand.border)
                .frame(width: 1)
                .accessibilityHidden(true)
            ManagerDetail(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ManagerBanners(model: model)
                }
        }
        .background { BrandCanvas() }
        // Pictures are fetched only while somebody can see this window (`WindowActivity`).
        .background { WindowVisibilityObserver().frame(width: 0, height: 0) }
        // The brand look is dark; the menu and Settings follow the system.
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("Camera Bridge")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                BridgeToggleButton(model: model)
                    .glassButtonStyle()
            }
        }
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .addCamera: AddCameraWizard(model: model)
            case .onboarding: OnboardingView(model: model)
            case .localNetworkAccess: LocalNetworkAccessSheet(model: model)
            case .vpnHelp: NetworkHelpSheet(page: NetworkHelpContent.vpn)
            case .networkHelp(let kind): NetworkHelpSheet(page: NetworkHelpContent.page(for: kind))
            }
        }
        .alert(model.message?.title ?? "", item: $model.message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.detail)
        }
        .overlay {
            // The single-camera viewer fills the whole window (sidebar included).
            if let id = model.expandedCameraID {
                SingleCameraViewer(model: model, cameraID: id)
                    .id(id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.expandedCameraID)
        .overlay(alignment: .bottom) {
            NoticeBanner(text: model.notice)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .onAppear {
            model.installWindowOpener(openWindow, openSettings: openSettings)
            model.managerWindowDidAppear()
            if model.selection == nil {
                model.selection = model.defaultSelection   // nil without cameras: the "No Cameras Yet" page
            }
            #if DEBUG
            // `-openAddCamera YES`: UI review of the wizard without clicking through.
            if UserDefaults.standard.bool(forKey: "openAddCamera") { model.showAddCamera() }
            // `-openVPNHelp YES`: the VPN Learn More sheet (UI review and screenshots; pair it with `-demoScenario vpn`).
            if UserDefaults.standard.bool(forKey: "openVPNHelp") { model.presentVPNHelp() }
            // `-openLocalNetworkHelp YES`: the Local Network access sheet (pair it with `-demoScenario network-denied`).
            if UserDefaults.standard.bool(forKey: "openLocalNetworkHelp"), model.presentedSheet == nil { model.presentedSheet = .localNetworkAccess }
            // `-selectCameraIndex 2`: opens that camera's page (UI review of every camera state).
            if let index = UserDefaults.standard.string(forKey: "selectCameraIndex").flatMap({ Int($0) }), model.engine.cameras.indices.contains(index) {
                model.selection = .camera(model.engine.cameras[index].id)
            }
            // `-selectPage diagnostics` / `sensors-bridge`: opens that page (screenshots of the pages the sidebar's cards open).
            switch UserDefaults.standard.string(forKey: "selectPage") {
            case "diagnostics": model.selection = .diagnostics
            case "sensors-bridge": model.selection = .sensorsBridge
            default: break
            }
            // `-demoExpand 1`: opens the single-camera viewer for that camera (UI review).
            if let index = UserDefaults.standard.string(forKey: "demoExpand").flatMap({ Int($0) }), model.engine.cameras.indices.contains(index) {
                model.expandCamera(model.engine.cameras[index].id)
            }
            // `-demoWindowAction close|miniaturize|hide`: does that to the window after 8 s (checks that live pictures stop with it).
            if let action = UserDefaults.standard.string(forKey: "demoWindowAction") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                    switch action {
                    case "close": window?.close()
                    case "miniaturize": window?.miniaturize(nil)
                    case "hide": NSApp.hide(nil)
                    default: break
                    }
                }
            }
            // `-windowWidth 1700 -windowHeight 1000`: the window's content size (UI review of the wide and narrow layouts).
            if let width = UserDefaults.standard.string(forKey: "windowWidth").flatMap({ Double($0) }),
               let height = UserDefaults.standard.string(forKey: "windowHeight").flatMap({ Double($0) }) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.setContentSize(NSSize(width: width, height: height))
                }
            }
            #endif
        }
        .onDisappear { model.managerWindowDidDisappear() }
    }

    private var subtitle: String {
        let engine = model.engine
        var parts = [StatusText.engineState(engine.state)]
        parts.append(engine.cameras.count == 1 ? String(localized: "1 camera") : String(localized: "\(engine.cameras.count) cameras"))
        if model.isPreview { parts.append(String(localized: "Sample Data")) }
        return parts.joined(separator: " · ")
    }
}

/// What sits above the detail column: the bridge's problem, the VPN finding.
private struct ManagerBanners: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let issue = model.bridgeIssue {
                BridgeIssueBanner(issue: issue) { Task { await model.resolve(issue) } }
            }
            if let message = model.networkBanner {
                NetworkNoticeBanner(message: message, learnMore: { model.presentNetworkHelp(for: message.kind) },
                                    dismiss: { model.dismissNetworkBanner(message) })
                    .task(id: message.id) { model.networkBannerAppeared(message) }
            }
        }
    }
}

private struct BridgeToggleButton: View {
    let model: AppModel

    var body: some View {
        let state = model.engine.state
        let title = StatusText.pauseResumeTitle(state)
        let isRunning = state == .running || state == .starting
        Button {
            Task { await model.toggleBridgeRunning() }
        } label: {
            Label(title, systemImage: isRunning ? "pause.fill" : "play.fill")
        }
        .help(title)
    }
}

private struct ManagerDetail: View {
    let model: AppModel

    var body: some View {
        switch model.selection {
        case .camera(let id):
            if let configuration = model.configuration(for: id) {
                CameraDetailView(model: model, cameraID: id, configuration: configuration)
                    .id(id)
            } else {
                ContentUnavailableView("Camera Not Found", systemImage: "video.slash",
                                       description: Text("This camera was removed."))
            }
        case .overview:
            OverviewView(model: model)
        case .sensorsBridge:
            SensorsBridgeView(model: model)
        case .diagnostics:
            DiagnosticsView(model: model)
        case nil:
            if model.engine.configurations.isEmpty {
                EmptyCamerasHero { model.showAddCamera() }
            } else {
                ContentUnavailableView("Select a Camera", systemImage: "video",
                                       description: Text("Choose a camera in the sidebar."))
            }
        }
    }
}

/// First-run page: a big friendly call to action instead of an empty list.
struct EmptyCamerasHero: View {
    let addCamera: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 54))
                .foregroundStyle(Brand.onAmber)
                .frame(width: 112, height: 112)
                .background(Brand.amber, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("No Cameras Yet")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Add a camera to bring it into the Apple Home app.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            BrandButton(title: "Add Camera…", systemImage: "plus", kind: .primary, large: true, action: addCamera)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Short-lived message at the bottom of the window (preview mode notices).
private struct NoticeBanner: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

#Preview {
    ManagerWindow(model: .preview())
        .frame(width: 1100, height: 780)
}

#Preview("Wide") {
    ManagerWindow(model: .preview())
        .frame(width: 1600, height: 1100)
}
