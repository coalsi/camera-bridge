import AppKit
import BridgeEngine
import SwiftUI

@main
struct CameraBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Settings › General › Show in Menu Bar. The model writes the same store (`AppModel.setPresence`).
    @AppStorage(AppPresence.menuBarKey, store: AppModel.launchDefaults) private var showInMenuBar = true

    var body: some Scene {
        let model = appDelegate.model

        MenuBarExtra(isInserted: $showInMenuBar) {
            StatusMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Camera Bridge", id: WindowID.manager) {
            ManagerWindow(model: model)
        }
        .defaultLaunchBehavior(model.opensManagerAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1600, height: 1100)
        .commands { ManagerCommands(model: model, updater: appDelegate.updater) }

        // About CameraBridge (app menu and status menu).
        Window("About Camera Bridge", id: WindowID.about) {
            AboutWindowContent()
                .environment(\.appUpdater, appDelegate.updater)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        // App-wide preferences, once: ⌘, and the status item's Settings… open this window.
        Settings {
            SettingsView(model: model)
                .environment(\.appUpdater, appDelegate.updater)
        }
    }
}

/// Status item. Status itself is text in the menu (macOS 27 hides menu-item images by default); the symbol only
/// distinguishes running, stopped/paused and needs-attention.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Symbol and VoiceOver label from the same inputs as the manager's banner: the warning triangle is also what
        // VoiceOver says. The brand mark (house + camera cutout) replaces the generic SF Symbol camera glyph while
        // running; attention states keep system glyphs, which read unambiguously at 18pt.
        let state = model.engine.state, issue = model.bridgeIssue
        Group {
            switch StatusText.menuBarGlyph(state: state, issue: issue) {
            case .brandMark:
                Image("MenuBarIcon").renderingMode(.template)
            case let .symbol(name):
                Image(systemName: name)
            }
        }
        .accessibilityLabel(Text(StatusText.menuBarAccessibilityLabel(state: state, issue: issue)))
        .task { model.installWindowOpener(openWindow, openSettings: openSettings) }
    }
}

#Preview("Menu bar label") {
    MenuBarLabel(model: .preview())
        .padding()
}

/// The main menu (shown while CameraBridge is in the Dock; SwiftUI supplies the standard App, Edit, View, Window and
/// Help menus around these): About, Check for Updates…, File › Add Camera… (⌘N) and Export Diagnostics…, Help links. Settings… (⌘,) comes from
/// the Settings scene.
struct ManagerCommands: Commands {
    let model: AppModel
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        // The menu bar item installs the window openers when it is there; with it hidden, these commands (built at
        // launch, in the Dock or not) are the always-present SwiftUI context that can open the manager from the Dock.
        let _ = installOpeners()
        CommandGroup(replacing: .appInfo) {
            AboutMenuButton()
            CheckForUpdatesButton(updater: updater)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Camera…") { model.showAddCamera() }
                .keyboardShortcut("n")
            Button("Export Diagnostics…") { model.exportDiagnostics() }
        }
        CommandGroup(replacing: .help) {
            Link("Camera Bridge Support", destination: CameraBridgeService.support)
            Link("Camera Bridge Website", destination: CameraBridgeService.website)
            Link("Privacy Policy", destination: CameraBridgeService.privacyPolicy)
        }
    }

    /// Hands the model the environment's window actions, once (and not while a view update is running: opening a
    /// window that was requested before the actions existed would happen inside it).
    private func installOpeners() {
        guard model.windowOpener == nil || model.settingsOpener == nil else { return }
        let model = model, openWindow = openWindow, openSettings = openSettings
        Task { @MainActor in
            if model.windowOpener == nil || model.settingsOpener == nil {
                model.installWindowOpener(openWindow, openSettings: openSettings)
            }
        }
    }
}

/// "About CameraBridge" in the app menu: opens (or brings forward) the About window.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Camera Bridge") {
            openWindow(id: WindowID.about)
            NSApp.activate()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.launching()
    /// Sparkle (Check for Updates…); the app's menu, Settings and About use it.
    let updater = AppUpdater()
    private var wakeObserver: (any NSObjectProtocol)?
    private var sleepObserver: (any NSObjectProtocol)?

    /// The Dock icon (activation policy) follows Settings › General › Show in Dock from the first moment. Without
    /// `LSUIElement` the app starts as a regular app; a menu-bar-only setting turns it into an accessory app here.
    func applicationWillFinishLaunching(_ notification: Notification) {
        model.presenceHandler = { [weak self] presence in self?.apply(presence, whileRunning: true) }
        apply(model.presence, whileRunning: false)
    }

    private func apply(_ presence: AppPresence, whileRunning: Bool) {
        guard let policy = presence.policyChange(from: NSApp.activationPolicy()) else { return }
        NSApp.setActivationPolicy(policy)
        // A changed policy deactivates the app (and takes the main menu with it): come back to the window in use.
        if whileRunning { DispatchQueue.main.async { NSApp.activate() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit stays in the app: forward wake so the engine restarts ingest and re-advertises.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [model] _ in
            Task { @MainActor in await model.systemDidWake() }
        }
        // The sleep is logged, and its length decides what the wake closes (the engine's connections that went silent in it).
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [model] _ in
            Task { @MainActor in model.systemWillSleep() }
        }
        model.didFinishLaunching()
        #if DEBUG
        if ScreenshotCapture.isRequested {
            Task(priority: .userInitiated) { await ScreenshotCapture.run(model: model) }
        }
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.applicationDidBecomeActive()   // Login item and Local Network access may have changed in System Settings
    }

    /// Clicking the Dock icon, or opening the app again from Finder or Launchpad, brings up the manager window: the
    /// access path when the status item is hidden or out of sight.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !model.isManagerWindowOpen { model.showManager() }
        return true
    }

    /// The Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(String(localized: "Open Camera Bridge"), #selector(openManagerFromDock)),
                                (String(localized: "Add Camera…"), #selector(addCameraFromDock)),
                                (StatusText.pauseResumeTitle(model.engine.state), #selector(toggleBridgeFromDock))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openManagerFromDock() { model.showManager() }
    @objc private func addCameraFromDock() { model.showAddCamera() }
    @objc private func toggleBridgeFromDock() { Task { await model.toggleBridgeRunning() } }

    /// A menu bar app keeps running when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Stops the engine (closes HAP sessions, withdraws Bonjour) before quitting, for at most
    /// `AppModel.terminationTimeLimit`: the reply doesn't wait for an engine stop that ignores cancellation.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.isPreview else { return .terminateNow }
        let model = model
        Task {
            await model.prepareToTerminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
