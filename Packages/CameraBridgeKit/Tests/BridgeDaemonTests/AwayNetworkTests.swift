import BridgeEngine
import BridgeSupport
import BridgeWeb
import Foundation
import Testing
@testable import BridgeDaemon

/// The network Away from home reads its addresses from: only on a box with Camera Bridge OS underneath.
@Suite struct AwayNetworkTests {
    @Test @MainActor func theDaemonGivesTheNetworkOnlyWithTheSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "away-network-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try Daemon.makeEnvironment(directory: directory, options: DaemonOptions())
        #expect(Daemon.awayNetwork(systemAvailable: false, environment: environment) == nil)
        #if os(Linux)
        #expect(Daemon.awayNetwork(systemAvailable: true, environment: environment) != nil)
        #else
        #expect(Daemon.awayNetwork(systemAvailable: true, environment: environment) == nil, "Away from home is part of Camera Bridge OS")
        #endif
    }

    #if os(Linux)
    /// A monitor the test fires by hand.
    private final class FakeMonitor: NetworkChangeMonitoring {
        let broadcaster = AsyncBroadcaster<Void>(bufferingNewest: 1)
        var changes: AsyncStream<Void> { broadcaster.subscribe() }
    }

    @Test func aChangeRightAfterReadingTheStreamIsNotLost() async {
        let monitor = FakeMonitor()
        let network = LinuxAwayNetwork(monitor: monitor)
        let changes = network.changes   // taken before the change, as AwayService.start() takes it
        monitor.broadcaster.yield(())
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func theNetworkReadsOffThePoolAndNeverThrows() async {
        let network = LinuxAwayNetwork(monitor: FakeMonitor())
        let prefixes = await network.ownPrefixes()
        #expect(prefixes.allSatisfy { $0.contains("/") }, "address/prefixLength")
        _ = await network.globalIPv6()
    }
    #endif
}
