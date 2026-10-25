/// The Sky Watcher as a plugin: a switch on the Plugins page (`BridgeSettings.plugins["sky"]`, off on a new box; `BridgeSettings.skyPluginOn`) and its own
/// page, `#/sky`. It has no account, no sign-in and nothing to sync, so it has no routes of its own: `PATCH plugins/sky` is the generic switch and
/// `GET plugins` lists it with the others. While the switch is off the engine runs none of the Sky Watcher and no camera can be turned on for it
/// (`WebApp.skyDetectorSettings`); what the box and its cameras were set to is kept.
enum SkyWatcherPlugin {
    static let id = "sky"

    /// What `PATCH cameras/:id` answers (400, with this field) when a camera is turned on for the Sky Watcher while the plugin is off.
    static let pluginOffField = "plugins.sky"
    static let pluginOffSentence = "Turn on Sky Watcher in Plugins first."
}
