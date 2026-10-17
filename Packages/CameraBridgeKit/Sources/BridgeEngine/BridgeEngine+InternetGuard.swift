import BridgeSupport
import CameraAdapters
import Foundation

// Camera Bridge OS's internet guard, Watch (docs/superpowers/specs/2026-10-17-internet-guard-design.md, stage 1), in the engine. "Watch its
// internet" (a step of Set up for Camera Bridge, BridgeEngine+CameraSetup.swift) points a camera's DNS at the bridge's address on its
// network; the box then answers every name it asks for with "does not exist" and keeps what it asked. Here: which cameras' Watch is done,
// the list of them kept in step with the box (`BridgeEnvironment.setGuardedCameras`: at start and whenever a saved configuration changes it,
// tried again with backoff after a refusal or when the box reports another list, never holding the setup), and the box's report
// (`BridgeEnvironment.guardReport`, read every `guardPollInterval`) as the security levels' evidence, the camera page's activity and the
// day's notice. The evidence also rests on the camera's DNS servers as its last security check read them (BridgeEngine+Security.swift):
// a camera that no longer asks the bridge's address now is not watched. Nothing here asks a camera.

/// The engine's side of the internet guard: the list it last sent, the one the box took, the sync under way, and the box's last report.
@MainActor
final class InternetGuardState {
    /// What the box should watch: every camera whose Watch is done (the last list asked for).
    var wanted: [GuardedCamera]?
    /// What the box took last.
    var synced: [GuardedCamera]?
    var sync: Task<Void, Never>?
    var poll: Task<Void, Never>?
    /// The box's last report and whether it was evidence then (available, running and recent).
    var report: GuardReport?
    var fresh = false
}

/// What a security check read of a watched camera's DNS servers (the guard's evidence rests on them).
enum CameraDNSCheck: Sendable, Equatable {
    /// Not read: the camera's Watch was not done at its check, or there is no guard.
    case notAsked
    case unreadable
    case read(CameraDNSReading)
}

extension BridgeEngine {
    /// The bridge has the internet guard (Camera Bridge OS) and can change its list.
    var offersInternetGuard: Bool { environment.hasInternetGuard && environment.setGuardedCameras != nil }

    /// Whether the camera's Watch is done, so the box watches its address: its DNS may point at the bridge. That is while the setup keeps
    /// the DNS servers to give back (the step changed them, or was about to), or the setup's last record of the step says done or already
    /// right (a camera that asked the bridge before). Restore gives the servers back and marks the record restored. A later run whose read
    /// of the step failed for a moment does not drop the camera while its servers are kept. Whether the camera really asks the bridge is the
    /// security check's to read (`GuardEvidence.asksBridge`).
    nonisolated static func internetWatchDone(_ camera: CameraConfiguration) -> Bool {
        if camera.setupBackup?.internetWatch != nil { return true }
        guard let record = camera.setupState?.steps.last(where: { $0.id == .internetWatch }) else { return false }
        return record.status == .done || record.status == .alreadyRight
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

    /// Every camera whose Watch is done, by its local address, once each, in the cameras' order.
    func guardedCameraList(_ cameras: [CameraConfiguration]) -> [GuardedCamera] {
        var list: [GuardedCamera] = []
        for camera in cameras where Self.internetWatchDone(camera) {
            guard let address = guardCameraAddress(camera), !list.contains(where: { $0.address == address }) else { continue }
            list.append(GuardedCamera(address: address, level: .watch))
        }
        return list
    }

    // MARK: The list

    /// The bridge starts: the box is told the whole list (it keeps its own across restarts, but the configuration may have changed while
    /// the bridge was off), and its report is read every `guardPollInterval`.
    func startInternetGuard() {
        guard offersInternetGuard, !isPreview else { return }
        syncInternetGuard(configurations, force: internetGuard.synced == nil)
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

    /// The bridge stops or pauses: the report is no longer read (the box keeps watching; a list being sent is still sent).
    func stopInternetGuardPoll() {
        internetGuard.poll?.cancel()
        internetGuard.poll = nil
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
    /// copy of its servers goes with its configuration). Best effort: a camera that does not take them is removed all the same, with a
    /// warning that it can't look up names until its DNS is changed on the camera.
    func giveDNSBackOnRemoval(_ camera: CameraConfiguration) async {
        guard tuning.restoresWatchOnRemoval, offersInternetGuard, !isPreview, let backup = camera.setupBackup?.internetWatch else { return }
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
            log.warning("\(camera.name): its DNS still points at Camera Bridge (\(Redact.string(outcome.detail))); it can’t look up names until "
                        + "its DNS is changed on the camera")
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

    /// The guard's evidence for `camera` from the box's last report and `dns`, the camera's DNS servers as its last security check read them;
    /// nil on a bridge without the guard.
    func internetGuardEvidence(for camera: CameraConfiguration, dns: CameraDNSCheck) -> GuardEvidence? {
        guard offersInternetGuard else { return nil }
        let address = guardCameraAddress(camera)
        let record = camera.setupState?.steps.last { $0.id == .internetWatch }
        return Self.guardEvidence(address: address, listed: Self.internetWatchDone(camera) && address != nil, asksBridge: asksBridge(camera, dns),
                                  waitsForRestart: record?.status == .done && record?.needsRestart == true,
                                  report: internetGuard.report, fresh: internetGuard.fresh, now: Date())
    }

    /// Whether the DNS servers read are the bridge's address on the camera's network now (it may have moved since); nil when not read.
    func asksBridge(_ camera: CameraConfiguration, _ dns: CameraDNSCheck) -> Bool? {
        guard case .read(let reading) = dns else { return nil }
        guard let server = internetWatchServer(camera) else { return false }
        return reading.pointsAt(server)
    }

    /// The evidence of the camera at `address`: watched when its Watch is done here (`listed`), the box watches that address and the camera
    /// asks the bridge (`asksBridge`); the box's lookups and names of that address whenever it is listed. `available` only for a report that
    /// is `fresh` (the box has the guard, its DNS answers, and it wrote the report recently): otherwise "no lookups seen" is no evidence.
    /// `watchedFor` from the box's `since`; `waitsForRestart`: the step was taken "after the camera restarts". Names as `GuardNames.shown` has them.
    nonisolated static func guardEvidence(address: String?, listed: Bool, asksBridge: Bool?, waitsForRestart: Bool = false, report: GuardReport?, fresh: Bool,
                                          now: Date) -> GuardEvidence {
        let available = fresh && report.map { $0.available && $0.running != false } == true
        guard listed, let address else {
            return GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: available, listed: false)
        }
        guard let entry = report?.camera(at: address), entry.level == .watch else {   // not on the box's list (yet)
            return GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: available, listed: true, asksBridge: asksBridge,
                                 waitsForRestart: waitsForRestart)
        }
        let names = GuardNames.shown(entry.names)
        let dayAgo = now.addingTimeInterval(-86_400)
        let recent = names.enumerated().filter { $0.element.last.map { $0 >= dayAgo } ?? false }.sorted { a, b in
            let left = a.element.last ?? .distantPast, right = b.element.last ?? .distantPast
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element.name)
        return GuardEvidence(watched: asksBridge == true, outsideLookups24h: entry.last24h, lastLookupNames: recent, available: available, today: entry.today,
                             names: names, listed: true, asksBridge: asksBridge, watchedFor: entry.since.map { max(0, now.timeIntervalSince($0)) },
                             waitsForRestart: waitsForRestart)
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
