import BridgeSupport
import Foundation

// The security check's readings (`readRemoteAccess`): what each camera family says about its ways out, read only (a check never writes).
// The cloud and UPnP come from the same readings as "Set up for Camera Bridge"'s steps (`featureLookup`, `ipcWebCloud(in:)`, the IPCamera
// Web family's `mobile`), so the two never disagree. A camera that refuses the login, or stops answering, is asked nothing more during the
// check: every reading left is unknown (no repeated failed logins, no waiting for a camera that is gone); one that stopped answering says so
// (`remoteAccessUnanswered`), so the engine keeps its last readings and tries again soon. Whether a cloud is linked to an account is read
// only where the camera says so: a cloud's online or signed-in status is not its binding (a bound camera can be offline).

extension CameraSettingsService {
    /// The services' names, as the findings and the page show them.
    static let hikConnectName = "Hik-Connect"
    static let reolinkP2PName = "Reolink P2P"
    static let hikvisionDDNSPath = "/ISAPI/System/Network/DDNS"

    /// What the camera says about its ways to be reached from outside the home: Hikvision (Hik-Connect, UPnP, DDNS where the camera has it;
    /// absent only where its capabilities say so), Reolink (`GetP2p`, `GetUpnp`, `GetDdns`; a refused command is unknown), an ONVIF camera
    /// of the IP camera web API (`P2PConfig` and `UPNPConfig`; RTMP unknown) or of the IPCamera Web family (`ipcamWebRemoteAccess`). Any
    /// other camera: its cloud is unknown. Video without a password is the RTSP check's (`RTSPAccessProbe`), except where the camera's own
    /// API says it. Throws only `CancellationError`.
    public func readRemoteAccess() async throws -> [RemoteAccessFinding] {
        remoteAccessUnanswered = false
        switch vendor {
        case .hikvision: return try await hikvisionRemoteAccess()
        case .reolink: return try await reolinkRemoteAccess()
        case .onvif: return try await onvifRemoteAccess()
        default: return [.cloudUnknown]
        }
    }

    /// Whether `error` is the camera's own answer (it is reachable and logged in): reading goes on. A login refusal, a transport failure
    /// or anything else stops the check's reading.
    static func cameraAnswered(_ error: any Error) -> Bool {
        if error is ISAPIRefusal || error is IPCamWebCameraError { return true }
        guard let error = error as? CameraAdapterError else { return false }
        switch error {
        case .httpStatus, .invalidResponse, .soapFault, .apiError, .unsupported: return true
        case .unauthorized, .lockedOut: return false
        }
    }

    /// Whether `error` says the camera did not answer at all (a transport failure, a timeout, a web server that is silent), not that it
    /// refused the login.
    static func cameraSilent(_ error: any Error) -> Bool {
        if cameraAnswered(error) || error is IPCamWebUnavailable { return false }
        if let error = error as? CameraAdapterError { return !error.isLoginRefusal }
        if let error = error as? IPCWebUnavailable { return error == .noAnswer }
        return true
    }

    /// `work`'s answer; nil when it failed (unknown), and once `stopped`, nothing is asked (a failure that is not the camera's own answer
    /// sets it, and `remoteAccessUnanswered` when the camera was silent). Throws only `CancellationError`.
    func attempt<T: Sendable>(_ stopped: inout Bool, _ work: () async throws -> T) async throws -> T? {
        guard !stopped else { return nil }
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Self.cameraAnswered(error) {
                stopped = true
                if Self.cameraSilent(error) { remoteAccessUnanswered = true }
            }
            return nil
        }
    }

    // MARK: Hikvision

    private func hikvisionRemoteAccess() async throws -> [RemoteAccessFinding] {
        var cloud = RemoteAccessFinding(feature: .cloud, state: .unknown, service: Self.hikConnectName)
        var upnp = RemoteAccessFinding(feature: .upnp, state: .unknown)
        var ddns = RemoteAccessFinding(feature: .ddns, state: .unknown)
        var stopped = false
        // registerStatus is whether the camera is signed in to Hik-Connect's servers now, not whether it is bound to an account: not read.
        cloud = try await hikvisionFeature(.cloud, cloud, &stopped)
        upnp = try await hikvisionFeature(.upnp, upnp, &stopped)
        if let found = try await attempt(&stopped, { try await isapi().document(Self.hikvisionDDNSPath) }) {
            ddns.state = found.map { Self.featureEnabled($0).map { $0 ? .on : .off } ?? .unknown } ?? .absent
        }
        return [cloud, upnp, ddns]
    }

    /// A Hikvision feature as `finding` with its state read: absent only where the camera's capabilities say it has none, unknown where
    /// nothing could be read (its path moved, another document, no answer).
    private func hikvisionFeature(_ feature: CameraNetworkFeature, _ finding: RemoteAccessFinding, _ stopped: inout Bool) async throws -> RemoteAccessFinding {
        var finding = finding
        switch try await attempt(&stopped, { try await featureLookup(feature) }) {
        case .found(_, let document)?:
            finding.state = Self.featureEnabled(document) == true ? .on : .off
            finding.canChange = true
        case .absent?: finding.state = .absent
        case .unreadable?, nil: break
        }
        return finding
    }

    // MARK: Reolink

    private func reolinkRemoteAccess() async throws -> [RemoteAccessFinding] {
        let api = ReolinkAPI(endpoint: endpoint, credentials: credentials, channel: reolinkChannel, cameraID: cameraID)
        defer { Task { await api.logout() } }
        var stopped = false
        var states: [RemoteAccessState] = []
        for (command, key) in [("GetP2p", "P2p"), ("GetUpnp", "Upnp"), ("GetDdns", "Ddns")] {
            let value = try await attempt(&stopped) { try await api.command(command)[key]?.object?["enable"]?.int }
            states.append((value ?? nil).map { $0 != 0 ? .on : .off } ?? .unknown)
        }
        return [RemoteAccessFinding(feature: .cloud, state: states[0], service: Self.reolinkP2PName),
                RemoteAccessFinding(feature: .upnp, state: states[1]),
                RemoteAccessFinding(feature: .ddns, state: states[2])]
    }

    // MARK: ONVIF cameras with a web API of their own

    private func onvifRemoteAccess() async throws -> [RemoteAccessFinding] {
        let ipcWebAccess: IPCWebAccess
        do {
            ipcWebAccess = try await ipcWeb()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A login refusal (the camera of the family can't be asked now), or a camera that did not answer.
            if Self.cameraSilent(error) { remoteAccessUnanswered = true }
            return [.cloudUnknown, RemoteAccessFinding(feature: .upnp, state: .unknown), RemoteAccessFinding(feature: .rtmp, state: .unknown)]
        }
        switch ipcWebAccess {
        case .speaks(let client, let device): return try await ipcWebRemoteAccess(client, device: device)
        case .unavailable: return [.cloudUnknown, RemoteAccessFinding(feature: .upnp, state: .unknown), RemoteAccessFinding(feature: .rtmp, state: .unknown)]
        case .none: break
        }
        switch try await ipcamWeb() {
        case .speaks(let client): return try await ipcamWebRemoteAccess(client)
        case .unavailable: return [RemoteAccessFinding(feature: .cloud, state: .unknown, service: "VisionEye cloud")]
        case .none: return [.cloudUnknown]
        }
    }

    /// The IP camera web API (`IPCWeb/`): only calls the client already makes and that were checked by hand on a real camera, since any
    /// refused call pauses the camera's web API (and with it night vision) until the camera restarts in the bridge. So RTMP
    /// (`getMediaStreamConfig`) is unknown, and the cloud's link too (`getNetworkStatus`'s `LoginStatus` is whether it is signed in now).
    private func ipcWebRemoteAccess(_ client: IPCWebClient, device: IPCWebDevice) async throws -> [RemoteAccessFinding] {
        var cloud = RemoteAccessFinding.cloudUnknown
        var upnp = RemoteAccessFinding(feature: .upnp, state: .unknown)
        let rtmp = RemoteAccessFinding(feature: .rtmp, state: .unknown)
        var stopped = false
        let network = try await attempt(&stopped) { try await client.read(Self.ipcNetworkRead, root: "NetworkConfig") }
        // A refused call paused the web API: nothing more is asked.
        if IPCWebLatch.shared.isTripped(IPCWebLatch.key(endpoint)) { stopped = true }
        if let network {
            if let p2p = Self.ipcWebCloud(in: network) {
                cloud.state = p2p.enabled != "0" ? .on : .off
                cloud.canChange = true
            } else {
                cloud.state = .absent
            }
            if let element = IPCWebXML.element("UPNPConfig", in: network) {
                upnp.state = IPCWebXML.attribute("Enable", of: element).map { $0 != "0" ? .on : .off } ?? .unknown
            } else {
                upnp.state = .absent
            }
        }
        return [cloud, upnp, rtmp]
    }
}
