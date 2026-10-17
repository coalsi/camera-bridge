import Foundation

// What Camera Bridge can read about a camera's ways to be reached from outside the home, for the camera security levels (BridgeEngine's
// `CameraSecurity`). A reader says only what the camera answered: a feature it could not read is `unknown`, never off.

/// A camera feature that can let it be reached from outside the home, or send its video out.
public enum RemoteAccessFeature: String, Sendable, Codable, CaseIterable {
    /// The maker's cloud or P2P service (Hik-Connect, Reolink's P2P, the cloud of a phone app).
    case cloud
    /// UPnP: the camera can open ports on the router.
    case upnp
    /// Dynamic DNS: the camera keeps a name on the internet that leads to the home.
    case ddns
    /// RTMP push: the camera sends its video to a server.
    case rtmp
    /// Video that plays without a password on the home network.
    case unauthenticatedVideo
    /// Another service of the camera (a protocol of its own on its own port) whose reach Camera Bridge cannot tell.
    case extraService
}

/// What a camera says about one feature.
public enum RemoteAccessState: String, Sendable, Codable, CaseIterable {
    case on, off
    /// The camera says it has no such feature.
    case absent
    /// Camera Bridge could not read it: no reader for this camera, no answer, or a refusal.
    case unknown
}

/// One feature as a camera reported it (`CameraSettingsService.readRemoteAccess()`, the RTSP check `RTSPAccessProbe`).
public struct RemoteAccessFinding: Sendable, Codable, Equatable {
    public var feature: RemoteAccessFeature
    public var state: RemoteAccessState
    /// The cloud only: whether it is linked to an account; nil when the camera does not say.
    public var linked: Bool?
    /// The service's name ("Hik-Connect", "Meari service"); nil for the camera's only one of its kind.
    public var service: String?
    /// "Set up for Camera Bridge" can change it on this camera.
    public var canChange: Bool

    public init(feature: RemoteAccessFeature, state: RemoteAccessState, linked: Bool? = nil, service: String? = nil, canChange: Bool = false) {
        self.feature = feature
        self.state = state
        self.linked = linked
        self.service = service
        self.canChange = canChange
    }

    /// The maker's cloud of a camera Camera Bridge has no reader for.
    public static let cloudUnknown = RemoteAccessFinding(feature: .cloud, state: .unknown)
}
