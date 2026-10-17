import BridgeEngine
import BridgeWeb
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The daemon's side of the internet guard (Watch, docs/superpowers/specs/2026-10-17-internet-guard-design.md): the `guard-set` request with
/// validated camera addresses, `status/guard.json` as a `GuardReport`, and the capability the engine gets on Camera Bridge OS only.
@Suite(.timeLimit(.minutes(2))) struct InternetGuardTests {
    private static let imageUnits = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Packages/CameraBridgeKit
        .deletingLastPathComponent().deletingLastPathComponent()                             // the repository
        .appending(path: "linux/os/mkosi.extra/usr/lib/systemd/system", directoryHint: .isDirectory)

    private static var report: [String: Any] { [
        "state": "ok", "message": "1 camera watched", "updatedAt": "2026-10-17T17:47:00Z", "available": true, "running": true,
        "timeZone": "America/Los_Angeles", "todayStart": "2026-10-17T07:00:00Z",
        "cameras": [
            ["address": "192.168.77.21", "level": "watch", "since": "2026-10-16T09:00:00Z", "today": 47, "last24h": 51, "extra": 1,
             "names": [["name": "p2p.example.com", "count": 47, "first": "2026-10-17T08:00:01Z", "last": "2026-10-17T17:46:01Z"]]],
            ["address": "fd00::21", "level": "watch", "today": 0, "last24h": 0, "names": []],
        ],
    ] }

    // MARK: guard-set

    @Test func theListGoesToTheHelperWithCanonicalAddressesAndTheTimeZone() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.system.setGuardedCameras([GuardedCamera(address: "192.168.77.21", level: .watch),
                                                GuardedCamera(address: "FD00:0:0:0:0:0:0:21", level: .watch),
                                                GuardedCamera(address: " 192.168.77.21 ", level: .watch)])
        let body = try #require(rig.helper?.bodies("guard-set").first)
        #expect(body == ["cameras": [["address": "192.168.77.21", "level": "watch"], ["address": "fd00::21", "level": "watch"]],
                         "timeZone": TimeZone.current.identifier] as NSDictionary, "each camera once, in the form the system logs it")
        try await rig.system.setGuardedCameras([])
        #expect(rig.helper?.bodies("guard-set").last == ["cameras": [], "timeZone": TimeZone.current.identifier] as NSDictionary, "an empty list turns it off")
        #expect(rig.helper?.refused.withLock { $0.isEmpty } == true)
    }

    @Test func addressesOutsideTheLocalNetworkNeverReachTheHelper() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        for address in ["8.8.8.8", "192.0.2.10", "2001:db8::1", "127.0.0.1", "::1", "localhost", "", "192.168.77.21; reboot", "192.168.077.21",
                        "::ffff:192.168.77.21", "fe80::1%en0", "192.168.77", "10.0.0.256", "camera.local"] {
            await #expect(throws: SystemError.self, "\(address)") {
                try await rig.system.setGuardedCameras([GuardedCamera(address: address, level: .watch)])
            }
        }
        let tooMany = (1...65).map { GuardedCamera(address: "10.0.0.\($0)", level: .watch) }
        await #expect(throws: SystemError("At most 64 cameras can be watched.")) { try await rig.system.setGuardedCameras(tooMany) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.helper?.names().isEmpty == true)
        #expect(rig.leftovers.isEmpty)
    }

    @Test func onlyAddressesOnTheLocalNetworkAreAccepted() {
        let accepted = ["10.1.2.3": "10.1.2.3", "172.16.0.1": "172.16.0.1", "172.31.255.254": "172.31.255.254", "192.168.77.21": "192.168.77.21",
                        "169.254.10.20": "169.254.10.20", "fd00::21": "fd00::21", "FC00:0:0:1:0:0:0:1": "fc00:0:0:1::1", "fe80::1": "fe80::1",
                        "febf:ffff::1": "febf:ffff::1"]
        for (input, canonical) in accepted { #expect(RequestFileSystemControl.guardedAddress(input) == canonical, "\(input)") }
        for refused in ["172.15.0.1", "172.32.0.1", "11.0.0.1", "0.0.0.0", "255.255.255.255", "fec0::1", "ff02::1", "2001:db8::1", "::", "1.2.3.4.5"] {
            #expect(RequestFileSystemControl.guardedAddress(refused) == nil, "\(refused)")
        }
    }

    @Test func aRefusedListShowsTheHelpersSentence() async throws {
        let rig = try Rig(helper: { helper, name, _ in helper.writeStatus(name, "failed", "failed (exit 1); see the system log") })
        defer { rig.finish() }
        do {
            try await rig.system.setGuardedCameras([GuardedCamera(address: "192.168.77.21", level: .watch)])
            Issue.record("should have failed")
        } catch let error as SystemError {
            #expect(error.message.hasPrefix("The system couldn’t change the internet guard."))
            #expect(error.message.contains("see the system log"))
        }
    }

    /// The job's end can belong to an older list (a request that came while the last one ran): the list counts as taken only when the
    /// box's report lists exactly its cameras, else it is refused and the engine sends it again.
    @Test func aListTheBoxDoesNotReportIsRefused() async throws {
        let rig = try Rig(helper: { helper, name, _ in
            helper.write("guard.json", ["state": "ok", "available": true, "running": true, "updatedAt": helper.clock.peek().formatted(Date.ISO8601FormatStyle()),
                                        "cameras": [["address": "192.168.77.22", "level": "watch", "today": 0, "last24h": 0, "names": []]]])
            helper.writeStatus(name, "ok", "done")
        })
        defer { rig.finish() }
        do {
            try await rig.system.setGuardedCameras([GuardedCamera(address: "192.168.77.21", level: .watch)])
            Issue.record("should have failed")
        } catch let error as SystemError {
            #expect(error.message == "The system couldn’t change the internet guard. It still watches another list.")
        }
        try await rig.system.setGuardedCameras([GuardedCamera(address: "192.168.77.22", level: .watch)])
    }

    // MARK: status/guard.json

    @Test func theReportComesFromTheStatusFile() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        #expect(await rig.system.guardReport() == .unavailable, "nothing written yet")
        let writer = FakeRootHelper(requests: rig.requests, status: rig.status, clock: rig.clock) { _, _, _ in }
        writer.write("guard.json", Self.report)
        let report = await rig.system.guardReport()
        #expect(report.available && report.running == true && report.timeZone == "America/Los_Angeles")
        #expect(report.todayStart == (try Date("2026-10-17T07:00:00Z", strategy: .iso8601)))
        #expect(report.cameras.map(\.address) == ["192.168.77.21", "fd00::21"])
        let camera = try #require(report.camera(at: "192.168.77.21"))
        #expect(camera.level == .watch && camera.today == 47 && camera.last24h == 51)
        #expect(camera.since == (try Date("2026-10-16T09:00:00Z", strategy: .iso8601)), "watched without a break since then")
        #expect(report.camera(at: "fd00::21")?.since == nil, "a box that does not say")
        #expect(camera.names == [GuardReport.Lookup(name: "p2p.example.com", count: 47, first: try Date("2026-10-17T08:00:01Z", strategy: .iso8601),
                                                    last: try Date("2026-10-17T17:46:01Z", strategy: .iso8601))])
    }

    @Test func aDamagedReportIsUnavailableAndALargeOneIsStillRead() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        try Data("not json".utf8).write(to: rig.status.appending(path: "guard.json"))
        #expect(await rig.system.guardReport() == .unavailable)
        // 64 cameras with 50 long names each is more than the other status files may be.
        let names = (0..<50).map { ["name": String(repeating: "a", count: 60) + ".\($0).example.com", "count": $0, "first": "2026-10-17T08:00:01Z",
                                    "last": "2026-10-17T17:46:01Z"] as [String: Any] }
        var large = Self.report
        large["cameras"] = (1...64).map { ["address": "10.0.0.\($0)", "level": "watch", "today": 1, "last24h": 1, "names": names] as [String: Any] }
        let writer = FakeRootHelper(requests: rig.requests, status: rig.status, clock: rig.clock) { _, _, _ in }
        writer.write("guard.json", large)
        #expect((try Data(contentsOf: rig.status.appending(path: "guard.json"))).count > 256 * 1024)
        #expect(await rig.system.guardReport().cameras.count == 64)
    }

    @Test func withoutTheSystemThereIsNoGuard() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let system = RequestFileSystemControl(requestDirectory: directory.file("requests"), statusDirectory: directory.file("status"), product: "Camera Bridge OS",
                                              version: "0.1", build: "test")
        await #expect(throws: SystemError.self) { try await system.setGuardedCameras([GuardedCamera(address: "192.168.77.21", level: .watch)]) }
        #expect(await system.guardReport() == .unavailable)
        #expect(directory.contents().isEmpty)
    }

    // MARK: The engine's capability

    @Test @MainActor func theGuardIsOfferedWhereTheImageHasItsUnit() throws {
        #expect(Daemon.offersInternetGuard(development: false, systemAvailable: true, unitDirectory: Self.imageUnits))
        #expect(!Daemon.offersInternetGuard(development: true, systemAvailable: true, unitDirectory: Self.imageUnits), "not in a development run")
        #expect(!Daemon.offersInternetGuard(development: false, systemAvailable: false, unitDirectory: Self.imageUnits), "not without the system")
        let empty = try TemporaryDirectory()
        defer { empty.remove() }
        #expect(!Daemon.offersInternetGuard(development: false, systemAvailable: true, unitDirectory: empty.url), "not on a box without the unit")
    }

    @Test @MainActor func theEngineReachesTheGuardThroughTheSystem() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let plain = BridgeEnvironment.testing(directory: rig.directory.url)
        #expect(!plain.hasInternetGuard && plain.setGuardedCameras == nil && plain.guardReport == nil, "off unless the daemon gives it")
        let environment = Daemon.withInternetGuard(plain, system: rig.system)
        #expect(environment.hasInternetGuard)
        let report = try #require(environment.guardReport)
        #expect(await report() == nil, "no report yet")
        let set = try #require(environment.setGuardedCameras)
        try await set([GuardedCamera(address: "192.168.77.21", level: .watch)])
        #expect(rig.helper?.bodies("guard-set").first?["cameras"] as? NSArray == [["address": "192.168.77.21", "level": "watch"]] as NSArray)
        rig.helper?.write("guard.json", Self.report)
        #expect(await report()?.cameras.count == 2)
    }
}
