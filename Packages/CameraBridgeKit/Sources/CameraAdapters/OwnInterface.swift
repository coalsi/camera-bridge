import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A maker's own interface that answered at a camera added as ONVIF (`CameraDrivers.ownInterface`).
public struct OwnInterface: Sendable, Equatable {
    public var vendor: CameraVendor
    /// The maker's name when the interface gives one (an OEM's, not always); nil: the driver's or ONVIF's own.
    public var manufacturer: String?
    public var model: String?

    public init(vendor: CameraVendor, manufacturer: String? = nil, model: String? = nil) {
        self.vendor = vendor
        self.manufacturer = manufacturer
        self.model = model
    }
}

public enum OwnInterfaceCheck: Sendable, Equatable {
    case found(OwnInterface)
    /// The camera refused the credentials at its maker's interface (one login was made, and logins to the camera pause: `ONVIFLoginGuard`).
    case rejected
    case none
}

/// A camera that answers but has no admin password yet: its maker's web page asks for one first.
public struct NotSetUp: Sendable, Equatable {
    /// "Hikvision" (also what its OEMs ship: ANNKE, LTS…) or "Reolink".
    public var maker: String
    public var vendor: CameraVendor

    public init(maker: String, vendor: CameraVendor) {
        self.maker = maker
        self.vendor = vendor
    }
}

extension CameraDrivers {
    /// Which of the makers' own interfaces answers at `endpoint` with `credentials`, asked after ONVIF has proven them (or could not be
    /// reached): Hikvision ISAPI (`/ISAPI/System/deviceInfo`, Digest: Hikvision and its OEMs such as ANNKE), then Reolink's and Dahua's
    /// and Amcrest's. Nothing is asked without credentials. Each check is bounded by `timeout`. The credentialed request is made only
    /// where the camera's unauthenticated answer showed that interface, at most once, and never while logins to the camera are paused;
    /// a refusal pauses them (`.rejected`) and ends the search, so a wrong password costs the camera one failed login here.
    public static func ownInterface(endpoint: CameraEndpoint, credentials: HTTPCredentials?, timeout: Duration = .seconds(4)) async -> OwnInterfaceCheck {
        guard let credentials else { return .none }
        // The three ask at once (an unreachable camera costs one timeout, not three); Hikvision's answer comes first.
        async let hikvision = (try? await withTimeout(timeout * 2 + .milliseconds(500)) {
            await hikvisionIdentity(endpoint: endpoint, credentials: credentials, timeout: timeout)
        }) ?? OwnInterfaceCheck.none
        async let reolink = (try? await withTimeout(timeout + .milliseconds(500)) { await isReolink(endpoint: endpoint, timeout: timeout) }) ?? false
        async let dahua = (try? await withTimeout(timeout + .milliseconds(500)) { await isDahua(endpoint: endpoint, timeout: timeout) }) ?? false
        let (hikvisionAnswer, isReolinkAnswer, isDahuaAnswer) = await (hikvision, reolink, dahua)
        if hikvisionAnswer != .none { return hikvisionAnswer }
        if isReolinkAnswer { return .found(OwnInterface(vendor: .reolink)) }
        if isDahuaAnswer { return .found(OwnInterface(vendor: .amcrest)) }
        return .none
    }

    /// ISAPI `deviceInfo`, asked without a login first: a camera that is not Hikvision's (404, no Digest challenge) is never sent the
    /// credentials.
    static func hikvisionIdentity(endpoint: CameraEndpoint, credentials: HTTPCredentials, timeout: Duration) async -> OwnInterfaceCheck {
        guard let url = endpoint.httpURL(path: "/ISAPI/System/deviceInfo") else { return .none }
        let anonymous = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        defer { anonymous.invalidate() }
        guard let (first, answer) = try? await anonymous.data(for: URLRequest(url: url)) else { return .none }
        var body = first
        switch answer.statusCode {
        case 200:
            break
        case 401:
            guard DigestChallenge.parse(answer.value(forHTTPHeaderField: "WWW-Authenticate") ?? "") != nil else { return .none }
            let key = AmcrestAPI.loginKey(endpoint)
            if ONVIFLoginGuard.shared.pause(host: key) != nil { return .none }
            let authenticated = AuthenticatingHTTPClient(credentials: credentials, timeout: timeout)
            defer { authenticated.invalidate() }
            guard let (data, response) = try? await authenticated.data(for: URLRequest(url: url)) else { return .none }
            if response.statusCode == 401 {
                ONVIFLoginGuard.shared.recordRejection(host: key)
                return .rejected
            }
            guard response.statusCode == 200 else { return .none }
            body = data
        default:
            return .none
        }
        guard isISAPIDeviceInfo(body), let tree = try? XMLTree.parse(body) else { return .none }
        let maker = tree.string("manufacturer")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = tree.string("model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .found(OwnInterface(vendor: .hikvision, manufacturer: maker?.isEmpty == false ? maker : nil,
                                   model: model?.isEmpty == false ? model : nil))
    }

    /// Dahua's CGI answers an unauthenticated `magicBox.cgi` with a Digest challenge whose realm is "Login to <serial>".
    static func isDahua(endpoint: CameraEndpoint, timeout: Duration) async -> Bool {
        guard let url = endpoint.httpURL(path: "/cgi-bin/magicBox.cgi", query: [URLQueryItem(name: "action", value: "getSystemInfo")]) else { return false }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        defer { client.invalidate() }
        guard let (_, response) = try? await client.data(for: URLRequest(url: url)), response.statusCode == 401 else { return false }
        let realm = DigestChallenge.parse(response.value(forHTTPHeaderField: "WWW-Authenticate") ?? "")?.realm ?? ""
        return realm.hasPrefix("Login to")
    }

    /// Whether `endpoint` is a camera that has not been set up yet, asked without any login: Hikvision's (and its OEMs') answers
    /// `GET /SDK/activateStatus` with `<Activated>false</Activated>` while it has no admin password. Reolink's new camera has an empty
    /// password instead and shows only when one is tried (`BridgeWeb`'s probe route). nil when it is set up or does not say.
    public static func needsSetup(endpoint: CameraEndpoint, timeout: Duration = .seconds(4)) async -> NotSetUp? {
        let inactive = (try? await withTimeout(timeout + .milliseconds(500)) { await isInactiveHikvision(endpoint: endpoint, timeout: timeout) }) ?? false
        return inactive ? NotSetUp(maker: "Hikvision", vendor: .hikvision) : nil
    }

    static func isInactiveHikvision(endpoint: CameraEndpoint, timeout: Duration) async -> Bool {
        guard let url = endpoint.httpURL(path: "/SDK/activateStatus") else { return false }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        defer { client.invalidate() }
        guard let (data, response) = try? await client.data(for: URLRequest(url: url)), response.statusCode == 200,
              let tree = try? XMLTree.parse(data), tree.matches("ActivateStatus") || tree.child("Activated") != nil else { return false }
        return tree.string("Activated")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "false"
    }
}
