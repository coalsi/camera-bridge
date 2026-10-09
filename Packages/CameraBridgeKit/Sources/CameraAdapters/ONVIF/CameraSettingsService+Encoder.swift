import BridgeSupport
import Foundation

/// Encoder changes that try several methods before failing (`CameraConfigMethod`): the vendor's own API, then ONVIF
/// with the camera's own configuration sent back changed in only the fields that differ, then ONVIF's complete
/// request. Each write is read back; a change that does not show up counts as a failure of that method. A credential
/// problem (rejected login, locked-out camera) ends the chain: more attempts would only add failed logins.
extension CameraSettingsService {
    private enum AttemptOutcome {
        /// Applied and read back (`changed`), or already as wanted (`changed == false`).
        case done(changed: Bool)
        case failed(CameraConfigFailure)
    }

    func hikvisionChannel(isSub: Bool) -> String {
        CameraDrivers.hikvisionChannelID(mainStreamURL: mainStreamURL, sub: isSub)
    }

    /// Changes each stream's encoder to `edits[i].desired`. Never throws for a camera that refuses (see each result);
    /// throws only `CancellationError`. `memoryUpdate` says which method to remember afterwards.
    public func applyEncoder(_ edits: [CameraEncoderEdit]) async throws -> [CameraEncoderEditResult] {
        var results: [CameraEncoderEditResult] = []
        for edit in edits {
            try Task.checkCancellation()
            results.append(try await applyEncoder(edit))
        }
        return results
    }

    private func applyEncoder(_ edit: CameraEncoderEdit) async throws -> CameraEncoderEditResult {
        let order = CameraConfigMethod.attemptOrder(vendor: vendor, preferred: preferredMethod)
        if let credentialFailure, let first = order.first {
            return CameraEncoderEditResult(isSub: edit.isSub, succeeded: false, method: nil,
                                           failures: [CameraConfigAttempt(method: first, failure: credentialFailure)])
        }
        var failures: [CameraConfigAttempt] = []
        for method in order {
            switch try await attempt(method, edit) {
            case .done(let changed):
                if changed {
                    preferredMethod = method
                    memoryUpdate = .remember(method)
                    log.info("Changed the \(edit.isSub ? "sub" : "main") stream's settings through \(method.displayName)")
                }
                return CameraEncoderEditResult(isSub: edit.isSub, succeeded: true, method: changed ? method : nil, failures: failures)
            case .failed(let failure):
                log.info("\(method.displayName) could not change the \(edit.isSub ? "sub" : "main") stream's settings: \(failure.summary)")
                failures.append(CameraConfigAttempt(method: method, failure: failure))
                if failure.stopsChain {
                    credentialFailure = failure
                    return CameraEncoderEditResult(isSub: edit.isSub, succeeded: false, method: nil, failures: failures)
                }
            }
        }
        if memoryUpdate == nil, preferredMethod != nil {
            memoryUpdate = .forget
            preferredMethod = nil
        }
        return CameraEncoderEditResult(isSub: edit.isSub, succeeded: false, method: nil, failures: failures)
    }

    private func attempt(_ method: CameraConfigMethod, _ edit: CameraEncoderEdit) async throws -> AttemptOutcome {
        do {
            switch method {
            case .hikvisionISAPI: return try await viaISAPI(edit)
            case .reolinkAPI: return try await viaReolink(edit)
            case .onvifMinimal: return try await viaONVIF(edit, minimal: true)
            case .onvifFull: return try await viaONVIF(edit, minimal: false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.from(error))
        }
    }

    /// Reads the setting back; a read that fails for another reason than the login does not undo a write that worked.
    private func verified(_ expected: EncoderValues, read: () async throws -> EncoderValues) async throws -> Bool {
        do {
            return try await read().satisfies(expected)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.info("Could not read the change back to check it (\(error)); assuming it applied")
            return true
        }
    }

    private static func unreadableFailure(_ unreadable: [String]) -> CameraConfigFailure {
        .unsupported("can't read \(unreadable.joined(separator: ", "))")
    }

    // MARK: Hikvision ISAPI

    private func viaISAPI(_ edit: CameraEncoderEdit) async throws -> AttemptOutcome {
        guard vendor == .hikvision else { return .failed(.unsupported("not a Hikvision camera")) }
        let api = HikvisionISAPI(endpoint: endpoint, credentials: credentials)
        let channel = hikvisionChannel(isSub: edit.isSub)
        let (_, current) = try await api.encoderValues(channelID: channel)
        let (changes, unreadable) = current.changes(toReach: edit.desired)
        if changes.isEmpty { return unreadable.isEmpty ? .done(changed: false) : .failed(Self.unreadableFailure(unreadable)) }
        try await api.setEncoderValues(changes, channelID: channel)
        guard try await verified(changes, read: { try await api.encoderValues(channelID: channel).values }) else { return .failed(.didNotStick) }
        return .done(changed: true)
    }

    // MARK: ONVIF

    private func viaONVIF(_ edit: CameraEncoderEdit, minimal: Bool) async throws -> AttemptOutcome {
        guard let client = await client() else { return .failed(.unsupported("camera has no ONVIF service")) }
        let token = edit.desired.token
        guard !token.isEmpty else { return .failed(.unsupported("no ONVIF profile for this stream")) }
        let node = try await client.rawVideoEncoderConfiguration(token: token)
        let current = ONVIFClient.encoderValues(node)
        var (changes, unreadable) = current.changes(toReach: edit.desired)
        if changes.isEmpty { return unreadable.isEmpty ? .done(changed: false) : .failed(Self.unreadableFailure(unreadable)) }
        if minimal {
            let codec = changes.codec ?? current.codec
            let options = edit.options.first { EncoderValues.normalizedCodec($0.encoding) == codec }
            let clamped = changes.clamped(to: options).dropping(unchangedFrom: current)
            if clamped.isEmpty { return .failed(.rejected("the value is outside the range the camera reports")) }
            changes = clamped
        }
        let read: () async throws -> EncoderValues = { ONVIFClient.encoderValues(try await client.rawVideoEncoderConfiguration(token: token)) }
        guard minimal else {
            try await client.setVideoEncoderConfiguration(Self.convert(edit.desired))
            return try await verified(changes, read: read) ? .done(changed: true) : .failed(.didNotStick)
        }
        // Minimal: with the camera told to persist the change, then (if it refuses or ignores that) without.
        var lastFailure: CameraConfigFailure = .didNotStick
        for persist in [true, false] {
            do {
                try await client.setVideoEncoderConfiguration(preserving: node, changes: changes, forcePersistence: persist)
            } catch let error as CameraAdapterError where error.isLoginRefusal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = .from(error)
                continue
            }
            if try await verified(changes, read: read) { return .done(changed: true) }
            lastFailure = .didNotStick
        }
        return .failed(lastFailure)
    }

    // MARK: Reolink

    private func viaReolink(_ edit: CameraEncoderEdit) async throws -> AttemptOutcome {
        guard vendor == .reolink else { return .failed(.unsupported("not a Reolink camera")) }
        let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
        let outcome: AttemptOutcome
        do {
            outcome = try await viaReolink(edit, api: api)
        } catch {
            await api.logout()
            throw error
        }
        await api.logout()
        return outcome
    }

    private func viaReolink(_ edit: CameraEncoderEdit, api: ReolinkAPI) async throws -> AttemptOutcome {
        let key = edit.isSub ? "subStream" : "mainStream"
        let channelParam = JSONValue.object(["channel": .number(Double(reolinkChannel))])
        guard var encoder = try await api.command("GetEnc", param: channelParam)["Enc"]?.object, let stream = encoder[key]?.object else {
            return .failed(.unsupported("no encoder settings in GetEnc"))
        }
        let current = Self.reolinkValues(stream)
        var (changes, unreadable) = current.changes(toReach: edit.desired)
        if changes.isEmpty { return unreadable.isEmpty ? .done(changed: false) : .failed(Self.unreadableFailure(unreadable)) }
        let fps = Int((changes.frameRate ?? current.frameRate ?? 15).rounded())
        if let gov = changes.govLength {
            // Reolink's `gop` counts seconds of frames (1…4): the nearest whole number of seconds.
            guard stream["gop"] != nil else { return .failed(.unsupported("no keyframe interval in GetEnc")) }
            let seconds = min(4, max(1, Int((Double(gov) / Double(max(1, fps))).rounded())))
            changes.govLength = seconds * max(1, fps)
        }
        var edited = stream
        if let codec = changes.codec { edited["vType"] = .string(codec == "H265" ? "h265" : "h264") }
        if let width = changes.width, let height = changes.height { edited["size"] = .string("\(width)*\(height)") }
        if let rate = changes.frameRate { edited["frame"] = .number(rate.rounded()) }
        if let bitrate = changes.bitrate { edited["bitRate"] = .number(Double(bitrate)) }
        if let gov = changes.govLength { edited["gop"] = .number(Double(gov / max(1, fps))) }
        if let profile = changes.h264Profile { edited["profile"] = .string(profile.lowercased().hasPrefix("base") ? "Base" : profile) }
        encoder[key] = .object(edited)
        encoder["channel"] = .number(Double(reolinkChannel))
        _ = try await api.command("SetEnc", param: .object(["Enc": .object(encoder)]))
        let expected = changes
        let verifiedChange = try await verified(expected) {
            guard let stream = try await api.command("GetEnc", param: channelParam)["Enc"]?[key]?.object else {
                throw CameraAdapterError.invalidResponse("GetEnc: no \(key)")
            }
            return Self.reolinkValues(stream)
        }
        return verifiedChange ? .done(changed: true) : .failed(.didNotStick)
    }

    /// A Reolink `Enc` stream object as `EncoderValues`; the keyframe interval (`gop`, seconds of frames when 1…8, else
    /// frames) in frames.
    static func reolinkValues(_ stream: [String: JSONValue]) -> EncoderValues {
        var values = EncoderValues()
        values.codec = stream["vType"]?.string.map(EncoderValues.normalizedCodec)
        if let size = stream["size"]?.string {
            let parts = size.split(whereSeparator: { $0 == "*" || $0 == "x" || $0 == "X" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                values.width = CameraNumbers.dimension(parts[0])
                values.height = CameraNumbers.dimension(parts[1])
            }
        }
        values.frameRate = stream["frame"]?.double
        values.bitrate = stream["bitRate"]?.int
        if let gop = stream["gop"]?.int {
            let fps = Int((values.frameRate ?? 15).rounded())
            values.govLength = (1...8).contains(gop) ? gop * max(1, fps) : gop
        }
        if let profile = stream["profile"]?.string { values.h264Profile = profile.lowercased().hasPrefix("base") ? "Baseline" : profile }
        return values
    }

    // MARK: Hikvision stream settings without ONVIF

    /// A Hikvision channel's encoder settings read over ISAPI as `CameraVideoEncoderSettings` (token and name empty: it
    /// can be applied only by ISAPI), for a camera whose ONVIF profiles can't be read. nil when the channel reports no codec.
    public func hikvisionEncoderSettings(isSub: Bool) async throws -> CameraVideoEncoderSettings? {
        let (_, values) = try await HikvisionISAPI(endpoint: endpoint, credentials: credentials)
            .encoderValues(channelID: hikvisionChannel(isSub: isSub))
        guard let codec = values.codec else { return nil }
        let resolution = values.width.flatMap { width in values.height.map { CameraResolution(width: width, height: $0) } }
        return CameraVideoEncoderSettings(token: "", name: "", encoding: codec, resolution: resolution, frameRate: values.frameRate,
                                          bitrate: values.bitrate, iFrameInterval: values.govLength, h264Profile: values.h264Profile)
    }
}
