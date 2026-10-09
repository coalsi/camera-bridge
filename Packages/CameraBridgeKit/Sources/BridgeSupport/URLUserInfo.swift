import Foundation

extension URL {
    /// The URL without `user:password@` — the one copy (CameraAdapters' drivers, BridgeEngine's `withoutStreamCredentials`,
    /// RTSP request lines, the app's wizard and connection editor, `Redact.url`). Stream URLs are stored, shown and
    /// reported without credentials; the password lives in the Keychain. A URL without user info (also an empty one,
    /// `rtsp://@host`, is user info) is returned unchanged, as is one `URLComponents` cannot rebuild.
    ///
    /// Only user info is removed: credentials some cameras take in the path or query (`/user=admin&password=…`) stay,
    /// since the camera needs them; `Redact.url` masks those for logs.
    public var removingUserInfo: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.user != nil || components.password != nil else { return self }
        components.user = nil
        components.password = nil
        return components.url ?? self
    }
}
