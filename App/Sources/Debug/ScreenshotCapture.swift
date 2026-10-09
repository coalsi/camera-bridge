#if DEBUG
import AppKit
import BridgeEngine
import BridgeSupport
import Foundation
import SwiftUI

/// Debug builds only: `-captureScreenshots YES` walks the manager window through every page and writes PNGs of the
/// window (drawn by the app itself, so no screen-recording permission is needed) to
/// `$TMPDIR/CameraBridgeScreenshots/`. For UI review without clicking through the menu bar. With
/// `-previewEngine YES` (sample data) it also captures the Add Camera sheet and every wizard step; on the live engine
/// only the manager pages and the onboarding sheet (the Add Camera sheet would search the network).
@MainActor
enum ScreenshotCapture {
    static let argumentKey = "captureScreenshots"
    private static let log = Log(category: "Screenshots")

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: argumentKey) }

    static func run(model: AppModel) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Capturing screenshots")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        log.notice("Capturing screenshots")
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraBridgeScreenshots", directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model.showManager()
            guard let window = await managerWindow() else {
                log.error("Manager window not found")
                return
            }
            // `-captureWidth 1600 -captureHeight 1100` picks the window's content size (default 1100x780).
            let defaults = UserDefaults.standard
            window.setContentSize(NSSize(width: defaults.object(forKey: "captureWidth") == nil ? 1100 : defaults.double(forKey: "captureWidth"),
                                         height: defaults.object(forKey: "captureHeight") == nil ? 780 : defaults.double(forKey: "captureHeight")))

            var pages: [(String, ManagerSelection?)] = [("overview", .overview)]   // without cameras: the "No Cameras Yet" page
            pages += model.engine.cameras.map { ("camera-\(slug($0.name))", .camera($0.id)) }
            pages.append(("sensors-bridge", .sensorsBridge))
            for (index, (name, selection)) in pages.enumerated() {
                model.selection = selection
                if case .camera = selection {
                    // Every tab of the camera page (the page remembers the last tab through this defaults key).
                    for tab in CameraTab.allCases {
                        UserDefaults.standard.set(tab.rawValue, forKey: "cameraDetailTab")
                        // `-captureTabPause 8`: longer, e.g. until a `-demoHeroLive YES` hero shows LIVE.
                        try await pause(seconds: defaults.object(forKey: "captureTabPause") == nil ? 1.2 : defaults.double(forKey: "captureTabPause"))
                        try write(window, to: directory.appending(path: "manager-\(index + 1)-\(name)-\(tab.rawValue).png"))
                    }
                    // `-captureFinalTab streams` leaves the window on that tab afterwards (a still of one page at the captured size).
                    UserDefaults.standard.set(UserDefaults.standard.string(forKey: "captureFinalTab") ?? CameraTab.overview.rawValue, forKey: "cameraDetailTab")
                } else {
                    try await pause()
                    try write(window, to: directory.appending(path: "manager-\(index + 1)-\(name).png"))
                }
            }
            // The sidebar sits in the glass layer, which window caching leaves blank: draw its table on its own.
            if let root = window.contentView, let sidebar = firstSubview(of: NSTableView.self, in: root) {
                try write(view: sidebar, to: directory.appending(path: "sidebar.png"))
            }
            // The menu bar extra: one status bar window per menu bar (display); the log line confirms it is on screen.
            let statusWindows = NSApp.windows.filter { NSStringFromClass(type(of: $0)) == "NSStatusBarWindow" && $0.isVisible }
            let onScreen = statusWindows.filter { window in NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
            log.notice("Status item: \(onScreen.count) of \(statusWindows.count) status bar windows on screen")

            model.selection = model.engine.cameras.first.map { .camera($0.id) }
            let onboardingWasUp = model.isOnboardingPresented
            if model.isPreview, !onboardingWasUp {
                model.isAddCameraPresented = true
                try await pause(seconds: 2)
                if let sheet = window.attachedSheet { try write(sheet, to: directory.appending(path: "sheet-add-camera.png")) }
                model.isAddCameraPresented = false
                try await pause()
            }

            model.isOnboardingPresented = true
            try await pause(seconds: 1.5)
            if let sheet = window.attachedSheet { try write(sheet, to: directory.appending(path: "sheet-onboarding.png")) }
            model.isOnboardingPresented = onboardingWasUp
            try await pause()

            if !onboardingWasUp {
                model.presentedSheet = .localNetworkAccess
                try await pause(seconds: 1.5)
                if let sheet = window.attachedSheet { try write(sheet, to: directory.appending(path: "sheet-local-network.png")) }
                model.presentedSheet = nil
                try await pause()
            }

            if model.isPreview {
                try await captureOverviewAndSheets(model: model, window: window, to: directory)
                try await captureWizardPages(model: model, to: directory)
            }
            log.notice("Screenshots written to \(directory.path)")
        } catch {
            log.error("Screenshot capture failed: \(error.localizedDescription)")
        }
    }

    /// Sample data only: the Overview in each layout (written to the preview defaults the page reads when it appears), the
    /// single-camera viewer, and the VPN sheet.
    private static func captureOverviewAndSheets(model: AppModel, window: NSWindow, to directory: URL) async throws {
        let layouts: [(String, OverviewLayout)] = [("auto", OverviewLayout()), ("2x2", OverviewLayout(mode: .grid2)), ("3x3", OverviewLayout(mode: .grid3)),
                                                   ("custom-3x2", OverviewLayout(mode: .custom, customColumns: 3, customRows: 2))]
        for (name, layout) in layouts {
            model.selection = .sensorsBridge   // leave the page so the Overview reads the layout again
            model.preferences.set(try JSONEncoder().encode(layout), forKey: OverviewModel.layoutKey)
            try await pause(seconds: 0.5)
            model.selection = .overview
            try await pause(seconds: 1.5)
            try write(window, to: directory.appending(path: "overview-\(name).png"))
        }
        model.preferences.removeObject(forKey: OverviewModel.layoutKey)

        if let first = model.engine.cameras.first {
            model.expandCamera(first.id)
            try await pause(seconds: 8)   // until the LIVE chip
            try write(window, to: directory.appending(path: "viewer-\(slug(first.name)).png"))
            model.closeExpandedCamera()
            try await pause()
        }

        for (name, sheet) in [("vpn-help", ManagerSheet.vpnHelp)] {
            model.presentedSheet = sheet
            try await pause(seconds: 1.5)
            if let attached = window.attachedSheet { try write(attached, to: directory.appending(path: "sheet-\(name).png")) }
            model.presentedSheet = nil
            try await pause()
        }
    }

    /// Every Add Camera page, driven through the preview fixtures (a discovered Hikvision camera), in its own window.
    private static func captureWizardPages(model: AppModel, to directory: URL) async throws {
        let wizard = AddCameraWizardModel(service: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AddCameraWizard(model: model, wizard: wizard))
        window.center()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        await wizard.discover()
        if let first = wizard.discovered.first { wizard.select(first) }
        var index = 1
        while true {
            try await pause(seconds: 0.8)
            try write(window, to: directory.appending(path: "wizard-\(index)-\(slug(wizard.step.title)).png"))
            index += 1
            if wizard.step == .connect {
                wizard.username = "admin"
                wizard.password = "sample"
            }
            if wizard.step == .features, let first = wizard.availableSensors.first {
                wizard.sensors[keyPath: first.keyPath] = true
            }
            guard wizard.step != .pairing, wizard.canContinue else { break }
            await wizard.goForward()
        }
    }

    private static func managerWindow() async -> NSWindow? {
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.manager) == true }) {
                // Shown even if the app couldn't take focus (launched from Terminal).
                if !window.isVisible { window.orderFrontRegardless() }
                if window.isVisible { return window }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func pause(seconds: Double = 1) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// The whole window (title bar and toolbar included), as the app draws it.
    private static func write(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        try write(view: view, to: url)
    }

    private static func write(view: NSView, to url: URL) throws {
        guard let rep = bitmap(for: view) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    /// `-captureScale 2`: pixels per point of the PNGs (2880x1800 from a 1440x900 window on a 1x display);
    /// default: the display's own scale.
    private static func bitmap(for view: NSView) -> NSBitmapImageRep? {
        let scale = UserDefaults.standard.double(forKey: "captureScale")
        guard scale > 1 else { return view.bitmapImageRepForCachingDisplay(in: view.bounds) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = view.bounds.size
        return rep
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstSubview(of: type, in: child) { return match }
        }
        return nil
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }
}
#endif
