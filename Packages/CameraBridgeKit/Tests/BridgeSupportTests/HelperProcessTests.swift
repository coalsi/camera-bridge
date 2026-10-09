import Foundation
import Testing
@testable import BridgeSupport

@Suite(.timeLimit(.minutes(1))) struct HelperOutputTests {
    @Test func splitsLinesAcrossChunks() {
        var splitter = HelperOutput.LineSplitter()
        #expect(splitter.feed(Data("hel".utf8)).isEmpty)
        #expect(splitter.feed(Data("lo\nwor".utf8)) == ["hello"])
        #expect(splitter.feed(Data("ld\r\n\n".utf8)) == ["world", ""])
        #expect(splitter.finish() == nil)
        _ = splitter.feed(Data("tail".utf8))
        #expect(splitter.finish() == "tail")
        #expect(splitter.finish() == nil)
    }

    @Test func aStreamWithoutLineEndsIsCutNotGrown() {
        var splitter = HelperOutput.LineSplitter(limit: 100)
        let lines = splitter.feed(Data(repeating: 0x61, count: 150))
        #expect(lines.count == 1 && lines[0].count == 150)
        #expect(splitter.finish() == nil)
    }

    @Test func invalidUTF8IsReplacedNotFatal() {
        var splitter = HelperOutput.LineSplitter()
        let lines = splitter.feed(Data([0x61, 0xFF, 0xFE, 0x62, 0x0A]))
        #expect(lines.count == 1 && lines[0].hasPrefix("a") && lines[0].hasSuffix("b"))
    }

    @Test func longLinesAreClippedForTheLog() {
        #expect(HelperOutput.clipped("short") == "short")
        let clipped = HelperOutput.clipped(String(repeating: "x", count: HelperOutput.maximumLineLength + 50))
        #expect(clipped.count == HelperOutput.maximumLineLength + 1 && clipped.hasSuffix("…"))
    }

    @Test func nullLauncherRunsNothing() {
        let launcher = NullHelperLauncher()
        #expect(launcher.locate("go2rtc") == nil)
        #expect(throws: HelperLaunchError.self) { try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/bin/sh"))) }
        #expect(!launcher.endStaleProcess(pidFile: URL(filePath: "/tmp/x.pid"), executable: URL(filePath: "/bin/sh")))
        #expect(PlatformServices(transport: UnusedNetworkTransport(), advertiser: NullServiceAdvertiser(), secrets: InMemorySecretStore(),
                                 networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager()).helpers.locate("x") == nil)
    }

    @Test func exitDescriptions() {
        #expect(HelperExit(status: 2).description == "exit status 2")
        #expect(HelperExit(status: 9, reason: .signaled).description == "signal 9")
    }
}

private struct UnusedNetworkTransport: NetworkTransport {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.closed }
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { throw TransportError.closed }
}
