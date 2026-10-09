// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Session handling follows HAP-NodeJS lib/camera/RTPStreamManagement.ts (handleSetupEndpoints,
// _handleSelectedStreamConfigurationWrite, handleSessionClosed, forceStop, streamingIsDisabled).

import BridgeSupport
import Foundation
import HAP
import HAPCore
import Synchronization

/// One CameraRTPStreamManagement service: SetupEndpoints → `prepareStream`, SelectedRTPStreamConfiguration →
/// start / reconfigure / end, StreamingStatus, and the stream's `Active` flag.
///
/// Every operation on the session (setup, commands, teardown) runs under one FIFO lock, so the delegate sees, per
/// session: `prepareStream`, then `.start` / `.reconfigure`, then exactly one `.stop` — never overlapping. A session
/// whose `prepareStream` succeeded always gets its `.stop` (end command, failed start, HAP connection closed,
/// `Active` or HomeKitCameraActive turned off, `CameraController.stopStreamingSession`).
///
/// Each delegate call has a deadline (`CameraControllerTimings.streamingDelegateTimeout`, below HAP's 9 s): a call that
/// misses it fails the request with -70408 and the service moves on (the call is cancelled; a `prepareStream` that
/// still succeeds later gets its `.stop`). A setup or command whose HAP request timed out while it waited for the lock
/// leaves the queue without reaching the delegate.
final class RTPStreamManagement: Sendable {
    private struct Session {
        let id: UUID
        let hapSessionID: UUID
        /// The controller (pairing) that set the session up: a new setup from it supersedes a session it never started.
        let controllerID: String
        /// When the session was admitted (a new setup supersedes an unstarted session older than `staleUnstartedSessionAge`).
        let admittedAt: ContinuousClock.Instant
        /// Ends the session if it is still not started `preparedSessionTimeout` after it was prepared.
        var expiry: Task<Void, Never>?
        /// HAP-NodeJS: 1378 on IPv4, 1228 on IPv6 (the controller's address family).
        let defaultMTU: Int
        /// The SetupEndpoints read-back, once `prepareStream` succeeded.
        var response: Data?
        /// The running video parameters, once started.
        var video: SelectedVideoParameters?
    }

    private struct State {
        var active = true
        var operatingModeEnabled = true
        var available = true
        var session: Session?
        /// The busy/error read-back for the last controller whose setup was refused.
        var rejection: (hapSessionID: UUID, response: Data)?
        var selected = RTPStreamManagement.suspendedConfiguration
        /// HAP sessions this service has a close handler on: one per HAP connection, however many setups it sends.
        var watchedHAPSessions: Set<UUID> = []

        var disabled: Bool { !active || !operatingModeEnabled }

        var status: CameraTLV.StreamingStatus {
            if session != nil { return .inUse }
            return available ? .available : .unavailable
        }
    }

    /// `{1: {2: suspend}}`: what SelectedRTPStreamConfiguration reads while no stream runs (HAP-NodeJS).
    static let suspendedConfiguration: Data = {
        var control = TLVBuilder()
        control.add(0x02, uint8: CameraTLV.SessionCommand.suspend.rawValue)
        var builder = TLVBuilder()
        builder.add(0x01, tlv: control)
        return builder.data
    }()

    let index: Int
    let service: Service
    private let delegate: any CameraStreamingDelegate
    private let delegateTimeout: Duration
    private let preparedSessionTimeout: Duration
    private let staleUnstartedSessionAge: Duration
    private let lock = AsyncSerialLock()
    private let state = Mutex(State())
    private let log: Log

    /// `log`: the controller's (tagged with its camera).
    init(index: Int, options: CameraStreamingOptions, delegate: any CameraStreamingDelegate, delegateTimeout: Duration,
         preparedSessionTimeout: Duration = CameraControllerTimings.standard.preparedSessionTimeout,
         staleUnstartedSessionAge: Duration = CameraControllerTimings.standard.staleUnstartedSessionAge,
         log: Log = Log(category: "camera")) {
        self.index = index
        self.log = log
        self.delegate = delegate
        self.delegateTimeout = delegateTimeout
        self.preparedSessionTimeout = preparedSessionTimeout
        self.staleUnstartedSessionAge = staleUnstartedSessionAge
        let service = Service(.cameraRTPStreamManagement, subtype: String(index))
        service.characteristic(.supportedVideoStreamConfiguration).update(.data(CameraTLV.supportedVideoStreamConfiguration(options)))
        service.characteristic(.supportedAudioStreamConfiguration).update(.data(CameraTLV.supportedAudioStreamConfiguration(options)))
        service.characteristic(.supportedRTPConfiguration).update(.data(CameraTLV.supportedRTPConfiguration(options)))
        service.characteristic(.selectedRTPStreamConfiguration).update(.data(Self.suspendedConfiguration))
        service.characteristic(.setupEndpoints).update(.data(CameraTLV.SetupEndpointsResponse.defaultValue))
        service.characteristic(.streamingStatus).update(.data(CameraTLV.streamingStatus(.available)))
        service.characteristic(.active).update(.uint(1))
        self.service = service

        service.characteristic(.setupEndpoints).onRead { [weak self] context async throws(HAPStatus) -> HAPValue in
            guard let self else { throw .serviceCommunicationFailure }
            return .data(self.setupEndpointsReadBack(for: context?.session.id))
        }
        service.characteristic(.setupEndpoints).onWrite { [weak self] value, context async throws(HAPStatus) -> HAPValue? in
            guard let self else { throw .serviceCommunicationFailure }
            try await self.handleSetupEndpoints(value, context: context)
            return nil
        }
        service.characteristic(.selectedRTPStreamConfiguration).onRead { [weak self] _ async throws(HAPStatus) -> HAPValue in
            guard let self else { throw .serviceCommunicationFailure }
            return .data(self.state.withLock { $0.disabled ? Self.suspendedConfiguration : $0.selected })
        }
        service.characteristic(.selectedRTPStreamConfiguration).onWrite { [weak self] value, _ async throws(HAPStatus) -> HAPValue? in
            guard let self else { throw .serviceCommunicationFailure }
            try await self.handleSelectedConfiguration(value)
            return nil
        }
    }

    // MARK: - State for the controller

    /// The stream management's `Active` characteristic (its write handler is the controller's: admin-only, persisted).
    var activeCharacteristic: Characteristic { service.characteristic(.active) }

    var isActive: Bool { state.withLock { $0.active } }

    /// A started (not only prepared) session.
    var isStreaming: Bool { state.withLock { $0.session?.video != nil } }

    /// Whether the session `id` (prepared or started) belongs to this service.
    func hasSession(_ id: UUID) -> Bool { state.withLock { $0.session?.id == id } }

    /// HAP sessions with a close handler (tests).
    var watchedHAPSessionCount: Int { state.withLock { $0.watchedHAPSessions.count } }

    /// Setups, commands and teardowns waiting for the service's lock (tests).
    var queuedOperationCount: Int { lock.waiterCount }

    /// Updates `Active`; the caller stops a running session when it turns off.
    func setActive(_ active: Bool) {
        state.withLock { $0.active = active }
        activeCharacteristic.mirror { .uint(self.state.withLock { $0.active } ? 1 : 0) }
    }

    /// HomeKitCameraActive; the caller stops a running session when it turns off.
    func setOperatingModeEnabled(_ enabled: Bool) {
        state.withLock { $0.operatingModeEnabled = enabled }
    }

    /// `false`: idle services report StreamingStatus unavailable and refuse setups (error read-back); a session in use
    /// keeps running (and reports in use) until it ends.
    func setStreamingAvailable(_ available: Bool) {
        state.withLock { $0.available = available }
        syncStatus()
    }

    /// HAP-NodeJS `handleFactoryReset` (the accessory lost its last pairing): `Active` on, the stored
    /// SelectedRTPStreamConfiguration and SetupEndpoints values back to their defaults, no refusal read-back, and a
    /// session still running ends (`.stop` once the operation in progress is done; the caller does not wait). The
    /// unpairing closes the controllers' connections, which normally ends the session first.
    func factoryReset(because reason: String) {
        setActive(true)
        state.withLock { $0.rejection = nil }
        service.characteristic(.selectedRTPStreamConfiguration).update(.data(Self.suspendedConfiguration))
        service.characteristic(.setupEndpoints).update(.data(CameraTLV.SetupEndpointsResponse.defaultValue))
        Task { await stopSession(nil, reason: reason) }
    }

    /// Ends the session `id` (any session when nil) and sends the delegate `.stop`. Waits for a setup or command in
    /// progress to finish first.
    func stopSession(_ id: UUID?, reason: String) async {
        await lock.withLock { await endSession(reason: reason) { id == nil || $0.id == id } }
    }

    /// Ends the session `id` from the accessory side at once: the service is free (and reports available) when this
    /// returns, so a controller that retries straight away is not refused as busy; the delegate's `.stop` follows in turn
    /// under the lock (after a setup or command in progress), never twice. False if the service has no such session.
    @discardableResult
    func forceStop(_ id: UUID, reason: String) -> Bool {
        let ended = state.withLock { state -> Bool in
            guard state.session?.id == id else { return false }
            state.session?.expiry?.cancel()
            state.session = nil
            state.selected = Self.suspendedConfiguration
            return true
        }
        guard ended else { return false }
        syncStatus()
        log.info("Stream \(index): stream ended (\(reason))")
        Task { await lock.withLock { await sendStop(id) } }
        return true
    }

    /// Ends the session if it was prepared and never started (`forceStop`); false if none. For the wake path: a session
    /// prepared before the Mac slept belongs to a controller that has long given up.
    @discardableResult
    func forceStopUnstarted(reason: String) -> Bool {
        let id = state.withLock { state -> UUID? in
            guard let session = state.session, session.video == nil else { return nil }
            return session.id
        }
        guard let id else { return false }
        return forceStop(id, reason: reason)
    }

    // MARK: - SetupEndpoints

    private func setupEndpointsReadBack(for hapSessionID: UUID?) -> Data {
        state.withLock { state in
            guard !state.disabled else { return CameraTLV.SetupEndpointsResponse.defaultValue }
            if let rejection = state.rejection, rejection.hapSessionID == hapSessionID { return rejection.response }
            if let session = state.session, session.hapSessionID == hapSessionID, let response = session.response { return response }
            return CameraTLV.SetupEndpointsResponse.defaultValue
        }
    }

    private func handleSetupEndpoints(_ value: HAPValue, context: HAPRequestContext) async throws(HAPStatus) {
        guard let data = value.dataValue else { throw .invalidValue }
        let request: CameraTLV.SetupEndpointsRequest
        do {
            request = try CameraTLV.SetupEndpointsRequest(parsing: data)
        } catch {
            log.warning("Stream \(index): ignoring a malformed SetupEndpoints write (\(error))")
            throw .invalidValue
        }
        let hapSession = context.session
        let done: Void? = try await lock.withLockUnlessCancelled { () async throws(HAPStatus) in
            try await setUp(request, hapSession: hapSession)
        }
        guard done != nil else {
            log.warning("Stream \(index): a stream setup timed out while it waited for an earlier operation")
            throw .operationTimedOut
        }
    }

    /// Holds `lock`.
    private func setUp(_ request: CameraTLV.SetupEndpointsRequest, hapSession: any HAPSessionHandle) async throws(HAPStatus) {
        enum Admission { case disabled, refused(CameraTLV.SetupEndpointsStatus), admitted }
        let now = ContinuousClock.now
        var superseded: (id: UUID, reason: String)?
        let admission = state.withLock { state -> Admission in
            guard !state.disabled else { return .disabled }
            if let existing = state.session, let reason = supersedeReason(existing, by: hapSession, now: now) {
                superseded = (existing.id, reason)
                existing.expiry?.cancel()
                state.session = nil
                state.selected = Self.suspendedConfiguration
            }
            let refusal: CameraTLV.SetupEndpointsStatus? = state.session != nil ? .busy : (state.available ? nil : .error)
            if let refusal {
                state.rejection = (hapSession.id, CameraTLV.SetupEndpointsResponse.failure(sessionID: request.sessionID, status: refusal))
                return .refused(refusal)
            }
            if state.rejection?.hapSessionID == hapSession.id { state.rejection = nil }
            state.session = Session(id: request.sessionID, hapSessionID: hapSession.id, controllerID: hapSession.controllerID,
                                    admittedAt: now, defaultMTU: request.isIPv6 ? 1228 : 1378)
            return .admitted
        }
        if let superseded {
            // The delegate's `.stop` follows in turn under the lock (after this setup), never twice.
            log.warning("Stream \(index): the earlier stream session \(superseded.reason); ending it so this setup is not refused as busy")
            let old = superseded.id
            Task { await lock.withLock { await sendStop(old) } }
        }
        switch admission {
        case .disabled:
            throw .notAllowedInCurrentState
        case .refused(let status):
            watch(hapSession)   // to drop its rejection read-back when it goes away
            log.info("Stream \(index): refused a stream setup (\(status == .busy ? "in use" : "camera unavailable"))")
            return
        case .admitted:
            break
        }
        syncStatus()
        watch(hapSession)

        let sessionID = request.sessionID
        var prepareRequest = PrepareStreamRequest(sessionID: sessionID, controllerAddress: request.controllerAddress, isIPv6: request.isIPv6,
                                                  controllerVideoPort: request.videoPort, controllerAudioPort: request.audioPort,
                                                  videoSRTP: request.videoSRTP, audioSRTP: request.audioSRTP, localAddress: hapSession.localAddress)
        prepareRequest.connectionZone = hapSession.zone
        prepareRequest.peerAddress = hapSession.remoteAddress
        let prepare = prepareRequest
        let response: PrepareStreamResponse
        do {
            let delegate = self.delegate
            response = try await withDeadline(delegateTimeout, followsCancellation: true, { try await delegate.prepareStream(prepare) },
                                              late: { [weak self] result in
                                                  guard case .success = result else { return }
                                                  self?.stopLatePreparation(sessionID)
                                              })
        } catch {
            refuseSetup(sessionID, hapSession: hapSession)
            log.warning("Stream \(index): preparing a stream failed: \(Self.describe(error))")
            throw Self.status(for: error)
        }
        if Task.isCancelled {
            // The HAP request timed out: the controller never sees this session, so release it again.
            await endSession(reason: "the setup request timed out") { $0.id == sessionID }
            refuseSetup(sessionID, hapSession: hapSession)
            throw .operationTimedOut
        }
        let accessoryAddress = Self.unmapped(response.accessoryAddress)
        guard Self.isIPv6Address(accessoryAddress) == request.isIPv6 else {
            // HAP-NodeJS: "ip versions must be the same". The controller asked for the other family than the delegate's
            // address (normally `localAddress`, the HAP connection's); advertising a mismatch would silently fail.
            log.warning("Stream \(index): the controller asked for an IPv\(request.isIPv6 ? 6 : 4) stream but the streaming delegate "
                        + "answered with \(response.accessoryAddress)")
            await endSession(reason: "its accessory address is of the other address family") { $0.id == sessionID }
            refuseSetup(sessionID, hapSession: hapSession)
            throw .serviceCommunicationFailure
        }
        let readBack = CameraTLV.SetupEndpointsResponse(
            sessionID: sessionID, status: .success, accessoryAddress: accessoryAddress, isIPv6: request.isIPv6,
            videoPort: response.videoPort, audioPort: response.audioPort, videoSRTP: response.videoSRTP, audioSRTP: response.audioSRTP,
            videoSSRC: response.videoSSRC, audioSSRC: response.audioSSRC).encoded
        let expiry = Task { [weak self, timeout = preparedSessionTimeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.preparedSessionExpired(sessionID)
        }
        let kept = state.withLock { state -> Bool in
            guard state.session?.id == sessionID else { return false }
            state.session?.response = readBack
            state.session?.expiry = expiry
            return true
        }
        if !kept { expiry.cancel() }
        log.info("Stream \(index): prepared a stream for \(hapSession.remoteAddress)")
    }

    /// Why a new setup from `hapSession` takes over the service from `existing`, nil if it stays busy. A session that was
    /// prepared but never started is the leftover of a controller that gave up (its retry is the new setup), so it yields to
    /// the same controller or HAP connection at once and to anyone after `staleUnstartedSessionAge`. A started session
    /// yields only to a setup on the HAP connection that owns it (its own controller restarting the stream): a different
    /// connection of the same controller may be another of that user's devices watching.
    private func supersedeReason(_ existing: Session, by hapSession: any HAPSessionHandle, now: ContinuousClock.Instant) -> String? {
        if existing.hapSessionID == hapSession.id {
            return existing.video == nil ? "was never started and its controller set up a new one"
                                         : "was still running when its controller set up a new one"
        }
        guard existing.video == nil else { return nil }
        if existing.controllerID == hapSession.controllerID { return "was never started and its controller set up a new one" }
        let age = now - existing.admittedAt
        if age > staleUnstartedSessionAge { return "was never started (prepared \(age) ago)" }
        return nil
    }

    /// Frees the service after a failed setup (no `.stop`: the session was not prepared, or was stopped already) and
    /// leaves the controller an error read-back.
    private func refuseSetup(_ sessionID: UUID, hapSession: any HAPSessionHandle) {
        state.withLock { state in
            if state.session?.id == sessionID {
                state.session?.expiry?.cancel()
                state.session = nil
            }
            state.rejection = (hapSession.id, CameraTLV.SetupEndpointsResponse.failure(sessionID: sessionID, status: .error))
        }
        syncStatus()
    }

    /// An IPv4-mapped IPv6 literal (`::ffff:a.b.c.d`) as the IPv4 address it stands for; anything else unchanged.
    static func unmapped(_ address: String) -> String {
        let prefix = "::ffff:"
        guard address.lowercased().hasPrefix(prefix) else { return address }
        let ipv4 = String(address.dropFirst(prefix.count))
        return isIPv6Address(ipv4) == false ? ipv4 : address
    }

    /// True for an IPv6 literal, false for an IPv4 one, nil for anything else (which the controller cannot use either).
    static func isIPv6Address(_ address: String) -> Bool? {
        if address.contains(":") { return true }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return false
    }

    /// One close handler per HAP connection (HAP-NodeJS registers one per session and removes it again); it ends
    /// whichever session that connection owns when it closes.
    private func watch(_ hapSession: any HAPSessionHandle) {
        let hapSessionID = hapSession.id
        guard state.withLock({ $0.watchedHAPSessions.insert(hapSessionID).inserted }) else { return }
        hapSession.onClose { [weak self] in
            guard let self else { return }
            Task { await self.hapSessionClosed(hapSessionID) }
        }
    }

    private func hapSessionClosed(_ hapSessionID: UUID) async {
        await lock.withLock {
            await endSession(reason: "its HAP connection closed") { $0.hapSessionID == hapSessionID }
            state.withLock { state in
                state.watchedHAPSessions.remove(hapSessionID)
                if state.rejection?.hapSessionID == hapSessionID { state.rejection = nil }
            }
        }
    }

    /// No Start came `preparedSessionTimeout` after the session was prepared: the controller gave up or its connection died
    /// between the two writes. The service is freed (and reports available) and the delegate gets its `.stop`.
    private func preparedSessionExpired(_ sessionID: UUID) {
        let unstarted = state.withLock { $0.session?.id == sessionID && $0.session?.video == nil }
        guard unstarted else { return }
        log.warning("Stream \(index): no Start came within \(preparedSessionTimeout) of preparing the stream; ending it so the camera "
                    + "is not left in use")
        forceStop(sessionID, reason: "no Start within \(preparedSessionTimeout)")
    }

    /// A `prepareStream` that returned only after its setup was abandoned: the session is already gone, so the delegate
    /// just gets its `.stop` (in turn, under the lock).
    private func stopLatePreparation(_ sessionID: UUID) {
        log.warning("Stream \(index): a stream preparation finished after its setup was abandoned; stopping it")
        Task {
            await lock.withLock { await sendStop(sessionID) }
        }
    }

    // MARK: - SelectedRTPStreamConfiguration

    private func handleSelectedConfiguration(_ value: HAPValue) async throws(HAPStatus) {
        guard let data = value.dataValue else { throw .invalidValue }
        let done: Void? = try await lock.withLockUnlessCancelled { () async throws(HAPStatus) in
            try await command(data)
        }
        guard done != nil else {
            log.warning("Stream \(index): a stream command timed out while it waited for an earlier operation")
            throw .operationTimedOut
        }
    }

    /// Holds `lock`.
    private func command(_ data: Data) async throws(HAPStatus) {
        let (disabled, current) = state.withLock { ($0.disabled, $0.session) }
        guard !disabled else { throw .notAllowedInCurrentState }
        let configuration: CameraTLV.SelectedRTPStreamConfiguration
        do {
            configuration = try CameraTLV.SelectedRTPStreamConfiguration(parsing: data, defaultMTU: current?.defaultMTU ?? 1378, base: current?.video)
        } catch {
            log.warning("Stream \(index): ignoring a malformed SelectedRTPStreamConfiguration write (\(error))")
            throw .invalidValue
        }
        guard let session = current, session.id == configuration.sessionID, session.response != nil else {
            if configuration.command == .end {
                // The controller ending a session that is gone already (the accessory ended it first, or both did at once):
                // nothing is left to end, and an error here is only noise for the controller.
                log.debug("Stream \(index): the controller ended a stream session that had ended already")
                return
            }
            log.warning("Stream \(index): \(configuration.command) for an unknown stream session")
            throw .invalidValue
        }
        switch configuration.command {
        case .start:
            guard session.video == nil, let video = configuration.video else { throw .invalidValue }
            do {
                try await callDelegate(.start(sessionID: session.id, video: video, audio: configuration.audio))
            } catch {
                log.warning("Stream \(index): starting the stream failed: \(Self.describe(error))")
                await endSession(reason: "starting it failed") { $0.id == session.id }
                throw Self.status(for: error)
            }
            record(video, selected: data, for: session.id)
            log.info("Stream \(index): streaming \(video.resolution.width)×\(video.resolution.height)@\(video.resolution.fps) "
                     + "\(video.maxBitrateKbps) kbps")
        case .reconfigure:
            guard session.video != nil, let video = configuration.video else { throw .invalidValue }
            do {
                try await callDelegate(.reconfigure(sessionID: session.id, video: video))
            } catch {
                log.warning("Stream \(index): reconfiguring the stream failed: \(Self.describe(error))")
                await endSession(reason: "reconfiguring it failed") { $0.id == session.id }
                throw Self.status(for: error)
            }
            record(video, selected: data, for: session.id)
        case .end:
            // Free the service now; the delegate's `.stop` (which may wait for a pipeline to wind down) follows in turn, so the
            // controller's End is not held up by it (an End behind a slow Start used to outlast HAP's 9 s).
            forceStop(session.id, reason: "the controller ended it")
        case .suspend, .resume:
            throw .invalidValue
        }
    }

    private func record(_ video: SelectedVideoParameters, selected: Data, for id: UUID) {
        state.withLock { state in
            guard state.session?.id == id else { return }
            state.session?.expiry?.cancel()
            state.session?.expiry = nil
            state.session?.video = video
            state.selected = selected
        }
    }

    // MARK: - Teardown

    /// Holds `lock`. Ends the session if `matches` it and sends `.stop`.
    private func endSession(reason: String, where matches: (Session) -> Bool) async {
        let ended = state.withLock { state -> UUID? in
            guard let session = state.session, matches(session) else { return nil }
            session.expiry?.cancel()
            state.session = nil
            state.selected = Self.suspendedConfiguration
            return session.id
        }
        guard let ended else { return }
        syncStatus()
        log.info("Stream \(index): stream ended (\(reason))")
        await sendStop(ended)
    }

    /// Holds `lock`. Runs to its deadline even when the caller was cancelled (teardown must happen).
    private func sendStop(_ sessionID: UUID) async {
        let delegate = self.delegate
        do {
            try await withDeadline(delegateTimeout, followsCancellation: false) { try await delegate.handleStreamRequest(.stop(sessionID: sessionID)) }
        } catch {
            log.warning("Stream \(index): the streaming delegate failed to stop a stream: \(Self.describe(error))")
        }
    }

    /// Start / reconfigure under the deadline; a HAP request that times out meanwhile abandons it too.
    private func callDelegate(_ request: StreamRequest) async throws {
        let delegate = self.delegate
        try await withDeadline(delegateTimeout, followsCancellation: true) { try await delegate.handleStreamRequest(request) }
    }

    private func syncStatus() {
        service.characteristic(.streamingStatus).mirror { .data(CameraTLV.streamingStatus(self.state.withLock { $0.status })) }
    }

    /// Delegate errors that are `HAPStatus` pass through; a missed deadline (`DeadlineExceeded`) or timed-out request
    /// (`withDeadline` throws `CancellationError` once the HAP request's task is cancelled) is -70408; others -70402.
    private static func status(for error: any Error) -> HAPStatus {
        if let status = error as? HAPStatus { return status }
        if error is DeadlineExceeded || error is CancellationError { return .operationTimedOut }
        return .serviceCommunicationFailure
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case is DeadlineExceeded: "the streaming delegate did not answer in time"
        case is CancellationError: "the HAP request timed out"
        default: String(describing: error)
        }
    }
}
