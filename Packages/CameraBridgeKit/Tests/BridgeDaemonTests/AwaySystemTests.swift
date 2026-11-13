import BridgeSupport
import BridgeWeb
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The daemon's side of Away from home on the system (docs/superpowers/specs/2026-11-12-away-from-home-design.md, "Daemon → root"): the
/// `away-set` request with checked values, and `status/away.json` as an `AwayStatus`.
@Suite(.timeLimit(.minutes(2))) struct AwaySystemTests {
    private static let key1 = String(repeating: "A", count: 43) + "="
    private static let key2 = String(repeating: "B", count: 42) + "A="

    private static func key(_ index: Int) -> String { String(format: "%042d", index) + "A=" }

    private static func request(_ keys: [String] = [key1], subnet: String = "10.77.12.0/24") -> AwayRequest {
        AwayRequest(on: true, subnet: subnet, peers: keys.enumerated().map { AwayRequest.Peer(publicKey: $1, address: "10.77.12.\($0 + 2)") })
    }

    private func writeStatus(_ rig: Rig, _ json: String) throws {
        try Data(json.utf8).write(to: rig.status.appending(path: "away.json"))
    }

    @Test func aSystemWithoutTheHelperHasNoAway() async throws {
        let rig = try Rig(helper: nil, awayHelper: "/nonexistent/cb-away")
        defer { rig.finish() }
        #expect(await rig.system.awayStatus() == nil)
        let withHelper = try Rig(helper: nil, awayHelper: "/bin/sh")
        defer { withHelper.finish() }
        #expect(await withHelper.system.awayStatus() == .off, "a helper but no status file yet")
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let nowhere = RequestFileSystemControl(requestDirectory: directory.file("requests"), statusDirectory: directory.file("status"), product: "p", version: "1",
                                               build: "b", awayHelper: "/bin/sh")
        #expect(await nowhere.awayStatus() == nil, "no request folders: no system")
        await #expect(throws: SystemError.self) { try await nowhere.setAway(Self.request()) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false)))?.isEmpty == true)
    }

    @Test func theStatusIsReadAndCleaned() async throws {
        let rig = try Rig(helper: nil, awayHelper: "/bin/sh")
        defer { rig.finish() }
        try writeStatus(rig, #"{"state":"ok","message":"Line one\nline\ttwo","publicKey":"\#(Self.key1)","port":51820,"router":"eero","updated":1800000000,"peers":[{"publicKey":"\#(Self.key2)","latestHandshake":1799999990,"endpoint":"2001:db8:9::7"},{"publicKey":"\#(Self.key1)","latestHandshake":0,"endpoint":null}]}"#)
        let status = try #require(await rig.system.awayStatus())
        #expect(status.state == "ok" && status.message == "Line one line two" && status.publicKey == Self.key1 && status.router == "eero" && status.updated == 1_800_000_000)
        #expect(status.peers == [AwayStatus.Peer(publicKey: Self.key2, latestHandshake: 1_799_999_990, endpoint: "2001:db8:9::7"),
                                 AwayStatus.Peer(publicKey: Self.key1, latestHandshake: 0, endpoint: nil)])
        try writeStatus(rig, #"{"state":"surprise","message":null,"updated":5}"#)
        let odd = try #require(await rig.system.awayStatus())
        #expect(odd.state == "failed", "an unknown state is a failure, not a success")
        #expect(odd.peers.isEmpty && odd.port == 51820 && odd.publicKey == nil)
    }

    @Test func theRequestCarriesOnlyCheckedValues() async throws {
        let rig = try Rig(awayHelper: "/bin/sh")
        defer { rig.finish() }
        var wrongPort = Self.request()
        wrongPort.port = 51821
        let twice = AwayRequest(on: true, subnet: "10.77.12.0/24", peers: [.init(publicKey: Self.key1, address: "10.77.12.2"), .init(publicKey: Self.key1, address: "10.77.12.3")])
        let refused: [AwayRequest] = [
            wrongPort,
            Self.request(subnet: "10.0.0.0/16"),
            Self.request(subnet: "10.42.5.0/24"),
            AwayRequest(on: true, subnet: "10.77.12.0/24", peers: [.init(publicKey: Self.key1, address: "10.77.13.2")]),
            AwayRequest(on: true, subnet: "10.77.12.0/24", peers: [.init(publicKey: Self.key1, address: "10.77.12.1")]),
            AwayRequest(on: true, subnet: "10.77.12.0/24", peers: [.init(publicKey: String(repeating: "A", count: 43), address: "10.77.12.2")]),
            AwayRequest(on: true, subnet: nil, peers: []),
            AwayRequest(on: true, subnet: "10.77.12.0/24", peers: (0..<65).map { .init(publicKey: Self.key($0), address: "10.77.12.\($0 % 250 + 2)") }),
            twice,
        ]
        for request in refused {
            #expect(request.problem != nil)
            await #expect(throws: SystemError.self) { try await rig.system.setAway(request) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.helper?.names().isEmpty == true)
        #expect(rig.leftovers.isEmpty)

        try await rig.system.setAway(Self.request())
        // Compared as parsed JSON: the encoder writes the slash in the subnet as "\/".
        #expect(rig.helper?.bodies("away-set").first == ["on": true, "port": 51820, "subnet": "10.77.12.0/24",
                                                          "peers": [["address": "10.77.12.2", "publicKey": Self.key1]]] as NSDictionary)
        #expect(Self.request().problem == nil)
        #expect(AwayRequest(on: false, subnet: nil, peers: []).problem == nil, "off needs nothing")
    }

    @Test func everyKeyIsInTheRequestEvenWithoutASubnet() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(AwayRequest(on: false, subnet: nil, peers: [])), as: UTF8.self)
        #expect(json == #"{"on":false,"peers":[],"port":51820,"subnet":null}"#)
    }

    @Test func aWireGuardPublicKeyIsThirtyTwoBytesWrittenTheOneWay() {
        #expect(AwayRequest.isPublicKey(Self.key1) && AwayRequest.isPublicKey(Self.key2))
        for bad in ["", String(repeating: "A", count: 43), String(repeating: "A", count: 42) + "B=", Self.key1 + "A", "AAAA", String(repeating: "A", count: 42) + "=="] {
            #expect(!AwayRequest.isPublicKey(bad), "\(bad)")
        }
    }

    @Test func theJobCountsOnlyWhenTheSystemListsExactlyTheseKeys() async throws {
        let dishonest = try Rig(helper: { helper, name, _ in
            helper.write("away.json", ["state": "ok", "message": NSNull(), "publicKey": Self.key1, "port": 51820, "router": NSNull(),
                                       "updated": Int(helper.clock.peek().timeIntervalSince1970),
                                       "peers": [["publicKey": Self.key2, "latestHandshake": 0, "endpoint": NSNull()]]])
            helper.writeStatus(name, "ok", "done")
        }, awayHelper: "/bin/sh")
        defer { dishonest.finish() }
        do {
            try await dishonest.system.setAway(Self.request())
            Issue.record("a list of other devices was taken for this one")
        } catch let error as SystemError {
            #expect(error.message == "The system couldn’t change Away from home. It still has another list of devices.")
        }
        let honest = try Rig(awayHelper: "/bin/sh")
        defer { honest.finish() }
        try await honest.system.setAway(Self.request([Self.key1, Self.key2]))
        let status = try #require(await honest.system.awayStatus())
        #expect(status.state == "ok" && Set(status.peers.map(\.publicKey)) == [Self.key1, Self.key2])
    }

    @Test func aFailedJobSaysTheSystemsSentence() async throws {
        let rig = try Rig(helper: { helper, name, _ in
            helper.write("away.json", ["state": "failed", "message": "The VPN interface isn’t up.", "publicKey": NSNull(), "port": 51820, "router": NSNull(),
                                       "updated": Int(helper.clock.peek().timeIntervalSince1970), "peers": []])
            helper.writeStatus(name, "failed", "failed (exit 1); see the system log")
        }, awayHelper: "/bin/sh")
        defer { rig.finish() }
        do {
            try await rig.system.setAway(Self.request())
            Issue.record("should have failed")
        } catch let error as SystemError {
            #expect(error.message == "The system couldn’t change Away from home. The VPN interface isn’t up.")
        }
    }

    @Test func anOlderRunsSentenceIsNotThisRequestsReason() async throws {
        // cb-away's own check refuses a request before it writes any status, so the file still holds an earlier run's failure.
        let rig = try Rig(helper: { helper, name, _ in helper.writeStatus(name, "failed", "failed (exit 1); see the system log") }, awayHelper: "/bin/sh")
        defer { rig.finish() }
        try writeStatus(rig, #"{"state":"failed","message":"The VPN interface isn’t up.","publicKey":null,"port":51820,"router":null,"peers":[],"updated":1000}"#)
        do {
            try await rig.system.setAway(Self.request())
            Issue.record("should have failed")
        } catch let error as SystemError {
            #expect(error.message.hasSuffix("failed (exit 1); see the system log") && !error.message.contains("VPN interface"))
        }
    }

    @Test func offIsDoneWhenTheSystemSaysOff() async throws {
        let rig = try Rig(awayHelper: "/bin/sh")
        defer { rig.finish() }
        try await rig.system.setAway(Self.request())
        try await rig.system.setAway(AwayRequest(on: false, subnet: "10.77.12.0/24", peers: []))
        #expect(await rig.system.awayStatus()?.state == "off")
        #expect(rig.helper?.bodies("away-set").last?["on"] as? Bool == false)
        // A system that still reports the tunnel after an off request has not turned it off.
        let stuck = try Rig(helper: { helper, name, _ in
            helper.write("away.json", ["state": "ok", "message": NSNull(), "publicKey": Self.key1, "port": 51820, "router": NSNull(),
                                       "updated": Int(helper.clock.peek().timeIntervalSince1970), "peers": []])
            helper.writeStatus(name, "ok", "done")
        }, awayHelper: "/bin/sh")
        defer { stuck.finish() }
        do {
            try await stuck.system.setAway(AwayRequest(on: false, subnet: nil, peers: []))
            Issue.record("a tunnel still reported was taken for off")
        } catch let error as SystemError {
            // The card shows this: a turn-off has no list of devices to compare.
            #expect(error.message == "The system couldn’t change Away from home. It still reports Away from home as on.")
        }
    }
}
