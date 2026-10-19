import BridgeEngine
import Foundation

/// What the person is told about a `NetworkNotice` (the engine's VPN findings): the manager window's banner, the menu bar
/// line and the Settings › Network row all read these.
struct NetworkNoticeMessage: Equatable, Identifiable {
    enum Severity: String, Equatable, Comparable {
        /// Nothing failed (yet): what CameraBridge did, and what to do if live view still doesn't load.
        case info
        /// Live view to the device failed.
        case warning

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs == .info && rhs == .warning }
    }

    /// The notice and how bad it is: a notice that gets worse (the stream failed after the fallback) is a new message, which
    /// the throttle shows again.
    let id: String
    let kind: NetworkNotice.Kind
    let severity: Severity
    let title: String
    let detail: String
    /// The menu bar's line (the full text is in the window's banner and Learn More).
    let menuTitle: String
    /// When the notice's episode began (`NetworkNotice.firstSeen`): a recurrence after it cleared is a new episode.
    let episodeStart: Date
    let date: Date

    /// The message for `notice`, nil when there is nothing to say: a stream to an off-network address that nevertheless got
    /// through is no problem.
    static func make(for notice: NetworkNotice) -> NetworkNoticeMessage? {
        switch notice.kind {
        case .macOnVPN:
            return NetworkNoticeMessage(
                id: "\(notice.id)#info", kind: .macOnVPN, severity: .info, title: String(localized: "This Mac Is on a VPN"),
                detail: String(localized: "This Mac is connected to a VPN; Apple Home devices may not be able to reach Camera Bridge. Turn the VPN off or enable LAN access."),
                menuTitle: String(localized: "This Mac Is on a VPN — Learn More…"), episodeStart: notice.firstSeen, date: notice.date)
        case .liveViewNotReceived:
            // Settled: a later live view of that device received video.
            if notice.delivery == .reached { return nil }
            let who = notice.cameraName.map { String(localized: "An iPhone or iPad watching \($0)") } ?? String(localized: "An iPhone or iPad watching a camera")
            return NetworkNoticeMessage(
                id: "\(notice.id)#warning", kind: .liveViewNotReceived, severity: .warning, title: String(localized: "Live View Did Not Reach a Device"),
                detail: String(localized: "\(who) answered Camera Bridge but never received the video, so Camera Bridge ended that live view for Home to try again, sending a different way each time. If it keeps happening, make sure the device is on the same network as this Mac (and not on a VPN) and that Camera Bridge is allowed under System Settings › Privacy & Security › Local Network."),
                menuTitle: String(localized: "Live View Did Not Reach a Device — Learn More…"), episodeStart: notice.firstSeen, date: notice.date)
        case .localNetworkDenied:
            let reason = notice.detail.map { " (\($0))" } ?? ""
            return NetworkNoticeMessage(
                id: "\(notice.id)#warning", kind: .localNetworkDenied, severity: .warning, title: String(localized: "Camera Bridge Cannot Send Live Video"),
                detail: String(localized: "Sending live video to a device on your network failed for good\(reason). Turn Camera Bridge on under System Settings › Privacy & Security › Local Network, and allow it in any firewall or VPN app."),
                menuTitle: String(localized: "Camera Bridge Cannot Send Live Video — Learn More…"), episodeStart: notice.firstSeen, date: notice.date)
        case .dualHomedSubnet:
            let interfaces = notice.interfaceName ?? String(localized: "two network interfaces")
            let subnet = notice.detail.map { " (\($0))" } ?? ""
            return NetworkNoticeMessage(
                id: "\(notice.id)#info", kind: .dualHomedSubnet, severity: .info, title: String(localized: "This Mac Is on Your Network Twice"),
                detail: String(localized: "\(interfaces) are connected to the same network\(subnet), usually Ethernet and Wi-Fi at once. Camera Bridge handles this by sending live video from the address the Home device connected to, but turning one of them off is more reliable."),
                menuTitle: String(localized: "This Mac Is on Your Network Twice — Learn More…"), episodeStart: notice.firstSeen, date: notice.date)
        case .controllerOnVPN:
            if !notice.usedFallback, notice.delivery == .reached { return nil }
            let failed = notice.delivery == .failed
            let advertised = notice.advertisedAddress ?? String(localized: "an address outside this network")
            let who = notice.cameraName.map { String(localized: "An iPhone or iPad watching \($0)") } ?? String(localized: "An iPhone or iPad watching a camera")
            let severity: Severity = failed ? .warning : .info
            let title = failed ? String(localized: "Live View to a Device on a VPN Failed") : String(localized: "A Device Watching Live View Is on a VPN")
            var detail: String
            if failed {
                detail = String(localized: "Live view to a device on a VPN failed — turn off the VPN on that device.")
                if notice.usedFallback, let peer = notice.peerAddress {
                    detail += " " + String(localized: "\(who) asked for video at \(advertised); Camera Bridge sent it to \(peer) instead, but nothing came back.")
                } else {
                    detail += " " + String(localized: "\(who) asked for video at \(advertised), which isn’t on this network, and nothing came back.")
                }
                detail += " " + String(localized: "You can also allow local network access in the VPN app (NordVPN: “Invisibility on LAN” off / “Local network” on).")
            } else if notice.usedFallback, let peer = notice.peerAddress {
                detail = String(localized: "\(who) seems to be on a VPN (asked for video at \(advertised)). Camera Bridge sent it to \(peer) instead.")
                    + " " + String(localized: "If live view still doesn’t load, turn off the VPN on that device or allow local network access in the VPN app (NordVPN: “Invisibility on LAN” off / “Local network” on).")
            } else {
                detail = String(localized: "\(who) seems to be on a VPN (asked for video at \(advertised), which isn’t on this network).")
                    + " " + String(localized: "If live view doesn’t load, turn off the VPN on that device or allow local network access in the VPN app (NordVPN: “Invisibility on LAN” off / “Local network” on).")
            }
            let menu = failed
                ? String(localized: "Live View to a Device on a VPN Failed — Learn More…")
                : (notice.cameraName.map { String(localized: "A Device Watching \($0) Is on a VPN — Learn More…") }
                    ?? String(localized: "A Device Watching Live View Is on a VPN — Learn More…"))
            return NetworkNoticeMessage(id: "\(notice.id)#\(severity.rawValue)", kind: .controllerOnVPN, severity: severity, title: title, detail: detail,
                                        menuTitle: menu, episodeStart: notice.firstSeen, date: notice.date)
        }
    }

    /// The messages for the notices that apply at `now`, the worst first, then the newest.
    static func messages(for notices: [NetworkNotice], now: Date = Date()) -> [NetworkNoticeMessage] {
        notices.filter { $0.isActive(at: now) }.compactMap(make(for:)).sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.date > $1.date
        }
    }
}

/// One banner per device and day: a message is shown once per 24 hours per notice and severity. Dismissing it hides it for
/// 24 hours; a notice that cleared (an hour without recurrence) and comes back within the day is not shown as a banner again
/// (it stays in the menu bar and in Settings); one that gets worse is a new message.
struct NetworkNoticeThrottle: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var episodeStart: Date
        var shownAt: Date
        var dismissedAt: Date?
    }

    static let window: TimeInterval = 86_400

    private(set) var entries: [String: Entry] = [:]

    /// Whether the banner for `message` may show at `now`.
    func allows(_ message: NetworkNoticeMessage, now: Date) -> Bool {
        guard let entry = entries[message.id] else { return true }
        if let dismissed = entry.dismissedAt, now.timeIntervalSince(dismissed) < Self.window { return false }
        if entry.episodeStart != message.episodeStart, now.timeIntervalSince(entry.shownAt) < Self.window { return false }
        return true
    }

    /// The banner for `message` was shown (the first time of its day).
    mutating func noteShown(_ message: NetworkNoticeMessage, now: Date) {
        if let entry = entries[message.id], now.timeIntervalSince(entry.shownAt) < Self.window { return }
        entries[message.id] = Entry(episodeStart: message.episodeStart, shownAt: now, dismissedAt: nil)
        prune(now: now)
    }

    /// The person dismissed the banner.
    mutating func dismiss(_ message: NetworkNoticeMessage, now: Date) {
        var entry = entries[message.id] ?? Entry(episodeStart: message.episodeStart, shownAt: now, dismissedAt: nil)
        entry.dismissedAt = now
        entries[message.id] = entry
    }

    private mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.shownAt) < Self.window * 2 }
    }
}

/// One block of a Learn More sheet: a heading and its lines, numbered when they are steps to follow.
struct HelpSection: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let systemImage: String
    let steps: [String]
    var numbered = true
}

/// The Learn More sheet of a network notice: what happened, what CameraBridge already did about it, and what the person can do.
struct NetworkHelpPage: Equatable {
    let title: String
    let systemImage: String
    let summary: String
    let sections: [HelpSection]
}

/// What Learn More shows for each kind of `NetworkNotice`: the two VPN kinds share the VPN page; each of the others has its own.
enum NetworkHelpContent {
    static func page(for kind: NetworkNotice.Kind) -> NetworkHelpPage {
        switch kind {
        case .controllerOnVPN, .macOnVPN: vpn
        case .liveViewNotReceived: liveViewNotReceived
        case .localNetworkDenied: localNetworkDenied
        case .dualHomedSubnet: dualHomedSubnet
        }
    }

    static let vpn = NetworkHelpPage(title: String(localized: "Live View and VPNs"), systemImage: "network.badge.shield.half.filled",
                                     summary: VPNHelpContent.summary, sections: VPNHelpContent.sections)

    static let liveViewNotReceived = NetworkHelpPage(
        title: String(localized: "Live View Did Not Reach a Device"), systemImage: "video.slash",
        summary: String(localized: "An iPhone, iPad or Apple TV asked for live video and Camera Bridge sent it, but the device’s own reports say none of it arrived. The device and this Mac can talk to each other, so the video is being lost somewhere on the way."),
        sections: [
            HelpSection(title: String(localized: "What Camera Bridge Did"), systemImage: "checkmark.circle", steps: [
                String(localized: "It tried another network path for the video: a different address and network connection on this Mac."),
                String(localized: "It ended that live view after a few seconds so the Home app starts it again. The next try is sent the other way."),
                String(localized: "It remembers what worked for that device for an hour, so you shouldn’t have to do anything if the other way works."),
            ], numbered: false),
            HelpSection(title: String(localized: "What You Can Do"), systemImage: "hand.point.up.left", steps: [
                String(localized: "Make sure the device and this Mac are on the same Wi-Fi or Ethernet network, and not on a guest network."),
                String(localized: "Turn off any VPN on the device and on this Mac, or allow local network access in the VPN app."),
                String(localized: "Look at your router for “client isolation”, “AP isolation” or “guest mode”. These stop devices on one network from reaching each other. Turn them off."),
                String(localized: "If this Mac’s firewall is on, open System Settings › Network › Firewall and make sure Camera Bridge is allowed, or turn the firewall off to test."),
                String(localized: "Open System Settings › Privacy & Security › Local Network and make sure Camera Bridge is turned on."),
                String(localized: "Open the Home app and try live view again."),
            ]),
        ])

    static let localNetworkDenied = NetworkHelpPage(
        title: String(localized: "Camera Bridge Cannot Send Live Video"), systemImage: "network.slash",
        summary: String(localized: "Sending live video to a device on your network failed, and kept failing. macOS does this when an app isn’t allowed to use the local network, and a firewall or VPN app can block it too."),
        sections: [
            HelpSection(title: String(localized: "What Camera Bridge Did"), systemImage: "checkmark.circle", steps: [
                String(localized: "It tried again for a couple of seconds, then ended that live view so the Home app can start it again once this is fixed."),
                String(localized: "It changed nothing else on your Mac or your network."),
            ], numbered: false),
            HelpSection(title: String(localized: "Allow Local Network Access"), systemImage: "hand.point.up.left", steps: [
                String(localized: "Open System Settings and choose Privacy & Security, then Local Network."),
                String(localized: "Find Camera Bridge in the list and turn it on. If it is on already, turn it off and on again."),
                String(localized: "If you use a firewall or a VPN app, allow Camera Bridge there too."),
                String(localized: "Open the Home app and try live view again."),
            ]),
        ])

    static let dualHomedSubnet = NetworkHelpPage(
        title: String(localized: "This Mac Is on Your Network Twice"), systemImage: "point.3.connected.trianglepath.dotted",
        summary: String(localized: "This Mac is connected to the same network in two ways at once, usually Ethernet and Wi-Fi. Each connection has its own address, and a Home device that connects to one can end up being answered from the other."),
        sections: [
            HelpSection(title: String(localized: "What Camera Bridge Did"), systemImage: "checkmark.circle", steps: [
                String(localized: "It sends live video from the same address the Home device connected to, so the answer comes back the way the device expects."),
                String(localized: "This works on its own. Nothing has to be turned off."),
            ], numbered: false),
            HelpSection(title: String(localized: "What You Can Do"), systemImage: "hand.point.up.left", steps: [
                String(localized: "For the most reliable setup, use only one connection. If the Mac is on Ethernet, turn Wi-Fi off in System Settings › Wi-Fi."),
                String(localized: "Or unplug the Ethernet cable and stay on Wi-Fi."),
                String(localized: "Camera Bridge notices the change by itself and announces your cameras to Home again."),
            ]),
        ])
}

/// The Learn More sheet: why a VPN stops Apple Home from reaching CameraBridge, and what to turn off or allow.
enum VPNHelpContent {
    typealias Section = HelpSection

    static let summary = String(localized: "Apple Home asks Camera Bridge to send live video to an address. A phone or iPad on a VPN gives the VPN’s address, which Camera Bridge can’t reach from your network. Camera Bridge falls back to the address the device connected from, but a VPN that blocks local network traffic can still keep the video from arriving.")

    static let sections: [Section] = [
        Section(title: String(localized: "On the iPhone or iPad"), systemImage: "iphone", steps: [
            String(localized: "Open Settings and turn off VPN, or open the VPN app and disconnect."),
            String(localized: "Or keep the VPN on and allow local network access in the VPN app (see NordVPN below)."),
            String(localized: "Open the Home app and try live view again."),
        ]),
        Section(title: String(localized: "NordVPN"), systemImage: "network.badge.shield.half.filled", steps: [
            String(localized: "Open the NordVPN app and go to its settings."),
            String(localized: "Turn off “Invisibility on LAN” so devices on your network can reach this one."),
            String(localized: "Turn on “Local network” (local network access) if the app has it. Names differ a little between versions."),
            String(localized: "Or disconnect NordVPN while you watch the cameras at home."),
        ]),
        Section(title: String(localized: "On this Mac"), systemImage: "desktopcomputer", steps: [
            String(localized: "Disconnect the VPN, or open the VPN app’s settings and allow LAN access (“Local network”, “Allow LAN traffic”)."),
            String(localized: "A VPN with a kill switch can block local traffic: turn the kill switch off or make an exception for your home network."),
            String(localized: "Camera Bridge notices when the VPN changes, and this message goes away once the Mac is off the VPN."),
        ]),
    ]
}
