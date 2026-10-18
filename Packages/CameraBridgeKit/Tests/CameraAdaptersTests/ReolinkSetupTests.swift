// Loopback fake Reolink and ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// "Set up for Camera Bridge" and the security check on a Reolink, through Reolink's own HTTP API only (owner decision, 2026-10-18): the time
/// source (`GetNtp` / `SetNtp`), the time zone (`GetTime` / `SetTime`: `Time.timeZone` and the `Dst` rule), the DNS (`GetLocalLink` /
/// `SetLocalLink`), UPnP off (`GetUpnp` / `SetUpnp`) and the cloud off (`GetP2p` / `SetP2p`, the UID), each read back and restorable, and
/// the encoder (`GetEnc` with its range, `SetEnc`). Reolink refuses ONVIF's writes to its ONVIF user, and such a refusal paused every ONVIF
/// login to the owner's doorbell: its ONVIF is never asked to change anything here (only `GetDNS` is read, for the servers DHCP gives a
/// doorbell on automatic DNS). Backups an earlier build saved through ONVIF go back through Reolink's API too. One API session serves a
/// whole run. Bodies are checked whole, against the HTTP API v8 guide's shapes. Against fakes only, with documentation addresses.
@Suite(.timeLimit(.minutes(1))) struct ReolinkSetupTests {
    private static let credentials = HTTPCredentials(username: "admin", password: "secret")
    private let bridge = "192.0.2.10"
    /// The read-back after a network restart, short for the fakes (a camera gets 30 s).
    private let quick = DNSReadBackTiming(limit: .seconds(10), interval: .milliseconds(20))

    /// The owner's doorbell: Reolink's API on the web port, and an ONVIF service beside it that must never be asked.
    private struct Doorbell {
        let camera: MockReolinkCamera
        let onvif: MockONVIFCamera
        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.server.port), onvifPort: Int(onvif.server.port)) }

        static func start() async throws -> Doorbell {
            Doorbell(camera: try await MockReolinkCamera.start(), onvif: try await MockONVIFCamera.start())
        }

        func service() -> CameraSettingsService {
            CameraSettingsService(endpoint: endpoint, credentials: ReolinkSetupTests.credentials, vendor: .reolink)
        }

        func stop() {
            camera.stop()
            onvif.stop()
        }
    }

    private func json(_ text: String) -> JSONValue {
        (try? JSONValue.parse(Data(text.utf8))) ?? .null
    }

    /// The body of the `index`-th request of `cmd`, as sent.
    private func body(_ camera: MockReolinkCamera, _ cmd: String, _ index: Int = 0) -> JSONValue? {
        let bodies = camera.bodies.value.filter { $0.cmd == cmd }
        return bodies.indices.contains(index) ? bodies[index].body : nil
    }

    /// The ONVIF actions the doorbell's ONVIF service was sent (the SOAP body's first element), in order.
    private func onvifActions(_ doorbell: Doorbell) -> [String] {
        doorbell.onvif.server.requests.compactMap { request in
            let body = request.bodyText
            guard let range = body.range(of: "Body>") else { return nil }
            return body[range.upperBound...].firstMatch(of: /<(?:[A-Za-z0-9]+:)?([A-Za-z0-9]+)/).map { String($0.output.1) }
        }
    }

    /// Nothing but reads went to the doorbell's ONVIF.
    private func onvifOnlyRead(_ doorbell: Doorbell) -> Bool {
        onvifActions(doorbell).allSatisfy { $0.hasPrefix("Get") }
    }

    /// Whether `cmd` was followed by `next` (the read-back).
    private func readBack(_ camera: MockReolinkCamera, _ cmd: String, by next: String) -> Bool {
        let commands = camera.commands.value
        guard let index = commands.firstIndex(of: cmd), commands.indices.contains(index + 1) else { return false }
        return commands[index + 1] == next
    }

    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var text: String { entries.value.map(\.message).joined(separator: "\n") }
    }

    // MARK: Time from the bridge

    @Test func theTimeSourceGoesThroughSetNtpNeverThroughONVIF() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let original = camera.ntp.value
        let service = doorbell.service()

        let (reading, backup) = try await service.readTimeSource(server: bridge)
        #expect(reading == CameraSetupReading(state: .willChange, changes: [.init(label: "Time source", now: "NTP from pool.ntp.org",
                                                                                  after: "NTP from the bridge (192.0.2.10)")]))
        let saved = try #require(backup)
        #expect(saved == CameraTimeSourceBackup(method: .reolinkAPI, mode: "NTP", hostName: "pool.ntp.org", port: "123", interval: 1440))

        #expect(try await service.applyTimeSource(server: bridge) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(camera.sets.map(\.cmd) == ["SetNtp"])
        #expect(body(camera, "SetNtp") == json(#"[{"action":0,"cmd":"SetNtp","param":{"Ntp":{"enable":1,"interval":1440,"port":123,"server":"192.0.2.10"}}}]"#))
        #expect(readBack(camera, "SetNtp", by: "GetNtp"), "read back")
        #expect(try await service.readTimeSource(server: bridge).0.state == .alreadyRight)

        #expect(try await service.restoreTimeSource(saved) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(json(camera.ntp.value) == json(original), "exactly as it was")
        #expect(doorbell.onvif.server.requests.isEmpty, "Reolink refuses ONVIF's writes to its ONVIF user: ONVIF is never asked")
        await service.close()
        #expect(camera.logins.value == 1 && camera.logouts.value == ["tok1"], "one session for the whole run")
    }

    @Test func aClockSetByHandGetsNTPAndBackItsOwn() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.ntp.set(#"{"enable":0,"interval":60,"port":124,"server":"time.example"}"#)
        let original = camera.ntp.value
        let service = doorbell.service()
        let (reading, backup) = try await service.readTimeSource(server: bridge)
        #expect(reading.changes == [.init(label: "Time source", now: "set by hand", after: "NTP from the bridge (192.0.2.10)")])
        #expect(backup == CameraTimeSourceBackup(method: .reolinkAPI, mode: "manual", hostName: "time.example", port: "124", interval: 60))
        #expect(try await service.applyTimeSource(server: bridge).succeeded)
        #expect(body(camera, "SetNtp")?[0]?["param"] == json(#"{"Ntp":{"enable":1,"interval":60,"port":123,"server":"192.0.2.10"}}"#))
        #expect(try await service.restoreTimeSource(try #require(backup)).succeeded)
        #expect(json(camera.ntp.value) == json(original))
    }

    /// The owner's doorbell holds a time source an earlier build saved through ONVIF (Oct 18: `onvifMinimal`, NTP, pool.ntp.org), and the
    /// setup keeps the oldest backup. This run sets the doorbell's clock through `SetNtp`, so Restore puts the old one back the same way
    /// (`SetNtp` with `Ntp` as read: `enable` from the backup's mode, `server` its first server, `port` and `interval` as read), read back,
    /// and never through ONVIF's `SetNTP`, which the doorbell refuses.
    @Test func aTimeSourceAnEarlierBuildSavedThroughONVIFGoesBackThroughSetNtp() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let original = camera.ntp.value
        let saved = try JSONDecoder().decode(CameraTimeSourceBackup.self,
                                             from: Data(#"{"method":"onvifMinimal","mode":"NTP","fromDHCP":false,"servers":["pool.ntp.org"]}"#.utf8))
        #expect(saved == CameraTimeSourceBackup(method: .onvifMinimal, mode: "NTP", fromDHCP: false, servers: ["pool.ntp.org"]))
        let service = doorbell.service()
        #expect(try await service.applyTimeSource(server: bridge).succeeded)
        #expect(json(camera.ntp.value)["server"] == .string(bridge))

        #expect(try await service.restoreTimeSource(saved) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(body(camera, "SetNtp", 1)?[0]?["param"] == json(#"{"Ntp":{"enable":1,"interval":1440,"port":123,"server":"pool.ntp.org"}}"#))
        #expect(readBack(camera, "SetNtp", by: "GetNtp"))
        #expect(json(camera.ntp.value) == json(original), "exactly as it was")
        #expect(doorbell.onvif.server.requests.isEmpty, "ONVIF's SetNTP is never sent")

        // A clock set by hand, saved through ONVIF, gets NTP off and keeps the server the camera has.
        let manual = CameraTimeSourceBackup(method: .onvifMinimal, mode: "Manual", fromDHCP: false, servers: [])
        #expect(try await service.restoreTimeSource(manual).succeeded)
        #expect(json(camera.ntp.value) == json(#"{"enable":0,"interval":1440,"port":123,"server":"pool.ntp.org"}"#))
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    /// An ONVIF backup that names no time server (the camera took it from DHCP, as ONVIF read it) can't give the camera its own server
    /// back: Restore says so and writes nothing, instead of leaving the bridge as its time server and calling it restored. One the setup
    /// completed with the camera's own server, port and interval when it ran (`BridgeEngine.mergedSetupBackup`) puts those back.
    @Test func anONVIFTimeSourceBackupWithoutAServerIsNotCalledRestored() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.ntp.set(#"{"enable":1,"interval":60,"port":124,"server":"time.example"}"#)
        let original = camera.ntp.value
        let service = doorbell.service()
        #expect(try await service.applyTimeSource(server: bridge).succeeded)
        let sets = camera.sets.count

        let fromDHCP = CameraTimeSourceBackup(method: .onvifMinimal, mode: "NTP", fromDHCP: true, servers: [])
        let refused = try await service.restoreTimeSource(fromDHCP, bridge: bridge)
        #expect(refused == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.noSavedTimeServer))
        #expect(refused.detail.contains("Reolink app"), "says where to set it")
        #expect(camera.sets.count == sets, "nothing is written")
        #expect(json(camera.ntp.value)["server"] == .string(bridge))

        var completed = fromDHCP
        completed.hostName = "time.example"
        completed.port = "124"
        completed.interval = 60
        #expect(try await service.restoreTimeSource(completed) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(json(camera.ntp.value) == json(original), "server, port and interval as the camera had them")
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    /// The refusal's advice followed: the owner set the camera's own time server by hand. That backup (naming no server) puts back only the
    /// switch and counts as restored, so Restore does not refuse it for ever; the server the owner chose stays.
    @Test func aServerSetByHandAfterTheRefusalLetsTheStepBeRestored() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        #expect(try await service.applyTimeSource(server: bridge).succeeded)
        var mine = try #require(try JSONSerialization.jsonObject(with: Data(camera.ntp.value.utf8)) as? [String: Any])
        mine["server"] = "time.example"
        mine["enable"] = 0
        camera.ntp.set(String(decoding: try JSONSerialization.data(withJSONObject: mine), as: UTF8.self))
        let fromDHCP = CameraTimeSourceBackup(method: .onvifMinimal, mode: "NTP", fromDHCP: true, servers: [])
        #expect(try await service.restoreTimeSource(fromDHCP, bridge: bridge) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(json(camera.ntp.value)["server"] == .string("time.example"), "the owner's server stays")
        #expect(json(camera.ntp.value)["enable"] == .number(1), "and the time comes from it, as the backup says")
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    /// A Reolink without `GetNtp` still has an ONVIF backup put back through ONVIF.
    @Test func aReolinkWithoutGetNtpPutsAnONVIFBackupBackThroughONVIF() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        doorbell.camera.errorQueue.set(["GetNtp": [-9]])
        let saved = CameraTimeSourceBackup(method: .onvifMinimal, mode: "NTP", fromDHCP: false, servers: ["pool.ntp.org"])
        _ = try await doorbell.service().restoreTimeSource(saved)
        #expect(onvifActions(doorbell).contains("SetNTP"))
        #expect(doorbell.camera.sets.isEmpty)
    }

    /// An account the camera does not let change its clock: the step says so before anything is sent (the account's `GetAbility` permit
    /// has no write bit), and a `SetNtp` the camera refuses with a credential code once the login worked is the same answer, not a wrong
    /// password: no login pause, and the steps after it still run.
    @Test func aTimeSourceThisAccountMayNotChangeSendsNothingAndSaysSo() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.abilities.set(["ntp": (permit: 4, ver: 1)])
        let service = doorbell.service()
        #expect(try await service.readTimeSource(server: bridge).0.state == .notSupported(CameraAdapterError.notPermittedReason))
        #expect(try await service.applyTimeSource(server: bridge) == .notPermittedRefusal)
        #expect(camera.sets.isEmpty)

        camera.abilities.set([:])
        camera.errorQueue.set(["SetNtp": [-27]])
        let other = doorbell.service()
        #expect(try await other.applyTimeSource(server: bridge) == .notPermittedRefusal)
        #expect(try await other.readTimeSource(server: bridge).0.state == .willChange, "the session still works")
        #expect(camera.logins.value == 2, "one login per service, none again after the refusal")
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    // MARK: Time zone

    /// The camera's `Time.timeZone` (seconds west of UTC, as the v8 guide's range has it) and its `Dst` rule are compared, not only the
    /// daylight-saving switch: a doorbell on Pacific time with daylight saving is not "already right" for Phoenix. `SetTime` carries `Dst`
    /// as read with what changes, and `Time` with only `timeZone` (every field of `SetTime` is optional): the clock itself is never written.
    @Test func theTimeZoneComparesTheOffsetAndTheRule() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.timeZone.set(28800)
        camera.dst.set(MockReolinkCamera.dst.replacingOccurrences(of: #""enable":0"#, with: #""enable":1"#))
        let originalDst = camera.dst.value
        let service = doorbell.service()

        let (reading, backup) = try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix")
        #expect(reading == CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: "UTC−8 with daylight saving",
                                                                                  after: "America/Phoenix (UTC−7)")]))
        let saved = try #require(backup)
        #expect(saved.method == .reolinkAPI && saved.value == "1")
        #expect(saved.reolinkTime == ["timeZone": 28800, "Dst.enable": 1, "Dst.endHour": 2, "Dst.endMin": 0, "Dst.endMon": 11, "Dst.endSec": 0,
                                      "Dst.endWeek": 1, "Dst.endWeekday": 0, "Dst.offset": 1, "Dst.startHour": 2, "Dst.startMin": 0, "Dst.startMon": 3,
                                      "Dst.startSec": 0, "Dst.startWeek": 2, "Dst.startWeekday": 0])

        #expect(try await service.applyTimeZone(posix: "MST7") == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(camera.sets.map(\.cmd) == ["SetTime"])
        let off = json(MockReolinkCamera.dst)
        #expect(body(camera, "SetTime")?[0]?["param"] == .object(["Dst": off, "Time": .object(["timeZone": .number(25200)])]))
        #expect(readBack(camera, "SetTime", by: "GetTime"))
        #expect(try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix").0.state == .alreadyRight)

        #expect(try await service.restoreTimeZone(saved) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(camera.timeZone.value == 28800 && json(camera.dst.value) == json(originalDst), "exactly as it was")
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    /// A zone with daylight saving gets the POSIX rule in Reolink's fields: "M3.2.0" is month 3, week 2, weekday 0 (Sunday), at 2:00 unless
    /// the rule says otherwise; week 5 is the last; `offset` is the shift in hours. The same offset with another rule is not right either.
    @Test func aDaylightSavingRuleIsWrittenInReolinksFields() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        // Denver: the camera's offset is right, its daylight saving off.
        #expect(try await service.readTimeZone(posix: "MST7MDT,M3.2.0,M11.1.0", zoneName: "America/Denver").0
                == CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: "UTC−7",
                                                                          after: "America/Denver (UTC−7 with daylight saving)")]))
        #expect(try await service.applyTimeZone(posix: "MST7MDT,M3.2.0,M11.1.0").succeeded)
        #expect(body(camera, "SetTime")?[0]?["param"] == .object(["Dst": json(MockReolinkCamera.dst.replacingOccurrences(of: #""enable":0"#, with: #""enable":1"#))]),
                "the offset was right: only Dst")

        // Berlin's rule on a camera with the US one.
        camera.timeZone.set(-3600)
        #expect(try await service.readTimeZone(posix: "CET-1CEST,M3.5.0,M10.5.0/3", zoneName: "Europe/Berlin").0
                == CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: "UTC+1 with daylight saving on other dates",
                                                                          after: "Europe/Berlin (UTC+1 with daylight saving)")]))
        #expect(try await service.applyTimeZone(posix: "CET-1CEST,M3.5.0,M10.5.0/3").succeeded)
        #expect(body(camera, "SetTime", 1)?[0]?["param"]?["Dst"] == json(#"{"enable":1,"endHour":3,"endMin":0,"endMon":10,"endSec":0,"endWeek":5,"endWeekday":0,"offset":1,"startHour":2,"startMin":0,"startMon":3,"startSec":0,"startWeek":5,"startWeekday":0}"#))
        #expect(try await service.readTimeZone(posix: "CET-1CEST,M3.5.0,M10.5.0/3", zoneName: "Europe/Berlin").0.state == .alreadyRight)

        // A half-hour daylight saving shift (Lord Howe) is not among Reolink's (1 or 2 hours): nothing is written.
        let before = camera.sets.count
        #expect(try await service.readTimeZone(posix: "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0", zoneName: "Australia/Lord_Howe").0.state
                == .notSupported("Camera Bridge can’t give this camera the daylight-saving rule of Australia/Lord_Howe"))
        #expect(try await service.applyTimeZone(posix: "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0").succeeded == false)
        #expect(camera.sets.count == before)
    }

    /// The guide's range for `timeZone` (-46800…43200) says seconds west of UTC, as POSIX counts; a camera whose own clock shows it counts
    /// east (its local time is UTC plus `timeZone`) is read and written its way, so a zone is never written with the wrong sign.
    @Test func aCameraThatCountsItsZoneEastIsWrittenItsWay() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.timeZoneCountsEast.set(true)
        camera.timeZone.set(-28800)
        let service = doorbell.service()
        #expect(try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix").0.changes
                == [.init(label: "Time zone", now: "UTC−8", after: "America/Phoenix (UTC−7)")])
        #expect(try await service.applyTimeZone(posix: "MST7").succeeded)
        #expect(body(camera, "SetTime")?[0]?["param"] == .object(["Time": .object(["timeZone": .number(-25200)])]))
        #expect(camera.timeZone.value == -25200)
    }

    // MARK: UPnP and the cloud (the UID)

    @Test func upnpAndTheUIDGoOffThroughTheirOwnCommands() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let service = doorbell.service()

        let (upnp, upnpBackup) = try await service.readFeature(.upnp)
        #expect(upnp == CameraSetupReading(state: .willChange, changes: [.init(label: "UPnP", now: "on", after: "off")]))
        #expect(upnpBackup == CameraFeatureBackup(path: "reolink:Upnp", enabled: true))
        let (cloud, cloudBackup) = try await service.readFeature(.cloud)
        #expect(cloud == CameraSetupReading(state: .willChange, changes: [.init(label: "Reolink P2P (UID, the maker’s cloud)", now: "on", after: "off")],
                                            note: CameraSettingsService.reolinkUIDOffNote(doorbell: true)))
        #expect(cloud.note?.contains("the Reolink app stops working away from home") == true && cloud.note?.contains("Apple Home") == true)
        #expect(cloudBackup == CameraFeatureBackup(path: "reolink:P2p", enabled: true))

        #expect(try await service.setFeature(.upnp, enabled: false, path: upnpBackup?.path) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(try await service.setFeature(.cloud, enabled: false, path: cloudBackup?.path) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(camera.sets.map(\.cmd) == ["SetUpnp", "SetP2p"])
        #expect(body(camera, "SetUpnp") == json(#"[{"action":0,"cmd":"SetUpnp","param":{"Upnp":{"enable":0}}}]"#))
        #expect(body(camera, "SetP2p") == json(#"[{"action":0,"cmd":"SetP2p","param":{"P2p":{"enable":0}}}]"#), "only the switch: never the UID")
        #expect(readBack(camera, "SetUpnp", by: "GetUpnp") && readBack(camera, "SetP2p", by: "GetP2p"))
        #expect(try await service.readFeature(.upnp).0.state == .alreadyRight)
        #expect(try await service.readFeature(.cloud).0.state == .alreadyRight)

        #expect(try await service.setFeature(.upnp, enabled: true, path: "reolink:Upnp").succeeded)
        #expect(try await service.setFeature(.cloud, enabled: true, path: "reolink:P2p").succeeded)
        #expect(json(camera.upnp.value) == json(#"{"enable":1}"#))
        #expect(json(camera.p2p.value) == json(#"{"enable":1,"uid":"\#(MockReolinkCamera.uid)"}"#))
        #expect(!capture.text.contains(MockReolinkCamera.uid), "the UID is never logged")
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    @Test func aCameraThatIsNoDoorbellIsToldOnlyAboutTheApp() {
        #expect(CameraSettingsService.reolinkUIDOffNote(doorbell: false).contains("the Reolink app stops working away from home"))
        #expect(!CameraSettingsService.reolinkUIDOffNote(doorbell: false).contains("ring"))
        #expect(CameraSettingsService.reolinkUIDOffNote(doorbell: true).contains("doorbell rings still come through Apple Home"))
    }

    /// A switch the camera does not have (`GetAbility` version 0, or "not support"), or one this account may not change: the step says so,
    /// and nothing is sent.
    @Test func aSwitchTheCameraLacksOrThisAccountMayNotChangeSendsNothing() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.abilities.set(["upnp": (permit: 6, ver: 0), "p2p": (permit: 4, ver: 1)])
        let service = doorbell.service()
        #expect(try await service.readFeature(.upnp).0.state == .notSupported(CameraNetworkFeature.upnp.reolinkHasNone))
        #expect(try await service.readFeature(.cloud).0.state == .notSupported(CameraAdapterError.notPermittedReason))
        #expect(try await service.setFeature(.upnp, enabled: false) == CameraSetupOutcome(succeeded: false, detail: CameraNetworkFeature.upnp.reolinkHasNone))
        #expect(try await service.setFeature(.cloud, enabled: false) == .notPermittedRefusal)
        #expect(camera.sets.isEmpty)

        camera.abilities.set([:])
        camera.errorQueue.set(["GetUpnp": [-9]])
        #expect(try await doorbell.service().readFeature(.upnp).0.state == .notSupported(CameraNetworkFeature.upnp.reolinkHasNone))
    }

    /// A change the camera refuses: as "not support", with where to do it by hand (the Reolink Client; the phone app has no such setting);
    /// with another code, in the camera's own words. A setting answered `rspCode` other than 200 did not take.
    @Test func aRefusedChangeSaysWhereToDoItByHand() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        camera.errorQueue.set(["SetP2p": [-9]])
        let refused = try await service.setFeature(.cloud, enabled: false)
        #expect(refused == CameraSetupOutcome(succeeded: false, detail: CameraNetworkFeature.cloud.reolinkCannotChange))
        #expect(refused.detail.contains("Reolink Client") && refused.detail.contains("Network › Advanced") && refused.detail.contains("phone app"))

        camera.setRspCodes.set(["SetUpnp": -4])
        #expect(try await service.setFeature(.upnp, enabled: false)
                == CameraSetupOutcome(succeeded: false, detail: "the camera refused the change (Reolink error -4: set config failed)"))
        #expect(json(camera.upnp.value) == json(#"{"enable":1}"#))
    }

    // MARK: Watch its internet (the DNS)

    /// `LocalLink` as read goes back with only `dns` changed (`auto` 0, the bridge in both slots): the address stays DHCP (or as fixed as it
    /// was). The doorbell restarts its network and forgets the session: the read-back waits for it, and what fails meanwhile is no refusal.
    /// Restore puts `dns` back exactly. ONVIF is never asked.
    @Test func theDNSGoesThroughLocalLinkKeepingEverythingElse() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.restartAfterLinkWrite.set(3)
        doorbell.onvif.dns.set(.init(fromDHCP: true, searchDomains: [], dhcpServers: ["192.168.77.1"]))   // what the router hands out
        let service = doorbell.service()

        let read = try #require(try await service.readDNS())
        #expect(read.method == .reolinkAPI && read.fromDHCP && read.servers == ["192.168.77.1"])
        let own = ["auto": "1", "dns1": "192.168.77.1", "dns2": "192.168.77.1"]
        #expect(read.backup == CameraDNSBackup(method: .reolinkAPI, fromDHCP: true, servers: ["192.168.77.1", "192.168.77.1"], ownAPI: own))
        let (watch, backup) = try await service.readInternetWatch(server: bridge)
        #expect(watch == CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: "192.168.77.1 from the router (DHCP)",
                                                                                after: "the bridge (192.0.2.10)")]))
        #expect(backup == read.backup)

        #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        var expected = try #require(json(MockReolinkCamera.localLink).object)
        expected["dns"] = json(#"{"auto":0,"dns1":"192.0.2.10","dns2":"192.0.2.10"}"#)
        #expect(camera.sets.map(\.cmd) == ["SetLocalLink"])
        #expect(body(camera, "SetLocalLink") == .array([.object(["action": .number(0), "cmd": .string("SetLocalLink"),
                                                                  "param": .object(["LocalLink": .object(expected)])])]))
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
        #expect(camera.logins.value == 2, "logged in again once the camera was back")

        #expect(try await service.restoreDNS(read.backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        #expect(json(camera.localLink.value) == json(MockReolinkCamera.localLink), "exactly as it was")
        #expect(onvifActions(doorbell).contains("GetDNS") && onvifOnlyRead(doorbell), "ONVIF only tells the servers DHCP gives")
    }

    /// With automatic DNS (`auto` 1) the doorbell asks the servers its router's DHCP hands out, whatever `dns1` and `dns2` still hold (the v8
    /// guide's own example keeps a server there): an owner who typed the bridge into both slots and then turned automatic DNS back on is not
    /// asking the bridge. The servers in use come from ONVIF's `DNSFromDHCP`; without them the reading never points at the bridge.
    @Test func withAutomaticDNSTheSlotsAreNotTheServersInUse() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        doorbell.camera.localLink.set(MockReolinkCamera.localLink.replacingOccurrences(of: #""dns1":"192.168.77.1","dns2":"192.168.77.1""#,
                                                                                        with: #""dns1":"192.0.2.10","dns2":"192.0.2.10""#))
        doorbell.onvif.dns.set(.init(fromDHCP: true, searchDomains: [], dhcpServers: ["192.168.77.1"]))
        let asksRouter = try #require(try await doorbell.service().readDNS())
        #expect(asksRouter.fromDHCP && asksRouter.servers == ["192.168.77.1"] && !asksRouter.pointsAt(bridge))
        #expect(asksRouter.backup.ownAPI == ["auto": "1", "dns1": bridge, "dns2": bridge], "the backup keeps the slots as they are")
        let watch = try await doorbell.service().readInternetWatch(server: bridge)
        #expect(watch.0 == CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: "192.168.77.1 from the router (DHCP)",
                                                                                  after: "the bridge (192.0.2.10)")]))

        doorbell.onvif.dns.set(.init(fromDHCP: true, searchDomains: [], dhcpServers: [bridge]))   // the router hands out the bridge
        let fromRouter = try #require(try await doorbell.service().readDNS())
        #expect(fromRouter.fromDHCP && fromRouter.pointsAt(bridge))

        doorbell.onvif.noDNS.set(true)   // ONVIF does not say: unknown, so not the bridge
        let unknown = try #require(try await doorbell.service().readDNS())
        #expect(unknown.fromDHCP && unknown.servers.isEmpty && unknown.serversUnknown && !unknown.pointsAt(bridge))
        #expect(try await doorbell.service().readInternetWatch(server: bridge).0.state == .willChange)
        #expect(doorbell.camera.sets.isEmpty && onvifOnlyRead(doorbell))
    }

    /// "Servers unknown" is not "no servers": with automatic DNS, a reading whose ONVIF does not say which servers DHCP gives (no `GetDNS`,
    /// an answer that says the camera does not take them from DHCP, ONVIF switched off in `GetNetPort`, no answer) says it does not know them
    /// (`serversUnknown`, which the Internet guard takes as an unreadable read); ONVIF that says DHCP gives none is a reading of no servers.
    /// Neither points at the bridge, and the setup's preview offers the change either way. Servers set by hand (`auto` 0) are always known.
    @Test func serversUnknownIsNotNoServers() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        doorbell.onvif.dns.set(.init(fromDHCP: true, searchDomains: [], dhcpServers: []))
        let none = try #require(try await doorbell.service().readDNS())
        #expect(none.fromDHCP && none.servers.isEmpty && !none.serversUnknown && !none.pointsAt(bridge))
        #expect(try await doorbell.service().readInternetWatch(server: bridge).0
                == CameraSetupReading(state: .willChange, changes: [.init(label: "DNS", now: "from the router (DHCP)", after: "the bridge (192.0.2.10)")]))

        doorbell.onvif.dns.set(.init(fromDHCP: false, searchDomains: [], dhcpServers: [], manualServers: [bridge]))   // ONVIF disagrees
        let disagrees = try #require(try await doorbell.service().readDNS())
        #expect(disagrees.serversUnknown && disagrees.servers.isEmpty && !disagrees.pointsAt(bridge))

        var endpoint = doorbell.endpoint
        endpoint.onvifPort = nil
        doorbell.camera.netPort.set(#"{"httpEnable":1,"httpPort":80,"onvifEnable":0,"onvifPort":\#(doorbell.onvif.server.port),"rtspEnable":1,"rtspPort":554}"#)
        let asked = doorbell.onvif.server.requests.count
        let off = try #require(try await CameraSettingsService(endpoint: endpoint, credentials: Self.credentials, vendor: .reolink).readDNS())
        #expect(off.serversUnknown && !off.pointsAt(bridge))
        #expect(doorbell.onvif.server.requests.count == asked, "ONVIF switched off is not asked")

        doorbell.onvif.otherAPI.set { _ in .status(503) }   // no answer (as while the camera starts)
        let silent = try #require(try await doorbell.service().readDNS())
        #expect(silent.serversUnknown && !silent.pointsAt(bridge))
        doorbell.onvif.otherAPI.set(nil)

        doorbell.camera.localLink.set(MockReolinkCamera.localLink.replacingOccurrences(of: #""auto":1"#, with: #""auto":0"#))
        let byHand = try #require(try await doorbell.service().readDNS())
        #expect(!byHand.serversUnknown && byHand.servers == ["192.168.77.1"], "servers set by hand are known without ONVIF")
        #expect(doorbell.camera.sets.isEmpty)
    }

    /// A Reolink saved the normal way has no ONVIF port (`CameraDrivers.detect` stores one only for an ONVIF camera; the driver asks
    /// `GetNetPort`): on automatic DNS the servers DHCP hands out are read at the ONVIF port `GetNetPort` reports, as the driver's events
    /// are, and no port is searched for. DNS the router hands out counts when it is the bridge alone (owner decision, 2026-10-18).
    @Test func onAutomaticDNSTheONVIFPortComesFromGetNetPort() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        var endpoint = doorbell.endpoint
        endpoint.onvifPort = nil
        doorbell.camera.netPort.set(#"{"httpEnable":1,"httpPort":80,"onvifEnable":1,"onvifPort":\#(doorbell.onvif.server.port),"rtspEnable":1,"rtspPort":554}"#)
        doorbell.onvif.dns.set(.init(fromDHCP: true, searchDomains: [], dhcpServers: [bridge]))   // the router hands out the bridge
        let service = CameraSettingsService(endpoint: endpoint, credentials: Self.credentials, vendor: .reolink)
        let read = try #require(try await service.readDNS())
        #expect(read.method == .reolinkAPI && read.fromDHCP && !read.serversUnknown && read.servers == [bridge] && read.pointsAt(bridge))
        #expect(doorbell.camera.commands.value.contains("GetNetPort"))
        let (watch, _) = try await service.readInternetWatch(server: bridge)
        #expect(watch == CameraSetupReading(state: .alreadyRight, note: CameraSettingsService.dnsFromRouterNote))
        #expect(onvifActions(doorbell).contains("GetDNS") && onvifOnlyRead(doorbell) && doorbell.camera.sets.isEmpty)

        // The port: the saved one, else GetNetPort's, else Reolink's default; none when GetNetPort says ONVIF is off.
        typealias NetPort = ReolinkDriver.ONVIFNetPort
        #expect(CameraSettingsService.reolinkONVIFPort(saved: 8080, netPort: NetPort(enabled: false, port: 8000)) == 8080)
        #expect(CameraSettingsService.reolinkONVIFPort(saved: nil, netPort: NetPort(enabled: true, port: 8001)) == 8001)
        #expect(CameraSettingsService.reolinkONVIFPort(saved: nil, netPort: NetPort(enabled: nil, port: nil)) == ReolinkDriver.defaultONVIFPort)
        #expect(CameraSettingsService.reolinkONVIFPort(saved: nil, netPort: NetPort(enabled: false, port: 8000)) == nil)
    }

    /// The owner's doorbell holds a DNS backup an earlier build saved through ONVIF (Oct 18: `onvifMinimal`, from DHCP, no servers), and the
    /// setup keeps the oldest backup. This run points its DNS at the bridge through `SetLocalLink`, so Restore puts the old one back that
    /// way: `LocalLink` as read with `dns.auto` 1 (the slots as they are: the camera asks DHCP's servers then), read back by `auto`; a backup
    /// of servers set by hand gets `auto` 0 and those servers. ONVIF's `SetDNS` is never sent.
    @Test func aDNSBackupAnEarlierBuildSavedThroughONVIFGoesBackThroughLocalLink() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let saved = try JSONDecoder().decode(CameraDNSBackup.self, from: Data(#"{"method":"onvifMinimal","fromDHCP":true,"servers":[]}"#.utf8))
        #expect(saved == CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: []))
        let service = doorbell.service()
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(json(camera.localLink.value)["dns"] == json(#"{"auto":0,"dns1":"192.0.2.10","dns2":"192.0.2.10"}"#))

        #expect(try await service.restoreDNS(saved, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"))
        var expected = try #require(json(MockReolinkCamera.localLink).object)
        expected["dns"] = json(#"{"auto":1,"dns1":"192.0.2.10","dns2":"192.0.2.10"}"#)
        #expect(body(camera, "SetLocalLink", 1)?[0]?["param"] == .object(["LocalLink": .object(expected)]), "only dns.auto changes")
        #expect(json(camera.localLink.value)["dns"]?["auto"] == .number(1))

        let fixed = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["192.168.77.1", "8.8.8.8"])
        #expect(try await service.restoreDNS(fixed, readBack: quick).succeeded)
        #expect(json(camera.localLink.value)["dns"] == json(#"{"auto":0,"dns1":"192.168.77.1","dns2":"8.8.8.8"}"#))
        let one = CameraDNSBackup(method: .onvifMinimal, fromDHCP: false, servers: ["192.168.77.1"])
        #expect(try await service.restoreDNS(one, readBack: quick).succeeded)
        #expect(json(camera.localLink.value)["dns"] == json(#"{"auto":0,"dns1":"192.168.77.1","dns2":""}"#))
        #expect(!onvifActions(doorbell).contains("SetDNS") && onvifOnlyRead(doorbell))
    }

    /// A camera whose DNS the owner pointed at the bridge by hand (`auto` 0, both slots) is already right, whoever did it.
    @Test func dnsPointedAtTheBridgeByHandIsAlreadyRight() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        doorbell.camera.localLink.set(MockReolinkCamera.localLink.replacingOccurrences(of: #""auto":1,"dns1":"192.168.77.1","dns2":"192.168.77.1""#,
                                                                                        with: #""auto":0,"dns1":"192.0.2.10","dns2":"192.0.2.10""#))
        let service = doorbell.service()
        #expect(try await service.readDNS()?.pointsAt(bridge) == true)
        #expect(try await service.readInternetWatch(server: bridge).0.state == .alreadyRight)
        #expect(doorbell.camera.sets.isEmpty && doorbell.onvif.server.requests.isEmpty)
    }

    /// Camera Bridge refuses rather than risk the camera's address: a fixed address that is not the one Camera Bridge reaches the camera at,
    /// or a `LocalLink` it does not know how to write back (another `type`, none), is left as it is. A fixed address that is the camera's own
    /// goes back as it was.
    @Test func aLinkThatCouldChangeTheAddressIsNotWritten() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        let fixed = MockReolinkCamera.localLink.replacingOccurrences(of: #""type":"DHCP""#, with: #""type":"Static""#)
        for link in [fixed, MockReolinkCamera.localLink.replacingOccurrences(of: #""type":"DHCP""#, with: #""type":"PPPoE""#),
                     MockReolinkCamera.localLink.replacingOccurrences(of: #","type":"DHCP""#, with: "")] {
            camera.localLink.set(link)
            #expect(try await service.applyDNS(server: bridge, readBack: quick) == CameraSetupOutcome(succeeded: false, detail: CameraSettingsService.reolinkLinkLeftAlone))
        }
        #expect(camera.sets.isEmpty && doorbell.onvif.server.requests.isEmpty)

        camera.localLink.set(fixed.replacingOccurrences(of: "192.168.77.31", with: "127.0.0.1"))
        #expect(try await service.applyDNS(server: bridge, readBack: quick).succeeded)
        #expect(body(camera, "SetLocalLink")?[0]?["param"]?["LocalLink"]?["type"] == .string("Static"))
        #expect(body(camera, "SetLocalLink")?[0]?["param"]?["LocalLink"]?["static"]?["ip"] == .string("127.0.0.1"))
    }

    @Test func aDNSChangeThisAccountMayNotMakeSendsNothing() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.abilities.set(["localLink": (permit: 4, ver: 1)])
        let service = doorbell.service()
        let backup = try #require(try await service.readDNS()).backup
        #expect(try await service.readInternetWatch(server: bridge).0.state == .notSupported(CameraAdapterError.notPermittedReason))
        #expect(try await service.applyDNS(server: bridge, readBack: quick) == .notPermittedRefusal)
        #expect(camera.sets.isEmpty)

        camera.abilities.set([:])
        camera.errorQueue.set(["SetLocalLink": [-27]])
        let other = doorbell.service()
        #expect(try await other.applyDNS(server: bridge, readBack: quick) == .notPermittedRefusal)
        #expect(try await other.restoreDNS(backup, readBack: quick) == CameraSetupOutcome(succeeded: true, detail: "via Reolink API"),
                "nothing to put back: the camera has its own DNS")
        #expect(onvifOnlyRead(doorbell))
    }

    // MARK: Streams

    /// `SetEnc` writes `frameRate` (never `frame`), with values from the camera's own range (`GetEnc` with action 1): the nearest frame rate
    /// and bit rate it offers, the keyframe interval in its `gop` bounds, whole seconds of the frame rate asked for. `width`, `height` and
    /// `vType` (internal or tied to the size) are not sent.
    @Test func setEncWritesFrameRateInsideTheCamerasRange() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        let desired = CameraVideoEncoderSettings(token: "main", name: "Main", encoding: "H264", resolution: CameraResolution(width: 2560, height: 1920),
                                                 frameRate: 25, bitrate: 2000, iFrameInterval: 50)
        let results = try await service.applyEncoder([CameraEncoderEdit(isSub: false, desired: desired)])
        #expect(results.first?.succeeded == true && results.first?.method == .reolinkAPI, "\(results)")
        #expect(body(camera, "GetEnc")?[0]?["action"] == .number(1), "the range is read")
        let sent = try #require(body(camera, "SetEnc")?[0]?["param"]?["Enc"])
        #expect(sent == json(#"{"audio":1,"channel":0,"mainStream":{"bitRate":2048,"frameRate":20,"gop":2,"profile":"High","size":"2560*1920"},"subStream":{"bitRate":256,"frameRate":15,"gop":4,"profile":"High","size":"640*480"}}"#))
        #expect(CameraSettingsService.reolinkValues(try #require(json(camera.enc.value)["mainStream"]?.object))
                == EncoderValues(codec: "H264", width: 2560, height: 1920, frameRate: 20, bitrate: 2048, govLength: 40, h264Profile: "High"))
        #expect(doorbell.onvif.server.requests.isEmpty)
    }

    /// The codec is tied to the picture size in the camera's range: H.264 at a size the camera offers only as H.265 is not possible through
    /// the HTTP API (nothing is sent); at a size it offers as H.264 the size is written and the codec follows it.
    @Test func theCodecFollowsTheSizeAndIsNeverWrittenOnItsOwn() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.enc.set(#"{"audio":0,"channel":0,"mainStream":{"bitRate":6144,"frameRate":25,"gop":2,"height":2160,"profile":"High","size":"3840*2160","vType":"h265","width":3840},"subStream":{"bitRate":256,"frameRate":10,"gop":4,"height":360,"profile":"High","size":"640*360","vType":"h264","width":640}}"#)
        camera.encRange.set(#"[{"chnBit":1,"mainStream":{"bitRate":[4096,6144,8192],"frameRate":[25,20,15],"gop":{"max":4,"min":1},"height":2160,"profile":["Base","Main","High"],"size":"3840*2160","vType":"h265","width":3840},"subStream":{"bitRate":[256],"frameRate":[10],"gop":{"max":4,"min":1},"size":"640*360","vType":"h264"}},{"chnBit":1,"mainStream":{"bitRate":[4096,6144,8192],"frameRate":[25,20,15],"gop":{"max":4,"min":1},"height":1440,"profile":["Base","Main","High"],"size":"2560*1440","vType":"h264","width":2560},"subStream":{"bitRate":[256],"frameRate":[10],"gop":{"max":4,"min":1},"size":"640*360","vType":"h264"}}]"#)
        let service = doorbell.service()
        let samesize = CameraVideoEncoderSettings(token: "", name: "", encoding: "H264", resolution: CameraResolution(width: 3840, height: 2160))
        let refused = try #require(try await service.applyEncoder([CameraEncoderEdit(isSub: false, desired: samesize)]).first)
        #expect(!refused.succeeded)
        #expect(refused.failures.first == CameraConfigAttempt(method: .reolinkAPI, failure: .unsupported(CameraSettingsService.reolinkCodecTiedToSize)))
        #expect(camera.sets.isEmpty)

        let smaller = CameraVideoEncoderSettings(token: "", name: "", encoding: "H264", resolution: CameraResolution(width: 2560, height: 1440))
        let done = try #require(try await service.applyEncoder([CameraEncoderEdit(isSub: false, desired: smaller)]).first)
        #expect(done.succeeded && done.method == .reolinkAPI, "\(done)")
        let main = try #require(body(camera, "SetEnc")?[0]?["param"]?["Enc"]?["mainStream"]?.object)
        #expect(main["size"] == .string("2560*1440") && main["vType"] == nil && main["width"] == nil && main["height"] == nil)
        #expect(json(camera.enc.value)["mainStream"]?["vType"] == .string("h264"))

        // A size change alone that would switch the codec unnoticed (the camera offers 3840×2160 only as H.265) is not sent.
        let sets = camera.sets.count
        let larger = CameraVideoEncoderSettings(token: "", name: "", encoding: "H264", resolution: CameraResolution(width: 3840, height: 2160))
        let kept = try #require(try await service.applyEncoder([CameraEncoderEdit(isSub: false, desired: larger)]).first)
        #expect(!kept.succeeded)
        #expect(kept.failures.first == CameraConfigAttempt(method: .reolinkAPI, failure: .unsupported(CameraSettingsService.reolinkSizeChangesCodec)))
        #expect(camera.sets.count == sets && json(camera.enc.value)["mainStream"]?["vType"] == .string("h264"))
    }

    // MARK: ONVIF only where Reolink's API cannot make the change

    /// Once Reolink's API answers that the account may not make a change (`GetAbility`'s permit, or a credential code once the login
    /// worked), the streams and Clean picture steps send nothing through ONVIF: the camera's ONVIF user would be refused too, and an ONVIF
    /// `NotAuthorized` as a first call is a refused login that pauses the camera's logins. The step says to use an administrator account
    /// (every way tried was refused so). Another refusal of Reolink's API ends the chain too.
    @Test func aChangeReolinksAPIRefusesIsNotSentThroughONVIF() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let desired = CameraVideoEncoderSettings(token: "main", name: "Main", encoding: "H264", resolution: CameraResolution(width: 2560, height: 1920),
                                                 frameRate: 25, bitrate: 2000, iFrameInterval: 50)
        camera.abilities.set(["enc": (permit: 4, ver: 1)])   // read only
        let readOnly = try #require(try await doorbell.service().applyEncoder([CameraEncoderEdit(isSub: false, desired: desired)]).first)
        #expect(!readOnly.succeeded && readOnly.failures == [CameraConfigAttempt(method: .reolinkAPI, failure: .notPermitted)])

        camera.abilities.set([:])
        camera.errorQueue.set(["SetEnc": [-27]])
        let refused = try #require(try await doorbell.service().applyEncoder([CameraEncoderEdit(isSub: false, desired: desired)]).first)
        #expect(!refused.succeeded && refused.failures == [CameraConfigAttempt(method: .reolinkAPI, failure: .notPermitted)])

        camera.setRspCodes.set(["SetEnc": -4])
        let rejected = try #require(try await doorbell.service().applyEncoder([CameraEncoderEdit(isSub: false, desired: desired)]).first)
        #expect(rejected.failures.map(\.method) == [.reolinkAPI], "\(rejected.failures)")
        camera.setRspCodes.set([:])

        camera.errorQueue.set(["SetOsd": [-7]])
        let clean = try await doorbell.service().cleanPicture()
        #expect(!clean.succeeded && clean.notPermitted && clean.summary == CameraAdapterError.notPermittedReason)
        #expect(camera.sets.filter { $0.cmd == "SetOsd" }.count == 1, "not sent again without the logo: the account may not change it")

        camera.setOsdError.set(-4)
        let other = try await doorbell.service().cleanPicture()
        #expect(!other.succeeded && !other.notPermitted && other.summary.hasPrefix("Reolink API: "), "\(other.summary)")
        #expect(doorbell.onvif.server.requests.isEmpty, "ONVIF is never asked")
    }

    /// ONVIF stays the way for a change Reolink's API cannot make at all: a codec it ties to another picture size (`SetEnc` has no codec), a
    /// camera without `GetOsd`. The streams keep Reolink's API first even when ONVIF changed them last time.
    @Test func onvifStaysTheWayForAChangeReolinksAPICannotMake() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        camera.enc.set(#"{"audio":0,"channel":0,"mainStream":{"bitRate":6144,"frameRate":25,"gop":2,"height":2160,"profile":"High","size":"3840*2160","vType":"h265","width":3840},"subStream":{"bitRate":256,"frameRate":10,"gop":4,"height":360,"profile":"High","size":"640*360","vType":"h264","width":640}}"#)
        camera.encRange.set(#"[{"chnBit":1,"mainStream":{"bitRate":[4096,6144,8192],"frameRate":[25,20,15],"gop":{"max":4,"min":1},"height":2160,"profile":["Base","Main","High"],"size":"3840*2160","vType":"h265","width":3840},"subStream":{"bitRate":[256],"frameRate":[10],"gop":{"max":4,"min":1},"size":"640*360","vType":"h264"}}]"#)
        let h264 = CameraVideoEncoderSettings(token: "", name: "", encoding: "H264", resolution: CameraResolution(width: 3840, height: 2160))
        let codec = try #require(try await doorbell.service().applyEncoder([CameraEncoderEdit(isSub: false, desired: h264)]).first)
        #expect(codec.failures.map(\.method) == [.reolinkAPI, .onvifMinimal, .onvifFull], "ONVIF is tried after Reolink's API cannot")
        #expect(codec.failures.first == CameraConfigAttempt(method: .reolinkAPI, failure: .unsupported(CameraSettingsService.reolinkCodecTiedToSize)))
        #expect(CameraConfigMethod.attemptOrder(vendor: .reolink, preferred: .onvifMinimal) == [.reolinkAPI, .onvifMinimal, .onvifFull])
        #expect(CameraConfigMethod.attemptOrder(vendor: .reolink, preferred: .onvifFull) == [.reolinkAPI, .onvifFull, .onvifMinimal])
        #expect(CameraConfigMethod.clockOrder(vendor: .reolink, preferred: .onvifMinimal) == [.reolinkAPI, .onvifMinimal])

        camera.osd.set(nil)   // no GetOsd ("not support")
        let clean = try await doorbell.service().cleanPicture()
        #expect(clean.succeeded && clean.method == .onvifMinimal, "\(clean.summary)")
        #expect(onvifActions(doorbell).contains("DeleteOSD"))
    }

    // MARK: One session

    /// A setup run's reading and the security check go through one API session (a Wi-Fi doorbell has few); `close()` ends it, and so does a
    /// service that is let go.
    @Test func oneSessionServesTheWholeRun() async throws {
        let doorbell = try await Doorbell.start()
        defer { doorbell.stop() }
        let camera = doorbell.camera
        let service = doorbell.service()
        _ = try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix")
        _ = try await service.readTimeSource(server: bridge)
        _ = try await service.readInternetWatch(server: bridge)
        _ = try await service.readCleanPicture()
        _ = try await service.readFeature(.upnp)
        _ = try await service.readFeature(.cloud)
        _ = try await service.readRemoteAccess()
        _ = try await service.readDNS()
        #expect(camera.logins.value == 1 && camera.logouts.value.isEmpty)
        #expect(camera.commands.value.filter { $0 == "GetAbility" }.count == 1, "the account's abilities are read once")
        await service.close()
        #expect(camera.logouts.value == ["tok1"])

        do {
            let passing = doorbell.service()
            _ = try await passing.readDNS()
        }
        #expect(await eventually { camera.logouts.value.count == 2 }, "a service that is let go logs out")
        #expect(onvifOnlyRead(doorbell), "ONVIF tells only the servers DHCP gives")
    }
}
#endif
