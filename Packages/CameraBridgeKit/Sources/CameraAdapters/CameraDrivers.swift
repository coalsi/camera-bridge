import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `CameraDrivers.detect` found: the vendor whose API answered and, for ONVIF, the device service's port when it
/// isn't the endpoint's HTTP port (store it as `CameraEndpoint.onvifPort`).
public struct VendorDetection: Sendable, Equatable {
    public var vendor: CameraVendor
    public var onvifPort: Int?

    public init(vendor: CameraVendor, onvifPort: Int? = nil) {
        self.vendor = vendor
        self.onvifPort = onvifPort
    }
}

public enum CameraDrivers {
    /// The driver for `vendor`. `transport` carries RTSP (probing, ONVIF backchannel) and Hikvision talkback TCP.
    public static func make(vendor: CameraVendor, endpoint: CameraEndpoint, credentials: HTTPCredentials?,
                            mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport) -> any CameraDriver {
        make(vendor: vendor, endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL,
             transport: transport, cameraID: nil)
    }

    /// As `make(vendor:endpoint:credentials:mainStreamURL:subStreamURL:transport:)`, for the configured camera `cameraID`:
    /// everything the driver builds — event sources (and Hikvision's shared alertStream, for each camera on it), camera
    /// API clients, RTSP probes and talkback sinks with their RTSP sessions — logs with the camera's ID
    /// (`LogEntry.cameraID`), so the camera's log shows its event channel, API and two-way audio lines.
    ///
    /// `reachability`: the camera's shared view of whether it answers at all. A Reolink driver sends nothing to a camera
    /// known to be unreachable and serializes its requests; the other drivers do not use it yet.
    ///
    /// `integration` and `go2rtc`: for the cameras that sit behind a service (`CameraVendor.go2rtc`): the facts saved about the
    /// service and the helper that turns its source into RTSP. The service's secret travels as the camera's `credentials` password.
    public static func make(vendor: CameraVendor, endpoint: CameraEndpoint, credentials: HTTPCredentials?,
                            mainStreamURL: URL?, subStreamURL: URL?, transport: any NetworkTransport, cameraID: UUID?,
                            reachability: CameraReachability? = nil, integration: IntegrationSettings? = nil,
                            go2rtc: (any Go2RTCStreamProviding)? = nil) -> any CameraDriver {
        switch vendor {
        case .hikvision:
            HikvisionDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, transport: transport,
                            cameraID: cameraID)
        case .reolink:
            ReolinkDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, transport: transport,
                          cameraID: cameraID, reachability: reachability)
        case .onvif:
            ONVIFDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, transport: transport,
                        cameraID: cameraID)
        case .rtsp:
            GenericRTSPDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL,
                              transport: transport, cameraID: cameraID)
        case .amcrest:
            AmcrestDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL, transport: transport,
                          cameraID: cameraID)
        case .doorbird:
            DoorBirdDriver(endpoint: endpoint, credentials: credentials, mainStreamURL: mainStreamURL, transport: transport, cameraID: cameraID)
        case .unifi:
            UnifiProtectDriver(endpoint: endpoint, credentials: credentials, settings: integration, provider: go2rtc,
                               rtspFactory: RTSPProbing.factory(transport: transport), cameraID: cameraID)
        case .go2rtc:
            Go2RTCDriver(cameraID: cameraID, settings: integration, credentials: credentials, provider: go2rtc,
                         rtspFactory: RTSPProbing.factory(transport: transport))
        case .demo:
            DemoCameraDriver()
        }
    }

    /// The cameras of a UniFi Protect console, from its official API with `apiKey` (the wizard's list). Throws
    /// `CameraAdapterError.unauthorized` for a key the console rejects.
    public static func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] {
        try await UnifiProtectAPI.listCameras(endpoint: endpoint, apiKey: apiKey)
    }

    /// Tries Hikvision ISAPI, Reolink API, then ONVIF; nil if none answer. (`detect` also reports the ONVIF port.)
    ///
    /// - Hikvision: `/ISAPI/System/deviceInfo` answers 401 with a Digest realm naming Hikvision (`hikvision`, `DS-…`), or
    ///   (with credentials) 200 with an ISAPI `DeviceInfo` document (`hikvision.com` / `isapi.org` namespace).
    /// - Reolink: `/api.cgi?cmd=GetDevInfo` answers with the API's JSON array (even "please login first").
    /// - ONVIF: an unauthenticated `GetSystemDateAndTime` succeeds on the ONVIF port (else the HTTP port, 8000, 8080, 2020).
    public static func detectVendor(endpoint: CameraEndpoint, credentials: HTTPCredentials?) async -> CameraVendor? {
        await detect(endpoint: endpoint, credentials: credentials)?.vendor
    }

    /// `detectVendor`, plus the port ONVIF's device service answered on when that isn't the endpoint's HTTP port: many
    /// ONVIF cameras serve it on 8000, 8080 or 2020 (Tapo), and the driver then needs `CameraEndpoint.onvifPort`.
    public static func detect(endpoint: CameraEndpoint, credentials: HTTPCredentials?) async -> VendorDetection? {
        await detect(endpoint: endpoint, credentials: credentials, fallbackONVIFPorts: defaultONVIFPorts)
    }

    /// The port of the camera's ONVIF device service: the configured ONVIF port (else the HTTP port) when it answers,
    /// else the first of 8000, 8080, 2020 that does. nil when that is the HTTP port (no `onvifPort` needed) or when
    /// nothing answers. For an ONVIF camera whose `onvifPort` isn't known (the person chose ONVIF themselves).
    public static func onvifPort(endpoint: CameraEndpoint) async -> Int? {
        await onvifPort(endpoint: endpoint, fallbackONVIFPorts: defaultONVIFPorts)
    }

    /// Where ONVIF devices commonly serve their device service besides the HTTP port.
    static let defaultONVIFPorts = [8000, 8080, 2020]

    /// The ISAPI channel ID (`"<n>01"` main, `"<n>02"` sub) a Hikvision camera's configured `mainStreamURL` names —
    /// `1` when the URL has no explicit ISAPI channel (a plain camera, not an NVR channel). For the HomeKit optimizer,
    /// which needs the same channel Hikvision's own driver uses to read/disable the smart codec over ISAPI.
    public static func hikvisionChannelID(mainStreamURL: URL?, sub: Bool) -> String {
        "\(HikvisionDriver.cameraNumber(from: mainStreamURL))\(sub ? "02" : "01")"
    }

    static func detectVendor(endpoint: CameraEndpoint, credentials: HTTPCredentials?, fallbackONVIFPorts: [Int],
                             timeout: Duration = .seconds(4)) async -> CameraVendor? {
        await detect(endpoint: endpoint, credentials: credentials, fallbackONVIFPorts: fallbackONVIFPorts, timeout: timeout)?.vendor
    }

    /// All checks run concurrently (so an unreachable host costs one timeout, not six); the answer follows the
    /// precedence Hikvision → Reolink → ONVIF, and the ONVIF port the order of `onvifPorts(for:fallback:)`.
    static func detect(endpoint: CameraEndpoint, credentials: HTTPCredentials?, fallbackONVIFPorts: [Int],
                       timeout: Duration = .seconds(4)) async -> VendorDetection? {
        let ports = onvifPorts(for: endpoint, fallback: fallbackONVIFPorts)
        let (vendors, answeredONVIFPorts) = await withTaskGroup(of: (CameraVendor, Int?)?.self) { group -> (Set<CameraVendor>, Set<Int>) in
            // Hard bounds on top of the request timeouts (the Hikvision check may make two requests).
            group.addTask {
                let hit = try? await withTimeout(timeout * 2 + .milliseconds(500)) {
                    await isHikvision(endpoint: endpoint, credentials: credentials, timeout: timeout)
                }
                return hit == true ? (.hikvision, nil) : nil
            }
            group.addTask {
                let hit = try? await withTimeout(timeout + .milliseconds(500)) { await isReolink(endpoint: endpoint, timeout: timeout) }
                return hit == true ? (.reolink, nil) : nil
            }
            for port in ports {
                group.addTask { await isONVIF(endpoint: endpoint, port: port, timeout: timeout) ? (.onvif, port) : nil }
            }
            var vendors: Set<CameraVendor> = []
            var answered: Set<Int> = []
            for await hit in group {
                guard let (vendor, port) = hit else { continue }
                vendors.insert(vendor)
                if let port { answered.insert(port) }
            }
            return (vendors, answered)
        }
        let vendor = [CameraVendor.hikvision, .reolink, .onvif].first { vendors.contains($0) }
        var onvifPort: Int?
        if vendor == .onvif, let port = ports.first(where: { answeredONVIFPorts.contains($0) }), port != endpoint.httpPort {
            onvifPort = port
        }
        let answer = vendor.map { "\($0.rawValue) API" + (onvifPort.map { " on port \($0)" } ?? "") } ?? "no supported camera API"
        Log(category: "detect").info("\(endpoint.host): \(answer) answered")
        return vendor.map { VendorDetection(vendor: $0, onvifPort: onvifPort) }
    }

    static func onvifPort(endpoint: CameraEndpoint, fallbackONVIFPorts: [Int], timeout: Duration = .seconds(4)) async -> Int? {
        let ports = onvifPorts(for: endpoint, fallback: fallbackONVIFPorts)
        let answered = await withTaskGroup(of: Int?.self) { group -> Set<Int> in
            for port in ports {
                group.addTask { await isONVIF(endpoint: endpoint, port: port, timeout: timeout) ? port : nil }
            }
            var answered: Set<Int> = []
            for await port in group { if let port { answered.insert(port) } }
            return answered
        }
        guard let port = ports.first(where: { answered.contains($0) }), port != endpoint.httpPort else { return nil }
        return port
    }

    /// The configured ONVIF port (else the HTTP port) first, then `fallback`, without repeats.
    static func onvifPorts(for endpoint: CameraEndpoint, fallback: [Int]) -> [Int] {
        var ports: [Int] = []
        for port in [endpoint.onvifPort ?? endpoint.httpPort] + fallback where !ports.contains(port) { ports.append(port) }
        return ports
    }

    static func isONVIF(endpoint: CameraEndpoint, port: Int, timeout: Duration) async -> Bool {
        var candidate = endpoint
        candidate.onvifPort = port
        guard let url = ONVIFClient.deviceServiceURL(for: candidate) else { return false }
        let client = ONVIFClient(deviceServiceURL: url, credentials: nil, timeout: timeout)
        do {
            _ = try await withTimeout(timeout + .milliseconds(500)) { try await client.systemDateAndTime() }
            return true
        } catch {
            return false
        }
    }

    static func isHikvision(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timeout: Duration) async -> Bool {
        guard let url = endpoint.httpURL(path: "/ISAPI/System/deviceInfo") else { return false }
        let anonymous = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        defer { anonymous.invalidate() }
        guard let (data, response) = try? await anonymous.data(for: URLRequest(url: url)) else { return false }
        switch response.statusCode {
        case 200:
            return isISAPIDeviceInfo(data)
        case 401:
            let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            let realm = DigestChallenge.parse(challenge)?.realm ?? ""
            if realm.localizedCaseInsensitiveContains("hikvision") || realm.uppercased().hasPrefix("DS-") { return true }
            guard let credentials else { return false }
            let authenticated = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout)
            defer { authenticated.invalidate() }
            guard let (body, authResponse) = try? await authenticated.data(for: URLRequest(url: url)), authResponse.statusCode == 200 else {
                return false
            }
            return isISAPIDeviceInfo(body)
        default:
            return false
        }
    }

    static func isISAPIDeviceInfo(_ data: Data) -> Bool {
        guard let tree = try? XMLTree.parse(data), tree.matches("DeviceInfo") else { return false }
        let namespace = tree.namespaceURI?.lowercased() ?? ""
        return namespace.contains("hikvision.com") || namespace.contains("isapi.org")
    }

    static func isReolink(endpoint: CameraEndpoint, timeout: Duration) async -> Bool {
        guard let url = endpoint.httpURL(path: "/api.cgi", query: [URLQueryItem(name: "cmd", value: "GetDevInfo")]) else { return false }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        defer { client.invalidate() }
        guard let (data, _) = try? await client.data(for: URLRequest(url: url)), let json = try? JSONValue.parse(data) else { return false }
        return json[0]?["cmd"]?.string != nil
    }
}
