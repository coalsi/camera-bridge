import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// The internet guard's pure pieces in the engine: when a camera's Watch counts as done, the addresses the guard takes, the box's report as
/// a camera's evidence and activity, the day's notice and its words, and a setup record that names a step this build does not know.
@Suite struct InternetGuardEvidenceTests {
    static let now = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    private func camera(state: [CameraSetupState.Record]?, backup: Bool, watched: String? = nil) -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.21"), username: "admin")
        camera.setupState = state.map { CameraSetupState(started: Self.now, applied: Self.now, steps: $0, watchedServer: watched) }
        if backup {
            camera.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                   internetWatch: CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        }
        return camera
    }

    /// The box watches a camera whose step's last result left its DNS pointing at the bridge (`watchedServer`, kept while a later run
    /// takes the step again), or, for a record saved before that field, whose last record of the step says done or already right. The DNS
    /// servers kept to give back are no proof: they are saved before the step runs and kept when the camera refuses it.
    @Test func theBoxWatchesACameraWhoseStepLeftItsDNSAtTheBridge() {
        #expect(!BridgeEngine.internetWatchDone(camera(state: nil, backup: false)))
        #expect(!BridgeEngine.internetWatchDone(camera(state: nil, backup: true)))
        #expect(!BridgeEngine.internetWatchDone(camera(state: [], backup: true)), "a first run that has not reached the step yet")
        #expect(BridgeEngine.internetWatchDone(camera(state: [], backup: true, watched: "192.168.77.2")), "a later run that has not reached it yet")
        #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .notSupported)], backup: true, watched: "192.168.77.2")),
                "a later run that could not read it")
        #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .done)], backup: true)), "an older build's record")
        #expect(BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: .alreadyRight)], backup: false)),
                "the camera already asked the bridge")
        for status in [CameraSetupStepStatus.notRun, .refused, .notOffered, .notSupported, .willChange, .restored] {
            #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: status)], backup: true)),
                    "\(status): the DNS servers kept to give back are no watch")
            #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .internetWatch, status: status)], backup: false)), "\(status)")
        }
        #expect(!BridgeEngine.internetWatchDone(camera(state: [.init(id: .cloud, status: .done)], backup: false)))
    }

    /// A reading of the camera's DNS servers decides its watch whoever set them (owner decision, 2026-10-18): one that points only at the
    /// bridge watches the camera, also one never set up (without growing a setup record), and one that asks other servers ends the watch,
    /// also one the setup or an older build made (the setup's record of what it did stays). A reading older than the setup's last run, one
    /// that asks the bridge and another server, and a camera still asking its old servers while its Watch waits for its restart change
    /// nothing; a reading-made watch read against a setup record that is gone (Restore cleared it) is none.
    @Test func aReadingDecidesTheWatchWhoeverSetTheDNS() throws {
        let bridge = "192.168.77.2", later = Self.now.addingTimeInterval(60)
        func reading(_ servers: [String], method: CameraConfigMethod = .onvifMinimal) -> CameraDNSReading {
            CameraDNSReading(servers: servers, fromDHCP: false, method: method, backup: CameraDNSBackup(method: method, fromDHCP: false, servers: servers))
        }

        // Never set up: the owner pointed it at the bridge on the camera, then changed it back.
        let plain = camera(state: nil, backup: false)
        let joined = try #require(BridgeEngine.watchAfterReading(plain, reading([bridge, bridge]), server: bridge, takenAt: later))
        #expect(joined.dnsWatch == CameraDNSWatch(server: bridge) && joined.setupState == nil && BridgeEngine.internetWatchDone(joined))
        #expect(BridgeEngine.watchAfterReading(joined, reading([bridge]), server: bridge, takenAt: later) == nil, "nothing changes")
        let left = try #require(BridgeEngine.watchAfterReading(joined, reading(["192.168.77.1"]), server: bridge, takenAt: later))
        #expect(left.dnsWatch == nil && !BridgeEngine.internetWatchDone(left))
        #expect(BridgeEngine.watchAfterReading(plain, reading([bridge, "8.8.8.8"]), server: bridge, takenAt: later) == nil,
                "a camera that also asks another server is not watched")
        #expect(BridgeEngine.watchAfterReading(plain, reading([]), server: bridge, takenAt: later) == nil)

        // Set up: Watch done, then changed back on the camera, then pointed at the bridge again.
        let done = camera(state: [.init(id: .internetWatch, status: .done)], backup: true, watched: bridge)
        let gone = try #require(BridgeEngine.watchAfterReading(done, reading(["8.8.8.8"]), server: bridge, takenAt: later))
        #expect(gone.setupState?.watchedServer == nil && gone.dnsWatch == CameraDNSWatch(server: nil, setupStarted: Self.now))
        #expect(!BridgeEngine.internetWatchDone(gone))
        #expect(gone.setupState?.steps == done.setupState?.steps && gone.setupBackup == done.setupBackup, "the setup's record and backup stay")
        let back = try #require(BridgeEngine.watchAfterReading(gone, reading([bridge]), server: bridge, takenAt: later))
        #expect(back.setupState?.watchedServer == bridge && back.dnsWatch == nil && BridgeEngine.internetWatchDone(back))
        #expect(BridgeEngine.watchAfterReading(done, reading(["8.8.8.8"]), server: bridge, takenAt: Self.now.addingTimeInterval(-60)) == nil,
                "a reading taken before the setup's last run: the run's result is newer")

        // A refused step, but the owner then pointed the camera at the bridge: watched.
        let refused = camera(state: [.init(id: .internetWatch, status: .refused)], backup: true)
        let pointed = try #require(BridgeEngine.watchAfterReading(refused, reading([bridge]), server: bridge, takenAt: later))
        #expect(pointed.setupState?.watchedServer == bridge && BridgeEngine.internetWatchDone(pointed))

        // An older build's record (done, no watchedServer): its watch ends at a reading of other servers too.
        let older = camera(state: [.init(id: .internetWatch, status: .done)], backup: true)
        #expect(BridgeEngine.internetWatchDone(older))
        let olderGone = try #require(BridgeEngine.watchAfterReading(older, reading(["8.8.8.8"]), server: bridge, takenAt: later))
        #expect(!BridgeEngine.internetWatchDone(olderGone))

        // ISAPI's "after the camera restarts": while it still asks the servers it had, it waits; other servers end the watch.
        var waiting = camera(state: [.init(id: .internetWatch, status: .done, needsRestart: true)], backup: false, watched: bridge)
        waiting.setupBackup = CameraSetupBackup(version: 1, created: Self.now,
                                                internetWatch: CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8", "1.1.1.1"]))
        #expect(BridgeEngine.watchAfterReading(waiting, reading(["8.8.8.8", "1.1.1.1"], method: .hikvisionISAPI), server: bridge, takenAt: later) == nil)
        let moved = try #require(BridgeEngine.watchAfterReading(waiting, reading(["9.9.9.9", "1.1.1.1"], method: .hikvisionISAPI), server: bridge,
                                                                takenAt: later))
        #expect(!BridgeEngine.internetWatchDone(moved))

        // Restore cleared the setup's record: a watch read against it is none, one read with no record still is.
        var restored = camera(state: nil, backup: false)
        restored.dnsWatch = CameraDNSWatch(server: nil, setupStarted: Self.now)
        #expect(!BridgeEngine.internetWatchDone(restored))
        restored.dnsWatch = CameraDNSWatch(server: bridge, setupStarted: Self.now)
        #expect(!BridgeEngine.internetWatchDone(restored), "read against a setup record that is gone")
        restored.dnsWatch = CameraDNSWatch(server: bridge)
        #expect(BridgeEngine.internetWatchDone(restored))
    }

    /// A reading that does not know which servers the camera asks (a Reolink on automatic DNS whose ONVIF did not say which DHCP gives) decides
    /// no watch: an unreadable read changes nothing (owner decision), whether the setup or a reading made the watch, and whether or not there
    /// is one. One that knows DHCP gives no server is a reading of no servers: it ends a watch.
    @Test func aReadingWhoseServersAreUnknownDecidesNoWatch() throws {
        let bridge = "192.168.77.2", later = Self.now.addingTimeInterval(60)
        let unknown = CameraDNSReading(servers: [], fromDHCP: true, method: .reolinkAPI,
                                       backup: CameraDNSBackup(method: .reolinkAPI, fromDHCP: true, servers: ["", ""]), serversUnknown: true)
        #expect(!unknown.pointsAt(bridge))
        var byReading = camera(state: nil, backup: false)
        byReading.dnsWatch = CameraDNSWatch(server: bridge)
        let bySetup = camera(state: [.init(id: .internetWatch, status: .done)], backup: true, watched: bridge)
        for watched in [byReading, bySetup, camera(state: nil, backup: false)] {
            #expect(BridgeEngine.watchAfterReading(watched, unknown, server: bridge, takenAt: later) == nil)
        }
        var none = unknown
        none.serversUnknown = false
        #expect(try #require(BridgeEngine.watchAfterReading(byReading, none, server: bridge, takenAt: later)).dnsWatch == nil)
        #expect(try #require(BridgeEngine.watchAfterReading(bySetup, none, server: bridge, takenAt: later)).setupState?.watchedServer == nil)
    }

    /// A watch a reading made before the camera had a setup record gives way to the record's once a reading with the record finds the bridge
    /// (it would otherwise outlive a Restore that clears the record); and a reading counts only while the camera's setup is what it was when
    /// the read began (`setupChanged`: a setup run or a restore saved meanwhile).
    @Test func aReadingCountsOnlyForTheSetupItWasReadAgainst() throws {
        let bridge = "192.168.77.2", later = Self.now.addingTimeInterval(60)
        let toBridge = CameraDNSReading(servers: [bridge], fromDHCP: false, method: .onvifMinimal,
                                        backup: CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: [bridge]))
        var both = camera(state: [.init(id: .internetWatch, status: .done)], backup: true, watched: bridge)
        both.dnsWatch = CameraDNSWatch(server: bridge)   // read before the setup ran
        let updated = try #require(BridgeEngine.watchAfterReading(both, toBridge, server: bridge, takenAt: later))
        #expect(updated.dnsWatch == nil && updated.setupState?.watchedServer == bridge)
        var restored = updated
        restored.setupState = nil
        restored.setupBackup = nil
        #expect(!BridgeEngine.internetWatchDone(restored), "a full Restore leaves no watch behind")

        let before = camera(state: [], backup: true)
        var run = before
        run.setupState?.steps = [.init(id: .internetWatch, status: .done)]
        run.setupState?.watchedServer = bridge
        #expect(BridgeEngine.setupChanged(since: before, run), "a run saved a step")
        var restore = before
        restore.setupBackup = nil
        restore.setupState = nil
        #expect(BridgeEngine.setupChanged(since: before, restore), "a restore cleared them")
        var other = before
        other.name = "Gate 2"
        other.dnsWatch = CameraDNSWatch(server: bridge)
        #expect(!BridgeEngine.setupChanged(since: before, other), "another edit, or the guard's own watch, is no setup change")
    }

    /// The watch a reading made is kept with the camera (config.json), read leniently: an odd value loses only the watch.
    @Test func aReadingsWatchIsStoredWithTheCamera() throws {
        var camera = camera(state: nil, backup: false)
        camera.dnsWatch = CameraDNSWatch(server: "192.168.77.2")
        let read = try JSONDecoder().decode(CameraConfiguration.self, from: JSONEncoder().encode(camera))
        #expect(read.dnsWatch == CameraDNSWatch(server: "192.168.77.2") && read == camera)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
        object["dnsWatch"] = "odd"
        let odd = try JSONDecoder().decode(CameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.dnsWatch == nil && odd.name == "Gate")
        object["dnsWatch"] = nil
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object)).dnsWatch == nil,
                "a camera saved before the field has none")
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
        ], local: 4)
        let watched = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, report: report([entry]), fresh: true, now: Self.now)
        #expect(watched.watched && watched.available && watched.outsideLookups24h == 5 && watched.today == 3)
        #expect(watched.localLookups == 4 && watched.lookupSeen, "the questions that never leave the home network, counted")
        #expect(watched.listed && watched.asksBridge == true && watched.watchedFor == 30 * 3600, "watched for as long as the box says")
        #expect(watched.lastLookupNames == ["time.example.com", "dev.hik-connect.com"], "the last 24 hours' names, newest first")
        #expect(watched.names.map(\.name) == ["dev.hik-connect.com", "old.example.com", "time.example.com"], "the week's, most asked first")

        let notListed = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: false, asksBridge: true, report: report([entry]), fresh: true, now: Self.now)
        #expect(!notListed.watched && !notListed.listed && notListed.outsideLookups24h == 0 && notListed.names.isEmpty && notListed.localLookups == 0,
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

        let router = BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, dnsFromRouter: true, report: report([entry]),
                                                fresh: true, now: Self.now)
        #expect(router.watched && router.dnsFromRouter, "DNS the router gives, pointing only at the bridge, is watched")
        #expect(!watched.dnsFromRouter)

        for (report, fresh) in [(report([entry]), false), (report([entry], running: false), true), (report([entry], available: false), true), (nil, true)] {
            #expect(!BridgeEngine.guardEvidence(address: "192.168.77.21", listed: true, asksBridge: true, report: report, fresh: fresh, now: Self.now).available)
        }
    }

    /// A camera watched on DNS its router gives (DHCP) says that the router can change it.
    @Test func aWatchOnTheRoutersDNSSaysTheRouterCanChangeIt() {
        let note = "Its DNS servers come from your router, which can change them when it renews the camera’s address."
        for watchedFor: TimeInterval in [3600, 172_800] {
            let evidence = GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: watchedFor, dnsFromRouter: true)
            let finding = CameraSecurity.guardFinding(evidence)
            #expect(finding.sentence.hasSuffix(" " + note), "\(watchedFor)")
            let own = CameraSecurity.guardFinding(GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: watchedFor))
            #expect(!own.sentence.contains("router") && finding.level == own.level, "\(watchedFor): the same level, with the note")
        }
        let trying = GuardEvidence(watched: true, outsideLookups24h: 2, lastLookupNames: [], available: true, watchedFor: 3600, dnsFromRouter: true)
        #expect(CameraSecurity.guardFinding(trying).sentence.hasSuffix(" " + note))
        let notWatched = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false, dnsFromRouter: true)
        #expect(!CameraSecurity.guardFinding(notWatched).sentence.contains("router"), "only a watch it rests on")
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
        #expect(notice.tried.map(\.id) == [ids.1, ids.0], "a camera that tried nothing today is not named")
        #expect(notice.detail == "Internet guard blocked 7 lookups from 2 cameras today. South tried 5 times, North 2 times.")

        let one = try #require(InternetGuardNotice.make(report: self.report([GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 1,
                                                                                                    last24h: 1, names: [])]), cameras: cameras, now: Self.now))
        #expect(one.sentence == "Internet guard blocked 1 lookup from 1 camera today." && one.title == "A Camera Tried to Reach the Internet")
        #expect(one.detail == "Internet guard blocked 1 lookup from 1 camera today. North tried once.")
        #expect(one.tried == [InternetGuardNotice.Camera(id: ids.0, name: "North", today: 1, mostAsked: nil)], "the box listed no names")
        #expect(InternetGuardNotice.make(report: self.report([]), cameras: cameras, now: Self.now) == nil)
        #expect(InternetGuardNotice.make(report: nil, cameras: cameras, now: Self.now) == nil)
    }

    /// Every camera that tried is in the notice, most first (a tie in the bridge's order of cameras); the text names the first three and
    /// counts the rest; the camera that tried most is still `cameraID` for a page that knows only that.
    @Test func theNoticeNamesEveryCameraThatTriedMostFirst() throws {
        let names = ["Patio New", "Doorbell", "Garage", "Side Gate", "Shed"]
        let ids = names.map { _ in UUID() }
        let cameras = names.indices.map { (id: ids[$0], name: names[$0], address: "192.168.77.\(21 + $0)") }
        let counts = [3, 9, 1, 1, 2]
        let report = report(counts.indices.map { GuardReport.Camera(address: "192.168.77.\(21 + $0)", level: .watch, today: counts[$0], last24h: counts[$0],
                                                                    names: []) })
        let notice = try #require(InternetGuardNotice.make(report: report, cameras: cameras, now: Self.now))
        #expect(notice.tried.map(\.name) == ["Doorbell", "Patio New", "Shed", "Garage", "Side Gate"], "most first; Garage before Side Gate, as the bridge lists them")
        #expect(notice.tried.map(\.today) == [9, 3, 2, 1, 1])
        #expect(notice.lookups == 16 && notice.cameras == 5 && notice.cameraID == ids[1] && notice.cameraName == "Doorbell")
        #expect(notice.detail == "Internet guard blocked 16 lookups from 5 cameras today. Doorbell tried 9 times, Patio New 3 times, Shed 2 times, "
                + "and 2 more cameras.")

        let four = try #require(InternetGuardNotice.make(report: report, cameras: Array(cameras.prefix(4)), now: Self.now))
        #expect(four.detail.hasSuffix("Doorbell tried 9 times, Patio New 3 times, Garage once, and 1 more camera."))
        let three = try #require(InternetGuardNotice.make(report: report, cameras: Array(cameras.prefix(3)), now: Self.now))
        #expect(three.detail.hasSuffix("Doorbell tried 9 times, Patio New 3 times, Garage once."), "three are all named")

        #expect(InternetGuardText.whoTried([]) == nil)
        let made = InternetGuardNotice(day: Self.now, lookups: 4, cameras: 1, cameraID: ids[0], cameraName: "Patio New", date: Self.now)
        #expect(made.tried.isEmpty && made.detail == made.sentence, "a notice made without its cameras says what it did before")
    }

    /// Each camera's most asked name is shown as the Security card shows it (a part that looks like its id is "*", the same shown name
    /// counted once), and is one it asked for today when the box says when.
    @Test func eachCameraOfTheNoticeHasItsMostAskedNameAsShown() throws {
        let today = Self.now.addingTimeInterval(-3600), lastWeek = Self.now.addingTimeInterval(-3 * 86_400)
        let cameras = [(id: UUID(), name: "Patio New", address: "192.168.77.21"), (id: UUID(), name: "Doorbell", address: "192.168.77.22"),
                       (id: UUID(), name: "Garage", address: "192.168.77.23")]
        let report = report([
            GuardReport.Camera(address: "192.168.77.21", level: .watch, today: 9, last24h: 9, names: [
                GuardReport.Lookup(name: "old.example.com", count: 40, first: lastWeek, last: lastWeek),
                GuardReport.Lookup(name: "time.example.org", count: 6, first: lastWeek, last: today),
                GuardReport.Lookup(name: "a1b2c3d4e5f6.p2p.example.com", count: 4, first: today, last: today),
                GuardReport.Lookup(name: "f6e5d4c3b2a1.p2p.example.com", count: 4, first: today, last: today),
            ]),
            GuardReport.Camera(address: "192.168.77.22", level: .watch, today: 3, last24h: 3, names: [
                GuardReport.Lookup(name: "cloud.example.net", count: 2),
                GuardReport.Lookup(name: "x1y2z3w4v5u6t7.devices.example.net", count: 1),
            ]),
            GuardReport.Camera(address: "192.168.77.23", level: .watch, today: 1, last24h: 1, names: [
                GuardReport.Lookup(name: "older.example.com", count: 5, first: lastWeek, last: lastWeek),
            ]),
        ])
        let notice = try #require(InternetGuardNotice.make(report: report, cameras: cameras, now: Self.now))
        #expect(notice.tried.map(\.mostAsked) == ["*.p2p.example.com", "cloud.example.net", "older.example.com"],
                "today's most asked, its id hidden and the two ids counted as one name; without times the box's first; none today: the most asked")
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
