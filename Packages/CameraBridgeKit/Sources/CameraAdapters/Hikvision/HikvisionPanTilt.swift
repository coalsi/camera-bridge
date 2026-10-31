import BridgeSupport
import Foundation

/// Pan, tilt and zoom of a Hikvision (or ANNKE) PTZ camera through ISAPI's `PTZCtrl` (2026-10-31): the wizard adds Hikvision's family
/// through ISAPI, and Hikvision ships with ONVIF off, so ONVIF's PTZ is no way in. In steps, as ONVIF's are (`ONVIFPanTilt`): every move is
/// `continuous` at half speed for `step`, then a stop (all zero); a stop follows a move whose answer was lost, and is sent once more when it
/// got none itself; steps never overlap and only one waits (`PanTiltSteps`). Logins go through Camera Bridge's pause after a refused one
/// (`ONVIFLoginGuard`, the camera's one account): a refused login is never repeated by tapping the pad.
actor HikvisionPanTilt: PanTiltControl {
    static let step: Duration = .milliseconds(400)
    /// Of ISAPI's -100…100.
    static let speed = 50

    private let isapi: HikvisionISAPI
    private let channel: Int
    /// The key `ONVIFLoginGuard` uses for this camera ("host:port" of its ISAPI).
    private let loginHost: String
    private let log: Log
    private var known: PanTiltCapabilities?
    private let steps = PanTiltSteps()

    init(isapi: HikvisionISAPI, channel: Int, loginHost: String, log: Log) {
        self.isapi = isapi
        self.channel = channel
        self.loginHost = loginHost
        self.log = log
    }

    private var capabilitiesPath: String { "/ISAPI/PTZCtrl/channels/\(channel)/capabilities" }
    private var continuousPath: String { "/ISAPI/PTZCtrl/channels/\(channel)/continuous" }

    /// What the channel's PTZ can do (`capabilities`: continuous pan/tilt and zoom spaces). A camera that answers 4xx has no PTZ; one that
    /// refuses the login is not asked again until it starts again (the runtime asks again and again for an hour, and each would be a failed
    /// login on the camera's lockout count).
    func capabilities() async throws -> PanTiltCapabilities {
        if let known { return known }
        if let pause = ONVIFLoginGuard.shared.pause(host: loginHost) { throw pause.error }
        let answer: PanTiltCapabilities
        do {
            let document = try await isapi.xml(capabilitiesPath)
            answer = PanTiltCapabilities(panTilt: document.firstDescendant("ContinuousPanTiltSpace") != nil,
                                         zoom: document.firstDescendant("ContinuousZoomSpace") != nil)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            ONVIFLoginGuard.shared.recordRejection(host: loginHost)
            answer = PanTiltCapabilities(panTilt: false, zoom: false)
            log.info("Hikvision PTZ: the camera refused the login; no pan and tilt until it starts again")
        } catch CameraAdapterError.httpStatus(let status) where (400..<500).contains(status) {
            answer = PanTiltCapabilities(panTilt: false, zoom: false)
        } catch CameraAdapterError.notPermitted {
            answer = PanTiltCapabilities(panTilt: false, zoom: false)
        }
        known = answer
        if answer.panTilt || answer.zoom {
            log.info("Hikvision PTZ: \(answer.panTilt ? "pan and tilt" : "no pan and tilt")\(answer.zoom ? ", zoom" : "") (channel \(channel))")
        }
        return answer
    }

    func move(pan: Double, tilt: Double) async throws {
        guard pan != 0 || tilt != 0 else { return }
        try await stepping(pan: Self.value(pan), tilt: Self.value(tilt), zoom: nil)
    }

    func zoom(_ speed: Double) async throws {
        guard speed != 0 else { return }
        try await stepping(pan: nil, tilt: nil, zoom: speed > 0 ? Self.speed : -Self.speed)
    }

    func stop() async throws {
        await steps.dropWaiting()   // a step still waiting never starts: the button was let go
        guard known?.panTilt == true || known?.zoom == true else { return }
        try await sendStop()
    }

    /// -1…1 as ISAPI's speed, at most `speed` either way.
    private static func value(_ amount: Double) -> Int {
        Int((min(max(amount, -1), 1) * Double(speed)).rounded())
    }

    private func stepping(pan: Int?, tilt: Int?, zoom: Int?) async throws {
        let can = try await capabilities()
        guard zoom == nil ? can.panTilt : can.zoom else { throw CameraAdapterError.unsupported("this camera has no PTZ") }
        try await steps.run { try await self.step(pan: pan, tilt: tilt, zoom: zoom) }
    }

    private func step(pan: Int?, tilt: Int?, zoom: Int?) async throws {
        do {
            try await send(pan: pan, tilt: tilt, zoom: zoom)
        } catch {
            // A move the camera may have acted on (its answer was lost or unreadable) is stopped all the same; a refusal moved nothing.
            if !PanTiltSteps.isRefusal(error) { try? await sendStop() }
            throw error
        }
        try? await Task.sleep(for: Self.step)
        try await sendStop()
    }

    private func sendStop() async throws {
        let isapi = isapi, path = continuousPath
        try await PanTiltSteps.stop { _ = try await isapi.put(path, body: Self.body(pan: 0, tilt: 0, zoom: 0)) }
    }

    private func send(pan: Int?, tilt: Int?, zoom: Int?) async throws {
        if let pause = ONVIFLoginGuard.shared.pause(host: loginHost) { throw pause.error }
        do {
            _ = try await isapi.put(continuousPath, body: Self.body(pan: pan, tilt: tilt, zoom: zoom))
        } catch let error as CameraAdapterError where error == .unauthorized {
            ONVIFLoginGuard.shared.recordRejection(host: loginHost)
            throw error
        }
    }

    /// A `PTZData` document with the axes asked for (some cameras refuse a zoom value when they have no zoom).
    static func body(pan: Int?, tilt: Int?, zoom: Int?) -> Data {
        var axes = ""
        if pan != nil || tilt != nil { axes += "<pan>\(pan ?? 0)</pan><tilt>\(tilt ?? 0)</tilt>" }
        if let zoom { axes += "<zoom>\(zoom)</zoom>" }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><PTZData version=\"2.0\" xmlns=\"http://www.isapi.org/ver20/XMLSchema\">"
            + axes + "</PTZData>").utf8)
    }
}
