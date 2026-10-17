import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// The internet guard's pure pieces in the engine: when a camera's Watch counts as done, the addresses the guard takes, the box's report as
/// a camera's evidence and activity, the day's notice and its words, and a setup record that names a step this build does not know.
@Suite struct InternetGuardEvidenceTests {
    static let now = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    private func camera(state: [CameraSetupState.Record]?, backup: Bool) -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.21"), username: "admin")
        camera.setupState = state.map { CameraSetupState(started: Self.now, applied: Self.now, steps: $0) }
        if backup {
            camera.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                   internetWatch: CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        }
        return camera
    }

    /// The box watches a camera whose DNS may point at it: while the setup keeps its DNS servers to give back, or its last record of the
    /// step says done or already right. A later run whose read of the step failed for a moment does not drop it.
    @Test func theBoxWatchesACameraWhileItsDNSMayPointAtTheBridge() {
        #expect(!BridgeEngine.internetWatchDone(camera(state: nil, backup: false)))
        #expect(BridgeEngine.internetWatchDone(camera(state: nil, backup: true)), "a run under way that has not reached the step yet")
        #expect(BridgeEngine.internetWatchDone(camera(state: [], backup: true)))
        #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .done)], backup: true)))
        #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .alreadyRight)], backup: false)),
                "the camera already asked the bridge")
        for status in [CameraSetupStepStatus.notRun, .refused, .notOffered, .notSupported, .willChange] {
            #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: status)], backup: true)),
                    "\(status): its DNS servers are still kept to give back")
            #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: status)], backup: false)), "\(status)")
        }
        #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .restored)], backup: false)), "given back")
        #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .cloud, status: .done)], backup: false)))
    }

    @Test func theGuardTakesOnlyLocalIPv4Addresses() {
        #expect(BridgeEngine.guardAddress("192.168.77.21") == "192.168.77.21")
        #expect(BridgeEngine.guardAddress(" 10.0.0.7 ") == "10.0.0.7")
        #expect(BridgeEngine.guardAddress("172.16.4.2") == "172.16.4.2" && BridgeEngine.guardAddress("169.254.9.9") == "169.254.9.9")
        for host in ["192.0.2.30", "8.8.8.8", "172.32.0.1", "127.0.0.1", "192.168.077.21", "192.168.77", "192.168.77.256", "camera.local", "fd00::21", ""] {
            #expect(BridgeEngine.guardAddress(host) == nil, "\(host)")
        }
    }

    @Test func theBridgesAddressMustBeOnTheCamerasNetwork() {
        let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                          InterfaceAddress(interface: "utun3", address: "10.5.0.2", prefixLength: 16),
                          InterfaceAddress(interface: "en0", address: "192.168.77.2", prefixLength: 24),
                          InterfaceAddress(interface: "en1", address: "fd00::2", prefixLength: 64)]
        #expect(BridgeEngine.bridgeAddress(onNetworkOf: "192.168.77.21", interfaces: interfaces) == "192.168.77.2")
        #expect(BridgeEngine.bridgeAddress(onNetworkOf: "192.168.78.21", interfaces: interfaces) == nil, "no fallback to another network")
        #expect(BridgeEngine.bridgeAddress(onNetworkOf: "10.5.0.9", interfaces: interfaces) == nil, "never a VPN's tunnel")
        #expect(BridgeEngine.bridgeAddress(onNetworkOf: "camera.local", interfaces: interfaces) == nil)
        #expect(BridgeEngine.timeServerAddress(cameraHost: "192.168.78.21", interfaces: interfaces) == "192.168.77.2", "the time source still falls back")
    }

    // MARK: Evidence

    private func report(_ cameras: [GuardReport.Camera], available: Bool = true, running: Bool? = true) -> GuardReport {
        GuardReport(available: available, running: running, updatedAt: Self.now, timeZone: "UTC", todayStart: Self.now.addingTimeInterval(-8 * 3600),
                    cameras: cameras)
    }

    @Test func theReportBecomesACamerasEvidence() {
        let older = Self.now.addingTimeInterval(-3 * 86_400), recent = Self.now.addingTimeInterval(-60), earlier = Self.now.addingTimeInterval(-3600)
        let entry = GuardReport.Camera(address: "192.168.77.21", level: .watch, since: Self.now.addingTimeInterval(-30 * 3600), today: 3, last24h: 5, names: [
            GuardReport.Lookup(name: "dev.hik-connect.com", count: 30, first: older, last: earlier),
            GuardReport.Lookup(name: "old.example.com", count: 9, first: older, last: older),
            GuardReport.Lookup(name: "time.example.com", count: 2, first: recent, last: recent),
        ])
        let watched = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, report: report([entry]), fresh: true, now: Self.now)
        #expect(watched.watched && watched.available && watched.outsideLookups24h == 5 && watched.today == 3)
        #expect(watched.listed && watched.asksBridge == true && watched.watchedFor == 30 * 3600, "watched for as long as the box says")
        #expect(watched.lastLookupNames == ["time.example.com", "dev.hik-connect.com"], "the last 24 hours' names, newest first")
        #expect(watched.names.map(\.name) == ["dev.hik-connect.com", "old.example.com", "time.example.com"], "the week's, most asked first")

        let notListed = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: false, asksBridge: true, report: report([entry]), fresh: true, now: Self.now)
        #expect(!notListed.watched && !notListed.listed && notListed.outsideLookups24h == 0 && notListed.names.isEmpty,
                "the box's old list is not this camera's watch")
        let notThere = BridgeEngine.guardEvidence(address: "192.168.77.22", listed: true, asksBridge: true, report: report([entry]), fresh: true, now: Self.now)
        #expect(!notThere.watched && notThere.listed && notThere.available, "the box does not have it (yet)")
        let unknownLevel = GuardReport.Camera(address: "192.168.77.21", level: nil, today: 0, last24h: 0, names: [])
        #expect(!BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, report: report([unknownLevel]), fresh: true, now: Self.now).watched)
        #expect(!BridgeEngine.guardEvidence(address: nil, listed: true, asksBridge: true, report: report([entry]), fresh: true, now: Self.now).watched)

        // The camera's DNS, read at its last check, points elsewhere (a DHCP renewal, a factory reset, the box at a new address) or could
        // not be read: what the box saw of that address still counts, but the camera is not watched.
        for asks in [false, nil] as [Bool?] {
            let elsewhere = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: asks, report: report([entry]), fresh: true, now: Self.now)
            #expect(!elsewhere.watched && elsewhere.listed && elsewhere.asksBridge == asks && elsewhere.outsideLookups24h == 5, "\(String(describing: asks))")
        }

        let waiting = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: false, waitsForRestart: true, report: report([entry]),
                                                 fresh: true, now: Self.now)
        #expect(waiting.waitsForRestart && !waiting.watched)

        for (report, fresh) in [(report([entry]), false), (report([entry], running: false), true), (report([entry], available: false), true), (nil, true)] {
            #expect(!BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, report: report, fresh: fresh, now: Self.now).available)
        }
    }

    @Test func namesThatLookLikeACamerasIDAreNotShown() {
        #expect(GuardNames.shown("dev.hik-connect.com") == "dev.hik-connect.com")
        #expect(GuardNames.shown("a1b2c3d4e5f6.p2p.example.com") == "*.p2p.example.com")
        #expect(GuardNames.shown("x1y2z3w4v5u6t7.devices.example.net") == "*.devices.example.net")
        #expect(GuardNames.shown("us-east-1.example.com") == "us-east-1.example.com")
        #expect(GuardNames.shown("3.pool.ntp.org") == "3.pool.ntp.org")
        let merged = GuardNames.shown([GuardReport.Lookup(name: "aaaa11112222.p2p.example.com", count: 2, last: Self.now),
                                       GuardReport.Lookup(name: "bbbb33334444.p2p.example.com", count: 3, last: Self.now.addingTimeInterval(-60))])
        #expect(merged == [GuardReport.Lookup(name: "*.p2p.example.com", count: 5, first: nil, last: Self.now)], "the same shown name once")
    }

    @Test func theAssessmentCarriesTheGuardsActivity() {
        let readings = [RemoteAccessFinding(feature: .cloud, state: .off), RemoteAccessFinding(feature: .unauthenticatedVideo, state: .off)]
        let lookups = (1...12).map { GuardReport.Lookup(name: "n\($0).example.com", count: 13 - $0, last: Self.now) }
        let evidence = GuardEvidence(watched: true, outsideLookups24h: 4, lastLookupNames: ["n1.example.com"], available: true, today: 2, names: lookups)
        let security = CameraSecurity.assess(readings, internetGuard: evidence, checkedAt: Self.now)
        #expect(security.internetGuard?.watched == true && security.internetGuard?.today == 2 && security.internetGuard?.last24h == 4)
        #expect(security.internetGuard?.names.count == 10, "the 10 most asked")
        #expect(CameraSecurity.assess(readings, internetGuard: nil, checkedAt: Self.now).internetGuard == nil, "no guard on this bridge")
    }

    // MARK: The notice

    @Test func theNoticeSaysWhatWasBlockedToday() throws {
        let ids = (UUID(), UUID(), UUID())
        let cameras = [(id: ids.0, name: "North", address: "192.168.77.21"), (id: ids.1, name: "South", address: "192.168.77.22"),
                       (id: ids.2, name: "Yard", address: "192.168.77.23")]
        let report = report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 2, last24h: 2, names: []),
                             GuardReport.Camera(address: "192.168.77.22", level: .watch, today: 5, last24h: 5, names: []),
                             GuardReport.Camera(address: "192.168.77.23", level: .watch, today: 0, last24h: 8, names: []),
                             GuardReport.Camera(address: "192.168.77.24", level: .watch, today: 50, last24h: 50, names: [])])
        let notice = try #require(InternetGuardNotice.make(report: report, cameras: cameras, now: Self.now))
        #expect(notice.lookups == 7 && notice.cameras == 2 && notice.cameraID == ids.1 && notice.cameraName == "South")
        #expect(notice.day == Self.now.addingTimeInterval(-8 * 3600) && notice.date == Self.now)
        #expect(notice.sentence == "Internet guard blocked 7 lookups from 2 cameras today.", "a camera the bridge doesn't watch is not counted")
        #expect(notice.title == "Cameras Tried to Reach the Internet")

        let one = try #require(InternetGuardNotice.make(report: self.report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 1,
                                                                                                    last24h: 1, names: [])]), cameras: cameras, now: Self.now))
        #expect(one.sentence == "Internet guard blocked 1 lookup from 1 camera today." && one.title == "A Camera Tried to Reach the Internet")
        #expect(InternetGuardNotice.make(report: self.report([]), cameras: cameras, now: Self.now) == nil)
        #expect(InternetGuardNotice.make(report: nil, cameras: cameras, now: Self.now) == nil)
    }

    @Test func theWordsComeFromOneTable() {
        #expect(InternetGuardText.name == "Internet guard" && InternetGuardText.watch == "Watch" && InternetGuardText.seal == "Seal")
        #expect(GuardLevel.watch.title == "Watch")
        #expect(BridgeEngine.cameraSetupTitle(.internetWatch) == InternetGuardText.watchStep && InternetGuardText.watchStep == "Watch its internet")
    }

    // MARK: Stored records

    @Test func aRecordOfAStepThisBuildDoesNotKnowIsSkippedNotTheWholeRecord() throws {
        let json = #"{"version":1,"started":0,"applied":10,"steps":[{"id":"timeZone","status":"done","needsRestart":false},"#
            + #"{"id":"sealInternet","status":"done","needsRestart":false},{"id":"cloud","status":"someday","needsRestart":false},"#
            + #"{"id":"internetWatch","status":"alreadyRight","needsRestart":false}]}"#
        let state = try JSONDecoder().decode(CameraSetupState.self, from: Data(json.utf8))
        #expect(state.steps.map(\.id) == [.timeZone, .internetWatch] && state.applied == Date(timeIntervalSinceReferenceDate: 10))
        #expect(try JSONDecoder().decode(CameraSetupState.self, from: JSONEncoder().encode(state)) == state)

        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.21"), username: "admin")
        camera.setupState = state
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
        object["setupState"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let read = try JSONDecoder().decode(CameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.setupState?.steps.map(\.id) == [.timeZone, .internetWatch], "the camera keeps its setup record")
    }
}
