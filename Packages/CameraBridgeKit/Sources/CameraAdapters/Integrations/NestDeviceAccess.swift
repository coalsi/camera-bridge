import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google's Device Access (Smart Device Management) sign-in, step by step, for the Add Camera wizard's Google Nest setup.
///
/// The person registers with Google's Device Access console (a one-time US$5 fee), creates an OAuth client in Google Cloud and a Device
/// Access project, and Camera Bridge helps with the rest: the authorization link to open, the sign-in code to turn into a refresh
/// token, and the list of cameras. These are Google's documented, official endpoints (developers.google.com/nest/device-access);
/// nothing here imitates another client. The client secret and refresh token are used for these calls and then only live in the
/// camera's go2rtc source (the Keychain).
///
/// Nothing is sent before the person presses the matching button.
public struct NestDeviceAccess: Sendable {
    /// What the OAuth client in Google Cloud lists as an authorized redirect (Google's own quick start uses this one): after the person
    /// allows access, the browser lands on a page with the code in the address.
    public static let defaultRedirect = "https://www.google.com"
    public static let consoleURL = URL(string: "https://console.nest.google.com/device-access")!
    public static let cloudCredentialsURL = URL(string: "https://console.cloud.google.com/apis/credentials")!
    public static let sdmAPIURL = URL(string: "https://console.cloud.google.com/apis/library/smartdevicemanagement.googleapis.com")!
    static let tokenEndpoint = "https://www.googleapis.com/oauth2/v4/token"
    static let devicesEndpoint = "https://smartdevicemanagement.googleapis.com/v1/enterprises"

    public struct Tokens: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
    }

    public struct Camera: Sendable, Equatable, Identifiable {
        public var deviceID: String
        public var name: String
        /// `WEB_RTC` (battery and wired cameras, newer doorbells) or `RTSP` (legacy Nest Cam, Hub Max); the first the camera lists.
        public var protocolName: String
        public var isDoorbell: Bool
        public var id: String { deviceID }
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidInput(String)
        /// Google refused: `reason` is its error text (`invalid_grant`: the code was used already or expired).
        case refused(String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let message): message
            case .refused(let reason):
                reason == "invalid_grant" ? "Google rejected the code. Codes work once and for a few minutes: open the link again and paste the new code."
                    : "Google refused the request (\(reason))."
            case .invalidResponse: "Google’s answer could not be understood."
            }
        }
    }

    /// Sends one request, returns the body and HTTP status. Replaced in tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? Self.liveTransport
    }

    private static let liveTransport: Transport = { request in
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(20), allowSelfSignedTLS: false)
        defer { client.invalidate() }
        do {
            let (data, response) = try await client.data(for: request)
            return (data, response.statusCode)
        } catch let error as HTTPClientError {
            throw error
        } catch {
            throw URLFreeErrors.sanitized(error, request: "Google request")
        }
    }

    // MARK: Step 1: the link

    /// The page where the person signs in with the Google account that owns the cameras and allows access:
    /// `https://nestservices.google.com/partnerconnections/<project>/auth?…`.
    public static func authorizationURL(projectID: String, clientID: String, redirect: String = defaultRedirect) throws -> URL {
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIdentifier(project) else { throw Failure.invalidInput("Enter the Device Access project ID (a UUID from the Device Access console).") }
        guard !client.isEmpty, !client.contains(where: \.isWhitespace) else { throw Failure.invalidInput("Enter the OAuth client ID from Google Cloud.") }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "nestservices.google.com"
        components.path = "/partnerconnections/\(project)/auth"
        components.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "access_type", value: "offline"),
                                 URLQueryItem(name: "prompt", value: "consent"), URLQueryItem(name: "client_id", value: client),
                                 URLQueryItem(name: "response_type", value: "code"),
                                 URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/sdm.service")]
        guard let url = components.url else { throw Failure.invalidInput("The project or client ID can’t be used in a link.") }
        return url
    }

    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 100 && text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    // MARK: Step 2: the code

    /// The code from what the person pasted: the address of the page Google redirected to (`https://www.google.com/?code=4/0A…&scope=…`)
    /// or the bare code.
    public static func code(from pasted: String) -> String? {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let components = URLComponents(string: text), let items = components.queryItems, let code = items.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }
        guard !text.contains("://"), !text.contains(where: \.isWhitespace), !text.contains("=") else { return nil }
        return text
    }

    /// Exchanges the code for tokens (`POST https://www.googleapis.com/oauth2/v4/token`).
    public func exchange(code: String, clientID: String, clientSecret: String, redirect: String = NestDeviceAccess.defaultRedirect) async throws -> Tokens {
        let body = Self.form(["client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                              "client_secret": clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), "code": code, "grant_type": "authorization_code",
                              "redirect_uri": redirect])
        let json = try await post(Self.tokenEndpoint, body: body)
        guard let refresh = json["refresh_token"]?.string, !refresh.isEmpty, let access = json["access_token"]?.string, !access.isEmpty else {
            throw Failure.refused("no refresh token (open the link again; Google sends it only on first consent)")
        }
        return Tokens(accessToken: access, refreshToken: refresh)
    }

    /// A new access token from a refresh token.
    public func accessToken(refreshToken: String, clientID: String, clientSecret: String) async throws -> String {
        let body = Self.form(["client_id": clientID, "client_secret": clientSecret, "refresh_token": refreshToken, "grant_type": "refresh_token"])
        let json = try await post(Self.tokenEndpoint, body: body)
        guard let access = json["access_token"]?.string, !access.isEmpty else { throw Failure.invalidResponse }
        return access
    }

    // MARK: Step 3: the cameras

    /// The project's cameras and doorbells (`GET …/enterprises/<project>/devices`).
    public func cameras(projectID: String, accessToken: String) async throws -> [Camera] {
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIdentifier(project), let url = URL(string: "\(Self.devicesEndpoint)/\(project)/devices") else {
            throw Failure.invalidInput("Enter the Device Access project ID.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await transport(request)
        let json = try Self.json(data, status: status)
        return Self.parseCameras(json)
    }

    static func parseCameras(_ json: JSONValue) -> [Camera] {
        guard case .array(let devices)? = json["devices"] else { return [] }
        return devices.compactMap { device in
            guard let type = device["type"]?.string, type.hasSuffix(".CAMERA") || type.hasSuffix(".DOORBELL"),
                  let path = device["name"]?.string, let id = path.split(separator: "/").last.map(String.init), !id.isEmpty else { return nil }
            let traits = device["traits"]
            var name = traits?["sdm.devices.traits.Info"]?["customName"]?.string ?? ""
            if name.isEmpty, case .array(let relations)? = device["parentRelations"] { name = relations.first?["displayName"]?.string ?? "" }
            var protocolName = "WEB_RTC"
            if case .array(let list)? = traits?["sdm.devices.traits.CameraLiveStream"]?["supportedProtocols"], let first = list.first?.string {
                protocolName = first
            }
            return Camera(deviceID: id, name: name.isEmpty ? (type.hasSuffix(".DOORBELL") ? "Nest Doorbell" : "Nest camera") : name, protocolName: protocolName,
                          isDoorbell: type.hasSuffix(".DOORBELL"))
        }
    }

    // MARK: Plumbing

    private func post(_ endpoint: String, body: Data) async throws -> JSONValue {
        guard let url = URL(string: endpoint) else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await transport(request)
        return try Self.json(data, status: status)
    }

    private static func json(_ data: Data, status: Int) throws -> JSONValue {
        let json = try? JSONValue.parse(data)
        guard (200..<300).contains(status) else {
            // Google's error text is short and holds no secret (`invalid_grant`, `invalid_client`).
            let reason = json?["error"]?.string ?? json?["error"]?["status"]?.string ?? "HTTP \(status)"
            throw Failure.refused(reason.count <= 60 ? reason : String(reason.prefix(60)))
        }
        guard let json else { throw Failure.invalidResponse }
        return json
    }

    static func form(_ values: [String: String]) -> Data {
        Data(Go2RTCSource.encodedQuery(values).utf8)
    }
}
