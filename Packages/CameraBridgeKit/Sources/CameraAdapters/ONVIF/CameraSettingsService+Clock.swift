import BridgeSupport
import Foundation

/// How CameraBridge hid a camera's own date/time overlay, and what it needs to put it back. Stored with the camera's
/// configuration while the clock is hidden; an unreadable value (written by a newer build) reads back as "not hidden".
public struct HiddenCameraClock: Sendable, Codable, Equatable {
    /// An ONVIF OSD element that was removed (or blanked), with the configuration it had.
    public struct RemovedOSD: Sendable, Codable, Equatable {
        public enum How: String, Sendable, Codable { case deleted, blanked }
        public var token: String
        /// The element's children as the camera reported them (serialized XML).
        public var children: String
        public var how: How

        public init(token: String, children: String, how: How) {
            self.token = token
            self.children = children
            self.how = how
        }
    }

    /// The method that hid it (`.hikvisionISAPI`, `.reolinkAPI`, or `.onvifMinimal` for ONVIF's OSD service): the one
    /// that puts it back.
    public var method: CameraConfigMethod
    /// ISAPI and Reolink: whether the camera showed its clock before (false: it was already off, and stays off when
    /// restored). nil: not known.
    public var wasShown: Bool?
    /// ONVIF: the elements removed.
    public var removedOSDs: [RemovedOSD]

    public init(method: CameraConfigMethod, wasShown: Bool? = nil, removedOSDs: [RemovedOSD] = []) {
        self.method = method
        self.wasShown = wasShown
        self.removedOSDs = removedOSDs
    }
}

/// What `CameraSettingsService.hideCameraClock()` / `restoreCameraClock(_:)` did.
public struct CameraClockChange: Sendable, Equatable {
    /// The camera's clock overlay is now hidden (true) or as it was before (false).
    public var succeeded: Bool
    /// The method that did it; nil when it failed.
    public var method: CameraConfigMethod?
    /// What to keep to put the clock back (hiding: set when `succeeded`; restoring: nil).
    public var backup: HiddenCameraClock?
    /// Methods that failed, in order (all of them when `succeeded` is false).
    public var failures: [CameraConfigAttempt]
    /// Every method that was tried says the camera has no such overlay or cannot change it.
    public var isUnsupported: Bool {
        !succeeded && !failures.isEmpty && failures.allSatisfy { if case .unsupported = $0.failure { true } else { false } }
    }

    public init(succeeded: Bool, method: CameraConfigMethod?, backup: HiddenCameraClock? = nil, failures: [CameraConfigAttempt] = []) {
        self.succeeded = succeeded
        self.method = method
        self.backup = backup
        self.failures = failures
    }

    /// "via ISAPI", "not supported by this camera", or the failures ("ONVIF: login rejected").
    public var summary: String {
        if succeeded { return method.map { "via \($0.clockDisplayName)" } ?? "already as wanted" }
        return isUnsupported ? "not supported by this camera" : CameraConfigAttempt.clockSummary(failures)
    }
}

extension CameraConfigMethod {
    /// The methods that can change a camera's on-screen clock for `vendor`, in order: the vendor's own API, then ONVIF's
    /// OSD service (`.onvifMinimal` stands for it; the encoder's minimal/full split does not apply). A `preferred` method
    /// that applies goes first.
    public static func clockOrder(vendor: CameraVendor?, preferred: CameraConfigMethod? = nil) -> [CameraConfigMethod] {
        var order: [CameraConfigMethod]
        switch vendor {
        case .hikvision: order = [.hikvisionISAPI, .onvifMinimal]
        case .reolink: order = [.reolinkAPI, .onvifMinimal]
        default: order = [.onvifMinimal]
        }
        let wanted = preferred == .onvifFull ? CameraConfigMethod.onvifMinimal : preferred
        if let wanted, let index = order.firstIndex(of: wanted), index != 0 {
            order.remove(at: index)
            order.insert(wanted, at: 0)
        }
        return order
    }

    /// "ISAPI", "Reolink API", "ONVIF" (the OSD service has no minimal/full split).
    public var clockDisplayName: String {
        switch self {
        case .onvifMinimal, .onvifFull: "ONVIF"
        default: displayName
        }
    }
}

extension CameraConfigAttempt {
    static func clockSummary(_ attempts: [CameraConfigAttempt]) -> String {
        attempts.map { "\($0.method.clockDisplayName): \($0.failure.summary)" }.joined(separator: "; ")
    }
}

/// Turning a camera's own date/time overlay off and back on, through the vendor's API and ONVIF's OSD service in turn
/// (`CameraConfigMethod.clockOrder`). Every write is read back. A credential problem (rejected login, locked-out camera)
/// ends the chain, like the encoder changes: more attempts would only add failed logins (ONVIF also keeps its own login
/// guard).
extension CameraSettingsService {
    private enum ClockOutcome {
        case done(HiddenCameraClock)
        case failed(CameraConfigFailure)
    }

    /// Hides the camera's own date/time overlay. Never throws for a camera that refuses (see the result); throws only
    /// `CancellationError`.
    public func hideCameraClock() async throws -> CameraClockChange {
        if let credentialFailure, let first = CameraConfigMethod.clockOrder(vendor: vendor, preferred: preferredMethod).first {
            return CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: first, failure: credentialFailure)])
        }
        var failures: [CameraConfigAttempt] = []
        for method in CameraConfigMethod.clockOrder(vendor: vendor, preferred: preferredMethod) {
            try Task.checkCancellation()
            switch try await hide(using: method) {
            case .done(let backup):
                log.info("Hid the camera's own clock through \(method.clockDisplayName)")
                return CameraClockChange(succeeded: true, method: method, backup: backup, failures: failures)
            case .failed(let failure):
                log.info("\(method.clockDisplayName) could not hide the camera's own clock: \(failure.summary)")
                failures.append(CameraConfigAttempt(method: method, failure: failure))
                if failure.stopsChain {
                    credentialFailure = failure
                    return CameraClockChange(succeeded: false, method: nil, failures: failures)
                }
            }
        }
        return CameraClockChange(succeeded: false, method: nil, failures: failures)
    }

    /// Puts the camera's own clock overlay back as `backup` found it, through the method that hid it.
    public func restoreCameraClock(_ backup: HiddenCameraClock) async throws -> CameraClockChange {
        if let credentialFailure {
            return CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: backup.method, failure: credentialFailure)])
        }
        do {
            let failure = try await restore(backup)
            if let failure {
                if failure.stopsChain { credentialFailure = failure }
                return CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: backup.method, failure: failure)])
            }
            log.info("Put the camera's own clock back through \(backup.method.clockDisplayName)")
            return CameraClockChange(succeeded: true, method: backup.method)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: backup.method, failure: .from(error))])
        }
    }

    // MARK: Hide

    private func hide(using method: CameraConfigMethod) async throws -> ClockOutcome {
        do {
            switch method {
            case .hikvisionISAPI: return try await hideViaISAPI()
            case .reolinkAPI: return try await hideViaReolink()
            case .onvifMinimal, .onvifFull: return try await hideViaONVIF()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.from(error))
        }
    }

    private func hideViaISAPI() async throws -> ClockOutcome {
        guard vendor == .hikvision else { return .failed(.unsupported("not a Hikvision camera")) }
        let api = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
        let input = HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false))
        guard let shown = try await api.dateTimeOverlayEnabled(inputChannel: input) else {
            return .failed(.unsupported("no date and time overlay in the camera's on-screen display"))
        }
        if shown {
            try await api.setDateTimeOverlayEnabled(false, inputChannel: input)
            guard try await api.dateTimeOverlayEnabled(inputChannel: input) == false else { return .failed(.didNotStick) }
        }
        return .done(HiddenCameraClock(method: .hikvisionISAPI, wasShown: shown))
    }

    private func hideViaReolink() async throws -> ClockOutcome {
        guard vendor == .reolink else { return .failed(.unsupported("not a Reolink camera")) }
        let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
        let outcome: ClockOutcome
        do {
            outcome = try await hideViaReolink(api: api)
        } catch {
            await api.logout()
            throw error
        }
        await api.logout()
        return outcome
    }

    /// GetOsd once, change only `osdTime.enable` in what it returned, SetOsd with that whole `Osd` object (Reolink replaces
    /// the camera's on-screen display with it: a partial object resets the rest), then GetOsd again to see that it stuck.
    /// A camera that refuses the write with an answer about the request itself (an ability error, -26; "not support", -9)
    /// has no switchable clock (some doorbells do not): that is reported as unsupported, and nothing is retried.
    private func hideViaReolink(api: ReolinkAPI) async throws -> ClockOutcome {
        guard let osd = try await reolinkOSD(api: api), let time = osd["osdTime"]?.object, let enable = time["enable"]?.int else {
            return .failed(.unsupported("no date and time in GetOsd"))
        }
        let shown = enable != 0
        if shown {
            try await writeReolinkClock(shown: false, of: osd, api: api)
            guard try await reolinkClockShown(api: api) == false else { return .failed(.didNotStick) }
        }
        return .done(HiddenCameraClock(method: .reolinkAPI, wasShown: shown))
    }

    private func reolinkOSD(api: ReolinkAPI) async throws -> [String: JSONValue]? {
        try await api.command("GetOsd", param: .object(["channel": .number(Double(reolinkChannel))]))["Osd"]?.object
    }

    private func reolinkClockShown(api: ReolinkAPI) async throws -> Bool? {
        guard let osd = try await reolinkOSD(api: api), let time = osd["osdTime"]?.object, let enable = time["enable"]?.int else { return nil }
        return enable != 0
    }

    /// Read-modify-write of `Osd/osdTime/enable`: the rest of the on-screen display (name, positions, watermark) is sent back as read.
    private func setReolinkClock(shown: Bool, api: ReolinkAPI) async throws {
        guard let osd = try await reolinkOSD(api: api) else { throw CameraAdapterError.unsupported("no date and time in GetOsd") }
        try await writeReolinkClock(shown: shown, of: osd, api: api)
    }

    /// `SetOsd` with `osd` (as `GetOsd` returned it) and only `osdTime.enable` changed.
    private func writeReolinkClock(shown: Bool, of osd: [String: JSONValue], api: ReolinkAPI) async throws {
        var osd = osd
        guard var time = osd["osdTime"]?.object else { throw CameraAdapterError.unsupported("no date and time in GetOsd") }
        time["enable"] = .number(shown ? 1 : 0)
        osd["osdTime"] = .object(time)
        if osd["channel"] == nil { osd["channel"] = .number(Double(reolinkChannel)) }
        _ = try await api.command("SetOsd", param: .object(["Osd": .object(osd)]))
    }

    private func hideViaONVIF() async throws -> ClockOutcome {
        guard let client = await client() else { return .failed(.unsupported("camera has no ONVIF service")) }
        let clocks = try await client.osds().filter(\.showsClock)
        guard !clocks.isEmpty else { return .failed(.unsupported("no date and time element in the camera's OSD")) }
        var removed: [HiddenCameraClock.RemovedOSD] = []
        var lastFailure: CameraConfigFailure?
        for clock in clocks {
            do {
                try await client.deleteOSD(token: clock.token)
                removed.append(.init(token: clock.token, children: clock.children, how: .deleted))
                continue
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = .from(error)
            }
            // A camera that will not delete its clock may still let it be blanked.
            guard let blank = ONVIFClient.blanked(children: clock.children) else { continue }
            do {
                try await client.setOSD(token: clock.token, children: blank)
                removed.append(.init(token: clock.token, children: clock.children, how: .blanked))
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = .from(error)
            }
        }
        guard !removed.isEmpty else { return .failed(lastFailure ?? .rejected("the camera would not remove its clock")) }
        let remaining = try await client.osds().filter { osd in osd.showsClock && removed.contains { $0.token == osd.token } }
        guard remaining.isEmpty else {
            _ = try? await restoreONVIF(removed, client: client)   // put back what was taken: it would not stay off
            return .failed(.didNotStick)
        }
        return .done(HiddenCameraClock(method: .onvifMinimal, removedOSDs: removed))
    }

    // MARK: Restore

    /// nil when restored; else why not.
    private func restore(_ backup: HiddenCameraClock) async throws -> CameraConfigFailure? {
        switch backup.method {
        case .hikvisionISAPI:
            guard vendor == .hikvision else { return .unsupported("not a Hikvision camera") }
            guard backup.wasShown != false else { return nil }   // it was off before: stays off
            let api = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
            let input = HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false))
            try await api.setDateTimeOverlayEnabled(true, inputChannel: input)
            return try await api.dateTimeOverlayEnabled(inputChannel: input) == true ? nil : .didNotStick
        case .reolinkAPI:
            guard vendor == .reolink else { return .unsupported("not a Reolink camera") }
            guard backup.wasShown != false else { return nil }
            let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
            do {
                try await setReolinkClock(shown: true, api: api)
                let shown = try await reolinkClockShown(api: api)
                await api.logout()
                return shown == true ? nil : .didNotStick
            } catch {
                await api.logout()
                throw error
            }
        case .onvifMinimal, .onvifFull:
            guard let client = await client() else { return .unsupported("camera has no ONVIF service") }
            return try await restoreONVIF(backup.removedOSDs, client: client)
        }
    }

    private func restoreONVIF(_ removed: [HiddenCameraClock.RemovedOSD], client: ONVIFClient) async throws -> CameraConfigFailure? {
        var failure: CameraConfigFailure?
        for osd in removed {
            do {
                switch osd.how {
                case .deleted: try await client.createOSD(children: osd.children)
                case .blanked: try await client.setOSD(token: osd.token, children: osd.children)
                }
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = .from(error)
            }
        }
        return failure
    }
}
