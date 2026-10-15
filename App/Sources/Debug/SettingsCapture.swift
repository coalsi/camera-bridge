#if DEBUG
import AppKit
import BridgeSupport
import Foundation

/// Debug builds only: `-captureSettings YES` opens the Settings window, walks through every tab and writes a PNG of each, plus `toolbar.json`
/// with what the window's toolbar holds and shows, to `$TMPDIR/CameraBridgeSettings/`. The toolbar of a Settings window drops the tabs that do
/// not fit into an overflow menu: `toolbar.json`'s `hidden` is the number of tabs that did (it must be 0), `window` and `tabs` say how wide the window
/// is and how many tabs it has. `-captureWidth` does not apply: the window is as `SettingsView` sizes it. Run with `-previewEngine YES`
/// (sample data, nothing changes) or in a measurement run. Quits when done.
@MainActor
enum SettingsCapture {
    static let argumentKey = "captureSettings"
    private static let log = Log(category: "Screenshots")

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: argumentKey) }

    static func run(model: AppModel) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraBridgeSettings", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.showSettings()
        guard let window = await settingsWindow() else {
            log.error("The Settings window did not open")
            Quit.now()
            return
        }
        for tab in SettingsTab.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
            try? await Task.sleep(for: .seconds(1))
            try? ScreenshotCapture.write(window, to: directory.appending(path: "settings-\(tab.rawValue).png"))
        }
        let toolbar = window.toolbar
        let items = toolbar?.items ?? []
        let visible = toolbar?.visibleItems ?? items
        let report: [String: Any] = [
            "window": ["width": window.contentLayoutRect.width, "height": window.contentLayoutRect.height],
            "tabs": SettingsTab.allCases.count,
            "items": items.count,
            "visible": visible.count,
            "hidden": max(0, items.count - visible.count),
            "itemFrames": items.compactMap { $0.view?.frame }.map { ["x": $0.minX, "width": $0.width] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appending(path: "toolbar.json"))
        }
        log.notice("Settings screenshots written to \(directory.path)")
        Quit.now()
    }

    private static func settingsWindow() async -> NSWindow? {
        for _ in 0..<50 {
            let candidates = NSApp.windows.filter { $0.toolbar != nil && $0.styleMask.contains(.titled) }
            if let window = candidates.first(where: { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true })
                ?? candidates.first(where: { abs($0.contentLayoutRect.width - 740) < 2 }) {
                if !window.isVisible { window.orderFrontRegardless() }
                if window.isVisible { return window }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
#endif
