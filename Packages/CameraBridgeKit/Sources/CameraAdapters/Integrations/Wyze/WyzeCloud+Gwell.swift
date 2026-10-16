import BridgeSupport
import Foundation

/// The Gwell helper's credentials (`WyzeHelpers`, `wyze-gwell`): Wyze's "Mars" service registers this client for one Gwell camera and
/// answers an access ID and token the helper logs in to the Gwell P2P servers with (valid up to the requested time, at most 7 days).
///
/// `POST https://wyze-mars-service.wyzecam.com/plugin/mars/v2/regist_gw_user/<MAC>`, body `{"nonce":"<ms>","ttl_minutes":10080,
/// "unique_id":"<phone id>"}`, headers `access_token`, `appid: 9319141212m2ik`, `requestid` = md5hex(md5hex(nonce)), `signature2` =
/// HMAC-MD5 with the key md5hex(access token + "wyze_app_secret_key_132") over the exact body bytes. Described by the hacky-wyze-gwell
/// project (MIT) and its users; not tried against a real Gwell camera from this code yet (the owner's camera is a Pan v4, which uses the
/// cloud route instead).
public struct WyzeGwellAccess: Sendable, Equatable, CustomStringConvertible {
    public var accessID: String
    /// Secret.
    public var accessToken: String
    public var description: String { "WyzeGwellAccess(…)" }
}

extension WyzeCloud {
    static let marsBase = "https://wyze-mars-service.wyzecam.com/plugin/mars/v2/regist_gw_user/"
    static let marsAppID = "9319141212m2ik"
    static let marsSecretSuffix = "wyze_app_secret_key_132"

    public func gwellAccess(_ session: WyzeSession, mac: String) async throws -> WyzeGwellAccess {
        let cleaned = mac.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 64, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              let url = URL(string: Self.marsBase + cleaned) else { throw WyzeError.unreadableAnswer }
        let nonce = String(Int64((now().timeIntervalSince1970 * 1000).rounded()))
        let unique = (session.phoneID ?? phoneID).replacingOccurrences(of: "\"", with: "")
        let body = Data(#"{"nonce":"\#(nonce)","ttl_minutes":10080,"unique_id":"\#(unique)"}"#.utf8)
        let key = Array(WyzeMD5.hex(session.accessToken + Self.marsSecretSuffix).utf8)
        let headers = ["Content-Type": "application/json", "access_token": session.accessToken, "appid": Self.marsAppID,
                       "requestid": WyzeMD5.hex(WyzeMD5.hex(nonce)), "signature2": Self.hmacMD5Hex(key: key, message: Array(body)),
                       "User-Agent": Self.userAgent]
        let secrets = [session.accessToken, session.refreshToken, session.keys.apiKey, session.keys.keyID]
        let status: Int
        let answer: Data
        do {
            (status, answer) = try await transportPost(url, headers: headers, json: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WyzeError.network(Self.scrub(URLFreeErrors.describe(error), secrets: secrets))
        }
        let json = try Self.check(status: status, body: answer, context: .api, secrets: secrets)
        let data = json["data"] ?? json
        guard let id = Self.text(data["accessId"] ?? data["access_id"]), let token = Self.text(data["accessToken"] ?? data["access_token"]) else {
            throw WyzeError.unreadableAnswer
        }
        return WyzeGwellAccess(accessID: id, accessToken: token)
    }

    /// HMAC-MD5 (RFC 2104) as lowercase hex.
    static func hmacMD5Hex(key: [UInt8], message: [UInt8]) -> String {
        var block = key.count > 64 ? WyzeMD5.digest(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = WyzeMD5.digest(block.map { $0 ^ 0x36 } + message)
        let outer = WyzeMD5.digest(block.map { $0 ^ 0x5C } + inner)
        return outer.map { String(format: "%02x", $0) }.joined()
    }
}
