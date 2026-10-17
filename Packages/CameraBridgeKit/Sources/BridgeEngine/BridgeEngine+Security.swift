import BridgeSupport
import CameraAdapters
import Foundation

// The cameras' security checks (owner decision, 2026-10-17; the levels: `CameraSecurity`). A check reads what the camera says about its
// ways out (`CameraSettingsService.readRemoteAccess()`), asks one of its stream addresses for its video without credentials
// (`RTSPAccessProbe`), reads a watched camera's DNS servers (`readDNS()`: the guard's gold rests on the camera asking the bridge now), and
// adds the Internet guard's evidence where there is a guard. It runs `securityCheckDelay` after a camera's runtime starts (unless it was
// checked within `securityCheckFreshness`), every `securityCheckInterval`, right after "Set up for Camera Bridge" ran or was restored, and on
// demand (`checkCameraSecurity`, at most once per `securityCheckCooldown`); a camera that did not answer (unreachable at its time, or it
// stopped answering during the check) is tried again after `securityCheckRetry`, doubling up to `securityCheckRetryCap`, and keeps its last
// check's readings meanwhile. The guard's report re-assesses without asking the cameras (`guardEvidenceChanged`), keeping the readings' time.
// Results are kept in memory only (`CameraStatus.security`). A check never writes to a camera, never sends credentials with the RTSP check,
// and does not hold the engine's operations: it only reads.

/// A check on demand came too soon after the camera's last one.
public struct CameraSecurityCheckTooSoon: Error, Equatable, Sendable, CustomStringConvertible {
    /// When it can run again.
    public var retryAfterSeconds: Int

    public init(retryAfterSeconds: Int) {
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var description: String { "This camera was checked less than a minute ago. Try again in \(retryAfterSeconds) s." }
}

/// The engine's security checks: each camera's last result with the readings it rests on (in memory only), the checks under way and the
/// scheduled ones.
@MainActor
final class CameraSecurityChecks {
    struct Record {
        var readings: [RemoteAccessFinding]
        var cloudModel: String?
        /// The camera's DNS servers as the check read them (a watched camera's only).
        var dns: CameraDNSCheck
        var security: CameraSecurity
        var finished: ContinuousClock.Instant
    }

    /// What one check gave: the camera's level, and whether the camera answered (a camera that did not keeps its last record's).
    struct Outcome: Sendable {
        var security: CameraSecurity
        var answered: Bool
    }

    var records: [UUID: Record] = [:]
    var running: [UUID: Task<Outcome?, Never>] = [:]
    var lastStarted: [UUID: ContinuousClock.Instant] = [:]
    var scheduled: [UUID: Task<Void, Never>] = [:]
    /// The checks in a row each camera did not answer (the next try waits longer).
    var retries: [UUID: Int] = [:]
    var daily: Task<Void, Never>?
}

extension BridgeEngine {
    /// Every camera but the demo camera is checked.
    nonisolated static func checksSecurity(_ camera: CameraConfiguration) -> Bool { camera.vendor != .demo }

    /// The vendors whose stream addresses are the camera's own (behind a helper or a console, the address is not the camera's).
    nonisolated static let securityProbeVendors: Set<CameraVendor> = [.hikvision, .reolink, .onvif, .rtsp, .amcrest, .doorbird]

    /// Checks the camera now and answers its level. A check already under way is joined. Throws `EngineError.unknownCamera`,
    /// `EngineError.invalidSettings` for the demo camera, `CameraSecurityCheckTooSoon` within `securityCheckCooldown` of the camera's last
    /// check, and `CameraOfflineError` for a camera known to be unreachable or that stopped answering during the check (its last level
    /// stays on its status).
    public func checkCameraSecurity(cameraID: UUID) async throws -> CameraSecurity {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        guard Self.checksSecurity(camera) else { throw EngineError.invalidSettings("Camera Bridge doesn’t check the demo camera") }
        if let running = securityChecks.running[cameraID], let outcome = await running.value {
            guard outcome.answered else { throw CameraOfflineError() }
            return outcome.security
        }
        if let last = securityChecks.lastStarted[cameraID] {
            let left = tuning.securityCheckCooldown - (ContinuousClock.now - last)
            if left > .zero { throw CameraSecurityCheckTooSoon(retryAfterSeconds: max(1, Int(left.timeInterval.rounded(.up)))) }
        }
        if runtimes[cameraID]?.isUnreachable == true { throw CameraOfflineError() }
        guard let outcome = await runSecurityCheck(camera) else { throw EngineError.unknownCamera }   // removed during the check
        guard outcome.answered else { throw CameraOfflineError() }
        return outcome.security
    }

    /// The guard's evidence may have changed (Camera Bridge OS): every camera's level is worked out again from its last readings, without
    /// asking it, and keeps the time those readings were taken. The status is refreshed only when a level or a finding changed.
    public func guardEvidenceChanged() async {
        guard !isPreview else { return }
        var changed = false
        for (id, record) in Array(securityChecks.records) {
            guard let camera = configurations.first(where: { $0.id == id }) else { continue }
            let evidence = await guardEvidence(for: camera, dns: record.dns)
            let security = CameraSecurity.assess(record.readings, cloudModel: record.cloudModel, internetGuard: evidence, checkedAt: record.security.checkedAt)
            guard securityChecks.records[id] != nil, security.level != record.security.level || security.findings != record.security.findings
                    || security.internetGuard != record.security.internetGuard else { continue }
            securityChecks.records[id]?.security = security
            changed = true
        }
        if changed { await refreshStatus() }
    }

    /// One check of `camera`, or the one already under way; nil when the camera was removed meanwhile.
    @discardableResult
    func runSecurityCheck(_ camera: CameraConfiguration) async -> CameraSecurityChecks.Outcome? {
        let id = camera.id
        if let running = securityChecks.running[id] { return await running.value }
        securityChecks.lastStarted[id] = .now
        let task = Task { [weak self] () -> CameraSecurityChecks.Outcome? in await self?.performSecurityCheck(camera) }
        securityChecks.running[id] = task
        let result = await task.value
        if securityChecks.running[id] == task { securityChecks.running[id] = nil }
        return result
    }

    private func performSecurityCheck(_ camera: CameraConfiguration) async -> CameraSecurityChecks.Outcome? {
        let checkedAt = Date()
        let model = CloudDependentModels.brand(of: camera)
        var readings: [RemoteAccessFinding] = []
        var answered = true
        var dns = CameraDNSCheck.notAsked
        if model == nil {   // a camera that works only through its maker's cloud is not asked
            let credentials = credentials
            let secrets = (try? await Self.offMain { try credentials.credentials(for: camera) }) ?? nil
            let service = camera.integration == nil && Self.securityProbeVendors.contains(camera.vendor)
                ? Self.encoderService(camera, secrets, profiles: cameraProfiles) : nil
            if let read = await securityReadings(camera, secrets, service: service) {
                readings = read
                if offersInternetGuard, Self.internetWatchDone(camera) { dns = await securityDNS(camera, secrets, service: service) }
                if let url = await securityProbeURL(camera) {
                    let state: RemoteAccessState
                    if let probe = tuning.rtspAccessProbe { state = await probe(url) } else {
                        state = await RTSPAccessProbe.check(url: url, transport: environment.platform.transport)
                    }
                    readings.append(RemoteAccessFinding(feature: .unauthenticatedVideo, state: state))
                }
            } else {
                answered = false
                readings = [.cloudUnknown]
            }
        }
        guard !Task.isCancelled, configurations.contains(where: { $0.id == camera.id }) else { return nil }
        if answered { securityChecks.retries[camera.id] = nil } else { scheduleSecurityRetry(camera.id) }
        if !answered, let previous = securityChecks.records[camera.id] {
            log.info("\(camera.name): security check: the camera did not answer; its last check stands")
            return .init(security: previous.security, answered: false)
        }
        let evidence = await guardEvidence(for: camera, dns: dns)
        let security = CameraSecurity.assess(readings, cloudModel: model, internetGuard: evidence, checkedAt: checkedAt)
        securityChecks.records[camera.id] = .init(readings: readings, cloudModel: model, dns: dns, security: security, finished: .now)
        log.info("\(camera.name): security check: \(answered ? security.title : "the camera did not answer")")
        await refreshStatus()
        return .init(security: security, answered: answered)
    }

    /// What the camera says (`readRemoteAccess`); a camera behind a helper or a console (no `service`) has its cloud unknown. nil when the
    /// camera stopped answering during the reading (not a refusal: a refused login is the camera's answer, and every reading left unknown).
    private func securityReadings(_ camera: CameraConfiguration, _ secrets: HTTPCredentials?, service: CameraSettingsService?) async -> [RemoteAccessFinding]? {
        if let reading = tuning.securityReading { return await reading(camera, secrets) }
        guard let service else { return [.cloudUnknown] }
        let readings = (try? await service.readRemoteAccess()) ?? [.cloudUnknown]
        return await service.remoteAccessUnanswered ? nil : readings
    }

    /// A watched camera's DNS servers (`readDNS`), for the guard's evidence.
    private func securityDNS(_ camera: CameraConfiguration, _ secrets: HTTPCredentials?, service: CameraSettingsService?) async -> CameraDNSCheck {
        if let read = tuning.securityDNS { return await read(camera, secrets).map(CameraDNSCheck.read) ?? .unreadable }
        guard let service, let reading = try? await service.readDNS() else { return .unreadable }
        return .read(reading)
    }

    /// The address the RTSP check asks: the configured sub stream, else the main stream (the vendor's usual ones when none is configured),
    /// else the ones the running ingest got from the camera. Never with credentials; nil for a camera whose video is not its own RTSP.
    func securityProbeURL(_ camera: CameraConfiguration) async -> URL? {
        guard camera.integration == nil, Self.securityProbeVendors.contains(camera.vendor) else { return nil }
        let configured = StreamSources.urls(for: camera)
        var url = configured.sub ?? configured.main
        if url == nil, let running = await runtimes[camera.id]?.rtspAddresses { url = running.sub ?? running.main }
        guard let url, url.scheme?.lowercased() == "rtsp" else { return nil }
        return url.removingUserInfo
    }

    /// The Internet guard's evidence for the camera, with `dns`, its DNS servers as its check read them; nil where there is no guard (the Mac
    /// app). On Camera Bridge OS: the box's last report (`internetGuardEvidence`, BridgeEngine+InternetGuard.swift).
    func guardEvidence(for camera: CameraConfiguration, dns: CameraDNSCheck) async -> GuardEvidence? {
        if let evidence = tuning.guardEvidence { return await evidence(camera) }
        return internetGuardEvidence(for: camera, dns: dns)
    }

    // MARK: Scheduling

    /// One check of the camera `delay` from now (a later call replaces it): only while the bridge runs, for a camera that is still there;
    /// one unreachable then is tried again later (`scheduleSecurityRetry`). `skipIfFresh` skips a camera checked within
    /// `securityCheckFreshness`.
    func scheduleSecurityCheck(_ cameraID: UUID, after delay: Duration, skipIfFresh: Bool) {
        guard tuning.securityChecks, !isPreview else { return }
        securityChecks.scheduled.removeValue(forKey: cameraID)?.cancel()
        let freshness = tuning.securityCheckFreshness
        securityChecks.scheduled[cameraID] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.securityChecks.scheduled[cameraID] = nil
            guard self.isActive, let camera = self.configurations.first(where: { $0.id == cameraID }), Self.checksSecurity(camera) else { return }
            if self.runtimes[cameraID]?.isUnreachable == true { return self.scheduleSecurityRetry(cameraID) }
            if skipIfFresh, let record = self.securityChecks.records[cameraID], ContinuousClock.now - record.finished < freshness { return }
            await self.runSecurityCheck(camera)
        }
    }

    /// The camera did not answer its check (or was unreachable at its time): it is checked again after `securityCheckRetry`, then twice as
    /// long each time it does not answer, up to `securityCheckRetryCap`, instead of a day later. Its last result stays meanwhile.
    func scheduleSecurityRetry(_ cameraID: UUID) {
        guard tuning.securityChecks, !isPreview, isActive else { return }
        let attempt = securityChecks.retries[cameraID, default: 0]
        securityChecks.retries[cameraID] = attempt + 1
        scheduleSecurityCheck(cameraID, after: min(tuning.securityCheckRetry * (1 << min(attempt, 16)), tuning.securityCheckRetryCap), skipIfFresh: false)
    }

    /// Every `securityCheckInterval`, each enabled camera that answers, one after the other.
    func startDailySecurityChecks() {
        guard tuning.securityChecks, !isPreview, securityChecks.daily == nil else { return }
        let interval = tuning.securityCheckInterval
        securityChecks.daily = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                for camera in self.configurations where camera.isEnabled && Self.checksSecurity(camera) {
                    guard !Task.isCancelled, self.isActive else { break }
                    if self.runtimes[camera.id]?.isUnreachable == true {
                        self.scheduleSecurityRetry(camera.id)
                        continue
                    }
                    await self.runSecurityCheck(camera)
                }
            }
        }
    }

    /// The bridge stops or pauses: no more scheduled checks (a check under way finishes: it only reads).
    func stopSecurityChecks() {
        securityChecks.daily?.cancel()
        securityChecks.daily = nil
        securityChecks.scheduled.values.forEach { $0.cancel() }
        securityChecks.scheduled.removeAll()
    }

    /// A removed camera's result and schedule go with it.
    func forgetSecurity(_ cameraID: UUID) {
        securityChecks.scheduled.removeValue(forKey: cameraID)?.cancel()
        securityChecks.records[cameraID] = nil
        securityChecks.lastStarted[cameraID] = nil
        securityChecks.retries[cameraID] = nil
    }
}
