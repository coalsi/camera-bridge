import BridgeSupport
import Foundation

/// What a camera's PTZ node supports (`GetNodes`): continuous pan/tilt and continuous zoom.
struct ONVIFPTZNode: Sendable, Equatable {
    var continuousPanTilt: Bool
    var continuousZoom: Bool
    /// `AuxiliaryCommands` the node lists (e.g. `tt:IRLamp|On`, `tt:Wiper|On`).
    var auxiliaryCommands: [String] = []
}

/// ONVIF PTZ (ver20 PTZ service): the service address, the node's spaces, `ContinuousMove` and `Stop`. Velocities are in the generic
/// spaces (-1…1), which every PTZ camera accepts when the space is left out of the request.
extension ONVIFClient {
    static let ptzNamespace = "http://www.onvif.org/ver20/ptz/wsdl"

    /// The PTZ service: from `GetServices`, else `GetCapabilities` (category PTZ), else the device service (some cameras serve every
    /// service there).
    func ptzServiceURL() async -> URL {
        if let url = try? await services()[Self.ptzNamespace] { return url }
        if let envelope = try? await call(deviceServiceURL, body: "<tds:GetCapabilities><tds:Category>PTZ</tds:Category></tds:GetCapabilities>",
                                          action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities"),
           let text = envelope.firstDescendant("PTZ")?.string("XAddr"), let url = URL(string: text.trimmingCharacters(in: .whitespaces)) {
            return Self.serviceURL(url, deviceServiceURL: deviceServiceURL)
        }
        return deviceServiceURL
    }

    func ptzNodes() async throws -> [ONVIFPTZNode] {
        let envelope = try await call(await ptzServiceURL(), body: "<tptz:GetNodes xmlns:tptz=\"\(Self.ptzNamespace)\"/>",
                                      action: "\(Self.ptzNamespace)/GetNodes")
        return Self.parsePTZNodes(envelope)
    }

    static func parsePTZNodes(_ envelope: XMLTree) -> [ONVIFPTZNode] {
        guard let response = envelope.firstDescendant("GetNodesResponse") else { return [] }
        return response.children("PTZNode").map { node in
            let spaces = node.child("SupportedPTZSpaces")
            return ONVIFPTZNode(continuousPanTilt: spaces?.child("ContinuousPanTiltVelocitySpace") != nil,
                                continuousZoom: spaces?.child("ContinuousZoomVelocitySpace") != nil,
                                auxiliaryCommands: node.children("AuxiliaryCommands").map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }

    /// `ContinuousMove` at a velocity (-1…1; pan right, tilt up and zoom in positive). Only the axes asked for are sent: some cameras
    /// refuse a zoom velocity when they have no zoom. With `timeout`, the move carries `Timeout` PT1S: the camera stops by itself after a
    /// second, even when the `Stop` after it is lost.
    func continuousMove(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?, timeout: Bool = true) async throws {
        _ = try await call(await ptzServiceURL(), body: Self.continuousMoveBody(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom, timeout: timeout),
                       action: "\(Self.ptzNamespace)/ContinuousMove")
    }

    static func continuousMoveBody(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?, timeout: Bool = true) -> String {
        func number(_ value: Double) -> String { String(format: "%.2f", min(max(value, -1), 1)) }
        var velocity = ""
        if pan != nil || tilt != nil { velocity += "<tt:PanTilt x=\"\(number(pan ?? 0))\" y=\"\(number(tilt ?? 0))\"/>" }
        if let zoom { velocity += "<tt:Zoom x=\"\(number(zoom))\"/>" }
        return "<tptz:ContinuousMove xmlns:tptz=\"\(ptzNamespace)\"><tptz:ProfileToken>\(XMLTree.escape(profileToken))</tptz:ProfileToken>"
            + "<tptz:Velocity>\(velocity)</tptz:Velocity>\(timeout ? "<tptz:Timeout>PT1S</tptz:Timeout>" : "")</tptz:ContinuousMove>"
    }

    /// The video source tokens (`GetVideoSources`), for the imaging service.
    func videoSourceTokens() async throws -> [String] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetVideoSources/>", action: "http://www.onvif.org/ver10/media/wsdl/GetVideoSources")
        return envelope.firstDescendant("GetVideoSourcesResponse")?.children("VideoSources").compactMap { $0.attribute("token") } ?? []
    }

    /// `Stop` of pan/tilt and zoom.
    func stopPTZ(profileToken: String) async throws {
        let body = "<tptz:Stop xmlns:tptz=\"\(Self.ptzNamespace)\"><tptz:ProfileToken>\(XMLTree.escape(profileToken))</tptz:ProfileToken>"
            + "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>"
        _ = try await call(await ptzServiceURL(), body: body, action: "\(Self.ptzNamespace)/Stop")
    }
}

/// Pan, tilt and zoom of an ONVIF camera in steps: every move is `ContinuousMove` for `step`, then `Stop`, so one tap turns the camera a
/// little and nothing leaves it turning (a camera on a cable must not spin). The move also carries `Timeout` PT1S, and a `Stop` is sent
/// after any move that may have reached the camera, even one whose answer was lost, and once more when the `Stop` itself got no answer.
/// Steps never overlap: a move that comes while one runs waits for it, and only one waits (a newer move takes its place, so a held button
/// on a slow camera builds no backlog); `stop()` drops the one waiting. The bridge repeats a move while a button is held.
actor ONVIFPanTilt: PanTiltControl {
    static let step: Duration = .milliseconds(400)
    static let speed = 0.5

    private let client: ONVIFClient
    private let log: Log
    private var profileToken: String?
    private var known: PanTiltCapabilities?
    private let steps = PanTiltSteps()
    /// The camera refused a move with a `Timeout` (some take none, or another range): moves go without it.
    private var noTimeout = false

    init(client: ONVIFClient, log: Log) {
        self.client = client
        self.log = log
    }

    func capabilities() async throws -> PanTiltCapabilities {
        if let known { return known }
        let profiles = try await client.profiles()
        let (main, _) = ONVIFDriver.selectProfiles(profiles)
        guard let profile = [main].compactMap({ $0 }).first(where: \.ptzConfigured) ?? profiles.first(where: \.ptzConfigured) else {
            known = PanTiltCapabilities(panTilt: false, zoom: false)
            return known!
        }
        profileToken = profile.token
        var capabilities = PanTiltCapabilities(panTilt: true, zoom: false)
        if let nodes = try? await client.ptzNodes(), !nodes.isEmpty {
            capabilities = PanTiltCapabilities(panTilt: nodes.contains(where: \.continuousPanTilt), zoom: nodes.contains(where: \.continuousZoom))
        }
        known = capabilities
        log.info("ONVIF PTZ: \(capabilities.panTilt ? "pan and tilt" : "no pan and tilt")\(capabilities.zoom ? ", zoom" : "") (profile \(profile.token))")
        await logNightVisionOptions()
        return capabilities
    }

    /// What the camera offers for its IR lights (read only, logged once): the PTZ node's auxiliary commands and the imaging IR-cut modes.
    private func logNightVisionOptions() async {
        let aux = ((try? await client.ptzNodes()) ?? []).flatMap(\.auxiliaryCommands)
        var imaging = "unknown"
        if let source = try? await client.videoSourceTokens().first {
            let options = try? await client.imagingOptions(videoSourceToken: source)
            let current = try? await client.imagingSettings(videoSourceToken: source)
            imaging = "IR-cut modes \(options?.irCutFilterModes ?? []), now \(current?.irCutFilter ?? "?") (source \(source))"
        }
        log.info("ONVIF night vision: auxiliary commands \(aux.isEmpty ? "none" : aux.joined(separator: ", ")); \(imaging)")
    }

    func move(pan: Double, tilt: Double) async throws {
        guard pan != 0 || tilt != 0 else { return }
        try await stepping(pan: pan * Self.speed * 2, tilt: tilt * Self.speed * 2, zoom: nil)
    }

    func zoom(_ speed: Double) async throws {
        guard speed != 0 else { return }
        try await stepping(pan: nil, tilt: nil, zoom: speed > 0 ? Self.speed : -Self.speed)
    }

    func stop() async throws {
        await steps.dropWaiting()   // a step still waiting never starts: the button was let go
        guard let profileToken else { return }
        try await Self.sendStop(client, profileToken: profileToken)
    }

    private func stepping(pan: Double?, tilt: Double?, zoom: Double?) async throws {
        _ = try await capabilities()
        guard let profileToken else { throw CameraAdapterError.unsupported("this camera has no PTZ profile") }
        try await steps.run { try await self.step(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom) }
    }

    private func step(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?) async throws {
        do {
            try await move(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom)
        } catch {
            // A move the camera may have acted on (its answer was lost or unreadable) is stopped all the same; a refusal moved nothing.
            if !PanTiltSteps.isRefusal(error) { try? await Self.sendStop(client, profileToken: profileToken) }
            throw error
        }
        try? await Task.sleep(for: Self.step)
        try await Self.sendStop(client, profileToken: profileToken)
    }

    private func move(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?) async throws {
        do {
            try await client.continuousMove(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom, timeout: !noTimeout)
        } catch CameraAdapterError.soapFault(let fault) where !noTimeout {
            // A camera that refuses the `Timeout` (some take none, or only another range) is asked without it, now and from now on.
            log.info("ONVIF PTZ: the camera refused a move with a timeout (\(fault)); moving without it")
            noTimeout = true
            try await client.continuousMove(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom, timeout: false)
        }
    }

    /// `Stop`, as `PanTiltSteps.stop` sends one.
    private static func sendStop(_ client: ONVIFClient, profileToken: String) async throws {
        try await PanTiltSteps.stop { try await client.stopPTZ(profileToken: profileToken) }
    }
}
