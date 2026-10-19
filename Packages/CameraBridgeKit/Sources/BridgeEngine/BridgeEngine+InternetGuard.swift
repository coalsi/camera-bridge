import BridgeSupport
import CameraAdapters
import Foundation

// Camera Bridge OS's internet guard, Watch (docs/superpowers/specs/2026-10-17-internet-guard-design.md, stage 1), in the engine. "Watch its
// internet" (a step of Set up for Camera Bridge, BridgeEngine+CameraSetup.swift) points a camera's DNS at the bridge's address on its
// network; the box then answers every name it asks for with "does not exist" and keeps what it asked. Here: which cameras are watched (the
// setup's result, or a reading of the camera's DNS servers that points only at the bridge, whoever set it: owner decision, 2026-10-18), the
// list of them kept in step with the box (`BridgeEnvironment.setGuardedCameras`: at start and whenever a saved configuration changes it,
// tried again with backoff after a refusal or when the box reports another list, never holding the setup), the guard's own reads of the
// cameras' DNS servers (every `guardDNSInterval` one camera after the other, `guardDNSReconnectDelay` after a camera comes back online, right
// after a login pause a read met ends, those two at most once each `guardDNSSpacing`; the security checks read them too,
// BridgeEngine+Security.swift; a reading a setup run or a restore changed the camera under is read again), and the box's report
// (`BridgeEnvironment.guardReport`, read every `guardPollInterval`) as the security levels' evidence, the camera page's activity and the
// day's notice. The evidence also rests on the camera's DNS servers as they were last read: a camera that no longer asks the bridge's
// address now is not watched. The reads only read: nothing here writes to a camera.

/// The engine's side of the internet guard: the list it last sent, the one the box took, the sync under way, the box's last report, and
/// the guard's own reads of the cameras' DNS servers.
@MainActor
final class InternetGuardState {
    /// What the box should watch: every watched camera (the last list asked for).
    var wanted: [GuardedCamera]?
    /// What the box took last.
    var synced: [GuardedCamera]?
    var sync: Task<Void, Never>?
    var poll: Task<Void, Never>?
    /// The box's last report and whether it was evidence then (available, running and recent).
    var report: GuardReport?
    var fresh = false
    /// The loop that reads every camera's DNS servers once each `guardDNSInterval` (`startGuardDNSReads`).
    var dnsLoop: Task<Void, Never>?
    /// Reads due at a set time, one per camera (`scheduleGuardDNSRead`: a camera back online, a login pause over).
    var dnsDue: [UUID: (at: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
    /// The guard's own read under way per camera (`readGuardDNS`), and when each camera's DNS was last read, by any read that asked the
    /// camera (not one that met a login pause: it sent nothing).
    var dnsReading: [UUID: Task<Void, Never>] = [:]
    var dnsReadAt: [UUID: ContinuousClock.Instant] = [:]
    /// Until when a camera's logins are paused (Camera Bridge's own pause after a refused login, or the camera's lock), as a read met it: no
    /// read runs before then.
    var loginsPausedUntil: [UUID: Date] = [:]
    /// The cameras whose last read was refused for its login: the guard does not read them on its own again (each would be another wrong
    /// password) until a read works (a security check: "Check again", the setup's, the one after the camera's runtime starts).
    var loginRefused: Set<UUID> = []
    /// The cameras seen online since the bridge started, and those of them that dropped since (`noteGuardConnections`).
    var seenOnline: Set<UUID> = []
    var dropped: Set<UUID> = []
}

/// What the Internet guard's reads of a camera's DNS servers decided where the setup's record does not say it
/// (`CameraConfiguration.dnsWatch`, `BridgeEngine.internetWatchDone`): the camera of a reading that points only at the bridge, with no setup
/// record, is watched; a reading of other servers ends the watch the setup's record (`setupStarted`) made. Engine-owned; nothing secret.
public struct CameraDNSWatch: Sendable, Codable, Equatable {
    /// The bridge's address the camera's DNS servers all point at; nil: the camera asks other servers.
    public var server: String?
    /// The setup's record (`CameraSetupState.started`) the reading was taken against; nil: the camera had none. A reading-made watch read
    /// against a record that is gone (Restore cleared it) is none.
    public var setupStarted: Date?

    public init(server: String?, setupStarted: Date? = nil) {
        self.server = server
        self.setupStarted = setupStarted
    }
}

/// A camera's DNS servers as they were last read (the guard's evidence rests on them).
enum CameraDNSCheck: Sendable, Equatable {
    /// Not read: the guard can't watch the camera, or there is no guard.
    case notAsked
    case unreadable
    case read(CameraDNSReading)
}

/// What one read of a camera's DNS servers gave: the reading, nothing (the camera does not show them, or did not answer), a reading that
/// does not know which servers the camera asks (`CameraDNSReading.serversUnknown`: unreadable too, though the camera signed in), a login
/// pause it met (nothing was sent), or the camera's refusal of the login.
enum GuardDNSRead: Sendable, Equatable {
    case read(CameraDNSReading)
    case unreadable
    case serversUnknown
    case paused(until: Date)
    case loginRefused
}

extension BridgeEngine {
    /// The bridge has the internet guard (Camera Bridge OS) and can change its list.
    var offersInternetGuard: Bool { environment.hasInternetGuard && environment.setGuardedCameras != nil }

    /// Whether the camera is watched, so the box watches its address: its DNS points at the bridge, as the newest of the setup's result and
    /// the guard's readings says (owner decision, 2026-10-18: whoever changed it, the router's DHCP included).
    /// - With a setup record: `CameraSetupState.watchedServer`, which the step sets when it is done or already right and clears when it is
    ///   refused, not run or restored (kept through a later run until its step has a result and when that run could not read it), and which
    ///   a reading sets or clears too (`watchAfterReading`). A record saved before that field counts when its last record of the step says
    ///   done or already right, unless a reading against that record found the camera asking other servers (`dnsWatch`).
    /// - Without one: a reading that found it asking only the bridge (`CameraConfiguration.dnsWatch`), not one read against a setup record
    ///   that is gone.
    /// The DNS servers the setup keeps to give back (`CameraSetupBackup.internetWatch`) are no proof: they are saved before the step runs and
    /// kept when the camera refuses it, for Restore and for a camera being removed. The web API's camera resource carries it
    /// (`internetWatched`), so the page never works it out again.
    public nonisolated static func internetWatchDone(_ camera: CameraConfiguration) -> Bool {
        guard let state = camera.setupState else {
            guard let watch = camera.dnsWatch else { return false }
            return watch.server != nil && watch.setupStarted == nil
        }
        if state.watchedServer != nil { return true }
        if let watch = camera.dnsWatch, watch.server == nil, watch.setupStarted == state.started { return false }
        guard let record = state.steps.last(where: { $0.id == .internetWatch }) else { return false }
        return record.status == .done || record.status == .alreadyRight
    }

    /// The camera's configuration after a reading of its DNS servers taken at `takenAt` (`server`: the bridge's address on its network now),
    /// nil when the reading changes nothing. A reading that points only at the bridge (`CameraDNSReading.pointsAt`) watches the camera:
    /// `watchedServer` with a setup record, `dnsWatch` without one (no setup record is grown, so the page still says it is not set up). One
    /// of other servers ends the watch: `watchedServer` cleared and `dnsWatch` noting the setup record it was read against (an older build's
    /// record has no `watchedServer` to clear), or `dnsWatch` cleared. The setup's record of what it did and its backup stay. Nothing changes
    /// for a reading taken before the setup's last run ended (the run's result is newer), nor for a camera whose Watch waits for its restart
    /// (ISAPI's "after the camera restarts") while it still asks the servers it had, nor for one that does not know which servers the camera
    /// asks (`serversUnknown`: an unreadable read changes nothing). A reading never ends a Watch's wait for the camera's restart, even one that
    /// shows the bridge: a camera can show the new servers at once and ask its old ones until it restarts (only the person's restart, or a new
    /// run, ends it: `offersCameraRestart`).
    nonisolated static func watchAfterReading(_ camera: CameraConfiguration, _ reading: CameraDNSReading, server: String, takenAt: Date) -> CameraConfiguration? {
        guard !reading.serversUnknown else { return nil }
        var updated = camera
        let asks = reading.pointsAt(server)
        if var state = camera.setupState {
            guard takenAt >= (state.applied ?? state.started) else { return nil }
            if asks {
                state.watchedServer = server
                updated.dnsWatch = nil   // the record holds the watch now (a reading's own, from before it, would outlive a Restore)
            } else {
                guard !waitsForRestart(camera, reading) else { return nil }
                state.watchedServer = nil
                updated.dnsWatch = CameraDNSWatch(server: nil, setupStarted: state.started)
            }
            updated.setupState = state
        } else {
            updated.dnsWatch = asks ? CameraDNSWatch(server: server) : nil
        }
        return updated == camera ? nil : updated
    }

    /// The setup's Watch was taken "after the camera restarts" (its record done with `needsRestart`) and the reading still shows the servers
    /// the setup saved: the camera has not restarted yet.
    nonisolated static func waitsForRestart(_ camera: CameraConfiguration, _ reading: CameraDNSReading) -> Bool {
        guard let record = camera.setupState?.steps.last(where: { $0.id == .internetWatch }), record.status == .done, record.needsRestart,
              let saved = camera.setupBackup?.internetWatch else { return false }
        return saved.servers == reading.backup.servers && saved.fromDHCP == reading.backup.fromDHCP
    }

    /// The camera's address as the guard knows it: a local IPv4 address (10/8, 172.16/12, 192.168/16, 169.254/16, the box's own check)
    /// written plainly; nil for a name, another address or IPv6 (the bridge's address on the camera's network is IPv4 only).
    nonisolated static func guardAddress(_ host: String) -> String? {
        let text = host.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), part.count == 1 || part.first != "0",
                  let value = Int(part), value <= 255 else { return nil }
            bytes.append(value)
        }
        let local = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
        return local ? text : nil
    }

    /// The camera's address for the guard (`EngineTuning.guardCameraAddress` in tests).
    func guardCameraAddress(_ camera: CameraConfiguration) -> String? {
        if let address = tuning.guardCameraAddress { return address(camera) }
        return Self.guardAddress(camera.endpoint.host)
    }

    /// The address "Watch its internet" points the camera's DNS at: the bridge's on the camera's own network; nil when the bridge has none
    /// there, so the step is not offered.
    func internetWatchServer(_ camera: CameraConfiguration) -> String? {
        guard let address = guardCameraAddress(camera) else { return nil }
        return Self.bridgeAddress(onNetworkOf: address, interfaces: tuning.interfaceAddresses?() ?? StreamAddress.interfaceAddresses())
    }

    /// Every watched camera (`internetWatchDone`), by its local address, once each, in the cameras' order.
    func guardedCameraList(_ cameras: [CameraConfiguration]) -> [GuardedCamera] {
        var list: [GuardedCamera] = []
        for camera in cameras where Self.internetWatchDone(camera) {
            guard let address = guardCameraAddress(camera), !list.contains(where: { $0.address == address }) else { continue }
            list.append(GuardedCamera(address: address, level: .watch))
        }
        return list
    }

    // MARK: The camera's DNS, read

    /// Whether the guard reads the camera's DNS servers: the bridge has the guard and an address on the camera's network, and the bridge
    /// reaches the camera directly through a maker's API or ONVIF (Hikvision, Reolink, Amcrest, ONVIF: the cameras the setup works with).
    /// Whether its Watch is done does not matter (a camera can be pointed at the bridge on the camera or by its router), and a camera that
    /// works only through its maker's cloud is read too: its DNS is still its own.
    func readsGuardDNS(_ camera: CameraConfiguration) -> Bool {
        offersInternetGuard && camera.integration == nil && Self.cameraSetupVendors.contains(camera.vendor) && internetWatchServer(camera) != nil
    }

    /// One read of the camera's DNS servers (`CameraSettingsService.readDNS()`, or `EngineTuning.securityDNS` in tests). None runs while a
    /// read met a login pause on the camera that has not ended (`.paused`, nothing sent). A reading that does not know which servers the
    /// camera asks (a Reolink on automatic DNS whose ONVIF did not say which DHCP gives) is `.serversUnknown`.
    func guardDNSRead(_ camera: CameraConfiguration, _ secrets: HTTPCredentials?, service: CameraSettingsService?) async -> GuardDNSRead {
        if let until = internetGuard.loginsPausedUntil[camera.id], until > Date() { return .paused(until: until) }
        do {
            let reading: CameraDNSReading?
            if let read = tuning.securityDNS {
                reading = try await read(camera, secrets)
            } else if let service {
                reading = try await service.readDNS()
            } else {
                reading = nil
            }
            guard let reading else { return .unreadable }
            return reading.serversUnknown ? .serversUnknown : .read(reading)
        } catch let error as CameraAdapterError {
            switch error {
            case .loginsPaused(let until), .lockedOut(let until): return .paused(until: until)
            case .unauthorized: return .loginRefused
            default: return .unreadable
            }
        } catch {
            return .unreadable
        }
    }

    /// What a read of the camera's DNS servers (taken at `takenAt`, of the camera as `against` had it when the read began) changes, and the
    /// DNS evidence to keep: its reading, or the last one (`previous`) when it gave none (an unreadable read changes nothing, and nor does one
    /// that does not know the camera's servers, though its login worked: owner decision, 2026-10-18). A reading
    /// decides the camera's watch (`watchAfterReading`, saved, so the box's list follows); a login pause it met has the camera read again
    /// `guardDNSPauseMargin` after the pause ends; a refused login stops the guard's own reads of the camera until a read works. nil, with
    /// nothing changed, for a reading a setup run or a restore changed the camera under (`setupChanged`: it may show the camera before what
    /// that did): the caller reads again (`settleGuardDNS`).
    func recordGuardDNS(_ cameraID: UUID, _ result: GuardDNSRead, takenAt: Date, against: CameraConfiguration,
                        previous: CameraDNSCheck?) async -> CameraDNSCheck? {
        if case .paused = result {} else { internetGuard.dnsReadAt[cameraID] = .now }   // a read that met a pause sent nothing
        switch result {
        case .read(let reading):
            internetGuard.loginRefused.remove(cameraID)
            internetGuard.loginsPausedUntil[cameraID] = nil
            guard await recordDNSWatch(cameraID, reading, takenAt: takenAt, against: against) else { return nil }
            return .read(reading)
        case .paused(let until):
            internetGuard.loginsPausedUntil[cameraID] = until
            let left = Duration.seconds(max(0, until.timeIntervalSinceNow))
            scheduleGuardDNSRead(cameraID, after: left + tuning.guardDNSPauseMargin)
        case .loginRefused:
            internetGuard.loginRefused.insert(cameraID)
        case .serversUnknown:
            internetGuard.loginRefused.remove(cameraID)   // the camera signed in: a read works
            internetGuard.loginsPausedUntil[cameraID] = nil
        case .unreadable:
            break
        }
        return Self.lastReading(previous)
    }

    /// The evidence a read that gave no reading leaves: the last reading, else none.
    nonisolated static func lastReading(_ previous: CameraDNSCheck?) -> CameraDNSCheck {
        if case .read? = previous, let previous { return previous }
        return .unreadable
    }

    /// Records `first`, a read of `camera` (as it was when the read began) taken at `takenAt` (`recordGuardDNS`); a reading the camera's setup
    /// changed under is read again with `read`, of the camera as it is then, at most twice more, and never counts itself: after a setup run
    /// or a restore, the evidence and the watch rest on the camera as that left it.
    func settleGuardDNS(_ camera: CameraConfiguration, first: GuardDNSRead, takenAt: Date, previous: CameraDNSCheck?,
                        read: (CameraConfiguration) async -> GuardDNSRead) async -> CameraDNSCheck {
        var result = first, taken = takenAt, against = camera
        for attempt in 0..<3 {
            if let dns = await recordGuardDNS(camera.id, result, takenAt: taken, against: against, previous: previous) { return dns }
            guard attempt < 2, !Task.isCancelled, let current = configurations.first(where: { $0.id == camera.id }) else { break }
            log.debug("\(camera.name): its setup changed while its DNS was read; reading it again")
            against = current
            taken = Date()
            result = await read(current)
        }
        return Self.lastReading(previous)
    }

    /// Whether the camera's setup changed since `against` (the camera as a read of its DNS began): a setup run or a restore saved its record
    /// or its backup meanwhile (so did another reading that changed its watch), so the reading may show the camera as it was before.
    nonisolated static func setupChanged(since against: CameraConfiguration, _ camera: CameraConfiguration) -> Bool {
        against.setupState != camera.setupState || against.setupBackup != camera.setupBackup
    }

    /// The camera's watch after a reading (`watchAfterReading`), saved under the engine's operations (so a setup run's result is never
    /// overwritten by a reading it made stale, and the box's list follows the save); logged when the camera joins or leaves the list. False,
    /// with nothing saved, when the camera's setup changed since the read began (`setupChanged`, also while it waited for a run or a restore
    /// to end).
    private func recordDNSWatch(_ cameraID: UUID, _ reading: CameraDNSReading, takenAt: Date, against: CameraConfiguration) async -> Bool {
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { return true }
        if Self.setupChanged(since: against, camera) { return false }
        guard let server = internetWatchServer(camera), Self.watchAfterReading(camera, reading, server: server, takenAt: takenAt) != nil else { return true }
        let counted = await operations.withLockUnlessCancelled { () -> Bool in
            guard let camera = configurations.first(where: { $0.id == cameraID }) else { return true }
            if Self.setupChanged(since: against, camera) { return false }
            guard let server = internetWatchServer(camera), let updated = Self.watchAfterReading(camera, reading, server: server, takenAt: takenAt) else {
                return true
            }
            await changeConfiguration(cameraID) { configuration in
                configuration.setupState = updated.setupState
                configuration.dnsWatch = updated.dnsWatch
            }
            let was = Self.internetWatchDone(camera), now = Self.internetWatchDone(updated)
            guard was != now else { return true }
            let name = InternetGuardText.name
            log.notice(now ? "\(camera.name): its DNS points at Camera Bridge, so the \(name) watches it"
                           : "\(camera.name): its DNS no longer points at Camera Bridge, so the \(name) no longer watches it")
            return true
        }
        return counted ?? true
    }

    /// Reads the camera's DNS servers by themselves (not what it lets out): a read under way is joined, and so is the camera's security
    /// check (it reads them too). Nothing for a camera the guard can't watch, one known to be unreachable (it is read when it comes back)
    /// or one whose logins are paused (it is read when the pause ends). The newest reading is the camera's evidence: its level is worked
    /// out again with it.
    func readGuardDNS(_ cameraID: UUID) async {
        if let running = internetGuard.dnsReading[cameraID] { return await running.value }
        if let check = securityChecks.running[cameraID] {
            _ = await check.value
            return
        }
        guard !isPreview, let camera = configurations.first(where: { $0.id == cameraID }), readsGuardDNS(camera),
              runtimes[cameraID]?.isUnreachable != true else { return }
        let task = Task { [weak self] () -> Void in await self?.performGuardDNSRead(camera) }
        internetGuard.dnsReading[cameraID] = task
        await task.value
        if internetGuard.dnsReading[cameraID] == task { internetGuard.dnsReading[cameraID] = nil }
    }

    private func performGuardDNSRead(_ camera: CameraConfiguration) async {
        let takenAt = Date()
        let credentials = credentials
        let secrets = (try? await Self.offMain { try credentials.credentials(for: camera) }) ?? nil
        let service = Self.encoderService(camera, secrets, profiles: cameraProfiles)
        let result = await guardDNSRead(camera, secrets, service: service)
        guard !Task.isCancelled, configurations.contains(where: { $0.id == camera.id }) else { return }
        let dns = await settleGuardDNS(camera, first: result, takenAt: takenAt, previous: securityChecks.records[camera.id]?.dns) { current in
            await self.guardDNSRead(current, secrets, service: service)
        }
        await reassessSecurity(camera.id, dns: dns)
    }

    /// The camera's last security check worked out again with `dns`, its newest DNS reading (no camera is asked); the status is refreshed
    /// only when something changed.
    func reassessSecurity(_ cameraID: UUID, dns: CameraDNSCheck) async {
        guard let record = securityChecks.records[cameraID], let camera = configurations.first(where: { $0.id == cameraID }) else { return }
        let evidence = await guardEvidence(for: camera, dns: dns)
        let security = CameraSecurity.assess(record.readings, cloudModel: record.cloudModel, internetGuard: evidence, checkedAt: record.security.checkedAt)
        guard securityChecks.records[cameraID] != nil, dns != record.dns || security != record.security else { return }
        securityChecks.records[cameraID]?.dns = dns
        securityChecks.records[cameraID]?.security = security
        await refreshStatus()
    }

    /// One read of the camera's DNS servers `delay` from now, unless one is due sooner, and no sooner than `guardDNSSpacing` after its last
    /// read (a camera whose stream keeps dropping is not read at every return: with a Reolink each read is a login of its own). None for a
    /// camera whose last read was refused for its login (each would be another wrong password); none when the camera was read between this
    /// call and the read's time (that read saw what this one would). Only while the bridge runs (and the engine's scheduled checks are on:
    /// `EngineTuning.securityChecks`).
    func scheduleGuardDNSRead(_ cameraID: UUID, after delay: Duration) {
        guard tuning.securityChecks, !isPreview, !internetGuard.loginRefused.contains(cameraID) else { return }
        let asked = ContinuousClock.now
        var at = asked + delay
        if let last = internetGuard.dnsReadAt[cameraID] { at = max(at, last + tuning.guardDNSSpacing) }
        if let due = internetGuard.dnsDue[cameraID], due.at <= at { return }
        internetGuard.dnsDue.removeValue(forKey: cameraID)?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(until: at)
            guard !Task.isCancelled, let self else { return }
            self.internetGuard.dnsDue[cameraID] = nil
            guard self.isActive, !self.internetGuard.loginRefused.contains(cameraID) else { return }
            if let last = self.internetGuard.dnsReadAt[cameraID], last > asked { return }
            await self.readGuardDNS(cameraID)
        }
        internetGuard.dnsDue[cameraID] = (at, task)
    }

    /// The guard's own reads: every `guardDNSInterval` (30 min) each enabled camera it can watch is read once, one after the other
    /// (`guardDNSInterval / count` apart, never all at once), unless one of its reads ran in the last half interval; a camera whose last
    /// read was refused for its login is left until a read works. Only on a bridge with the guard, while it runs and its scheduled checks
    /// are on.
    func startGuardDNSReads() {
        guard tuning.securityChecks, offersInternetGuard, !isPreview, internetGuard.dnsLoop == nil else { return }
        let interval = tuning.guardDNSInterval
        internetGuard.dnsLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let round = self?.guardDNSRound() else { return }
                guard !round.isEmpty else {
                    try? await Task.sleep(for: interval)
                    continue
                }
                for id in round {
                    try? await Task.sleep(for: interval / round.count)
                    guard !Task.isCancelled, let self else { return }
                    guard self.isActive, !self.internetGuard.loginRefused.contains(id) else { continue }
                    if let last = self.internetGuard.dnsReadAt[id], ContinuousClock.now - last < interval / 2 { continue }
                    await self.readGuardDNS(id)
                }
            }
        }
    }

    /// The cameras one round of the guard's own reads goes through: every enabled camera it can watch, in the cameras' order.
    private func guardDNSRound() -> [UUID] {
        configurations.filter { $0.isEnabled && readsGuardDNS($0) }.map(\.id)
    }

    /// The bridge stops or pauses: no more reads of its own (one under way finishes: it only reads); a camera online again after the next
    /// start is no return.
    func stopGuardDNSReads() {
        internetGuard.dnsLoop?.cancel()
        internetGuard.dnsLoop = nil
        internetGuard.dnsDue.values.forEach { $0.task.cancel() }
        internetGuard.dnsDue.removeAll()
        internetGuard.seenOnline.removeAll()
        internetGuard.dropped.removeAll()
    }

    /// A camera that comes back online after it went offline (it may have just applied a network change, or restarted to take one) has its
    /// DNS read `guardDNSReconnectDelay` (2 min) later, at most once each `guardDNSSpacing` (`scheduleGuardDNSRead`). Reconnecting alone is no
    /// drop (a camera that streams on demand reconnects at every wake); its first time online after the bridge starts is no return (the
    /// security check after its runtime starts reads it); a disabled or idle camera starts again. From the status loop (`refreshStatus`).
    func noteGuardConnections(_ statuses: [CameraStatus]) {
        guard offersInternetGuard, tuning.securityChecks, isActive else { return }
        for status in statuses {
            switch status.connection {
            case .online:
                if internetGuard.dropped.remove(status.id) != nil, let camera = configurations.first(where: { $0.id == status.id }), readsGuardDNS(camera) {
                    scheduleGuardDNSRead(status.id, after: tuning.guardDNSReconnectDelay)
                }
                internetGuard.seenOnline.insert(status.id)
            case .offline:
                if internetGuard.seenOnline.contains(status.id) { internetGuard.dropped.insert(status.id) }
            case .connecting:
                break
            case .idle, .disabled:
                internetGuard.seenOnline.remove(status.id)
                internetGuard.dropped.remove(status.id)
            }
        }
    }

    /// A removed camera's reads go with it.
    func forgetGuardDNS(_ cameraID: UUID) {
        internetGuard.dnsDue.removeValue(forKey: cameraID)?.task.cancel()
        internetGuard.dnsReadAt[cameraID] = nil
        internetGuard.loginsPausedUntil[cameraID] = nil
        internetGuard.loginRefused.remove(cameraID)
        internetGuard.seenOnline.remove(cameraID)
        internetGuard.dropped.remove(cameraID)
    }

    // MARK: The list

    /// The bridge starts: the box is told the whole list (it keeps its own across restarts, but the configuration may have changed while
    /// the bridge was off), the guard's own reads of the cameras' DNS servers begin (`startGuardDNSReads`), and the box's report is read
    /// every `guardPollInterval`.
    func startInternetGuard() {
        guard offersInternetGuard, !isPreview else { return }
        syncInternetGuard(configurations, force: internetGuard.synced == nil)
        startGuardDNSReads()
        guard environment.guardReport != nil, internetGuard.poll == nil else { return }
        let interval = tuning.guardPollInterval
        internetGuard.poll = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.pollGuardReport()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The bridge stops or pauses: the report is no longer read and the guard reads no camera's DNS on its own (the box keeps watching; a
    /// list being sent is still sent).
    func stopInternetGuardPoll() {
        internetGuard.poll?.cancel()
        internetGuard.poll = nil
        stopGuardDNSReads()
    }

    /// Sends the box the list `cameras` call for when it differs from the last one asked for (or `force`). Returns at once: a refusal is
    /// logged and the list is sent again after `guardSyncRetry`, doubling up to `guardSyncRetryCap`, until the box takes it or a newer
    /// list replaces it.
    func syncInternetGuard(_ cameras: [CameraConfiguration], force: Bool = false) {
        guard offersInternetGuard, !isPreview, let send = environment.setGuardedCameras else { return }
        let list = guardedCameraList(cameras)
        if !force, list == internetGuard.wanted, internetGuard.sync != nil || internetGuard.synced == list { return }
        internetGuard.wanted = list
        internetGuard.sync?.cancel()
        let first = tuning.guardSyncRetry, cap = tuning.guardSyncRetryCap
        internetGuard.sync = Task { [weak self] in
            var wait = first
            while !Task.isCancelled {
                do {
                    try await send(list)
                    guard let self, !Task.isCancelled else { return }
                    self.internetGuard.synced = list
                    self.internetGuard.sync = nil
                    self.log.info("Internet guard: \(list.count) camera\(list.count == 1 ? " is" : "s are") watched")
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.log.warning("The internet guard's list could not be changed (\(Redact.string(Self.readableReason(error)))); "
                                     + "trying again in \(Int(wait.timeInterval.rounded())) s")
                }
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, cap)
            }
        }
    }

    /// A camera being removed whose Watch saved its DNS servers gets them back (the box stops answering it with its removal, and the only
    /// copy of its servers goes with its configuration), also when the step was refused (a camera can take part of a change). Best effort: a
    /// camera that does not take them is removed all the same, with a warning that it may not look up names until its DNS is changed on it.
    /// One watched because its DNS was set on the camera (or by its router) has none saved: the warning says to change it there.
    func giveDNSBackOnRemoval(_ camera: CameraConfiguration) async {
        guard tuning.restoresWatchOnRemoval, offersInternetGuard, !isPreview else { return }
        guard let backup = camera.setupBackup?.internetWatch else {
            if Self.internetWatchDone(camera) {
                log.warning("\(camera.name): its DNS still points at Camera Bridge (set on the camera); it may not look up names until its DNS is "
                            + "changed on the camera or in the router")
            }
            return
        }
        let outcome: CameraSetupOutcome
        if Self.cameraSetupVendors.contains(camera.vendor), runtimes[camera.id]?.isUnreachable != true {
            let credentials = credentials
            let secrets = (try? await Self.offMain { try credentials.credentials(for: camera) }) ?? nil
            let service = Self.encoderService(camera, secrets, profiles: cameraProfiles)
            outcome = (try? await service.restoreDNS(backup)) ?? CameraSetupOutcome(succeeded: false, detail: "the camera refused Camera Bridge’s login")
        } else {
            outcome = CameraSetupOutcome(succeeded: false, detail: "the camera doesn’t answer")
        }
        if outcome.succeeded {
            log.notice("\(camera.name): its own DNS servers are back")
        } else {
            log.warning("\(camera.name): its DNS may still point at Camera Bridge (\(Redact.string(outcome.detail))); it may not look up names "
                        + "until its DNS is changed on the camera")
        }
    }

    // MARK: The report

    /// Reads the box's report: every camera's level is worked out again from its last readings (`guardEvidenceChanged`: the report may have
    /// changed or gone stale, a day of watching may have passed, the bridge may have another address); a box that reports other cameras
    /// than the list it took is sent the list again; then the day's notice.
    func pollGuardReport() async {
        guard offersInternetGuard, let read = environment.guardReport else { return }
        let report = await read()
        let now = Date()
        let fresh = report.map { report in
            report.available && report.running != false
                && report.updatedAt.map { now.timeIntervalSince($0) < tuning.guardReportStaleAfter.timeInterval } == true
        } ?? false
        internetGuard.report = report
        internetGuard.fresh = fresh
        await guardEvidenceChanged()
        if let report, report.available, internetGuard.sync == nil, let synced = internetGuard.synced,
           Set(report.cameras.map(\.address)) != Set(synced.map(\.address)) {
            log.warning("The internet guard reports other cameras than it was sent; sending the list again")
            syncInternetGuard(configurations, force: true)
        }
        refreshInternetGuardNotice(now: now)
    }

    /// The guard's evidence for `camera` from the box's last report and `dns`, the camera's DNS servers as they were last read (by its
    /// security check or the guard's own read); nil on a bridge without the guard. DNS the router gives (DHCP) is noted (`dnsFromRouter`).
    func internetGuardEvidence(for camera: CameraConfiguration, dns: CameraDNSCheck) -> GuardEvidence? {
        guard offersInternetGuard else { return nil }
        let address = guardCameraAddress(camera)
        let record = camera.setupState?.steps.last { $0.id == .internetWatch }
        let fromRouter = if case .read(let reading) = dns { reading.fromDHCP } else { false }
        return Self.guardEvidence(address: address, listed: Self.internetWatchDone(camera) && address != nil, asksBridge: asksBridge(camera, dns),
                                  waitsForRestart: record?.status == .done && record?.needsRestart == true, dnsFromRouter: fromRouter,
                                  report: internetGuard.report, fresh: internetGuard.fresh, now: Date())
    }

    /// Whether the DNS servers read are the bridge's address on the camera's network now (it may have moved since); nil when not read.
    func asksBridge(_ camera: CameraConfiguration, _ dns: CameraDNSCheck) -> Bool? {
        guard case .read(let reading) = dns else { return nil }
        guard let server = internetWatchServer(camera) else { return false }
        return reading.pointsAt(server)
    }

    /// The evidence of the camera at `address`: watched when it is on the guard's list here (`listed`: its Watch done, or its DNS read
    /// pointing at the bridge), the box watches that address and the camera asks the bridge (`asksBridge`); the box's lookups and names of
    /// that address whenever it is listed. `available` only for a report that is `fresh` (the box has the guard, its DNS answers, and it
    /// wrote the report recently): otherwise "no lookups seen" is no evidence. `watchedFor` from the box's `since` (when the camera joined
    /// its list); `waitsForRestart`: the step was taken "after the camera restarts"; `dnsFromRouter`: the reading's servers came from DHCP.
    /// Names as `GuardNames.shown` has them; `localLookups` the box's count of the camera's questions that never leave the home network.
    nonisolated static func guardEvidence(address: String?, listed: Bool, asksBridge: Bool?, waitsForRestart: Bool = false, dnsFromRouter: Bool = false,
                                          report: GuardReport?, fresh: Bool, now: Date) -> GuardEvidence {
        let available = fresh && report.map { $0.available && $0.running != false } == true
        guard listed, let address else {
            return GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: available, listed: false)
        }
        guard let entry = report?.camera(at: address), entry.level == .watch else {   // not on the box's list (yet)
            return GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: available, listed: true, asksBridge: asksBridge,
                                 waitsForRestart: waitsForRestart, dnsFromRouter: dnsFromRouter)
        }
        let names = GuardNames.shown(entry.names)
        let dayAgo = now.addingTimeInterval(-86_400)
        let recent = names.enumerated().filter { $0.element.last.map { $0 >= dayAgo } ?? false }.sorted { a, b in
            let left = a.element.last ?? .distantPast, right = b.element.last ?? .distantPast
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element.name)
        return GuardEvidence(watched: asksBridge == true, outsideLookups24h: entry.last24h, lastLookupNames: recent, available: available, today: entry.today,
                             names: names, localLookups: entry.local, listed: true, asksBridge: asksBridge, watchedFor: entry.since.map { max(0, now.timeIntervalSince($0)) },
                             waitsForRestart: waitsForRestart, dnsFromRouter: dnsFromRouter)
    }

    // MARK: The notice

    /// The day's notice from the box's last report: a new one the first time something is blocked on a day, its figures refreshed at most
    /// every `guardNoticeRefresh`, none when nothing was blocked today or the report is no evidence.
    func refreshInternetGuardNotice(now: Date) {
        let watched = configurations.compactMap { camera -> (id: UUID, name: String, address: String)? in
            guard Self.internetWatchDone(camera), let address = guardCameraAddress(camera) else { return nil }
            return (camera.id, camera.name, address)
        }
        guard internetGuard.fresh, let notice = InternetGuardNotice.make(report: internetGuard.report, cameras: watched, now: now) else {
            if internetGuardNotice != nil { internetGuardNotice = nil }
            return
        }
        if let current = internetGuardNotice, current.day == notice.day, now.timeIntervalSince(current.date) < tuning.guardNoticeRefresh.timeInterval {
            return
        }
        if internetGuardNotice?.day != notice.day { log.info("\(notice.sentence)") }
        internetGuardNotice = notice
    }
}
