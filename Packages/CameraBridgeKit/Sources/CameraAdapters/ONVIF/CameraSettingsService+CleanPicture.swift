import BridgeSupport
import Foundation

/// What a camera drew on its own picture before "Clean picture" turned it off (its clock, its name, text lines, a logo), kept to put it back
/// exactly as it was.
public struct CleanPictureBackup: Sendable, Codable, Equatable {
    /// The way it was turned off.
    public var method: CameraConfigMethod
    /// Hikvision: the whole overlays document as the camera had it (XML). Reolink: its `Osd` object (JSON). The IP camera web API: the
    /// overlay's `Enable` as it was ("1"). nil for ONVIF.
    public var document: String?
    /// ONVIF: the text elements that were removed or blanked.
    public var removedOSDs: [HiddenCameraClock.RemovedOSD]

    public init(method: CameraConfigMethod, document: String? = nil, removedOSDs: [HiddenCameraClock.RemovedOSD] = []) {
        self.method = method
        self.document = document
        self.removedOSDs = removedOSDs
    }
}

/// The result of turning a camera's own labels off or back on.
public struct CleanPictureChange: Sendable {
    public var succeeded: Bool
    public var method: CameraConfigMethod?
    /// The backup to keep after turning them off.
    public var backup: CleanPictureBackup?
    /// What happened, for a person ("via ISAPI", or why not).
    public var summary: String
    /// Every way that could change the labels was refused to the account Camera Bridge uses (`CameraAdapterError.notPermitted`; a way the
    /// camera does not have aside): `summary` is then `CameraAdapterError.notPermittedReason`, and Set up for Camera Bridge goes on.
    public var notPermitted: Bool

    public init(succeeded: Bool, method: CameraConfigMethod? = nil, backup: CleanPictureBackup? = nil, summary: String, notPermitted: Bool = false) {
        self.succeeded = succeeded
        self.method = method
        self.backup = backup
        self.summary = summary
        self.notPermitted = notPermitted
    }
}

/// "Clean picture": every label the camera draws itself (date and time, its name, text lines, a logo) off, so the bridge draws its own the same
/// way on every camera. The vendor's API is tried first (Hikvision ISAPI's overlays document, Reolink's `Osd`), then ONVIF's OSD service (its
/// text elements are removed); on a Reolink, ONVIF only when Reolink's API cannot do it at all (no `GetOsd`, "not support", "ability
/// error": `CameraConfigFailure.leavesONVIF`), never after it answered otherwise (the account may not, another refusal). An ONVIF camera
/// that speaks the IP camera web API uses only that (its overlay switch): its ONVIF OSD answers cannot be trusted, also while that API
/// cannot be asked. Turning it back on writes back what was saved.
extension CameraSettingsService {
    public func cleanPicture() async throws -> CleanPictureChange {
        let web: IPCWebAccess
        do {
            web = try await ipcWeb()
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            return CleanPictureChange(succeeded: false, summary: "the camera refused the login")
        }
        if case .unavailable(let why) = web { return CleanPictureChange(succeeded: false, summary: why) }
        if case .speaks(let client, _) = web {
            do {
                let backup = try await cleanViaIPCWeb(client)
                log.info("Turned the camera's own labels off through \(CameraConfigMethod.ipcWebAPI.clockDisplayName)")
                return CleanPictureChange(succeeded: true, method: .ipcWebAPI, backup: backup, summary: "via \(CameraConfigMethod.ipcWebAPI.clockDisplayName)")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                return CleanPictureChange(succeeded: false, summary: "the camera refused the login")
            } catch {
                return CleanPictureChange(succeeded: false, summary: "\(CameraConfigMethod.ipcWebAPI.clockDisplayName): \(Redact.string(String(describing: error)))")
            }
        }
        var reasons: [String] = []
        var refusals: [any Error] = []
        for method in CameraConfigMethod.clockOrder(vendor: vendor, preferred: preferredMethod) {
            try Task.checkCancellation()
            do {
                if let backup = try await clean(using: method) {
                    log.info("Turned the camera's own labels off through \(method.clockDisplayName)")
                    return CleanPictureChange(succeeded: true, method: method, backup: backup, summary: "via \(method.clockDisplayName)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                return CleanPictureChange(succeeded: false, summary: "the camera refused the login")
            } catch {
                refusals.append(error)
                reasons.append("\(method.clockDisplayName): \(CameraAdapterError.refusalWords(error))")
                // Reolink's API answered: its ONVIF user would only be refused too (and a refused first call pauses its logins).
                if method == .reolinkAPI, !CameraConfigFailure.from(error).leavesONVIF { break }
            }
        }
        if Self.refusedOnlyForTheAccount(refusals) {
            return CleanPictureChange(succeeded: false, summary: CameraAdapterError.notPermittedReason, notPermitted: true)
        }
        return CleanPictureChange(succeeded: false, summary: reasons.isEmpty ? "not supported by this camera" : reasons.joined(separator: "; "))
    }

    /// An error after which the same way is not asked again: the account may not make the change (`.notPermitted`), a refused login, a
    /// cancellation (the logo is not the reason then).
    static func endsTheWay(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? CameraAdapterError else { return false }
        if case .notPermitted = error { return true }
        return error.isLoginRefusal
    }

    /// Whether the ways that failed were refused for the account Camera Bridge uses (`.notPermitted`), at least one, and the others found
    /// nothing to use (`.unsupported`).
    static func refusedOnlyForTheAccount(_ refusals: [any Error]) -> Bool {
        var refused = false
        for error in refusals {
            switch error as? CameraAdapterError {
            case .notPermitted?: refused = true
            case .unsupported?: continue
            default: return false
            }
        }
        return refused
    }

    /// Writes back what `cleanPicture()` saved.
    public func restorePicture(_ backup: CleanPictureBackup) async throws -> CleanPictureChange {
        do {
            switch backup.method {
            case .hikvisionISAPI:
                guard let document = backup.document, let body = document.data(using: .utf8) else { throw CameraAdapterError.invalidResponse("no saved overlays") }
                let api = isapi()
                let input = HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false))
                _ = try await api.put(HikvisionISAPI.overlaysPath(inputChannel: input), body: body)
            case .reolinkAPI:
                guard let document = backup.document, let osd = try? JSONDecoder().decode(JSONValue.self, from: Data(document.utf8)) else {
                    throw CameraAdapterError.invalidResponse("no saved Osd")
                }
                _ = try await reolink().command("SetOsd", param: .object(["Osd": osd]))
            case .onvifMinimal, .onvifFull:
                guard let client = await client() else { throw CameraAdapterError.unsupported("camera has no ONVIF service") }
                for osd in backup.removedOSDs {
                    switch osd.how {
                    case .deleted: try await client.createOSD(children: osd.children)
                    case .blanked: try await client.setOSD(token: osd.token, children: osd.children)
                    }
                }
            case .ipcWebAPI:
                switch try await ipcWeb() {
                case .speaks(let client, _): try await restoreViaIPCWeb(backup, client: client)
                case .unavailable(let why): throw IPCWebUnavailable(reason: why)
                case .none: throw CameraAdapterError.unsupported("the camera's web API does not answer")
                }
            }
            log.info("Put the camera's own labels back through \(backup.method.clockDisplayName)")
            return CleanPictureChange(succeeded: true, method: backup.method, summary: "via \(backup.method.clockDisplayName)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CleanPictureChange(succeeded: false, summary: CameraAdapterError.refusalWords(error))
        }
    }

    /// The backup when every label is off now; nil when this method does not apply to the camera. Throws when the camera answered with an error.
    private func clean(using method: CameraConfigMethod) async throws -> CleanPictureBackup? {
        switch method {
        case .hikvisionISAPI:
            guard vendor == .hikvision else { return nil }
            let api = isapi()
            let path = HikvisionISAPI.overlaysPath(inputChannel: HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false)))
            guard let document = String(data: try await api.get(path), encoding: .utf8) else { throw CameraAdapterError.invalidResponse("overlays: not UTF-8") }
            let clean = Self.allOverlaysOff(document)
            if clean != document, let body = clean.data(using: .utf8) { _ = try await api.put(path, body: body) }
            return CleanPictureBackup(method: .hikvisionISAPI, document: document)
        case .reolinkAPI:
            guard vendor == .reolink else { return nil }
            let api = reolink()
            guard let osd = try await api.command("GetOsd", param: .object(["channel": .number(Double(reolinkChannel))]))["Osd"]?.object else {
                throw CameraAdapterError.unsupported("no on-screen display in GetOsd")
            }
            let saved = String(decoding: try JSONEncoder().encode(JSONValue.object(osd)), as: UTF8.self)
            // Only what is on is turned off: a camera that draws nothing (some doorbells) is clean as it is, and is not written to (its SetOsd
            // refuses settings it does not have). A camera that refuses the logo setting is tried again without it.
            var off = osd
            var changed = false
            for key in ["osdChannel", "osdTime"] {
                if var element = off[key]?.object, element["enable"]?.int == 1 { element["enable"] = .number(0); off[key] = .object(element); changed = true }
            }
            let logo = off["watermark"]?.int == 1
            if logo { off["watermark"] = .number(0); changed = true }
            guard changed else { return CleanPictureBackup(method: .reolinkAPI, document: saved) }
            if off["channel"] == nil { off["channel"] = .number(Double(reolinkChannel)) }
            do {
                _ = try await api.command("SetOsd", param: .object(["Osd": .object(off)]))
            } catch let error where logo && !Self.endsTheWay(error) {
                off["watermark"] = osd["watermark"]
                _ = try await api.command("SetOsd", param: .object(["Osd": .object(off)]))
            }
            return CleanPictureBackup(method: .reolinkAPI, document: saved)
        case .onvifMinimal, .onvifFull:
            guard let client = await client() else { return nil }
            let texts = try await client.osds().filter { $0.type.caseInsensitiveCompare("Text") == .orderedSame }
            guard !texts.isEmpty else { throw CameraAdapterError.unsupported("no text elements in the camera's OSD") }
            var removed: [HiddenCameraClock.RemovedOSD] = []
            var notPermitted: (any Error)?
            for text in texts {
                do {
                    try await client.deleteOSD(token: text.token)
                    removed.append(.init(token: text.token, children: text.children, how: .deleted))
                    continue
                } catch {
                    if case CameraAdapterError.notPermitted = error { notPermitted = error }
                }
                guard let blank = ONVIFClient.blanked(children: text.children) else { continue }
                do {
                    try await client.setOSD(token: text.token, children: blank)
                    removed.append(.init(token: text.token, children: text.children, how: .blanked))
                } catch {
                    if case CameraAdapterError.notPermitted = error { notPermitted = error }
                }
            }
            // Every change refused to the account (its login works) is said so: the setup goes on after it.
            if removed.isEmpty, let notPermitted { throw notPermitted }
            guard !removed.isEmpty else { throw CameraAdapterError.unsupported("the camera kept its labels") }
            return CleanPictureBackup(method: method, removedOSDs: removed)
        case .ipcWebAPI:
            return nil   // not in the clock order: `cleanPicture()` asks the web API itself
        }
    }

    /// The overlays document with every `<enabled>true</enabled>` turned to false (date and time, channel name, text lines).
    static func allOverlaysOff(_ document: String) -> String {
        document.replacingOccurrences(of: "<enabled>true</enabled>", with: "<enabled>false</enabled>", options: .caseInsensitive)
    }
}
