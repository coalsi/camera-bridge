import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where a clip goes. The person is asked every time, so the model asks through this: tests answer for the person, the app opens a panel.
nonisolated protocol ClipDestinationPicking: Sendable {
    /// One camera in one part: a Save panel named `suggestedName`, starting in `startingIn`. Returns the file the person chose; nil when they cancelled.
    @MainActor func pickFile(suggestedName: String, startingIn: URL?) async -> URL?
    /// Several cameras (or several parts): a panel that chooses a folder, starting in `startingIn`. Returns that folder; nil when they cancelled.
    @MainActor func pickFolder(startingIn: URL?) async -> URL?
}

/// The panels of the app: a Save panel or a folders-only panel as a sheet on the window the person is using (as Save Snapshot does), else a panel of
/// its own. Without a folder to start in a panel opens in Downloads, never in the recordings folder.
nonisolated struct PanelClipDestinations: ClipDestinationPicking {
    init() {}

    @MainActor func pickFile(suggestedName: String, startingIn: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Clip")
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = Self.startFolder(startingIn)
        return await Self.run(panel) ? panel.url : nil
    }

    @MainActor func pickFolder(startingIn: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Save Clips")
        panel.message = String(localized: "Choose where to save the clips. Camera Bridge makes a new folder there.")
        panel.prompt = String(localized: "Save Clips")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.startFolder(startingIn)
        return await Self.run(panel) ? panel.url : nil
    }

    /// The folder a panel opens in: the one asked for, else Downloads.
    static func startFolder(_ requested: URL?) -> URL? {
        requested ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Shows `panel` as a sheet on the key window (else on its own) and says whether the person chose something.
    @MainActor private static func run(_ panel: NSSavePanel) async -> Bool {
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        }
        return response == .OK
    }
}
