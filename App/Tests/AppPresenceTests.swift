import AppKit
import BridgeEngine
import Foundation
import Testing

/// Settings › General › Show in Dock / Show in Menu Bar: the "at least one" rule, persistence, and the activation policy
/// each combination needs.
@Suite struct AppPresenceTests {
    @Test func newAndExistingInstallsStartWithBothOn() {
        let scratch = ScratchDefaults()
        let presence = AppPresence(defaults: scratch.defaults)
        #expect(presence == AppPresence(showInDock: true, showInMenuBar: true))
        #expect(presence == .standard)
    }

    @Test func storedChoicesAreReadBack() {
        let scratch = ScratchDefaults()
        AppPresence(showInDock: false, showInMenuBar: true).save(to: scratch.defaults)
        #expect(AppPresence(defaults: scratch.defaults) == AppPresence(showInDock: false, showInMenuBar: true))
        AppPresence(showInDock: true, showInMenuBar: false).save(to: scratch.defaults)
        #expect(AppPresence(defaults: scratch.defaults) == AppPresence(showInDock: true, showInMenuBar: false))
        #expect(AppPresence.dockKey == "showInDock" && AppPresence.menuBarKey == "showInMenuBar")
    }

    @Test func theLastOneOnCannotBeTurnedOff() {
        let both = AppPresence.standard
        #expect(both.canTurnOff(.dock) && both.canTurnOff(.menuBar))

        let dockOnly = AppPresence(showInDock: true, showInMenuBar: false)
        #expect(!dockOnly.canTurnOff(.dock), "the Dock is the last one on")
        #expect(dockOnly.setting(.dock, to: false) == dockOnly, "refused")
        #expect(dockOnly.setting(.menuBar, to: true) == both)

        let menuBarOnly = AppPresence(showInDock: false, showInMenuBar: true)
        #expect(!menuBarOnly.canTurnOff(.menuBar))
        #expect(menuBarOnly.setting(.menuBar, to: false) == menuBarOnly, "refused")
        #expect(menuBarOnly.setting(.dock, to: true) == both)

        #expect(both.setting(.dock, to: false) == menuBarOnly)
        #expect(both.setting(.menuBar, to: false) == dockOnly)
    }

    @Test func aStoredStateWithBothOffIsRepairedAndWrittenBack() {
        let scratch = ScratchDefaults()
        AppPresence(showInDock: false, showInMenuBar: false).save(to: scratch.defaults)
        let presence = AppPresence.loadRepairing(from: scratch.defaults)
        #expect(presence == AppPresence(showInDock: false, showInMenuBar: true), "the menu bar, the app's original home, comes back")
        #expect(scratch.defaults.bool(forKey: AppPresence.menuBarKey), "the status item's @AppStorage reads the repair too")
        #expect(!scratch.defaults.bool(forKey: AppPresence.dockKey))
        #expect(AppPresence(showInDock: false, showInMenuBar: false).repaired == presence)
    }

    @Test func theDockSettingDecidesTheActivationPolicy() {
        #expect(AppPresence(showInDock: true, showInMenuBar: true).activationPolicy == .regular)
        #expect(AppPresence(showInDock: true, showInMenuBar: false).activationPolicy == .regular)
        #expect(AppPresence(showInDock: false, showInMenuBar: true).activationPolicy == .accessory)
    }

    @Test func thePolicyIsOnlyChangedWhenItDiffers() {
        let dock = AppPresence(showInDock: true, showInMenuBar: true)
        let menuBarOnly = AppPresence(showInDock: false, showInMenuBar: true)
        #expect(dock.policyChange(from: .regular) == nil)
        #expect(dock.policyChange(from: .accessory) == .regular)
        #expect(dock.policyChange(from: .prohibited) == .regular)
        #expect(menuBarOnly.policyChange(from: .accessory) == nil)
        #expect(menuBarOnly.policyChange(from: .regular) == .accessory)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AppPresenceModelTests {
    private func model(defaults: UserDefaults) -> AppModel {
        AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                 defaults: defaults, previewLatency: .zero)
    }

    @Test func settingsChangesPersistAndReachTheAppDelegate() {
        let scratch = ScratchDefaults()
        let model = model(defaults: scratch.defaults)
        var applied: [AppPresence] = []
        model.presenceHandler = { applied.append($0) }
        #expect(model.presence == .standard)

        model.setPresence(.dock, to: false)
        #expect(model.presence == AppPresence(showInDock: false, showInMenuBar: true))
        #expect(!scratch.defaults.bool(forKey: AppPresence.dockKey) && scratch.defaults.bool(forKey: AppPresence.menuBarKey))
        #expect(applied == [AppPresence(showInDock: false, showInMenuBar: true)])

        model.setPresence(.menuBar, to: false)   // the last one on: refused, nothing stored, nothing applied
        #expect(model.presence == AppPresence(showInDock: false, showInMenuBar: true))
        #expect(scratch.defaults.bool(forKey: AppPresence.menuBarKey))
        #expect(applied.count == 1)

        model.setPresence(.dock, to: true)
        model.setPresence(.menuBar, to: false)
        #expect(model.presence == AppPresence(showInDock: true, showInMenuBar: false))
        #expect(applied.count == 3)
        #expect(model.presence.activationPolicy == .regular)
    }

    @Test func aNewModelReadsTheStoredPresence() {
        let scratch = ScratchDefaults()
        AppPresence(showInDock: true, showInMenuBar: false).save(to: scratch.defaults)
        #expect(model(defaults: scratch.defaults).presence == AppPresence(showInDock: true, showInMenuBar: false))
    }
}
