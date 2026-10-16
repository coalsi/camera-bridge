import Foundation

/// The person's own API key pair from Wyze's developer console (developer-api-console.wyze.com). Secret: kept in the SecretStore.
public struct WyzeAPIKeys: Sendable, Codable, Equatable, CustomStringConvertible {
    public var keyID: String
    public var apiKey: String

    public init(keyID: String, apiKey: String) {
        self.keyID = keyID
        self.apiKey = apiKey
    }

    /// Never the key itself.
    public var description: String { "WyzeAPIKeys(…)" }
}

/// What the plugin keeps (in the SecretStore): never the password. `description` names the account only.
public struct WyzeSession: Sendable, Codable, Equatable, CustomStringConvertible, CustomReflectable {
    public var email: String
    public var keys: WyzeAPIKeys
    /// About two days.
    public var accessToken: String
    /// About 30 days; `WyzeCloud.refresh` returns a new one each time.
    public var refreshToken: String
    public var userID: String?
    /// When `accessToken` was issued.
    public var obtained: Date
    /// The phone ID the session was signed in with; every later call (refresh, lists, the cloud video helper) uses the same one. nil for
    /// a session saved before it was kept.
    public var phoneID: String?

    public init(email: String, keys: WyzeAPIKeys, accessToken: String, refreshToken: String, userID: String? = nil, obtained: Date,
                phoneID: String? = nil) {
        self.email = email
        self.keys = keys
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.obtained = obtained
        self.phoneID = phoneID
    }

    public var description: String { "WyzeSession(\(email))" }
    public var customMirror: Mirror { Mirror(self, children: ["email": email, "obtained": obtained]) }
}

/// Two-step verification asked for at sign-in; carries what the second call needs. The password hash stays in memory only (Wyze
/// keeps the sign-in session for a few minutes); `description` and the mirror show the kinds only.
public struct WyzeVerification: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A code from an authenticator app (Wyze: `TotpVerificationCode`).
        case authenticatorApp
        /// A code Wyze texts to the account's phone (`PrimaryPhone`).
        case textMessage
        /// A code Wyze e-mails (`Email`).
        case email

        /// Wyze's `mfa_options` / `mfa_type` name.
        var wyzeName: String {
            switch self {
            case .authenticatorApp: "TotpVerificationCode"
            case .textMessage: "PrimaryPhone"
            case .email: "Email"
            }
        }

        init?(wyzeName: String) {
            guard let kind = Self.allCases.first(where: { $0.wyzeName == wyzeName }) else { return nil }
            self = kind
        }
    }

    /// What the account offers, in Wyze's order.
    public var kinds: [Kind]
    /// The email address as signed in with (shown by the page: "code sent to …" is Wyze's business, not ours).
    public var email: String

    var passwordHash: String
    var keys: WyzeAPIKeys
    var userID: String?
    var smsSessionID: String?
    var emailSessionID: String?
    /// The authenticator app's ID (`mfa_details.totp_apps[0].app_id`): the `verification_id` of a TOTP code.
    var totpAppID: String?
    /// The `session_id` Wyze answers `sendSmsCode` with: the `verification_id` of a texted code.
    var textVerificationID: String?
    /// The `session_id` Wyze answers `sendEmailCode` with.
    var emailVerificationID: String?
    var phoneID: String

    init(kinds: [Kind], email: String, passwordHash: String, keys: WyzeAPIKeys, userID: String?, smsSessionID: String?, emailSessionID: String?,
         totpAppID: String?, phoneID: String) {
        self.kinds = kinds
        self.email = email
        self.passwordHash = passwordHash
        self.keys = keys
        self.userID = userID
        self.smsSessionID = smsSessionID
        self.emailSessionID = emailSessionID
        self.totpAppID = totpAppID
        self.phoneID = phoneID
    }

    /// Whether Wyze was asked to send the code of `kind` (an authenticator app's code needs nothing sent).
    public func codeSent(for kind: Kind) -> Bool {
        switch kind {
        case .authenticatorApp: true
        case .textMessage: textVerificationID != nil
        case .email: emailVerificationID != nil
        }
    }

    public var description: String { "WyzeVerification(\(kinds.map(\.rawValue).joined(separator: ", ")))" }
    public var customMirror: Mirror { Mirror(self, children: ["kinds": kinds]) }
}

public enum WyzeSignIn: Sendable {
    case signedIn(WyzeSession)
    case needsVerification(WyzeVerification)
}

/// How the bridge can reach a Wyze camera.
public enum WyzeConnection: String, Sendable, Codable {
    /// RTSP-capable firmware, and a TUTK camera with DTLS firmware (go2rtc's local connection works too).
    case rtspAndLocal
    /// RTSP-capable firmware only.
    case rtspOnly
    /// A TUTK camera with DTLS firmware without RTSP: go2rtc's local (unofficial) connection.
    case localOnly
    /// The Pan v4 on current firmware: only Wyze's cloud ("lake", Agora) carries its video. Experimental and unofficial: the
    /// `wyze-lake` helper brings it in, the internet is needed for every session.
    case cloud
    /// Gwell models (`GW_`: OG, OG Telephoto, Doorbell Pro, Doorbell Duo): the `wyze-gwell` helper (unofficial; a cloud handshake each
    /// session, video over the LAN when the camera's address is known).
    case gwell
    /// Cloud-only cameras Camera Bridge can't read, firmware without DTLS.
    case unsupported
}

/// One camera on the account (`get_object_list`, product type `Camera`). `enr` is the camera's local encryption key: secret.
public struct WyzeDevice: Sendable, Codable, Equatable, Identifiable, CustomStringConvertible {
    public var id: String { mac }
    public var mac: String
    public var nickname: String
    /// Wyze's product model (`HL_CAM4`).
    public var productModel: String
    /// The name people know (`Wyze Cam v4`); the product model when it is not known.
    public var modelName: String
    public var firmware: String
    /// The address the cloud last saw (can be stale: resolve the MAC locally first, `NeighborTable`).
    public var ip: String?
    /// The TUTK UID (`device_params.p2p_id`).
    public var p2pID: String?
    /// Secret.
    public var enr: String?
    public var dtls: Bool
    public var online: Bool
    public var connection: WyzeConnection

    public init(mac: String, nickname: String, productModel: String, modelName: String? = nil, firmware: String, ip: String? = nil,
                p2pID: String? = nil, enr: String? = nil, dtls: Bool, online: Bool, connection: WyzeConnection? = nil) {
        self.mac = mac
        self.nickname = nickname
        self.productModel = productModel
        self.modelName = modelName ?? WyzeModels.name(for: productModel)
        self.firmware = firmware
        self.ip = ip
        self.p2pID = p2pID
        self.enr = enr
        self.dtls = dtls
        self.online = online
        self.connection = connection ?? WyzeModels.connection(model: productModel, firmware: firmware, p2pID: p2pID, enr: enr, dtls: dtls)
    }

    /// No `enr`.
    public var description: String { "WyzeDevice(\(nickname), \(productModel), \(mac), \(connection.rawValue))" }
}

/// Known Wyze camera models.
public enum WyzeModels {
    /// Product model → the name on the box (docker-wyze-bridge's and go2rtc's model lists, MIT).
    public static let names: [String: String] = [
        "WYZEC1": "Wyze Cam v1",
        "WYZEC1-JZ": "Wyze Cam v2",
        "WYZE_CAKP2JFUS": "Wyze Cam v3",
        "HL_CAM3P": "Wyze Cam v3 Pro",
        "HL_CAM4": "Wyze Cam v4",
        "WYZECP1_JEF": "Wyze Cam Pan",
        "HL_PAN2": "Wyze Cam Pan v2",
        "HL_PAN3": "Wyze Cam Pan v3",
        "HL_PANP": "Wyze Cam Pan Pro",
        "HL_PAN4": "Wyze Cam Pan v4",
        "GW_GC1": "Wyze Cam OG",
        "GW_GC2": "Wyze Cam OG Telephoto",
        "WVOD1": "Wyze Cam Outdoor",
        "HL_WCO2": "Wyze Cam Outdoor v2",
        "HL_CFL2": "Wyze Cam Floodlight v2",
        "LD_CFP": "Wyze Cam Floodlight Pro",
        "WYZEDB3": "Wyze Video Doorbell",
        "HL_DB2": "Wyze Video Doorbell v2",
        "GW_BE1": "Wyze Video Doorbell Pro",
        "AN_RDB1": "Wyze Battery Video Doorbell",
        "AN_RSCW": "Wyze Battery Cam Pro",
    ]

    /// Gwell-based models (every `GW_` model), which go2rtc's local connection does not speak.
    public static func isGwell(_ model: String) -> Bool {
        model.uppercased().hasPrefix("GW_")
    }

    /// Models whose video only Wyze's cloud ("lake", Agora) carries: the Pan v4 (`p2p.providers` = `["lake"]` on firmware 4.70).
    public static func isCloudOnly(_ model: String) -> Bool {
        model.uppercased() == "HL_PAN4"
    }

    /// Models that pan and tilt and that the bridge can turn (through the cloud session: the Pan v4).
    public static func pansAndTilts(_ model: String) -> Bool {
        model.uppercased() == "HL_PAN4"
    }

    public static func name(for model: String) -> String { names[model.uppercased()] ?? model }

    /// The best way in the camera allows: RTSP when the firmware has it; go2rtc's local connection for TUTK cameras with DTLS
    /// firmware and the details it needs (UID and `enr`); nothing for Gwell models.
    public static func connection(model: String, firmware: String, p2pID: String?, enr: String?, dtls: Bool) -> WyzeConnection {
        if isGwell(model) { return .gwell }
        if isCloudOnly(model) { return .cloud }
        let rtsp = WyzeFirmware.hasRTSP(model: model, firmware: firmware)
        let local = dtls && !(p2pID ?? "").isEmpty && !(enr ?? "").isEmpty
        switch (rtsp, local) {
        case (true, true): return .rtspAndLocal
        case (true, false): return .rtspOnly
        case (false, true): return .localOnly
        case (false, false): return .unsupported
        }
    }
}

public enum WyzeError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Wyze: "Invalid User Name or Password" / `UserNameOrPasswordError`.
    case wrongPassword
    /// The key ID / API key pair was refused (HTTP 401/403, or a message about the key).
    case badAPIKey
    /// Wyze refused the sign-in without saying which part (its "please check username, password, keyid or apikey").
    case credentialsRejected
    /// The two-step verification code was refused.
    case verificationFailed
    /// A texted or e-mailed code was entered before asking Wyze to send it (`WyzeCloud.sendCode`).
    case codeNotRequested
    /// Too many attempts (code 3044, "Too many failed attempts", HTTP 429).
    case rateLimited
    /// The refresh token is no longer accepted: sign in again.
    case signInExpired
    /// The access token has expired (code 2001): refresh the session, then ask again.
    case accessTokenExpired
    /// `UserIsLocked`.
    case accountLocked
    /// Anything else Wyze refused: its message (cut short, secrets masked) or code.
    case server(String)
    case unreadableAnswer
    /// The request did not get an answer (no address or token in it).
    case network(String)

    public var description: String {
        switch self {
        case .wrongPassword: "Wyze did not accept the email address or password."
        case .badAPIKey: "Wyze did not accept the API key. Check the key ID and API key from developer-api-console.wyze.com."
        case .credentialsRejected: "Wyze did not accept the sign-in. Check the email address, password, key ID and API key."
        case .verificationFailed: "Wyze did not accept the verification code. Check it and try again, or ask for a new code."
        case .codeNotRequested: "Ask Wyze to send the code first."
        case .rateLimited: "Wyze is refusing requests after too many attempts. Wait a few minutes, then try again."
        case .signInExpired: "The Wyze sign-in has expired. Sign in again."
        case .accessTokenExpired: "The Wyze session needs renewing."
        case .accountLocked: "Wyze has locked the account. Unlock it in the Wyze app, then sign in again."
        case .server(let reason): "Wyze refused the request (\(reason))."
        case .unreadableAnswer: "Wyze’s answer could not be understood."
        case .network(let reason): "Camera Bridge could not reach Wyze (\(reason))."
        }
    }

    public var errorDescription: String? { description }
}
