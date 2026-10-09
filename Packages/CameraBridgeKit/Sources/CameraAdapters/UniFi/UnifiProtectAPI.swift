import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// UniFi Protect's official Integration API (Ubiquiti; the API key is created in Protect › Settings › Control Plane › Integrations).
// The facts used here are the documented endpoints under `/proxy/protect/integration/v1/`: `meta/info`, `cameras`,
// `cameras/{id}/rtsps-stream` and `cameras/{id}/snapshot`, with the key in the `X-API-KEY` header; the events WebSocket is
// `subscribe/events`. They were read from Ubiquiti's published OpenAPI description (Protect 5.3 to 7.3) and the MIT-licensed uiprotect
// project's notes. Nothing is taken from Scrypted's UniFi plugin or its unlicensed library.

struct UnifiCamera: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    /// The model name (`UVC G4 Doorbell Pro`, `UVC Micro`).
    var type: String
    /// `CONNECTED`, `CONNECTING`, `DISCONNECTED`.
    var state: String
    var mac: String

    var isConnected: Bool { state.uppercased() == "CONNECTED" }
    var isDoorbell: Bool { type.lowercased().contains("doorbell") }

    static func parseList(_ data: Data) throws -> [UnifiCamera] {
        guard let json = try? JSONValue.parse(data), case .array(let items) = json else {
            throw CameraAdapterError.invalidResponse("the console did not send a camera list")
        }
        return items.compactMap { item in
            guard let id = item["id"]?.string, !id.isEmpty else { return nil }
            return UnifiCamera(id: id, name: item["name"]?.string ?? id, type: item["type"]?.string ?? "", state: item["state"]?.string ?? "",
                               mac: item["mac"]?.string ?? "")
        }
    }
}

/// A Protect camera for the wizard's list.
public struct UnifiProtectCamera: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    public var isConnected: Bool
    public var isDoorbell: Bool

    public init(id: String, name: String, model: String, isConnected: Bool, isDoorbell: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.isConnected = isConnected
        self.isDoorbell = isDoorbell
    }
}

/// The official Protect API over HTTPS with the console's self-signed certificate accepted (`AuthenticatingHTTPClient`).
struct UnifiProtectAPI: Sendable {
    static let basePath = "/proxy/protect/integration/v1"

    let endpoint: CameraEndpoint
    private let apiKey: String
    private let http: AuthenticatingHTTPClient

    /// `useHTTPS`: always true for a console (tests talk plain HTTP to a loopback double).
    init(endpoint: CameraEndpoint, apiKey: String, useHTTPS: Bool = true, timeout: Duration = .seconds(10)) {
        var secure = endpoint
        secure.useHTTPS = useHTTPS
        self.endpoint = secure
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
    }

    func invalidate() {
        http.invalidate()
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let url = endpoint.httpURL(path: Self.basePath + path) else { throw CameraAdapterError.invalidResponse("invalid console address") }
        var request = CameraHTTP.request(url, method: method, body: body, contentType: body == nil ? nil : "application/json")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await CameraHTTP.send(http, request)
            _ = response
            return data
        } catch CameraAdapterError.httpStatus(let status) where status == 403 {
            throw CameraAdapterError.unauthorized   // an API key the console does not accept
        }
    }

    /// The Protect application version (`applicationVersion`), which also proves the key works.
    func applicationVersion() async throws -> String {
        let data = try await send(try request("/meta/info"))
        return (try? JSONValue.parse(data))?["applicationVersion"]?.string ?? ""
    }

    func cameras() async throws -> [UnifiCamera] {
        try UnifiCamera.parseList(try await send(try request("/cameras")))
    }

    /// The RTSPS address of a quality (`high`, `medium`, `low`): the existing stream when there is one, else a new one is created.
    func rtspsStream(cameraID: String, quality: String) async throws -> String {
        let path = "/cameras/\(cameraID)/rtsps-stream"
        if let existing = try? await send(try request(path)), let url = Self.streamURL(in: existing, quality: quality) { return url }
        let body = try JSONSerialization.data(withJSONObject: ["qualities": [quality]])
        let created = try await send(try request(path, method: "POST", body: body))
        guard let url = Self.streamURL(in: created, quality: quality) else {
            throw CameraAdapterError.invalidResponse("the console did not create the \(quality) stream")
        }
        return url
    }

    static func streamURL(in data: Data, quality: String) -> String? {
        guard let json = try? JSONValue.parse(data), case .string(let url)? = json[quality], !url.isEmpty else { return nil }
        return url
    }

    func snapshot(cameraID: String) async throws -> Data {
        let data = try await send(try request("/cameras/\(cameraID)/snapshot?highQuality=false"))
        guard CameraHTTP.looksLikeJPEG(data) else { throw CameraAdapterError.invalidResponse("not a JPEG") }
        return data
    }
}

extension UnifiProtectAPI {
    /// For the wizard: the console's cameras with an API key. Closes its connection when done.
    static func listCameras(endpoint: CameraEndpoint, apiKey: String, useHTTPS: Bool = true) async throws -> [UnifiProtectCamera] {
        let api = UnifiProtectAPI(endpoint: endpoint, apiKey: apiKey, useHTTPS: useHTTPS)
        defer { api.invalidate() }
        _ = try await api.applicationVersion()
        return try await api.cameras().map {
            UnifiProtectCamera(id: $0.id, name: $0.name, model: $0.type, isConnected: $0.isConnected, isDoorbell: $0.isDoorbell)
        }
    }
}
