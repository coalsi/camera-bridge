import BridgeSupport
import Foundation

/// What a camera's PTZ node supports (`GetNodes`): continuous pan/tilt and continuous zoom.
struct ONVIFPTZNode: Sendable, Equatable {
    var continuousPanTilt: Bool
    var continuousZoom: Bool
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
                                continuousZoom: spaces?.child("ContinuousZoomVelocitySpace") != nil)
        }
    }

    /// `ContinuousMove` at a velocity (-1…1; pan right, tilt up and zoom in positive). Only the axes asked for are sent: some cameras
    /// refuse a zoom velocity when they have no zoom.
    func continuousMove(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?) async throws {
        _ = try await call(await ptzServiceURL(), body: Self.continuousMoveBody(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom),
                       action: "\(Self.ptzNamespace)/ContinuousMove")
    }

    static func continuousMoveBody(profileToken: String, pan: Double?, tilt: Double?, zoom: Double?) -> String {
        func number(_ value: Double) -> String { String(format: "%.2f", min(max(value, -1), 1)) }
        var velocity = ""
        if pan != nil || tilt != nil { velocity += "<tt:PanTilt x=\"\(number(pan ?? 0))\" y=\"\(number(tilt ?? 0))\"/>" }
        if let zoom { velocity += "<tt:Zoom x=\"\(number(zoom))\"/>" }
        return "<tptz:ContinuousMove xmlns:tptz=\"\(ptzNamespace)\"><tptz:ProfileToken>\(XMLTree.escape(profileToken))</tptz:ProfileToken>"
            + "<tptz:Velocity>\(velocity)</tptz:Velocity></tptz:ContinuousMove>"
    }

    /// `Stop` of pan/tilt and zoom.
    func stopPTZ(profileToken: String) async throws {
        let body = "<tptz:Stop xmlns:tptz=\"\(Self.ptzNamespace)\"><tptz:ProfileToken>\(XMLTree.escape(profileToken))</tptz:ProfileToken>"
            + "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>"
        _ = try await call(await ptzServiceURL(), body: body, action: "\(Self.ptzNamespace)/Stop")
    }
}

/// Pan, tilt and zoom of an ONVIF camera in steps: every move is `ContinuousMove` for `step`, then `Stop`, so one tap turns the camera a
/// little and nothing leaves it turning (a camera on a cable must not spin). Steps never overlap: a move that comes while one runs waits
/// for it; the bridge repeats a move while a button is held.
actor ONVIFPanTilt: PanTiltControl {
    static let step: Duration = .milliseconds(400)
    static let speed = 0.5

    private let client: ONVIFClient
    private let log: Log
    private var profileToken: String?
    private var known: PanTiltCapabilities?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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
        return capabilities
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
        guard let profileToken else { return }
        try await client.stopPTZ(profileToken: profileToken)
    }

    private func stepping(pan: Double?, tilt: Double?, zoom: Double?) async throws {
        _ = try await capabilities()
        guard let profileToken else { throw CameraAdapterError.unsupported("this camera has no PTZ profile") }
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        try await client.continuousMove(profileToken: profileToken, pan: pan, tilt: tilt, zoom: zoom)
        try? await Task.sleep(for: Self.step)
        // Stopped whatever happens to the wait: a cancelled request must not leave the camera turning.
        try await client.stopPTZ(profileToken: profileToken)
    }
}
