import BridgeEngine
import BridgeSupport
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// `--lan` and the hidden `--demo-keyframe-seconds`: the two development flags the NVR's integration runs use. `--dev` alone keeps the web
/// interface on 127.0.0.1; only a person who asks for `--lan` (and only next to `--dev`) opens it to the network.
@Suite struct DevelopmentFlagsTests {
    @Test func devKeepsTheWebInterfaceOnLoopbackAndLanOpensItAgain() throws {
        let dev = try DaemonOptions.parse(arguments: ["--dev"])
        #expect(dev.development && dev.webLoopbackOnly && !dev.lan)
        let lan = try DaemonOptions.parse(arguments: ["--dev", "--lan"])
        #expect(lan.development && lan.lan && !lan.webLoopbackOnly, "only the web listener changes")
        let reversed = try DaemonOptions.parse(arguments: ["--lan", "--dev"])
        #expect(reversed.lan && !reversed.webLoopbackOnly, "the order does not matter")
        #expect(lan.port == 8080 && lan.hapBasePort == nil && lan.sensorsBridgePort == nil, "--lan changes nothing else")
        let explicit = try DaemonOptions.parse(arguments: ["--dev", "--lan", "--hap-base-port", "38100", "--sensors-port", "0", "--port", "8181"])
        #expect(explicit.hapBasePort == 38_100 && explicit.sensorsBridgePort == 0 && explicit.port == 8181 && !explicit.webLoopbackOnly && explicit.development)
    }

    @Test func lanAloneIsRefusedSoARealBoxIsNeverOpenedByAccident() {
        for arguments in [["--lan"], ["--loopback-only", "--lan"], ["--port", "8181", "--lan"]] {
            do {
                _ = try DaemonOptions.parse(arguments: arguments)
                Issue.record("\(arguments) must be refused")
            } catch let error as DaemonOptions.UsageError {
                #expect(error.message.contains("--dev"))
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test(arguments: [["--dev", "--demo-keyframe-seconds", "12"], ["--preview", "--demo-keyframe-seconds=12"], ["--demo-keyframe-seconds", "12", "--dev"]])
    func theDemoKeyframeIntervalIsAcceptedWithDevOrPreview(arguments: [String]) throws {
        #expect(try DaemonOptions.parse(arguments: arguments).demoKeyframeSeconds == 12)
        #expect(try DaemonOptions.parse(arguments: ["--dev"]).demoKeyframeSeconds == nil)
    }

    @Test(arguments: [
        ["--demo-keyframe-seconds", "12"],
        ["--dev", "--demo-keyframe-seconds", "0"],
        ["--dev", "--demo-keyframe-seconds", "121"],
        ["--dev", "--demo-keyframe-seconds", "twelve"],
        ["--dev", "--demo-keyframe-seconds", "nan"],
        ["--dev", "--demo-keyframe-seconds"],
    ])
    func anythingElseIsAUsageError(arguments: [String]) {
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: arguments) }
    }

    @Test func theUsageTextDocumentsLanAndNotTheHiddenFlag() {
        #expect(DaemonOptions.usage.contains("--lan"))
        #expect(!DaemonOptions.usage.contains("demo-keyframe"))
    }

    /// Apple TVs find the box by `_camera-bridge._tcp`, and only a Camera Bridge OS box announces it: not a development run (`--lan` included, which
    /// opens the web interface to the network), not the preview, and not a Mac (its environment advertises nothing). Every Apple TV in the house
    /// would otherwise list a second "Camera Bridge".
    @Test @MainActor func onlyCameraBridgeOSAnnouncesForAppleTVs() throws {
        let directory = try TemporaryDirectory(prefix: "cb-flags")
        defer { directory.remove() }
        let platform = NullServiceAdvertiser()
        var environment = BridgeEnvironment.testing(directory: directory.url)
        environment.platform.advertiser = platform
        let box = try DaemonOptions.parse(arguments: [])
        let development = try DaemonOptions.parse(arguments: ["--dev"])
        let lan = try DaemonOptions.parse(arguments: ["--dev", "--lan"])
        let preview = try DaemonOptions.parse(arguments: ["--preview"])

        environment.advertise = false   // a Mac, and every test environment
        for options in [box, development, lan, preview] {
            #expect(Daemon.viewerAdvertiser(options: options, environment: environment) == nil)
        }

        environment.advertise = true    // Camera Bridge OS
        let announced = try #require(Daemon.viewerAdvertiser(options: box, environment: environment), "the box announces")
        #expect(announced as AnyObject === platform, "through the platform's own advertiser")
        #expect(Daemon.viewerAdvertiser(options: development, environment: environment) == nil, "--dev announces nothing")
        #expect(Daemon.viewerAdvertiser(options: lan, environment: environment) == nil, "--dev --lan announces nothing")
        #expect(Daemon.viewerAdvertiser(options: preview, environment: environment) == nil, "--preview announces nothing")
    }
}
