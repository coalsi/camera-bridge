import Foundation
import Testing
@testable import BridgeEngine

/// What the engine gets from Camera Bridge OS's internet guard: `GuardedCamera` for the list it sends, `GuardReport` for what the box saw
/// (`status/guard.json`, linux/os/README.md), read leniently because the root side writes it.
@Suite struct InternetGuardTypesTests {
    private func report(_ json: String) throws -> GuardReport {
        try JSONDecoder().decode(GuardReport.self, from: Data(json.utf8))
    }

    private func date(_ text: String) throws -> Date { try Date(text, strategy: .iso8601) }

    @Test func aGuardedCameraIsAnAddressAndALevel() throws {
        let camera = GuardedCamera(address: "192.168.77.21", level: .watch)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? NSDictionary
        #expect(encoded == ["address": "192.168.77.21", "level": "watch"] as NSDictionary)
        #expect(try JSONDecoder().decode(GuardedCamera.self, from: JSONEncoder().encode(camera)) == camera)
        #expect(GuardLevel.allCases == [.watch], "stage 1: Watch only")
    }

    @Test func theStatusFileIsReadAsTheRootSideWritesIt() throws {
        let decoded = try report("""
        {"state":"ok","message":"2 cameras watched","updatedAt":"2026-10-17T17:47:00Z","available":true,"running":false,
         "timeZone":"America/Los_Angeles","todayStart":"2026-10-17T07:00:00Z",
         "cameras":[{"address":"192.168.77.21","level":"watch","today":47,"last24h":51,
                     "names":[{"name":"p2p.example.com","count":47,"first":"2026-10-17T08:00:01Z","last":"2026-10-17T17:46:01Z"}]}]}
        """)
        #expect(decoded == GuardReport(available: true, running: false, updatedAt: try date("2026-10-17T17:47:00Z"), timeZone: "America/Los_Angeles",
                                       todayStart: try date("2026-10-17T07:00:00Z"),
                                       cameras: [GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 47, last24h: 51,
                                                                    names: [GuardReport.Lookup(name: "p2p.example.com", count: 47, first: try date("2026-10-17T08:00:01Z"),
                                                                                               last: try date("2026-10-17T17:46:01Z"))])]))
    }

    @Test func whatTheRootSideLeavesOutOrGetsWrongDoesNotLoseTheRest() throws {
        let decoded = try report("""
        {"available":true,"updatedAt":"yesterday","newField":{"x":1},
         "cameras":[{"address":"192.168.77.21","level":"seal","today":"3","last24h":4.0,
                     "names":[{"name":"","count":1},{"name":"cloud.example.net","count":2,"first":12},{"count":5}]},
                    {"level":"watch","today":3},
                    {"address":"","today":1},
                    "not a camera",
                    {"address":"192.168.77.22"}]}
        """)
        #expect(decoded.available && decoded.updatedAt == nil && decoded.running == nil && decoded.todayStart == nil)
        #expect(decoded.cameras.map(\.address) == ["192.168.77.21", "192.168.77.22"], "a camera without an address is skipped")
        let first = decoded.cameras[0]
        #expect(first.level == nil, "a level this build does not know")
        #expect(first.today == 3 && first.last24h == 4)
        #expect(first.names == [GuardReport.Lookup(name: "cloud.example.net", count: 2, first: nil, last: nil)])
        #expect(decoded.cameras[1] == GuardReport.Camera(address: "192.168.77.22", level: nil, today: 0, last24h: 0, names: []))
        #expect(try report("{}") == GuardReport(available: false), "an empty file says nothing")
        #expect(GuardReport.unavailable == GuardReport(available: false))
    }

    @Test func aReportSurvivesTheWebLayersEncoder() throws {
        let original = GuardReport(available: true, running: true, updatedAt: try date("2026-10-17T17:47:00Z"), timeZone: "UTC", todayStart: try date("2026-10-17T00:00:00Z"),
                                   cameras: [GuardReport.Camera(address: "fd00::21", level: .watch, today: 1, last24h: 2,
                                                                names: [GuardReport.Lookup(name: "a.example.com", count: 2, first: try date("2026-10-17T01:00:00Z"),
                                                                                           last: try date("2026-10-17T02:00:00Z"))])])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try JSONDecoder().decode(GuardReport.self, from: encoder.encode(original)) == original)
        #expect(original.camera(at: "fd00::21")?.today == 1 && original.camera(at: "192.168.77.21") == nil)
    }
}
