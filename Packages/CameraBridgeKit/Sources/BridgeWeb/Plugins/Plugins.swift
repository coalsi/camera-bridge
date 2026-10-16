import BridgeEngine
import Foundation

/// The plugins this build of the bridge has (compiled in: nothing is downloaded or loaded at run time). A plugin is switched on per bridge
/// (`BridgeSettings.plugins`), keeps its secrets in the platform `SecretStore` (`BridgeBackend.pluginSecret(id:)`) and has its own routes
/// under `plugins/<id>/…` and its own page `#/plugins/<id>`.
enum PluginCatalog {
    struct Descriptor: Sendable, Encodable {
        var id: String
        var name: String
        var summary: String
        /// What the person needs to use it, in a sentence.
        var needs: String
        /// Unofficial access the vendor's terms do not cover, said on the page.
        var caution: String?
    }

    static let all: [Descriptor] = [
        Descriptor(
            id: WyzePlugin.id, name: "Wyze",
            summary: "Sign in to your Wyze account to see your Wyze cameras and add them: through the camera’s own RTSP where it has it, or a local Wyze connection.",
            needs: "A Wyze account and an API key from Wyze’s developer console.",
            caution: "The local Wyze connection is unofficial: Wyze’s terms allow its API keys and RTSP, not other apps. Camera Bridge prefers RTSP when the camera has it."),
        Descriptor(
            id: EufyPlugin.id, name: "eufy",
            summary: "Sign in to a eufy account to see its cameras and add them, battery cameras included: they wake for a live view, a recording or motion.",
            needs: "A eufy account. Best: a second account that your main account shares the cameras with, so the eufy app stays signed in.",
            caution: "eufy has no official way in for other apps: this uses the same connection as the eufy app, through the open-source eufy SDK, and can stop working when eufy changes it."),
    ]

    static func descriptor(id: String) -> Descriptor? { all.first { $0.id == id } }
}
