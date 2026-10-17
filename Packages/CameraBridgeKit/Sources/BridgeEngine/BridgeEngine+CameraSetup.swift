import BridgeSupport
import CameraAdapters
import Foundation

// "Set up for Camera Bridge" (docs/superpowers/specs/2026-10-16-camera-setup-design.md, stages 1 and 2): one place per camera that makes it
// right for the bridge. Every step is read first (its value then is the backup), shown as a preview, applied in a safe order and read
// back; "Restore original settings" writes every saved value back. The steps themselves are CameraAdapters' (`CameraSettingsService`
// +Setup, +NTP, +DNS, +Network, +Encoder, +CleanPicture); the plan for the streams is the HomeKit optimizer's (`plannedEncoderFixes`);
// "Watch its internet" is offered where the bridge has Camera Bridge OS's internet guard (BridgeEngine+InternetGuard.swift).

/// Where a step stands: in a preview (`willChange`, `alreadyRight`, `notSupported`, `notOffered`), after a run (`done`, `refused`, `notRun`),
/// or after a restore (`restored`, `refused`).
public enum CameraSetupStepStatus: String, Sendable, Codable {
    case willChange, alreadyRight, notSupported, notOffered, done, refused, notRun, restored
}

/// One step as the page shows it.
public struct CameraSetupStep: Sendable, Codable, Equatable {
    public var id: CameraSetupStepID
    public var title: String
    public var status: CameraSetupStepStatus
    /// What changes (now → after); empty when nothing does.
    public var changes: [CameraSetupChange]
    /// Why not, the camera's words, or how it was done ("via ISAPI").
    public var detail: String?
    /// The camera took the change and applies it when it restarts (it is not restarted by the bridge).
    public var needsRestart: Bool

    public init(id: CameraSetupStepID, title: String, status: CameraSetupStepStatus, changes: [CameraSetupChange] = [], detail: String? = nil,
                needsRestart: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.changes = changes
        self.detail = detail
        self.needsRestart = needsRestart
    }
}

/// The setup's record in a camera's configuration: which version of the setup ran, when, and what each step did. A step this build does
/// not know (a record written by a newer one) is left out when it is read, and the rest of the record is kept.
public struct CameraSetupState: Sendable, Codable, Equatable {
    /// The setup's contents are versioned in code: a camera says which setup it has ("Set up for Camera Bridge (1)").
    public static let currentVersion = 1

    public struct Record: Sendable, Codable, Equatable {
        public var id: CameraSetupStepID
        public var status: CameraSetupStepStatus
        public var detail: String?
        public var needsRestart: Bool

        public init(id: CameraSetupStepID, status: CameraSetupStepStatus, detail: String? = nil, needsRestart: Bool = false) {
            self.id = id
            self.status = status
            self.detail = detail
            self.needsRestart = needsRestart
        }
    }

    public var version: Int
    public var started: Date
    /// When the last run ended; nil while one runs (or when the bridge stopped during it: the page offers to finish or restore).
    public var applied: Date?
    public var steps: [Record]

    public init(version: Int = CameraSetupState.currentVersion, started: Date, applied: Date? = nil, steps: [Record] = []) {
        self.version = version
        self.started = started
        self.applied = applied
        self.steps = steps
    }

    /// The run ended (it may have stopped at a step the camera refused).
    public var isFinished: Bool { applied != nil }

    private enum CodingKeys: String, CodingKey { case version, started, applied, steps }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        started = try container.decode(Date.self, forKey: .started)
        applied = try container.decodeIfPresent(Date.self, forKey: .applied)
        steps = try container.decodeIfPresent([Lenient].self, forKey: .steps)?.compactMap(\.record) ?? []
    }

    /// One record, or nil for a step or status this build does not know.
    private struct Lenient: Decodable {
        var record: Record?
        init(from decoder: any Decoder) throws { record = try? Record(from: decoder) }
    }

    /// The step's last record now says `status` (its value was put back).
    mutating func mark(_ id: CameraSetupStepID, _ status: CameraSetupStepStatus) {
        guard let index = steps.lastIndex(where: { $0.id == id }) else { return }
        steps[index].status = status
    }
}

/// What `cameraSetupPreview`, `applyCameraSetup` and `restoreCameraSetup` answer.
public struct CameraSetupReport: Sendable, Codable, Equatable {
    public var steps: [CameraSetupStep]
    public var state: CameraSetupState?
    /// Saved values exist: "Restore original settings" can run.
    public var canRestore: Bool
    /// The step the run stopped at (the camera refused it); the steps before it stay done.
    public var stoppedAt: CameraSetupStepID?
    /// The bridge restarted the camera's stream (its encoder changed): recording has a short gap.
    public var streamRestarted: Bool
    /// A resolution or codec changed: Home recording may need to be turned off and on again for this camera.
    public var mayNeedRecordingReEnabled: Bool

    public init(steps: [CameraSetupStep], state: CameraSetupState?, canRestore: Bool, stoppedAt: CameraSetupStepID? = nil, streamRestarted: Bool = false,
                mayNeedRecordingReEnabled: Bool = false) {
        self.steps = steps
        self.state = state
        self.canRestore = canRestore
        self.stoppedAt = stoppedAt
        self.streamRestarted = streamRestarted
        self.mayNeedRecordingReEnabled = mayNeedRecordingReEnabled
    }
}

/// What reading the camera found, for every step: the readings, the values to keep before changing anything, and the streams' plan.
struct CameraSetupRead {
    var readings: [CameraSetupStepID: CameraSetupReading] = [:]
    /// The camera's values now, for the steps that will change.
    var fresh = CameraSetupBackup(version: CameraSetupState.currentVersion, created: Date())
    var posix: String?
    var timeServer: String?
    /// The bridge's address on the camera's network, for "Watch its internet".
    var guardServer: String?
    var planned: [PlannedEncoderFix] = []
    var mainSmartCodecOn = false
    var subSmartCodecOn = false
    /// The streams step's note without the "it sends H.265" sentence (which only describes the camera before the change).
    var streamsNote: String?
}

extension BridgeEngine {
    /// The cameras the setup works with: those the bridge reaches directly through their own API or ONVIF.
    public static let cameraSetupVendors: Set<CameraVendor> = [.hikvision, .onvif, .reolink, .amcrest]

    /// The step names (one table, so they can be renamed in one place).
    public nonisolated static func cameraSetupTitle(_ step: CameraSetupStepID) -> String {
        switch step {
        case .timeZone: "Time zone"
        case .timeSource: "Time from the bridge"
        case .internetWatch: InternetGuardText.watchStep
        case .cleanPicture: "Clean picture"
        case .streams: "Streams for recording, Apple Home and live view"
        case .videoPassword: "Video password"
        case .extraServices: "Extra services off"
        case .upnp: "UPnP off"
        // Hikvision's Hik-Connect, or the cloud of a camera that speaks the IP camera web API: the change row names the service where known.
        case .cloud: "Cloud off"
        }
    }

    /// Reads the camera and shows what the setup would change. Changes nothing. Throws `EngineError.unknownCamera`, `EngineError.invalidSettings`
    /// for a camera the setup does not work with, `CameraOfflineError` for an unreachable camera, and the camera's login refusal.
    public func cameraSetupPreview(cameraID: UUID) async throws -> CameraSetupReport {
        let (camera, service) = try await cameraSetupService(cameraID)
        let read = try await readCameraSetup(camera, service: service)
        let steps = CameraSetupStepID.allCases.map { Self.previewStep($0, read.readings[$0]) }
        return CameraSetupReport(steps: steps, state: camera.setupState, canRestore: camera.setupBackup.map { !$0.isEmpty } ?? false)
    }

    /// Applies the setup: reads every step again, saves the values it will change (an existing setup, Optimize or Clean picture backup is
    /// folded in: the oldest value wins), then applies the steps in order, each read back. A step the camera refuses stops the run; the
    /// steps before it stay done and `restoreCameraSetup` undoes them. Running it again changes nothing that is already right.
    public func applyCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        return try await operations.withLock {
            let (camera, service) = try await cameraSetupService(cameraID)
            let read = try await readCameraSetup(camera, service: service)
            var backup = Self.mergedSetupBackup(existing: camera.setupBackup, fresh: read.fresh, readings: read.readings,
                                                cleanPicture: camera.cleanPictureBackup, optimization: homeKitOptimizationSnapshots[cameraID])
            if let code = backup.cloud?.cloudAuthcode {
                await keepSetupCloudAuthcode(code, camera: camera)
                backup.cloud?.cloudAuthcode = nil
            }
            var state = CameraSetupState(started: Date())
            // The backup is saved before the first change.
            await changeConfiguration(cameraID) { configuration in
                configuration.setupBackup = backup.isEmpty ? nil : backup
                configuration.setupState = state
                configuration.cleanPictureBackup = nil   // now in the setup's backup: one way back
            }
            homeKitOptimizationSnapshots[cameraID] = nil

            var steps: [CameraSetupStep] = []
            var stoppedAt: CameraSetupStepID?
            var streamChanged = false
            var codecChanged = false
            for id in CameraSetupStepID.allCases {
                let preview = Self.previewStep(id, read.readings[id])
                var step = preview
                if stoppedAt != nil, preview.status == .willChange {
                    step.status = .notRun
                } else if preview.status == .willChange {
                    let outcome = await applyStep(id, read: read, service: service, backup: &backup, camera: camera)
                    step.status = outcome.succeeded ? .done : .refused
                    // A note about a part not offered stays; the streams step's "it sends H.265" sentence goes once it is changed.
                    step.detail = outcome.succeeded ? ((id == .streams ? read.streamsNote : preview.detail) ?? outcome.detail) : outcome.detail
                    step.needsRestart = outcome.needsRestart
                    if outcome.succeeded, id == .streams {
                        streamChanged = true
                        codecChanged = read.planned.contains { $0.fixes.contains("codec") }
                    }
                    if !outcome.succeeded { stoppedAt = id }
                    log.info("\(camera.name): camera setup, \(Self.cameraSetupTitle(id).lowercased()): \(outcome.succeeded ? "done" : "refused") (\(outcome.detail))")
                }
                steps.append(step)
                state.steps.append(.init(id: id, status: step.status, detail: step.detail, needsRestart: step.needsRestart))
                let saved = backup, record = state
                await changeConfiguration(cameraID) { configuration in
                    configuration.setupBackup = saved.isEmpty ? nil : saved
                    configuration.setupState = record
                }
            }
            state.applied = Date()
            let finished = state, saved = backup
            await changeConfiguration(cameraID) { configuration in
                configuration.setupState = finished
                configuration.setupBackup = saved.isEmpty ? nil : saved
            }
            await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
            var record = finished
            if streamChanged {
                await restartAfterCameraSetup(camera)
                // The camera's own read-back can say H.264 while it still sends H.265: check what the restarted ingest receives.
                let check = await streamsCheckAfterSetup(cameraID, planned: read.planned)
                if codecChanged, let main = check.main, !Self.isH264(main) { codecChanged = false }   // the recordings' codec did not change
                if let problem = check.problem {
                    log.warning("\(camera.name): camera setup, streams: \(problem)")
                    if let index = steps.firstIndex(where: { $0.id == .streams }) {
                        steps[index].status = .refused
                        steps[index].detail = problem
                    }
                    if let index = record.steps.firstIndex(where: { $0.id == .streams }) {
                        record.steps[index].status = .refused
                        record.steps[index].detail = problem
                    }
                    let checked = record
                    await changeConfiguration(cameraID) { $0.setupState = checked }
                }
            }
            scheduleSecurityCheck(cameraID, after: .zero, skipIfFresh: false)   // what the camera now lets out
            return CameraSetupReport(steps: steps, state: record, canRestore: !saved.isEmpty, stoppedAt: stoppedAt, streamRestarted: streamChanged,
                                     mayNeedRecordingReEnabled: codecChanged)
        }
    }

    /// Writes back every value the setup saved, newest change first, each read back; a value the camera takes back leaves the backup, so a
    /// failed restore can be tried again. When everything is back the setup's record is cleared.
    public func restoreCameraSetup(cameraID: UUID) async throws -> CameraSetupReport {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        return try await operations.withLock {
            let (camera, service) = try await cameraSetupService(cameraID)
            guard var backup = camera.setupBackup, !backup.isEmpty else {
                throw EngineError.invalidSettings("this camera has no saved settings to put back")
            }
            var steps: [CameraSetupStep] = []
            var streamChanged = false
            for id in CameraSetupStepID.allCases.reversed() where backup.holds(id) {
                let outcome = await restoreStep(id, backup: backup, service: service, camera: camera)
                if outcome.succeeded {
                    backup = backup.clearing(id)
                    if id == .streams { streamChanged = true }
                    let saved = backup
                    await changeConfiguration(cameraID) { configuration in
                        configuration.setupBackup = saved.isEmpty ? nil : saved
                        // The camera asks its own DNS servers again: its Watch is over (the guard's list follows the save).
                        if id == .internetWatch { configuration.setupState?.mark(.internetWatch, .restored) }
                    }
                }
                log.info("\(camera.name): camera setup, \(Self.cameraSetupTitle(id).lowercased()) \(outcome.succeeded ? "restored" : "not restored") (\(outcome.detail))")
                steps.append(CameraSetupStep(id: id, title: Self.cameraSetupTitle(id), status: outcome.succeeded ? .restored : .refused, detail: outcome.detail,
                                             needsRestart: outcome.needsRestart))
            }
            let cleared = backup.isEmpty
            if cleared { await changeConfiguration(cameraID) { $0.setupBackup = nil; $0.setupState = nil } }
            await rememberConfigMethod(cameraID: cameraID, service.memoryUpdate)
            if streamChanged { await restartAfterCameraSetup(camera) }
            scheduleSecurityCheck(cameraID, after: .zero, skipIfFresh: false)
            let state = configurations.first { $0.id == cameraID }?.setupState
            return CameraSetupReport(steps: Array(steps.reversed()), state: state, canRestore: !cleared, streamRestarted: streamChanged)
        }
    }

    // MARK: Reading

    private func cameraSetupService(_ cameraID: UUID) async throws -> (CameraConfiguration, CameraSettingsService) {
        guard !isPreview else { throw EngineError.cameraNotRunning }
        guard let camera = configurations.first(where: { $0.id == cameraID }) else { throw EngineError.unknownCamera }
        guard Self.cameraSetupVendors.contains(camera.vendor) else {
            throw EngineError.invalidSettings("Set up for Camera Bridge works with Hikvision, Reolink, Amcrest and ONVIF cameras the bridge reaches directly")
        }
        if runtimes[cameraID]?.isUnreachable == true { throw CameraOfflineError() }
        let credentials = credentials
        let secrets = try await Self.offMain { try credentials.credentials(for: camera) }
        return (camera, Self.encoderService(camera, secrets, profiles: cameraProfiles))
    }

    /// Runs one step's read: a login refusal (or cancellation) ends the whole setup, anything else marks the step as not possible now.
    private func readStep<T>(_ work: () async throws -> T, unreadable: (String) -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch {
            return unreadable("the camera did not answer: \(Self.readableReason(error))")
        }
    }

    func readCameraSetup(_ camera: CameraConfiguration, service: CameraSettingsService) async throws -> CameraSetupRead {
        var read = CameraSetupRead()

        // Time zone: the bridge's.
        let identifier = settings.timeZone ?? TimeZone.current.identifier
        if let posix = PosixTimeZone.string(for: identifier) {
            read.posix = posix
            let (reading, value) = try await readStep({ try await service.readTimeZone(posix: posix, zoneName: identifier) },
                                                      unreadable: { (CameraSetupReading.notSupported($0), nil) })
            read.readings[.timeZone] = reading
            read.fresh.timeZone = value
        } else {
            read.readings[.timeZone] = .init(state: .notSupported("this system has no description of the time zone \(identifier)"))
        }

        // Time from the bridge: only where the bridge serves time (Camera Bridge OS), at its address on the camera's network.
        if environment.servesTime, let server = Self.timeServerAddress(cameraHost: camera.endpoint.host, interfaces: tuning.interfaceAddresses?() ?? StreamAddress.interfaceAddresses()) {
            read.timeServer = server
            let (reading, value) = try await readStep({ try await service.readTimeSource(server: server) },
                                                      unreadable: { (CameraSetupReading.notSupported($0), nil) })
            read.readings[.timeSource] = reading
            read.fresh.timeSource = value
        }

        // Watch its internet: only where the bridge has the internet guard (Camera Bridge OS), at its address on the camera's network.
        if !offersInternetGuard {
            read.readings[.internetWatch] = .notOffered(InternetGuardText.notOnThisBridge)
        } else if let server = internetWatchServer(camera) {
            read.guardServer = server
            let (reading, value) = try await readStep({ try await service.readInternetWatch(server: server) },
                                                      unreadable: { (CameraSetupReading.notSupported($0), nil) })
            read.readings[.internetWatch] = reading
            read.fresh.internetWatch = value
        } else {
            read.readings[.internetWatch] = .notOffered(InternetGuardText.notOnItsNetwork)
        }

        // Clean picture: already done by the Clean picture switch when it has a backup.
        if camera.cleanPictureBackup != nil || camera.setupBackup?.cleanPicture != nil {
            read.readings[.cleanPicture] = CameraSetupReading(state: .alreadyRight)
        } else {
            read.readings[.cleanPicture] = try await readStep({ try await service.readCleanPicture() }, unreadable: { CameraSetupReading.notSupported($0) })
        }

        // Streams: the HomeKit optimizer's plan.
        let streams = try await readStep({ try await readStreams(camera, service: service) },
                                         unreadable: { StreamsRead(reading: CameraSetupReading.notSupported($0)) })
        read.readings[.streams] = streams.reading
        read.streamsNote = streams.streamsNote
        read.planned = streams.planned
        read.mainSmartCodecOn = streams.mainSmartCodecOn
        read.subSmartCodecOn = streams.subSmartCodecOn
        read.fresh.streams = streams.backup

        // The IPCamera Web family's video password and extra services (not offered on other cameras).
        let (password, passwordBackup) = try await readStep({ try await service.readVideoPassword() }, unreadable: { (CameraSetupReading.notSupported($0), nil) })
        read.readings[.videoPassword] = password
        read.fresh.videoPassword = passwordBackup
        let (services, servicesBackup) = try await readStep({ try await service.readExtraServices() }, unreadable: { (CameraSetupReading.notSupported($0), nil) })
        read.readings[.extraServices] = services
        read.fresh.extraServices = servicesBackup

        // UPnP and the maker's cloud (Hikvision's own settings, the cloud of the cameras with a web API of their own).
        for (id, feature) in [(CameraSetupStepID.upnp, CameraNetworkFeature.upnp), (.cloud, .cloud)] {
            let (reading, value) = try await readStep({ try await service.readFeature(feature) }, unreadable: { (CameraSetupReading.notSupported($0), nil) })
            read.readings[id] = reading
            if id == .upnp { read.fresh.upnp = value } else { read.fresh.cloud = value }
        }
        return read
    }

    struct StreamsRead {
        var reading: CameraSetupReading
        var streamsNote: String?
        var planned: [PlannedEncoderFix] = []
        var mainSmartCodecOn = false
        var subSmartCodecOn = false
        var backup: CameraStreamsBackup?
    }

    private func readStreams(_ camera: CameraConfiguration, service: CameraSettingsService) async throws -> StreamsRead {
        let snapshot = try? await service.fetchSnapshot()
        var main = snapshot?.mainProfile?.settings
        var sub = snapshot?.subProfile?.settings
        var result = StreamsRead(reading: CameraSetupReading(state: .alreadyRight))
        var changes: [CameraSetupChange] = []
        var streams = CameraStreamsBackup()
        if camera.vendor == .hikvision {
            if main == nil { main = try? await service.hikvisionEncoderSettings(isSub: false) }
            if sub == nil { sub = try? await service.hikvisionEncoderSettings(isSub: true) }
            let mainChannel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false)
            let subChannel = CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: true)
            result.mainSmartCodecOn = (try? await service.hikvisionSmartCodecEnabled(channelID: mainChannel)) == true
            result.subSmartCodecOn = (try? await service.hikvisionSmartCodecEnabled(channelID: subChannel)) == true
            if result.mainSmartCodecOn || result.subSmartCodecOn {
                streams.mainSmartCodec = result.mainSmartCodecOn ? true : nil
                streams.subSmartCodec = result.subSmartCodecOn ? true : nil
                changes.append(.init(label: "Smart codec (H.264+ or H.265+)", now: "on", after: "off"))
            }
        }
        // Only H.264/H.265 streams: never a JPEG/MJPEG encoder (the ONVIF profiles are already chosen that way; ISAPI's may be MJPEG).
        if let value = main, !CameraSettingsService.isStreamCodec(value.encoding) { main = nil }
        if let value = sub, !CameraSettingsService.isStreamCodec(value.encoding) { sub = nil }
        guard main != nil || sub != nil else {
            return StreamsRead(reading: .notSupported("the camera has no H.264 or H.265 stream whose settings it shows"))
        }
        let note = main == nil ? "Main stream: not offered, the camera has no H.264 or H.265 main stream whose settings it shows."
            : sub == nil ? "Sub stream: not offered, the camera has no H.264 or H.265 sub stream whose settings it shows." : nil
        // The codecs the bridge really receives: a camera's settings can name H.264 while it sends H.265 (a Jennov's ONVIF did).
        // A measurement counts only for the stream it is of: the same picture size (a camera whose stream addresses differ only in their
        // query, as Dahua's do, can have its profiles matched to the wrong stream).
        let facts = await measuredStreamFacts(camera.id)
        let mainMeasured = Self.sameSize(main, facts?.main) ? facts?.main?.codec : nil
        let subMeasured = Self.sameSize(sub, facts?.sub) ? facts?.sub?.codec : nil
        result.planned = Self.plannedEncoderFixes(main: main, mainProfile: snapshot?.mainProfile, sub: sub, subProfile: snapshot?.subProfile,
                                                  mainHasBFrames: facts?.main?.hasBFrames == true,
                                                  mainMeasuredCodec: mainMeasured, subMeasuredCodec: subMeasured)
        var notes = note.map { [$0] } ?? []
        result.streamsNote = note
        for plan in result.planned {
            let name = plan.isSub ? "sub" : "main"
            var shown = plan.before
            if let real = Self.measuredCodecMismatch(reported: plan.before.encoding, measured: plan.isSub ? subMeasured : mainMeasured) {
                shown.encoding = real
                notes.append("The camera says its \(name) stream is \(Self.codecDisplayName(plan.before.encoding)), but it sends \(real).")
            }
            changes.append(.init(label: plan.isSub ? "Sub stream" : "Main stream", now: CameraSetupText.encoder(shown),
                                 after: CameraSetupText.encoder(plan.edit.desired)))
            if plan.isSub { streams.subEncoder = plan.before; streams.subOptions = plan.options } else { streams.mainEncoder = plan.before; streams.mainOptions = plan.options }
        }
        result.backup = streams.isEmpty ? nil : streams
        let noted = notes.isEmpty ? nil : notes.joined(separator: " ")
        result.reading = changes.isEmpty ? CameraSetupReading(state: .alreadyRight, note: noted)
            : CameraSetupReading(state: .willChange, changes: changes, note: noted)
        return result
    }

    /// What the camera's ingest measures of its streams now (`CameraRuntime.readinessFacts`); nil without an ingest.
    private func measuredStreamFacts(_ cameraID: UUID) async -> (main: MeasuredStreamFacts?, sub: MeasuredStreamFacts?)? {
        if let measured = tuning.measuredStreamFacts { return await measured(cameraID) }
        return await runtimes[cameraID]?.readinessFacts()
    }

    /// Whether a measurement is of this stream: the same picture size, give or take a few lines (1080 against 1088), or either unknown.
    nonisolated static func sameSize(_ settings: CameraVideoEncoderSettings?, _ measured: MeasuredStreamFacts?) -> Bool {
        guard let size = settings?.resolution, let width = measured?.width, let height = measured?.height else { return true }
        return abs(size.width - width) <= 16 && abs(size.height - height) <= 16
    }

    /// After the setup changed a stream's codec and restarted the camera's ingest: watches the new ingest (up to
    /// `EngineTuning.cameraSetupMeasureWait`, ending early once every changed stream arrives as H.264, since a camera can take a few
    /// seconds to switch) and says when one still arrives as something else (`streamsStillWrong`). Streams whose codec the setup did not
    /// change are not waited for. `problem` is nil when it is right or nothing was measured in time (a camera that sends nothing until
    /// asked is not a failure); `main` is the main stream's measured codec, nil when not measured.
    func streamsCheckAfterSetup(_ cameraID: UUID, planned: [PlannedEncoderFix]) async -> (problem: String?, main: String?) {
        let changed = planned.filter { Self.isH264($0.edit.desired.encoding) && (!Self.isH264($0.before.encoding) || $0.edit.rewriteCodec) }
        let wantsMain = changed.contains { !$0.isSub }, wantsSub = changed.contains { $0.isSub }
        // Nothing to wait for without an ingest (the camera is off or not started in this bridge).
        guard wantsMain || wantsSub, runtimes[cameraID] != nil || tuning.measuredStreamFacts != nil else { return (nil, nil) }
        let clock = ContinuousClock(), deadline = clock.now + tuning.cameraSetupMeasureWait
        var facts: (main: MeasuredStreamFacts?, sub: MeasuredStreamFacts?) = (nil, nil)
        while true {
            facts = await measuredStreamFacts(cameraID) ?? (nil, nil)
            let right = (!wantsMain || facts.main?.codec.map(Self.isH264) == true) && (!wantsSub || facts.sub?.codec.map(Self.isH264) == true)
            if right || clock.now >= deadline || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let problem = Self.streamsStillWrong(planned: changed, measuredMain: wantsMain ? facts.main?.codec : nil, measuredSub: wantsSub ? facts.sub?.codec : nil)
        return (problem, facts.main?.codec)
    }

    static func previewStep(_ id: CameraSetupStepID, _ reading: CameraSetupReading?) -> CameraSetupStep {
        let title = cameraSetupTitle(id)
        guard let reading else {
            let why = id == .timeSource ? "Camera Bridge OS serves time to cameras; this bridge does not." : "not supported by this camera"
            return CameraSetupStep(id: id, title: title, status: .notOffered, detail: why)
        }
        switch reading.state {
        case .willChange: return CameraSetupStep(id: id, title: title, status: .willChange, changes: reading.changes, detail: reading.note)
        case .alreadyRight: return CameraSetupStep(id: id, title: title, status: .alreadyRight, detail: reading.note)
        case .notSupported(let why): return CameraSetupStep(id: id, title: title, status: .notSupported, detail: why)
        case .notOffered(let why): return CameraSetupStep(id: id, title: title, status: .notOffered, detail: why)
        }
    }

    // MARK: The backup

    /// One backup: what an earlier run saved stays (it is the camera's original value); a Clean picture or Optimize backup is folded in;
    /// the values read now fill the steps that will change and have none yet.
    static func mergedSetupBackup(existing: CameraSetupBackup?, fresh: CameraSetupBackup, readings: [CameraSetupStepID: CameraSetupReading],
                                  cleanPicture: CleanPictureBackup?, optimization: HomeKitOptimizationSnapshot?) -> CameraSetupBackup {
        var backup = existing ?? CameraSetupBackup(version: CameraSetupState.currentVersion, created: fresh.created)
        func changing(_ id: CameraSetupStepID) -> Bool { readings[id]?.state == .willChange }
        if backup.timeZone == nil, changing(.timeZone) { backup.timeZone = fresh.timeZone }
        if backup.timeSource == nil, changing(.timeSource) { backup.timeSource = fresh.timeSource }
        if backup.internetWatch == nil, changing(.internetWatch) { backup.internetWatch = fresh.internetWatch }
        if backup.cleanPicture == nil { backup.cleanPicture = cleanPicture }
        if backup.upnp == nil, changing(.upnp) { backup.upnp = fresh.upnp }
        if backup.cloud == nil, changing(.cloud) { backup.cloud = fresh.cloud }
        if backup.videoPassword == nil, changing(.videoPassword) { backup.videoPassword = fresh.videoPassword }
        if backup.extraServices == nil, changing(.extraServices) { backup.extraServices = fresh.extraServices }
        // Streams: the oldest value of each field wins (an earlier run's, then Optimize's undo, then the values now).
        var streams = backup.streams ?? CameraStreamsBackup()
        if let optimization {
            if streams.mainEncoder == nil, let main = optimization.mainEncoder { streams.mainEncoder = main; streams.mainOptions = optimization.mainOptions }
            if streams.subEncoder == nil, let sub = optimization.subEncoder { streams.subEncoder = sub; streams.subOptions = optimization.subOptions }
            if streams.mainSmartCodec == nil { streams.mainSmartCodec = optimization.hikvisionMainSmartCodec }
            if streams.subSmartCodec == nil { streams.subSmartCodec = optimization.hikvisionSubSmartCodec }
        }
        if changing(.streams), let now = fresh.streams {
            if streams.mainEncoder == nil, let main = now.mainEncoder { streams.mainEncoder = main; streams.mainOptions = now.mainOptions }
            if streams.subEncoder == nil, let sub = now.subEncoder { streams.subEncoder = sub; streams.subOptions = now.subOptions }
            if streams.mainSmartCodec == nil { streams.mainSmartCodec = now.mainSmartCodec }
            if streams.subSmartCodec == nil { streams.subSmartCodec = now.subSmartCodec }
        }
        backup.streams = streams.isEmpty ? nil : streams
        return backup
    }

    // MARK: Applying and restoring

    private func applyStep(_ id: CameraSetupStepID, read: CameraSetupRead, service: CameraSettingsService, backup: inout CameraSetupBackup,
                           camera: CameraConfiguration) async -> CameraSetupOutcome {
        do {
            switch id {
            case .timeZone:
                guard let posix = read.posix else { return CameraSetupOutcome(succeeded: false, detail: "no time zone") }
                return try await service.applyTimeZone(posix: posix)
            case .timeSource:
                guard let server = read.timeServer else { return CameraSetupOutcome(succeeded: false, detail: "no address for the bridge") }
                return try await service.applyTimeSource(server: server)
            case .internetWatch:
                guard let server = read.guardServer else { return CameraSetupOutcome(succeeded: false, detail: "no address for the bridge") }
                return try await service.applyDNS(server: server)
            case .cleanPicture:
                let change = try await service.cleanPicture()
                if change.succeeded, backup.cleanPicture == nil { backup.cleanPicture = change.backup }
                return CameraSetupOutcome(succeeded: change.succeeded, detail: change.summary)
            case .streams:
                return try await applyStreams(read, service: service, camera: camera)
            case .videoPassword:
                return try await service.requireVideoPassword()
            case .extraServices:
                return try await service.turnOffExtraServices()
            case .upnp:
                return try await service.setFeature(.upnp, enabled: false, path: backup.upnp?.path)
            case .cloud:
                return try await service.setFeature(.cloud, enabled: false, path: backup.cloud?.path)
            }
        } catch {
            return CameraSetupOutcome(succeeded: false, detail: Self.setupReason(error))
        }
    }

    private func applyStreams(_ read: CameraSetupRead, service: CameraSettingsService, camera: CameraConfiguration) async throws -> CameraSetupOutcome {
        if read.mainSmartCodecOn {
            try await service.setHikvisionSmartCodec(enabled: false, channelID: CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false))
        }
        if read.subSmartCodecOn {
            try await service.setHikvisionSmartCodec(enabled: false, channelID: CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: true))
        }
        guard !read.planned.isEmpty else { return CameraSetupOutcome(succeeded: true, detail: "via ISAPI") }
        let results = try await service.applyEncoder(read.planned.map(\.edit))
        let failed = results.filter { !$0.succeeded }
        if !failed.isEmpty { return CameraSetupOutcome(succeeded: false, detail: failed.map(\.summary).joined(separator: "; ")) }
        let methods = results.compactMap(\.method).map(\.displayName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return CameraSetupOutcome(succeeded: true, detail: methods.isEmpty ? "already as wanted" : "via \(methods.joined(separator: " and "))")
    }

    private func restoreStep(_ id: CameraSetupStepID, backup: CameraSetupBackup, service: CameraSettingsService,
                             camera: CameraConfiguration) async -> CameraSetupOutcome {
        do {
            switch id {
            case .timeZone:
                guard let value = backup.timeZone else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.restoreTimeZone(value)
            case .timeSource:
                guard let value = backup.timeSource else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.restoreTimeSource(value)
            case .internetWatch:
                guard let value = backup.internetWatch else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.restoreDNS(value)
            case .cleanPicture:
                guard let value = backup.cleanPicture else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                let change = try await service.restorePicture(value)
                return CameraSetupOutcome(succeeded: change.succeeded, detail: change.summary)
            case .streams:
                guard let value = backup.streams else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                var edits: [CameraEncoderEdit] = []
                if let main = value.mainEncoder { edits.append(CameraEncoderEdit(isSub: false, desired: main, options: value.mainOptions)) }
                if let sub = value.subEncoder { edits.append(CameraEncoderEdit(isSub: true, desired: sub, options: value.subOptions)) }
                if !edits.isEmpty {
                    let failed = try await service.applyEncoder(edits).filter { !$0.succeeded }
                    if !failed.isEmpty { return CameraSetupOutcome(succeeded: false, detail: failed.map(\.summary).joined(separator: "; ")) }
                }
                if value.mainSmartCodec == true {
                    try await service.setHikvisionSmartCodec(enabled: true, channelID: CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: false))
                }
                if value.subSmartCodec == true {
                    try await service.setHikvisionSmartCodec(enabled: true, channelID: CameraDrivers.hikvisionChannelID(mainStreamURL: camera.mainStreamURL, sub: true))
                }
                return CameraSetupOutcome(succeeded: true, detail: "as the camera had them")
            case .videoPassword:
                guard let value = backup.videoPassword else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.restoreServiceSwitches(value)
            case .extraServices:
                guard let value = backup.extraServices else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.restoreServiceSwitches(value)
            case .upnp:
                guard let value = backup.upnp else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                return try await service.setFeature(.upnp, enabled: value.enabled, path: value.path)
            case .cloud:
                guard var value = backup.cloud else { return CameraSetupOutcome(succeeded: true, detail: "nothing saved") }
                var kept = false
                if value.cloudAuthcode == nil {
                    // Kept apart from the configuration (`keepSetupCloudAuthcode`); none kept: the camera's own goes back with the switch.
                    // A store that cannot be read fails the step, so a kept value is neither lost nor replaced by the camera's.
                    let credentials = credentials, id = camera.id
                    do {
                        value.cloudAuthcode = try await Self.offMain { try credentials.setupCloudAuthcode(for: id) }
                    } catch {
                        log.warning("\(camera.name): camera setup, the cloud's sign-in value could not be read from the secret store")
                        return CameraSetupOutcome(succeeded: false, detail: "Camera Bridge could not read the cloud’s saved sign-in, so nothing was changed")
                    }
                    kept = value.cloudAuthcode != nil
                }
                let outcome = try await service.setFeature(.cloud, enabled: value.enabled, path: value.path, saved: value)
                if outcome.succeeded, kept { await keepSetupCloudAuthcode(nil, camera: camera) }   // given back: no longer kept
                return outcome
            }
        } catch {
            return CameraSetupOutcome(succeeded: false, detail: Self.setupReason(error))
        }
    }

    /// The sign-in value of the maker's cloud that the setup turns off (an IP camera web API camera's Authcode) goes to the platform's
    /// secret store, never into the configuration, which reaches the page, its events and the Mac's backup file (nil deletes it, once
    /// the cloud is back). A value that cannot be kept is said in the log without it: Restore then gives back the one the camera has.
    private func keepSetupCloudAuthcode(_ code: String?, camera: CameraConfiguration) async {
        let credentials = credentials, id = camera.id
        do {
            try await Self.offMain { try credentials.setSetupCloudAuthcode(code, for: id) }
        } catch {
            log.warning("\(camera.name): camera setup, the cloud's sign-in value could not be \(code == nil ? "deleted" : "kept") in the secret store")
        }
    }

    /// A step's failure in a person's words (never with an address or a password).
    nonisolated static func setupReason(_ error: any Error) -> String {
        if let error = error as? CameraAdapterError, error.isLoginRefusal { return "the camera refused the login" }
        if let error = error as? CameraConfigError { return error.summary }
        return Redact.string(readableReason(error))
    }

    private func restartAfterCameraSetup(_ camera: CameraConfiguration) async {
        guard isActive, runtimes[camera.id] != nil else { return }
        log.notice("Restarting \(camera.name)'s ingest after its camera setup changed its streams")
        await stopRuntime(camera.id)
        if camera.isEnabled { await startRuntimes([camera]) }
        await refreshStatus()
    }

    // MARK: The bridge's address

    /// The bridge's IPv4 address cameras should take time from: the one on the camera's own subnet when the camera's address is known,
    /// else the bridge's only private address, else its first. nil when it has none (only loopback, link-local or tunnels).
    nonisolated static func timeServerAddress(cameraHost: String, interfaces: [InterfaceAddress]) -> String? {
        let candidates = bridgeAddressCandidates(interfaces)
        if let match = bridgeAddress(onNetworkOf: cameraHost, interfaces: interfaces) { return match }
        func isPrivate(_ address: String) -> Bool {
            guard let b = StreamAddress.addressBytes(address), b.count == 4 else { return false }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
        }
        return candidates.first { isPrivate($0.address) }?.address ?? candidates.first?.address
    }

    /// The bridge's IPv4 address on the subnet of `cameraHost` (an IPv4 address); nil when it has none there (no fallback: "Watch its
    /// internet" needs the camera to reach the bridge directly).
    nonisolated static func bridgeAddress(onNetworkOf cameraHost: String, interfaces: [InterfaceAddress]) -> String? {
        guard let camera = StreamAddress.addressBytes(cameraHost), camera.count == 4 else { return nil }
        return bridgeAddressCandidates(interfaces).first { entry in
            guard let bits = entry.prefixLength, bits > 0, bits <= 32, let bytes = StreamAddress.addressBytes(entry.address) else { return false }
            return StreamAddress.samePrefix(bytes, camera, bits: bits)
        }?.address
    }

    /// The bridge's IPv4 addresses a camera could use: no loopback, tunnel or link-local one.
    private nonisolated static func bridgeAddressCandidates(_ interfaces: [InterfaceAddress]) -> [InterfaceAddress] {
        interfaces.filter { entry in
            guard !entry.isIPv6, !StreamAddress.isLoopback(entry.address), !MacVPNDetector.isTunnelName(entry.interface),
                  let bytes = StreamAddress.addressBytes(entry.address), bytes.count == 4 else { return false }
            return !(bytes[0] == 169 && bytes[1] == 254)
        }
    }
}
