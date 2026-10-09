import AppKit
import BridgeEngine
import SwiftUI

/// Menu bar menu (`.menu` style): quick status and a few actions. Everything else lives in the manager window
/// (cameras, Sensors Bridge) or the Settings window (Launch at Login, Keep Mac Awake, webhook, logging): the menu
/// doesn't repeat those controls.
struct StatusMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let engine = model.engine

        Text(StatusText.menuHeader(engine.state))
        if model.isPreview {
            Text("Preview Mode — Sample Data")
        }
        // The manager's banner, from the menu bar: a login item launch stays here, with no window.
        if let issue = model.bridgeIssue, let title = issue.menuItemTitle {
            Button(title) { open { model.show(issue) } }
        }
        // Network findings: what CameraBridge noticed about devices that can't reach it (the banner's Learn More).
        ForEach(model.networkMessages) { message in
            Button(message.menuTitle) { open { model.presentNetworkHelp(for: message.kind) } }
        }

        if !engine.cameras.isEmpty {
            Divider()
            ForEach(engine.cameras) { camera in
                let address = model.configuration(for: camera.id)?.displayAddress
                Button(StatusText.menuLine(for: camera, address: address)) { open { model.showManager(selecting: .camera(camera.id)) } }
                    .accessibilityLabel(Text(StatusText.accessibleMenuLine(for: camera, address: address)))
            }
        }

        Divider()

        Button("Open Camera Bridge") { open { model.showManager() } }
        Button("Add Camera…") { open { model.showAddCamera() } }
        Button(StatusText.pauseResumeTitle(engine.state)) {
            Task { await model.toggleBridgeRunning() }
        }

        Divider()

        Button("Settings…") { open { model.showSettings() } }
            .keyboardShortcut(",")
        Button("About Camera Bridge") {
            openWindow(id: WindowID.about)
            NSApp.activate()
        }
        Button("Quit Camera Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Makes sure the model can open the manager and Settings windows, then runs `action`.
    private func open(_ action: () -> Void) {
        if model.windowOpener == nil || model.settingsOpener == nil {
            model.installWindowOpener(openWindow, openSettings: openSettings)
        }
        action()
    }
}

#Preview {
    VStack(alignment: .leading) {
        StatusMenu(model: .preview())
    }
    .padding()
}
