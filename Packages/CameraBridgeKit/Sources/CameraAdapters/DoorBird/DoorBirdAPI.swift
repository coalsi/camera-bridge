import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// DoorBird's LAN API (revision 0.36, https://www.doorbird.com/api). DoorBird grants a licence to build integrations on it; the
// facts here (endpoints, the event monitor's `doorbell:H` lines, the permissions and limits) come from that public document.

/// DoorBird's RTSP address: `rtsp://<device>/mpeg/media.amp`; newer firmware also serves `/mpeg/720p/media.amp`.
public enum DoorBirdRTSP {
    public static let path = "/mpeg/media.amp"
    public static let hdPath = "/mpeg/720p/media.amp"
}

struct DoorBirdInfo: Sendable, Equatable {
    var deviceType: String
    var firmware: String
    var build: String
    var macAddress: String
    var relays: [String]

    /// `{"BHA":{"RETURNCODE":"1","VERSION":[{"FIRMWARE":"000109","BUILD_NUMBER":"15120529","PRIMARY_MAC_ADDR":"1CCAE3700000","RELAYS":["1","2"],
    /// "DEVICE-TYPE":"DoorBird D101"}]}}`. Older firmware answers only the firmware and build number.
    static func parse(_ data: Data) throws -> DoorBirdInfo {
        guard let json = try? JSONValue.parse(data), let bha = json["BHA"] else {
            throw CameraAdapterError.invalidResponse("not a DoorBird answer")
        }
        guard bha["RETURNCODE"]?.string == "1" else {
            throw CameraAdapterError.invalidResponse("the DoorBird refused the request (code \(bha["RETURNCODE"]?.string ?? "?"))")
        }
        guard let version = bha["VERSION"]?[0] else { throw CameraAdapterError.invalidResponse("the DoorBird sent no version") }
        var relays: [String] = []
        if case .array(let list)? = version["RELAYS"] { relays = list.compactMap(\.string) }
        return DoorBirdInfo(deviceType: version["DEVICE-TYPE"]?.string ?? "DoorBird", firmware: version["FIRMWARE"]?.string ?? "",
                            build: version["BUILD_NUMBER"]?.string ?? "", macAddress: version["PRIMARY_MAC_ADDR"]?.string ?? "", relays: relays)
    }
}

/// The event monitor's lines: `doorbell:H` (pressed), `doorbell:L` (released), `motionsensor:H` / `:L`.
enum DoorBirdMonitorLine: Sendable, Equatable {
    case doorbell(active: Bool)
    case motion(active: Bool)

    static func parse(_ line: String) -> DoorBirdMonitorLine? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let active: Bool
        switch parts[1].trimmingCharacters(in: .whitespaces).uppercased() {
        case "H": active = true
        case "L": active = false
        default: return nil
        }
        switch parts[0].trimmingCharacters(in: .whitespaces).lowercased() {
        case "doorbell": return .doorbell(active: active)
        case "motionsensor": return .motion(active: active)
        default: return nil
        }
    }
}

/// Splits the monitor's bytes into lines, ignoring the multipart framing (`--ioboundary`, `Content-Type: text/plain`, blank lines).
struct DoorBirdMonitorParser: Sendable {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [DoorBirdMonitorLine] {
        buffer.append(chunk)
        var lines: [DoorBirdMonitorLine] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let line = DoorBirdMonitorLine.parse(text) { lines.append(line) }
        }
        if buffer.count > 64 * 1024 { buffer = Data() }
        return lines
    }
}

/// DoorBird over HTTP with the app user's credentials (Basic or Digest). The device allows one connection per second and blocks the
/// address for a minute after wrong credentials (HTTP 423): a rejected login pauses logins to it (`ONVIFLoginGuard`, two minutes).
struct DoorBirdAPI: Sendable {
    let endpoint: CameraEndpoint
    private let http: AuthenticatingHTTPClient
    private let hasCredentials: Bool

    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.http = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout)
        self.hasCredentials = credentials != nil
    }

    func invalidate() {
        http.invalidate()
    }

    static func loginKey(_ endpoint: CameraEndpoint) -> String { "\(endpoint.host):\(endpoint.httpPort)" }

    /// The status → error mapping every call shares: 401 wrong credentials, 423 blocked for a minute, 204 no permission.
    static func check(_ response: HTTPURLResponse, key: String, hasCredentials: Bool, now: Date = Date()) throws {
        try check(status: response.statusCode, key: key, hasCredentials: hasCredentials, now: now)
    }

    static func check(status: Int, key: String, hasCredentials: Bool, now: Date = Date()) throws {
        switch status {
        case 200..<204, 205..<300: return
        case 204: throw CameraAdapterError.unsupported("the DoorBird user has no permission for this (give it “Watch always”)")
        case 401:
            if hasCredentials { ONVIFLoginGuard.shared.recordRejection(host: key, now: now) }
            throw CameraAdapterError.unauthorized
        case 423:
            ONVIFLoginGuard.shared.recordRejection(host: key, now: now)
            throw CameraAdapterError.lockedOut(until: now.addingTimeInterval(ONVIFLoginGuard.rejectionPause))
        default: throw CameraAdapterError.httpStatus(status)
        }
    }

    private func get(_ path: String) async throws -> Data {
        let key = Self.loginKey(endpoint)
        if hasCredentials, let until = ONVIFLoginGuard.shared.blockedUntil(host: key) { throw CameraAdapterError.lockedOut(until: until) }
        guard let url = endpoint.httpURL(path: path) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.data(for: URLRequest(url: url))
        } catch {
            throw CameraHTTP.sanitized(error)
        }
        try Self.check(response, key: key, hasCredentials: hasCredentials)
        return data
    }

    func info() async throws -> DoorBirdInfo {
        try DoorBirdInfo.parse(try await get("/bha-api/info.cgi"))
    }

    /// The live image. The DoorBird answers 204 when the user may not watch and nobody rang lately: that is `unsupported`.
    func snapshot() async throws -> Data {
        let data = try await get("/bha-api/image.cgi")
        guard CameraHTTP.looksLikeJPEG(data) else { throw CameraAdapterError.invalidResponse("not a JPEG") }
        return data
    }

    /// The event monitor: one long response with `doorbell:H` / `motionsensor:H` lines (the device allows eight at a time), read as it
    /// arrives (`RawHTTPStream`).
    static func monitor(endpoint: CameraEndpoint, credentials: HTTPCredentials?, readTimeout: Duration, transport: any NetworkTransport) async throws
        -> RawHTTPStream.Opened {
        try await RawHTTPStream.openEventStream(endpoint: endpoint, target: "/bha-api/monitor.cgi?ring=doorbell,motionsensor", credentials: credentials,
                                                transport: transport, readTimeout: readTimeout)
    }
}
