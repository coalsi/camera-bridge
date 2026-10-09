import AppKit
import SwiftUI

enum WindowID {
    static let manager = "manager"
    static let about = "about"
}

extension AppModel {
    /// Lets the model (menu items, the reopen handler) open the manager window: `openWindow` + `NSApp.activate()`,
    /// since an agent app isn't frontmost when its menu bar extra is used.
    func installWindowOpener(_ openWindow: OpenWindowAction, openSettings: OpenSettingsAction? = nil) {
        if let openSettings {
            settingsOpener = {
                NSApp.activate()
                openSettings()
            }
        }
        windowOpener = {
            openWindow(id: WindowID.manager)
            NSApp.activate()
        }
    }
}
