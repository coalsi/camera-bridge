import BridgeSupport
import Foundation

// "Set up for Camera Bridge" and the security check on a Reolink, through Reolink's own HTTP API only (owner decision, 2026-10-18; commands
// checked against the Camera HTTP API User Guide v8 and reolink_aio): the time source (`GetNtp` / `SetNtp`), the time zone (`GetTime` /
// `SetTime`, `ReolinkTimeZone`), UPnP off (`GetUpnp` / `SetUpnp`) and the cloud off (`GetP2p` / `SetP2p`: the UID). The DNS (`GetLocalLink` /
// `SetLocalLink`) is in +DNS.swift, the encoder (`GetEnc` / `SetEnc`) in +Encoder.swift. Reolink refuses ONVIF's writes to its ONVIF user
// (the owner's doorbell answered `SetNTP` with NotAuthorized), so none of these goes through ONVIF. Every write is read back, and its backup
// puts back exactly what the camera had. One API session serves the whole run (`reolink()`). A change `GetAbility` says this account may not
// make is not sent: the step says so (`CameraAdapterError.notPermittedReason`), as it does for a write the camera refuses with a credential
// code once the login worked (`CameraAdapterError.notPermitted`): not a wrong password, so the steps that don't need it still run.
// `GetP2p`'s `uid` (the camera's identity at Reolink's cloud) is never read, logged or kept: only `enable` is.

/// What `GetAbility` says about one module for Camera Bridge's account (v8 guide §3.1.1): `ver` 0, the camera does not have it; `permit`'s
/// bits are option (1), write (2) and read (4), 6 being read and write.
struct ReolinkAbility: Sendable, Equatable {
    var permit: Int
    var ver: Int
    var exists: Bool { ver != 0 }
    var writable: Bool { permit & 2 != 0 }
}

extension CameraNetworkFeature {
    /// Reolink's commands, the `value` key and the `GetAbility` module.
    var reolink: (get: String, set: String, key: String, module: String) {
        self == .upnp ? ("GetUpnp", "SetUpnp", "Upnp", "upnp") : ("GetP2p", "SetP2p", "P2p", "p2p")
    }

    var reolinkLabel: String { self == .upnp ? "UPnP" : "Reolink P2P (UID, the maker’s cloud)" }

    /// A Reolink without the switch (`GetAbility` version 0, or "not support").
    var reolinkHasNone: String { self == .upnp ? "this camera has no UPnP setting" : "this camera has no UID (P2P) setting" }

    /// Where to turn it off by hand on a Reolink that refuses the change: Reolink's support articles 900000627963 (UPnP) and 4404480742425
    /// (UID) put both in the Reolink Client on a computer, under Network › Advanced, and say the phone app has neither.
    var reolinkCannotChange: String {
        let name = self == .upnp ? "UPnP" : "UID"
        return "The camera did not let Camera Bridge change it. Turn \(name) off in the Reolink Client on a computer: Device Settings › Network › "
            + "Advanced › \(name) (older Clients say Camera Settings); the phone app has no such setting. Or block the camera’s internet in your "
            + "router (see Keep this camera local)."
    }
}

extension CameraSettingsService {
    // MARK: The session

    /// The camera's Reolink API session, made once and kept for the service's life.
    func reolink() -> ReolinkAPI {
        if let reolinkSession { return reolinkSession }
        let made = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
        reolinkSession = made
        return made
    }

    /// Ends the service's camera sessions now (a Reolink's API session holds one of the camera's few). The service's end does it too; a
    /// later call logs in again.
    public func close() async {
        await reolinkSession?.logout()
    }

    /// What `GetAbility` says about `module` for Camera Bridge's account (device-wide, or the channel's: `enc`, `osd`); nil when the camera
    /// does not say. Asked once for the service's life. Throws a login refusal and a cancellation only.
    func reolinkAbility(_ module: String, perChannel: Bool = false) async throws -> ReolinkAbility? {
        if !reolinkAbilities.asked {
            var value: JSONValue?
            do {
                value = try await reolink().command("GetAbility", param: ReolinkDriver.abilityParam(credentials))
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                value = nil   // not said: the camera decides when the change is sent
            }
            reolinkAbilities = (true, value)
        }
        let ability = reolinkAbilities.value?["Ability"]
        guard let entry = perChannel ? ability?["abilityChn"]?[reolinkChannel]?[module] : ability?[module],
              let ver = entry["ver"]?.int, let permit = entry["permit"]?.int else { return nil }
        return ReolinkAbility(permit: permit, ver: ver)
    }

    /// Whether `GetAbility` says the camera has `module` but this account may not change it (a preview then says
    /// `CameraAdapterError.notPermittedReason`, and nothing is sent).
    func reolinkMayNotChange(_ module: String, perChannel: Bool = false) async throws -> Bool {
        guard let ability = try await reolinkAbility(module, perChannel: perChannel) else { return false }
        return ability.exists && !ability.writable
    }

    /// Sends a setting (`Set…`) through the session: nil when the camera took it (`rspCode` 200), else the step's refusal: nothing is sent
    /// when `GetAbility` says this account may not change `module`, and that, like a credential answer once the login worked, is
    /// `CameraSetupOutcome.notPermittedRefusal`; "not support" (-9) and "ability error" (-26) are `unsupported`; any other code is the
    /// camera's, with its detail. Throws a login refusal, a transport failure and a cancellation.
    func reolinkSet(_ cmd: String, _ param: JSONValue, module: String?, perChannel: Bool = false, unsupported: String) async throws -> CameraSetupOutcome? {
        if let module, try await reolinkMayNotChange(module, perChannel: perChannel) { return .notPermittedRefusal }
        let answer: ReolinkAPI.Answer
        do {
            answer = try await reolink().answer(cmd, param: param)
        } catch CameraAdapterError.notPermitted {
            return .notPermittedRefusal
        }
        guard case .refused(let code, let detail) = answer else { return nil }
        return .refused(ReolinkAPI.unsupportedCodes.contains(code) ? unsupported : Self.reolinkRefusal(code, detail))
    }

    /// "the camera refused the change (Reolink error -13: set config failed)".
    static func reolinkRefusal(_ code: Int, _ detail: String?) -> String {
        "the camera refused the change (Reolink error \(code)\(detail.map { ": \($0)" } ?? ""))"
    }

    /// `cmd`'s value; nil when the camera answers it with an error code (it does not have the setting). Throws login refusals and transport
    /// failures.
    func reolinkValue(_ cmd: String) async throws -> JSONValue? {
        do {
            return try await reolink().command(cmd)
        } catch CameraAdapterError.apiError {
            return nil
        }
    }

    // MARK: Time from the bridge

    /// `GetNtp`'s `Ntp` (`enable`, `server`, `port`, `interval`); nil when the camera does not have it.
    func reolinkNtp() async throws -> [String: JSONValue]? {
        try await reolinkValue("GetNtp")?["Ntp"]?.object
    }

    static func reolinkTimeSourceBackup(_ ntp: [String: JSONValue]) -> CameraTimeSourceBackup {
        CameraTimeSourceBackup(method: .reolinkAPI, mode: ntp["enable"]?.int == 1 ? "NTP" : "manual", hostName: ntp["server"]?.string,
                               port: ntp["port"]?.string, interval: ntp["interval"]?.int)
    }

    /// NTP on, from `server`, port 123.
    static func reolinkNtpPointsAt(_ server: String, _ ntp: [String: JSONValue]) -> Bool {
        ntp["enable"]?.int == 1 && ntp["server"]?.string.map { ONVIFClient.sameAddress($0, server) } == true && (ntp["port"]?.int ?? 123) == 123
    }

    static func reolinkTimeSourceText(_ ntp: [String: JSONValue]) -> String {
        guard ntp["enable"]?.int == 1 else { return "set by hand" }
        let server = Redact.cameraText(ntp["server"]?.string ?? "", limit: 64)
        guard !server.isEmpty else { return "NTP, no server set" }
        let port = ntp["port"]?.int ?? 123
        return port == 123 ? "NTP from \(server)" : "NTP from \(server), port \(port)"
    }

    func readReolinkTimeSource(server: String) async throws -> (CameraSetupReading, CameraTimeSourceBackup?) {
        guard let ntp = try await reolinkNtp() else { return (.notSupported("the camera does not show its time servers"), nil) }
        let backup = Self.reolinkTimeSourceBackup(ntp)
        if Self.reolinkNtpPointsAt(server, ntp) { return (CameraSetupReading(state: .alreadyRight), backup) }
        if try await reolinkMayNotChange("ntp") { return (.notSupported(CameraAdapterError.notPermittedReason), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time source", now: Self.reolinkTimeSourceText(ntp),
                                                                     after: "NTP from the bridge (\(server))")]), backup)
    }

    /// `SetNtp` with `Ntp` as read and `enable` 1, `server` the bridge, `port` 123 (`interval` as the camera had it), then `GetNtp` again.
    func applyReolinkTimeSource(server: String) async throws -> CameraSetupOutcome {
        guard let ntp = try await reolinkNtp() else { return .refused("the camera does not show its time servers") }
        if Self.reolinkNtpPointsAt(server, ntp) { return CameraSetupOutcome(succeeded: true, detail: "via Reolink API") }
        var edited = ntp
        edited["enable"] = .number(1)
        edited["server"] = .string(server)
        edited["port"] = .number(123)
        if let refusal = try await reolinkSet("SetNtp", .object(["Ntp": .object(edited)]), module: "ntp",
                                              unsupported: "the camera does not let its time servers be changed") { return refusal }
        guard let after = try await reolinkNtp(), Self.reolinkNtpPointsAt(server, after) else { return .refused("the camera kept its own time source") }
        log.info("Set the camera's clock to NTP from the bridge through its Reolink API")
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    /// `SetNtp` with what the backup kept (`enable`, `server`, `port`, `interval`), read back.
    func restoreReolinkTimeSource(_ backup: CameraTimeSourceBackup) async throws -> CameraSetupOutcome {
        guard let ntp = try await reolinkNtp() else { return .refused("the camera no longer shows its time servers") }
        var edited = ntp
        edited["enable"] = .number(backup.mode.caseInsensitiveCompare("NTP") == .orderedSame ? 1 : 0)
        if let host = backup.hostName { edited["server"] = .string(host) }
        if let port = backup.port.flatMap({ Int($0) }) { edited["port"] = .number(Double(port)) }
        if let interval = backup.interval { edited["interval"] = .number(Double(interval)) }
        return try await writeReolinkNtp(edited, as: ntp, checking: ["enable", "server", "port", "interval"])
    }

    /// Why Restore can't give a Reolink its own time server back: the backup an earlier build saved through ONVIF names none.
    static let noSavedTimeServer = "the time source an earlier build of Camera Bridge saved names no time server (the camera took it from "
        + "the router’s DHCP, as ONVIF showed it), so Camera Bridge can’t put the camera’s own back: set its time server in the Reolink app or Client"

    /// Puts back a Reolink's time source from a backup saved through ONVIF (by a build before 2026-10-18, which read a Reolink's time servers
    /// through ONVIF; the setup keeps the oldest backup, so the owner's doorbell still has one): `SetNtp` with `Ntp` as read, `enable` from the
    /// backup's mode (1 for NTP), `server` the backup's first server (else its `hostName`: the camera's own, which the setup adds to such a
    /// backup that names none, `BridgeEngine.completedReolinkTimeSource`, with its `port` and `interval`), `port` and `interval` as the backup
    /// has them, else as read; then read back. nil when the camera does not show `GetNtp` (ONVIF then, whose writes a Reolink may refuse). A
    /// backup of NTP that names no server is refused, nothing written (`noSavedTimeServer`): the camera would keep the bridge as its time
    /// server. One of a clock set by hand turns NTP off and leaves the server, which the camera then does not ask.
    func restoreReolinkTimeSourceFromONVIF(_ backup: CameraTimeSourceBackup, bridge: String? = nil) async throws -> CameraSetupOutcome? {
        guard let ntp = try await reolinkNtp() else { return nil }
        let usesNTP = backup.mode.caseInsensitiveCompare("NTP") == .orderedSame
        let server = backup.servers.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? backup.hostName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if usesNTP, server == nil {
            // Refused only while the camera still asks the bridge: once someone set its own server (as the refusal advises), only the
            // switch goes back and the step counts as restored, so Restore does not refuse it for ever.
            guard let bridge, case .string(let now)? = ntp["server"], !now.isEmpty, now != bridge else { return .refused(Self.noSavedTimeServer) }
            var edited = ntp
            edited["enable"] = .number(1)
            return try await writeReolinkNtp(edited, as: ntp, checking: ["enable"])
        }
        var edited = ntp
        var checking = ["enable"]
        edited["enable"] = .number(usesNTP ? 1 : 0)
        if let server {
            edited["server"] = .string(server)
            checking.append("server")
        }
        if let port = backup.port.flatMap({ Int($0) }) {
            edited["port"] = .number(Double(port))
            checking.append("port")
        }
        if let interval = backup.interval {
            edited["interval"] = .number(Double(interval))
            checking.append("interval")
        }
        return try await writeReolinkNtp(edited, as: ntp, checking: checking)
    }

    /// `SetNtp` with `edited` unless the camera already has it (`ntp`, as read), then `GetNtp` again: the keys `checking` must read back
    /// as written.
    private func writeReolinkNtp(_ edited: [String: JSONValue], as ntp: [String: JSONValue], checking: [String]) async throws -> CameraSetupOutcome {
        if edited != ntp {
            if let refusal = try await reolinkSet("SetNtp", .object(["Ntp": .object(edited)]), module: "ntp",
                                                  unsupported: "the camera does not let its time servers be changed") { return refusal }
            guard let after = try await reolinkNtp(), checking.allSatisfy({ after[$0] == edited[$0] }) else {
                return .refused("the camera kept the bridge as its time server")
            }
            log.info("Put the camera's time source back through its Reolink API")
        }
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    // MARK: Time zone

    func readReolinkTimeZone(posix: String, zoneName: String, target: String) async throws -> (CameraSetupReading, CameraTimeZoneBackup?) {
        guard let value = try await reolinkValue("GetTime"),
              let camera = ReolinkTimeZone(camera: value, countsEast: ReolinkTimeZone.countsEast(value, now: Date())) else {
            return (.notSupported("the camera reports no time zone"), nil)
        }
        let backup = CameraTimeZoneBackup(method: .reolinkAPI, value: camera.rule != nil ? "1" : "0", reolinkTime: ReolinkTimeZone.saved(value))
        guard let wanted = ReolinkTimeZone(posix: posix) else {
            return (.notSupported("Camera Bridge can’t give this camera the daylight-saving rule of \(zoneName)"), backup)
        }
        if camera.matches(wanted) { return (CameraSetupReading(state: .alreadyRight), backup) }
        if try await reolinkMayNotChange("time") { return (.notSupported(CameraAdapterError.notPermittedReason), backup) }
        return (CameraSetupReading(state: .willChange, changes: [.init(label: "Time zone", now: camera.text(against: wanted), after: target)]), backup)
    }

    /// `SetTime` with what changes (`ReolinkTimeZone.setTimeParam`), then `GetTime` again, read in the camera's sign as before the write.
    func applyReolinkTimeZone(posix: String) async throws -> CameraSetupOutcome {
        guard let wanted = ReolinkTimeZone(posix: posix) else { return .refused("Camera Bridge can’t give this camera this time zone’s daylight-saving rule") }
        guard let value = try await reolinkValue("GetTime") else { return .refused("the camera reports no time zone") }
        let east = ReolinkTimeZone.countsEast(value, now: Date())
        guard let current = ReolinkTimeZone(camera: value, countsEast: east) else { return .refused("the camera reports no time zone") }
        guard !current.matches(wanted), let param = ReolinkTimeZone.setTimeParam(value, wanted: wanted, countsEast: east) else {
            return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
        }
        if let refusal = try await reolinkSet("SetTime", param, module: "time", unsupported: "the camera does not let its time zone be changed") {
            return refusal
        }
        guard let after = try await reolinkValue("GetTime"), ReolinkTimeZone(camera: after, countsEast: east)?.matches(wanted) == true else {
            return .refused("the camera kept its time zone")
        }
        log.info("Set the camera's time zone to \(posix) through its Reolink API")
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    /// Puts back the `timeZone` and `Dst` the backup kept; a backup from before 2026-10-18 kept only the daylight-saving switch (`value`).
    func restoreReolinkTimeZone(_ backup: CameraTimeZoneBackup) async throws -> CameraSetupOutcome {
        guard let saved = backup.reolinkTime else {
            if let refusal = try await setReolinkDaylightSaving(backup.value == "1") { return refusal }
            return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
        }
        guard let value = try await reolinkValue("GetTime") else { return .refused("the camera no longer shows its clock settings") }
        guard let param = ReolinkTimeZone.restoreParam(value, saved: saved) else { return CameraSetupOutcome(succeeded: true, detail: "via Reolink API") }
        if let refusal = try await reolinkSet("SetTime", param, module: "time", unsupported: "the camera does not let its time zone be changed") {
            return refusal
        }
        guard let after = try await reolinkValue("GetTime"), ReolinkTimeZone.restoreParam(after, saved: saved) == nil else {
            return .refused("the camera did not take its old time zone back")
        }
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    /// GetTime, then SetTime with only `Dst.enable` changed (to `daylightSaving`): what a backup from before 2026-10-18 puts back. nil when it
    /// worked (or was already so), else the refusal.
    func setReolinkDaylightSaving(_ daylightSaving: Bool) async throws -> CameraSetupOutcome? {
        do {
            guard var dst = try await reolinkValue("GetTime")?["Dst"]?.object, let enable = dst["enable"]?.int else {
                return .refused("no daylight saving in GetTime")
            }
            let wanted = daylightSaving ? 1 : 0
            if enable == wanted { return nil }
            dst["enable"] = .number(Double(wanted))
            if let refusal = try await reolinkSet("SetTime", .object(["Dst": .object(dst)]), module: "time",
                                                  unsupported: "the camera does not let its daylight saving be changed") { return refusal }
            guard try await reolinkValue("GetTime")?["Dst"]?["enable"]?.int == wanted else { return .refused("the camera kept its daylight saving") }
            log.info("Turned the camera's daylight saving \(daylightSaving ? "on" : "off") through its own API")
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .refused(error)
        }
    }

    // MARK: UPnP and the cloud (the UID)

    /// The cloud step's note on a Reolink (owner decision, 2026-10-18): what turning the UID off means.
    static func reolinkUIDOffNote(doorbell: Bool) -> String {
        "With its UID off, the Reolink app stops working away from home"
            + (doorbell ? "; doorbell rings still come through Apple Home." : "; Apple Home keeps working there.")
    }

    /// The feature's switch (`enable`); nil when the camera does not have the command ("not support", "ability error") or shows no switch.
    /// Only `enable` is read (`GetP2p` also answers the camera's `uid`). Throws other refusals as `.apiError`.
    func reolinkSwitch(_ feature: CameraNetworkFeature) async throws -> Bool? {
        switch try await reolink().answer(feature.reolink.get) {
        case .value(let value, _): return value[feature.reolink.key]?["enable"]?.int.map { $0 != 0 }
        case .refused(let code, _) where ReolinkAPI.unsupportedCodes.contains(code): return nil
        case .refused(let code, _): throw CameraAdapterError.apiError(command: feature.reolink.get, code: code)
        }
    }

    /// A Reolink's UPnP or UID switch for the preview; the backup holds `reolink:Upnp` or `reolink:P2p` and the switch.
    func readReolinkFeature(_ feature: CameraNetworkFeature) async throws -> (CameraSetupReading, CameraFeatureBackup?) {
        if let ability = try await reolinkAbility(feature.reolink.module), !ability.exists { return (.notSupported(feature.reolinkHasNone), nil) }
        guard let enabled = try await reolinkSwitch(feature) else { return (.notSupported(feature.reolinkHasNone), nil) }
        let backup = CameraFeatureBackup(path: "reolink:\(feature.reolink.key)", enabled: enabled)
        guard enabled else { return (CameraSetupReading(state: .alreadyRight), backup) }
        if try await reolinkMayNotChange(feature.reolink.module) { return (.notSupported(CameraAdapterError.notPermittedReason), backup) }
        let note = feature == .cloud ? Self.reolinkUIDOffNote(doorbell: try await reolinkIsDoorbell()) : nil
        return (CameraSetupReading(state: .willChange, changes: [.init(label: feature.reolinkLabel, now: "on", after: "off")], note: note), backup)
    }

    /// `SetUpnp {"Upnp":{"enable":0|1}}` or `SetP2p {"P2p":{"enable":0|1}}` (only the switch, as the guide's example writes it), read back.
    func setReolinkFeature(_ feature: CameraNetworkFeature, enabled: Bool) async throws -> CameraSetupOutcome {
        if let ability = try await reolinkAbility(feature.reolink.module), !ability.exists { return .refused(feature.reolinkHasNone) }
        guard let current = try await reolinkSwitch(feature) else { return .refused(feature.reolinkHasNone) }
        if current == enabled { return CameraSetupOutcome(succeeded: true, detail: "already \(enabled ? "on" : "off")") }
        let param = JSONValue.object([feature.reolink.key: .object(["enable": .number(enabled ? 1 : 0)])])
        if let refusal = try await reolinkSet(feature.reolink.set, param, module: feature.reolink.module, unsupported: feature.reolinkCannotChange) {
            return refusal
        }
        guard try await reolinkSwitch(feature) == enabled else { return .refused("the camera kept it \(enabled ? "off" : "on")") }
        log.info("Turned the camera's \(feature == .upnp ? "UPnP" : "UID (P2P)") \(enabled ? "on" : "off") through its Reolink API")
        return CameraSetupOutcome(succeeded: true, detail: "via Reolink API")
    }

    /// Whether the camera is a doorbell (`GetDevInfo`); false when it does not say.
    func reolinkIsDoorbell() async throws -> Bool {
        do {
            return ReolinkDriver.isDoorbell(devInfo: try await reolink().command("GetDevInfo")["DevInfo"], visitorSupported: false)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }
}
