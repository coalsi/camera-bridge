import Foundation

/// Something about the network that can keep Apple Home devices from getting live video from this Mac, shown by the app
/// as a banner, a menu bar line, a Settings row and in the diagnostics export (`BridgeEngine.recentNetworkNotices`).
///
/// - `controllerOnVPN`: a HomeKit controller (an iPhone or iPad) asked for a live stream at an RTP address that is on
///   none of this Mac's networks — almost always the address of a VPN tunnel on that device (NordVPN's NordLynx hands
///   every device 10.5.0.2). The stream then goes to the HAP connection's peer address instead
///   (`StreamAddress.controllerRoute`); `delivery` says whether video then reached the device.
/// - `macOnVPN`: this Mac itself is connected to a VPN (`MacVPNDetector`), which can stop Apple Home devices on the LAN
///   from reaching CameraBridge.
/// - `liveViewNotReceived`: a controller's RTCP kept arriving but its receiver reports show it receives none of the live
///   video (the stream is ended after a few seconds so Home retries; CameraBridge tries other ways to send meanwhile).
/// - `localNetworkDenied`: sending live video failed with "no route to host" / "operation not permitted" and kept failing,
///   which is what macOS does when the Local Network permission is off or a firewall blocks the app.
/// - `dualHomedSubnet`: two network interfaces of this Mac (Ethernet and Wi-Fi) hold addresses on one subnet. CameraBridge
///   sends live video from the address the Home device connected to, but turning one interface off is more reliable.
public struct NetworkNotice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case controllerOnVPN
        case macOnVPN
        case liveViewNotReceived
        case localNetworkDenied
        case dualHomedSubnet
    }

    /// Whether live video reached the controller once the stream started (its first RTCP packet arrived).
    public enum Delivery: String, Sendable, Equatable {
        /// The stream was set up; it has not been verified yet.
        case pending
        /// The controller answered: video got through.
        case reached
        /// The controller did not answer: video did not get through (yet).
        case failed
    }

    /// How long a `controllerOnVPN` notice stays after the last time it was seen.
    public static let lifetime: TimeInterval = 3600

    public var kind: Kind
    /// The camera whose live view was asked for (`controllerOnVPN`).
    public var cameraID: UUID?
    /// That camera's name when the notice was recorded; the engine fills it in from the configuration.
    public var cameraName: String?
    /// The address the controller asked for video at (`controllerOnVPN`), e.g. "10.5.0.2".
    public var advertisedAddress: String?
    /// The HAP connection's address: the controller's address on this network, nil when it is unknown.
    public var peerAddress: String?
    /// The stream was sent to `peerAddress` instead of `advertisedAddress`.
    public var usedFallback: Bool
    public var delivery: Delivery
    /// The tunnel interface of this Mac's VPN ("utun4"), `macOnVPN` only; the interfaces sharing a subnet ("en0, en1") for
    /// `dualHomedSubnet`.
    public var interfaceName: String?
    /// What was seen, in words: why the controller counts as not receiving, the failed send's errno, the shared subnet
    /// (`liveViewNotReceived`, `localNetworkDenied`, `dualHomedSubnet`).
    public var detail: String?
    /// When this was last seen.
    public var date: Date
    /// When this episode began: the first time it was seen since it was last cleared.
    public var firstSeen: Date

    public init(kind: Kind, cameraID: UUID? = nil, cameraName: String? = nil, advertisedAddress: String? = nil, peerAddress: String? = nil,
                usedFallback: Bool = false, delivery: Delivery = .pending, interfaceName: String? = nil, detail: String? = nil,
                date: Date = Date(), firstSeen: Date? = nil) {
        self.kind = kind
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.advertisedAddress = advertisedAddress
        self.peerAddress = peerAddress
        self.usedFallback = usedFallback
        self.delivery = delivery
        self.interfaceName = interfaceName
        self.detail = detail
        self.date = date
        self.firstSeen = firstSeen ?? date
    }

    /// The device a `controllerOnVPN` notice is about: its address on this network (else the address it advertised), so one
    /// phone is one notice however many cameras it watches. `macOnVPN` is one notice for this Mac.
    public var deviceKey: String {
        switch kind {
        case .macOnVPN, .localNetworkDenied, .dualHomedSubnet: "mac"
        case .controllerOnVPN, .liveViewNotReceived: StreamAddress.canonical(peerAddress ?? advertisedAddress ?? "unknown")
        }
    }

    public var id: String { "\(kind.rawValue):\(deviceKey)" }

    /// Whether the notice still applies at `now`: a `controllerOnVPN` notice clears an hour after it was last seen
    /// (`lifetime`); `macOnVPN` is removed by the engine when the VPN is gone.
    public func isActive(at now: Date) -> Bool {
        kind == .macOnVPN || now.timeIntervalSince(date) < Self.lifetime
    }
}

/// The notices the engine currently knows, one per `NetworkNotice.id`.
struct NetworkNoticeLog: Sendable, Equatable {
    private(set) var notices: [NetworkNotice] = []

    /// Records `notice`: a new one is added; one that is already there is updated and keeps its `firstSeen` unless it had
    /// expired meanwhile (a new episode). The newest report about a device wins (a new stream's pending notice
    /// replaces the verdict of the one before it). Returns whether anything changed.
    @discardableResult
    mutating func record(_ notice: NetworkNotice, now: Date = Date()) -> Bool {
        var incoming = notice
        if let index = notices.firstIndex(where: { $0.id == notice.id }) {
            let existing = notices[index]
            if existing.isActive(at: now) { incoming.firstSeen = existing.firstSeen }
            if incoming.cameraName == nil { incoming.cameraName = existing.cameraName }
            if incoming == existing { return false }
            notices[index] = incoming
        } else {
            notices.append(incoming)
        }
        return true
    }

    /// Removes the notices of `kind` (this Mac is no longer on a VPN). Returns whether any was there.
    @discardableResult
    mutating func remove(_ kind: NetworkNotice.Kind) -> Bool {
        let before = notices.count
        notices.removeAll { $0.kind == kind }
        return notices.count != before
    }

    /// Drops what has expired (`NetworkNotice.isActive`). Returns whether anything was dropped.
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let before = notices.count
        notices.removeAll { !$0.isActive(at: now) }
        return notices.count != before
    }
}
