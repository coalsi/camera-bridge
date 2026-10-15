import BridgeSupport
import Foundation

/// What a camera drew on its own picture before "Clean picture" turned it off (its clock, its name, text lines, a logo), kept to put it back
/// exactly as it was.
public struct CleanPictureBackup: Sendable, Codable, Equatable {
    /// The way it was turned off.
    public var method: CameraConfigMethod
    /// Hikvision: the whole overlays document as the camera had it (XML). Reolink: its `Osd` object (JSON). nil for ONVIF.
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

    public init(succeeded: Bool, method: CameraConfigMethod? = nil, backup: CleanPictureBackup? = nil, summary: String) {
        self.succeeded = succeeded
        self.method = method
        self.backup = backup
        self.summary = summary
    }
}

/// "Clean picture": every label the camera draws itself (date and time, its name, text lines, a logo) off, so the bridge draws its own the same
/// way on every camera. The vendor's API is tried first (Hikvision ISAPI's overlays document, Reolink's `Osd`), then ONVIF's OSD service (its
/// text elements are removed). Turning it back on writes back what was saved.
extension CameraSettingsService {
    public func cleanPicture() async throws -> CleanPictureChange {
        var reasons: [String] = []
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
                reasons.append("\(method.clockDisplayName): \(Redact.string(String(describing: error)))")
            }
        }
        return CleanPictureChange(succeeded: false, summary: reasons.isEmpty ? "not supported by this camera" : reasons.joined(separator: "; "))
    }

    /// Writes back what `cleanPicture()` saved.
    public func restorePicture(_ backup: CleanPictureBackup) async throws -> CleanPictureChange {
        do {
            switch backup.method {
            case .hikvisionISAPI:
                guard let document = backup.document, let body = document.data(using: .utf8) else { throw CameraAdapterError.invalidResponse("no saved overlays") }
                let api = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
                let input = HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false))
                _ = try await api.put(HikvisionISAPI.overlaysPath(inputChannel: input), body: body)
            case .reolinkAPI:
                guard let document = backup.document, let osd = try? JSONDecoder().decode(JSONValue.self, from: Data(document.utf8)) else {
                    throw CameraAdapterError.invalidResponse("no saved Osd")
                }
                let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
                defer { Task { await api.logout() } }
                _ = try await api.command("SetOsd", param: .object(["Osd": osd]))
            case .onvifMinimal, .onvifFull:
                guard let client = await client() else { throw CameraAdapterError.unsupported("camera has no ONVIF service") }
                for osd in backup.removedOSDs {
                    switch osd.how {
                    case .deleted: try await client.createOSD(children: osd.children)
                    case .blanked: try await client.setOSD(token: osd.token, children: osd.children)
                    }
                }
            }
            log.info("Put the camera's own labels back through \(backup.method.clockDisplayName)")
            return CleanPictureChange(succeeded: true, method: backup.method, summary: "via \(backup.method.clockDisplayName)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CleanPictureChange(succeeded: false, summary: Redact.string(String(describing: error)))
        }
    }

    /// The backup when every label is off now; nil when this method does not apply to the camera. Throws when the camera answered with an error.
    private func clean(using method: CameraConfigMethod) async throws -> CleanPictureBackup? {
        switch method {
        case .hikvisionISAPI:
            guard vendor == .hikvision else { return nil }
            let api = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
            let path = HikvisionISAPI.overlaysPath(inputChannel: HikvisionISAPI.inputChannel(streamingChannelID: hikvisionChannel(isSub: false)))
            guard let document = String(data: try await api.get(path), encoding: .utf8) else { throw CameraAdapterError.invalidResponse("overlays: not UTF-8") }
            let clean = Self.allOverlaysOff(document)
            if clean != document, let body = clean.data(using: .utf8) { _ = try await api.put(path, body: body) }
            return CleanPictureBackup(method: .hikvisionISAPI, document: document)
        case .reolinkAPI:
            guard vendor == .reolink else { return nil }
            let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
            defer { Task { await api.logout() } }
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
            } catch where logo {
                off["watermark"] = osd["watermark"]
                _ = try await api.command("SetOsd", param: .object(["Osd": .object(off)]))
            }
            return CleanPictureBackup(method: .reolinkAPI, document: saved)
        case .onvifMinimal, .onvifFull:
            guard let client = await client() else { return nil }
            let texts = try await client.osds().filter { $0.type.caseInsensitiveCompare("Text") == .orderedSame }
            guard !texts.isEmpty else { throw CameraAdapterError.unsupported("no text elements in the camera's OSD") }
            var removed: [HiddenCameraClock.RemovedOSD] = []
            for text in texts {
                if (try? await client.deleteOSD(token: text.token)) != nil {
                    removed.append(.init(token: text.token, children: text.children, how: .deleted))
                } else if let blank = ONVIFClient.blanked(children: text.children), (try? await client.setOSD(token: text.token, children: blank)) != nil {
                    removed.append(.init(token: text.token, children: text.children, how: .blanked))
                }
            }
            guard !removed.isEmpty else { throw CameraAdapterError.unsupported("the camera kept its labels") }
            return CleanPictureBackup(method: method, removedOSDs: removed)
        }
    }

    /// The overlays document with every `<enabled>true</enabled>` turned to false (date and time, channel name, text lines).
    static func allOverlaysOff(_ document: String) -> String {
        document.replacingOccurrences(of: "<enabled>true</enabled>", with: "<enabled>false</enabled>", options: .caseInsensitive)
    }
}
