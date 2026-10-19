import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where an Amcrest / Dahua camera serves its streams: `rtsp://host:554/cam/realmonitor?channel=1&subtype=0` (main) and
/// `subtype=1` (sub stream).
public enum AmcrestRTSP {
    public static func path(channel: Int, sub: Bool) -> String {
        "/cam/realmonitor?channel=\(max(1, channel))&subtype=\(sub ? 1 : 0)"
    }
}

/// What `magicBox.cgi` and a few other CGI calls told about the camera.
struct AmcrestDeviceInfo: Sendable, Equatable {
    var deviceType: String
    var serialNumber: String
    var firmware: String
    var machineName: String
    /// `getDeviceClass`: `VTO` for a Dahua door station, `NVR`, `IPC`.
    var deviceClass: String

    /// Doorbells: a door station (class `VTO`), or a model name that says so (Amcrest `AD…`, `DB6…`, Dahua `VTO…`, EmpireTech `DB2X`,
    /// `AV-V…`).
    var isDoorbell: Bool {
        if deviceClass.uppercased() == "VTO" { return true }
        let model = deviceType.uppercased()
        return ["VTO", "AD1", "AD2", "AD3", "AD4", "DB6", "DB2", "AV-V"].contains { model.hasPrefix($0) }
    }
}

/// Dahua's CGI over `AuthenticatingHTTPClient` (Digest; Basic when a device asks for it). Responses are `key=value` lines.
///
/// A rejected login pauses every login to the camera for two minutes (`ONVIFLoginGuard`, shared with ONVIF): a camera locks the
/// account after a few wrong passwords, and a locked account also blocks the stream.
struct AmcrestAPI: Sendable {
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

    /// The key the login guard uses for this camera.
    static func loginKey(_ endpoint: CameraEndpoint) -> String { "\(endpoint.host):\(endpoint.httpPort)" }

    /// `key=value` lines (table.Foo.Bar=1 for config calls) as a dictionary; blank and malformed lines are skipped.
    static func parseKeyValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// One GET, whatever the camera answers except a refused login (HTTP 401: `.unauthorized`, and logins to the camera pause,
    /// `ONVIFLoginGuard`). While logins are paused nothing is sent.
    private func exchange(_ path: String, query: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        let key = Self.loginKey(endpoint)
        if hasCredentials, let pause = ONVIFLoginGuard.shared.pause(host: key) { throw pause.error }
        guard let url = endpoint.httpURL(path: path, query: query) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: CameraHTTP.request(url))
        } catch {
            throw CameraHTTP.sanitized(error)
        }
        if response.statusCode == 401 {
            if hasCredentials { ONVIFLoginGuard.shared.recordRejection(host: key) }
            throw CameraAdapterError.unauthorized
        }
        return (data, response)
    }

    /// The body of a 2xx answer; any other status is `.httpStatus`.
    private func get(_ path: String, query: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await exchange(path, query: query)
        guard (200..<300).contains(response.statusCode) else { throw CameraAdapterError.httpStatus(response.statusCode) }
        return (data, response)
    }

    /// The most of a configuration answer that is read as text: a camera's `Network` table is a few kilobytes. The client has already
    /// buffered the whole body (up to its own limit, `AuthenticatingHTTPClient.defaultMaximumBodySize`); only the string made from it, and
    /// so what is parsed, is capped.
    static let maximumConfigAnswer = 64 * 1024

    /// The answer's status and text (the first `maximumConfigAnswer` bytes of the body), whatever the status but a refused login: a camera
    /// says why in the body of a 400, and a page that is not Dahua's answers 200 or 404.
    func answer(_ path: String, query: [URLQueryItem]) async throws -> (status: Int, text: String) {
        let (data, response) = try await exchange(path, query: query)
        return (response.statusCode, String(decoding: data.prefix(Self.maximumConfigAnswer), as: UTF8.self))
    }

    private func values(_ action: String, in cgi: String = "magicBox") async throws -> [String: String] {
        let (data, _) = try await get("/cgi-bin/\(cgi).cgi", query: [URLQueryItem(name: "action", value: action)])
        return Self.parseKeyValues(String(decoding: data, as: UTF8.self))
    }

    func deviceInfo() async throws -> AmcrestDeviceInfo {
        // The first call decides whether the login works; the others are optional (older firmware lacks some).
        let system = try await values("getSystemInfo")
        var type = system["deviceType"] ?? ""
        if type.isEmpty { type = (try? await values("getDeviceType"))?["type"] ?? "" }
        var serial = system["serialNumber"] ?? ""
        if serial.isEmpty { serial = (try? await values("getSerialNo"))?["sn"] ?? "" }
        let version = (try? await values("getSoftwareVersion"))?["version"] ?? ""
        let name = (try? await values("getMachineName"))?["name"] ?? ""
        let deviceClass = (try? await values("getDeviceClass"))?["class"] ?? ""
        return AmcrestDeviceInfo(deviceType: type, serialNumber: serial, firmware: version.split(separator: ",").first.map(String.init) ?? version,
                                 machineName: name, deviceClass: deviceClass)
    }

    /// A JPEG from `snapshot.cgi` (some devices append a vendor block after the end-of-image marker; it is cut off).
    func snapshot(channel: Int = 1) async throws -> Data {
        let (data, _) = try await get("/cgi-bin/snapshot.cgi", query: [URLQueryItem(name: "channel", value: String(channel))])
        guard CameraHTTP.looksLikeJPEG(data) else { throw CameraAdapterError.invalidResponse("not a JPEG") }
        return Self.trimmedJPEG(data)
    }

    /// The bytes up to and including the last end-of-image marker (FF D9).
    static func trimmedJPEG(_ data: Data) -> Data {
        guard let end = data.indices.reversed().first(where: { $0 > data.startIndex && data[$0 - 1] == 0xFF && data[$0] == 0xD9 }) else { return data }
        return data.prefix(upTo: data.index(after: end))
    }

    /// The long-lived `eventManager.cgi?action=attach` response, read as it arrives (`RawHTTPStream`). `codes=[All]` goes out with its
    /// brackets, as the camera expects.
    static func eventStream(endpoint: CameraEndpoint, credentials: HTTPCredentials?, heartbeat: Int, readTimeout: Duration,
                            transport: any NetworkTransport) async throws -> RawHTTPStream.Opened {
        let target = "/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=\(min(max(heartbeat, 1), 60))"
        return try await RawHTTPStream.openEventStream(endpoint: endpoint, target: target, credentials: credentials, transport: transport,
                                                       readTimeout: readTimeout)
    }
}
