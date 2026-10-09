import AppKit
import Foundation

/// Where CameraBridge shows up on the Mac: in the Dock (and the ⌘-Tab switcher), in the menu bar, or both (Settings ›
/// General). At least one is always on, so the app can always be reached. New and existing installs start with both
/// on. The Dock setting decides the activation policy (`.regular` shows the Dock icon and the main menu; `.accessory`
/// is the menu-bar-only app); the menu bar setting decides whether the status item is inserted.
struct AppPresence: Equatable {
    var showInDock: Bool
    var showInMenuBar: Bool

    static let dockKey = "showInDock"
    static let menuBarKey = "showInMenuBar"
    static let standard = AppPresence(showInDock: true, showInMenuBar: true)

    enum Place: Equatable {
        case dock, menuBar
    }

    /// Reads the stored settings: a missing key is on, and a stored state with both off (edited by hand) is repaired.
    init(defaults: UserDefaults) {
        self.init(showInDock: defaults.object(forKey: Self.dockKey) as? Bool ?? true,
                  showInMenuBar: defaults.object(forKey: Self.menuBarKey) as? Bool ?? true)
        self = repaired
    }

    init(showInDock: Bool, showInMenuBar: Bool) {
        self.showInDock = showInDock
        self.showInMenuBar = showInMenuBar
    }

    /// `init(defaults:)`, and when both were stored off, the repair written back so that every reader of the stored
    /// settings (the status item's `@AppStorage`) agrees with it.
    static func loadRepairing(from defaults: UserDefaults) -> AppPresence {
        let presence = AppPresence(defaults: defaults)
        if defaults.object(forKey: dockKey) as? Bool == false, defaults.object(forKey: menuBarKey) as? Bool == false {
            presence.save(to: defaults)
        }
        return presence
    }

    func save(to defaults: UserDefaults) {
        defaults.set(showInDock, forKey: Self.dockKey)
        defaults.set(showInMenuBar, forKey: Self.menuBarKey)
    }

    func isOn(_ place: Place) -> Bool {
        switch place {
        case .dock: showInDock
        case .menuBar: showInMenuBar
        }
    }

    /// Both off is not a state CameraBridge can be in: the menu bar (the app's original home) comes back on.
    var repaired: AppPresence {
        showInDock || showInMenuBar ? self : AppPresence(showInDock: false, showInMenuBar: true)
    }

    /// Whether `place` may be switched off: only while the other one stays on. Settings disables the switch that is
    /// the last one on.
    func canTurnOff(_ place: Place) -> Bool {
        switch place {
        case .dock: showInMenuBar
        case .menuBar: showInDock
        }
    }

    /// `self` with `place` set to `on`, or unchanged when that would turn off the last one.
    func setting(_ place: Place, to on: Bool) -> AppPresence {
        guard on || canTurnOff(place) else { return self }
        var result = self
        switch place {
        case .dock: result.showInDock = on
        case .menuBar: result.showInMenuBar = on
        }
        return result
    }

    /// The activation policy this presence needs: a Dock icon (and a main menu, and ⌘-Tab) is `.regular`.
    var activationPolicy: NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// What to set the activation policy to, given the current one; nil when it already matches (setting the same
    /// policy again would still make the app deactivate and reactivate).
    func policyChange(from current: NSApplication.ActivationPolicy) -> NSApplication.ActivationPolicy? {
        current == activationPolicy ? nil : activationPolicy
    }
}
