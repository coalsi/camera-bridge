import Foundation
import Testing

@Suite struct LaunchOptionsTests {
    @Test func defaultsToTheLiveEngine() {
        let scratch = ScratchDefaults()
        #expect(LaunchOptions(defaults: scratch.defaults) == LaunchOptions())
        #expect(!LaunchOptions().usesPreviewEngine)
    }

    /// `-previewEngine YES` lands in the argument domain as a Bool, like any other default.
    @Test func readsLaunchArguments() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(true, forKey: "previewEngine")
        scratch.defaults.set("YES", forKey: "openManager")
        scratch.defaults.set(true, forKey: "showOnboarding")
        scratch.defaults.set("YES", forKey: "openSettings")
        let options = LaunchOptions(defaults: scratch.defaults)
        #expect(options.usesPreviewEngine && options.opensManagerAtLaunch && options.showsOnboarding && options.opensSettingsAtLaunch)
    }
}
