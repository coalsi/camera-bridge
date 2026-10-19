import BridgeSupport
import Foundation

/// Encoder changes that try several methods before failing (`CameraConfigMethod`): the vendor's own API, then ONVIF
/// with the camera's own configuration sent back changed in only the fields that differ, then ONVIF's complete
/// request. Each write is read back; a change that does not show up counts as a failure of that method. A credential
/// problem (rejected login, locked-out camera) ends the chain: more attempts would only add failed logins. On a Reolink,
/// ONVIF is tried only after Reolink's API could not make the change at all (`CameraConfigFailure.leavesONVIF`).
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
        chain: for method in order {
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
                // Reolink's API answered (the account may not, a refusal, no answer): its ONVIF would only be refused too.
                if method == .reolinkAPI, !failure.leavesONVIF { break chain }
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
            case .ipcWebAPI: return .failed(.unsupported("the web API does not change the encoder"))
            case .dahuaCGI: return .failed(.unsupported("Dahua’s API does not change the encoder"))
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

    /// An edit that rewrites the codec (`CameraEncoderEdit.rewriteCodec`) writes it even when the camera's settings already name it.
    private static func rewritingCodec(_ changes: inout EncoderValues, _ edit: CameraEncoderEdit) {
        guard edit.rewriteCodec, changes.codec == nil else { return }
        changes.codec = EncoderValues.normalizedCodec(edit.desired.encoding)
    }

    private static func unreadableFailure(_ unreadable: [String]) -> CameraConfigFailure {
        .unsupported("can't read \(unreadable.joined(separator: ", "))")
    }

    // MARK: Hikvision ISAPI

    private func viaISAPI(_ edit: CameraEncoderEdit) async throws -> AttemptOutcome {
        guard vendor == .hikvision else { return .failed(.unsupported("not a Hikvision camera")) }
        let api = isapi()
        let channel = hikvisionChannel(isSub: edit.isSub)
        let (_, current) = try await api.encoderValues(channelID: channel)
        var (changes, unreadable) = current.changes(toReach: edit.desired)
        Self.rewritingCodec(&changes, edit)
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
        Self.rewritingCodec(&changes, edit)
        if changes.isEmpty { return unreadable.isEmpty ? .done(changed: false) : .failed(Self.unreadableFailure(unreadable)) }
        if minimal {
            let codec = changes.codec ?? current.codec
            let options = edit.options.first { EncoderValues.normalizedCodec($0.encoding) == codec }
            var clamped = changes.clamped(to: options).dropping(unchangedFrom: current)
            if edit.rewriteCodec, clamped.codec == nil { clamped.codec = changes.codec }   // the same codec, written on purpose
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

    /// Why a codec change is not written through Reolink's HTTP API: the camera's range ties each picture size to one codec, and `vType` is not
    /// a `SetEnc` field (reolink_aio changes the codec through Reolink's other protocol, Baichuan).
    static let reolinkCodecTiedToSize = "this camera changes its codec only together with its picture size, in the Reolink app or Client"
    /// A size change alone that the camera's range ties to another codec than the one it sends.
    static let reolinkSizeChangesCodec = "at that picture size this camera sends another codec, so Camera Bridge left its size as it is"

    private func viaReolink(_ edit: CameraEncoderEdit) async throws -> AttemptOutcome {
        guard vendor == .reolink else { return .failed(.unsupported("not a Reolink camera")) }
        return try await viaReolink(edit, api: reolink())
    }

    /// `GetEnc` with action 1 (the value and the range: each picture size the camera offers with its one codec, its frame rates, bit rates,
    /// `gop` bounds and profiles), then `SetEnc` with the camera's `Enc` as read and only this stream's values changed, each inside the range:
    /// the nearest `frameRate` and `bitRate` the camera offers, `gop` (whole seconds of frames, of the frame rate asked for) within its bounds,
    /// a profile it offers (else the stream's). The codec follows the size: `vType` is never sent, and `width`, `height` and `resolution`
    /// ("internal use only, not needed for SetEnc", v8 guide §3.5.1) are left out of both streams. Read back with `GetEnc`.
    private func viaReolink(_ edit: CameraEncoderEdit, api: ReolinkAPI) async throws -> AttemptOutcome {
        let key = edit.isSub ? "subStream" : "mainStream"
        let channelParam = JSONValue.object(["channel": .number(Double(reolinkChannel))])
        let value: JSONValue
        let element: JSONValue
        switch try await api.answer("GetEnc", param: channelParam, action: 1) {
        case .value(let read, let whole): (value, element) = (read, whole)
        case .refused(let code, _): return .failed(.from(CameraAdapterError.apiError(command: "GetEnc", code: code)))
        }
        guard var encoder = value["Enc"]?.object, let stream = encoder[key]?.object else {
            return .failed(.unsupported("no encoder settings in GetEnc"))
        }
        let current = Self.reolinkValues(stream)
        var (changes, unreadable) = current.changes(toReach: edit.desired)
        Self.rewritingCodec(&changes, edit)
        if changes.isEmpty { return unreadable.isEmpty ? .done(changed: false) : .failed(Self.unreadableFailure(unreadable)) }
        let ranges = Self.reolinkRanges(element["range"]?["Enc"], key: key, channel: reolinkChannel)
        let size = changes.width.flatMap { width in changes.height.map { "\(width)*\($0)" } } ?? stream["size"]?.string
        let range = ranges.first { $0["size"]?.string == size }
        if !ranges.isEmpty, range == nil { return .failed(.unsupported("the camera does not offer \(size ?? "this picture size") for this stream")) }
        let rangeCodec = range?["vType"]?.string.map(EncoderValues.normalizedCodec)
        if let codec = changes.codec, rangeCodec != codec {
            return .failed(.unsupported(Self.reolinkCodecTiedToSize))
        }
        // A size the camera offers only with another codec would switch it unnoticed (the read-back checks only what was asked).
        if changes.codec == nil, changes.width != nil, let rangeCodec, let now = current.codec, rangeCodec != now {
            return .failed(.unsupported(Self.reolinkSizeChangesCodec))
        }

        // The keyframe interval in whole seconds of the frame rate asked for (Reolink's `gop`), then every value inside the range.
        let asked = changes.frameRate ?? current.frameRate ?? 15
        var gop = stream["gop"]?.int
        if let frames = changes.govLength {
            guard gop != nil else { return .failed(.unsupported("no keyframe interval in GetEnc")) }
            gop = min(4, max(1, Int((Double(frames) / max(1, asked)).rounded())))
        }
        var frameRate = changes.frameRate ?? current.frameRate
        var bitRate = changes.bitrate ?? current.bitrate
        var profile = changes.h264Profile.map(Self.reolinkProfile) ?? stream["profile"]?.string
        if let range {
            frameRate = frameRate.map { Self.nearest($0, in: range["frameRate"]) }
            bitRate = bitRate.map { Int(Self.nearest(Double($0), in: range["bitRate"])) }
            if let low = range["gop"]?["min"]?.int, let high = range["gop"]?["max"]?.int, low <= high { gop = gop.map { min(high, max(low, $0)) } }
            if let offered = range["profile"]?.array?.compactMap(\.string), let wanted = profile, !offered.contains(wanted) {
                profile = stream["profile"]?.string
            }
        }

        // What the camera should show afterwards: only what differs from now.
        var expected = EncoderValues()
        expected.codec = changes.codec
        expected.width = changes.width
        expected.height = changes.height
        if let frameRate, frameRate != current.frameRate { expected.frameRate = frameRate }
        if let bitRate, bitRate != current.bitrate { expected.bitrate = bitRate }
        if let gop {
            let frames = gop * max(1, Int((frameRate ?? asked).rounded()))
            if frames != current.govLength { expected.govLength = frames }
        }
        if let profile, profile != stream["profile"]?.string { expected.h264Profile = profile == "Base" ? "Baseline" : profile }
        guard !expected.isEmpty else { return .failed(.rejected("the value is outside the range the camera reports")) }

        var edited = Self.reolinkWritable(stream)
        if changes.width != nil, let size { edited["size"] = .string(size) }
        if let frameRate { edited["frameRate"] = .number(frameRate) }
        if let bitRate { edited["bitRate"] = .number(Double(bitRate)) }
        if let gop { edited["gop"] = .number(Double(gop)) }
        if let profile { edited["profile"] = .string(profile) }
        encoder[key] = .object(edited)
        let other = edit.isSub ? "mainStream" : "subStream"
        if let stream = encoder[other]?.object { encoder[other] = .object(Self.reolinkWritable(stream)) }
        encoder["channel"] = .number(Double(reolinkChannel))
        if try await reolinkMayNotChange("enc", perChannel: true) { return .failed(.notPermitted) }
        if case .refused(let code, let detail) = try await api.answer("SetEnc", param: .object(["Enc": .object(encoder)])) {
            return .failed(ReolinkAPI.unsupportedCodes.contains(code) ? .unsupported("SetEnc not supported")
                : .rejected("SetEnc error \(code)\(detail.map { ": \($0)" } ?? "")"))
        }
        let verifiedChange = try await verified(expected) {
            guard let stream = try await api.command("GetEnc", param: channelParam)["Enc"]?[key]?.object else {
                throw CameraAdapterError.invalidResponse("GetEnc: no \(key)")
            }
            return Self.reolinkValues(stream)
        }
        return verifiedChange ? .done(changed: true) : .failed(.didNotStick)
    }

    /// A stream object as `SetEnc` takes it: as read without `width`, `height`, `resolution` and `vType`.
    static func reolinkWritable(_ stream: [String: JSONValue]) -> [String: JSONValue] {
        var writable = stream
        for field in ["width", "height", "resolution", "vType"] { writable[field] = nil }
        return writable
    }

    /// The range entries (`GetEnc` with action 1) of stream `key` that apply to `channel` (`chnBit`, when given, has its bit).
    static func reolinkRanges(_ range: JSONValue?, key: String, channel: Int) -> [[String: JSONValue]] {
        let entries = range?.array ?? range.map { [$0] } ?? []
        return entries.compactMap { entry in
            if let bits = entry["chnBit"]?.int, (0..<62).contains(channel), bits & (1 << channel) == 0 { return nil }
            return entry[key]?.object
        }
    }

    /// The offered value nearest `value` (the lower one of two as near); `value` when the camera lists none.
    static func nearest(_ value: Double, in offered: JSONValue?) -> Double {
        let values = (offered?.array ?? []).compactMap(\.double)
        return values.min { lhs, rhs in
            let (a, b) = (abs(lhs - value), abs(rhs - value))
            return a == b ? lhs < rhs : a < b
        } ?? value
    }

    /// Reolink's name of an H.264 profile: "Base", "Main", "High".
    static func reolinkProfile(_ profile: String) -> String {
        profile.lowercased().hasPrefix("base") ? "Base" : profile
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
        values.frameRate = stream["frameRate"]?.double
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
        let (_, values) = try await isapi()
            .encoderValues(channelID: hikvisionChannel(isSub: isSub))
        guard let codec = values.codec else { return nil }
        let resolution = values.width.flatMap { width in values.height.map { CameraResolution(width: width, height: $0) } }
        return CameraVideoEncoderSettings(token: "", name: "", encoding: codec, resolution: resolution, frameRate: values.frameRate,
                                          bitrate: values.bitrate, iFrameInterval: values.govLength, h264Profile: values.h264Profile)
    }
}
