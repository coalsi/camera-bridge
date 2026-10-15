import Foundation
import Testing
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
}
