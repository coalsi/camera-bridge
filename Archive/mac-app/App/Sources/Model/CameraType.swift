import CameraAdapters
import Foundation

/// How a type of camera is added, as the wizard's Camera Type page lists it: ONVIF/RTSP with automatic detection, brand presets for
/// cameras that speak a vendor API, and integrations with services that offer no plain RTSP/ONVIF. Brand names are used here (and only
/// here and in the docs) to say what is compatible.
enum CameraType: String, CaseIterable, Identifiable {
    case automatic, hikvision, reolink, tapo, amcrest, doorbird, wyzeRTSP, rtspURL
    case unifiProtect
    case ring, googleNest, wyzeCloud, tuya, otherCloud
    case demo

    var id: Self { self }

    enum Group: Int, CaseIterable, Identifiable {
        case network, console, cloud, demo

        var id: Self { self }

        var title: String {
            switch self {
            case .network: String(localized: "Cameras on Your Network")
            case .console: String(localized: "Consoles")
            case .cloud: String(localized: "Cloud Cameras")
            case .demo: String(localized: "Try Camera Bridge")
            }
        }

        var footer: String? {
            switch self {
            case .cloud:
                String(localized: "These cameras have no RTSP or ONVIF address. Camera Bridge reaches them through its built-in streaming helper (go2rtc), which runs on this Mac only.")
            case .console:
                String(localized: "The console’s own address and an API key you create in it; the video goes through the streaming helper.")
            default:
                nil
            }
        }
    }

    /// What the person gets from Camera Bridge with this type.
    enum Support: Equatable {
        case yes, no
        case partly(String)
    }

    var group: Group {
        switch self {
        case .automatic, .hikvision, .reolink, .tapo, .amcrest, .doorbird, .wyzeRTSP, .rtspURL: .network
        case .unifiProtect: .console
        case .ring, .googleNest, .wyzeCloud, .tuya, .otherCloud: .cloud
        case .demo: .demo
        }
    }

    /// The engine route the type takes.
    var vendorChoice: VendorChoice {
        switch self {
        case .automatic: .automatic
        case .hikvision: .hikvision
        case .reolink: .reolink
        case .tapo: .onvif
        case .amcrest: .amcrest
        case .doorbird: .doorbird
        case .wyzeRTSP, .rtspURL: .rtspURL
        case .unifiProtect: .unifi
        case .ring, .googleNest, .wyzeCloud, .tuya, .otherCloud: .go2rtc
        case .demo: .demo
        }
    }

    /// The service of a cloud type (`IntegrationSettings.service`).
    var service: IntegrationService? {
        switch self {
        case .ring: .ring
        case .googleNest: .nest
        case .wyzeCloud: .wyze
        case .tuya: .tuya
        case .otherCloud: .other
        case .unifiProtect: .unifiProtect
        default: nil
        }
    }

    /// The type a bare vendor choice stands for (a choice made in code, not in the list).
    static func standard(for choice: VendorChoice) -> CameraType {
        switch choice {
        case .automatic: .automatic
        case .hikvision: .hikvision
        case .reolink: .reolink
        case .onvif: .automatic
        case .amcrest: .amcrest
        case .doorbird: .doorbird
        case .unifi: .unifiProtect
        case .go2rtc: .otherCloud
        case .rtspURL: .rtspURL
        case .demo: .demo
        }
    }

    /// Whether the person searches the network for the camera first (ONVIF WS-Discovery) and types its address.
    var usesDiscovery: Bool {
        switch self {
        case .automatic, .hikvision, .reolink, .tapo, .amcrest, .doorbird: true
        default: false
        }
    }

    /// Whether the camera is reached through the go2rtc helper.
    var needsStreamingHelper: Bool {
        switch self {
        case .unifiProtect, .ring, .googleNest, .wyzeCloud, .tuya, .otherCloud: true
        default: false
        }
    }

    /// Cloud and console types sign in elsewhere; the Connect page asks for different things.
    var isIntegration: Bool { needsStreamingHelper }

    var title: String {
        switch self {
        case .automatic: String(localized: "ONVIF / RTSP Camera (Detect Automatically)")
        case .hikvision: "Hikvision"
        case .reolink: "Reolink"
        case .tapo: "TP-Link Tapo"
        case .amcrest: String(localized: "Amcrest / Dahua")
        case .doorbird: "DoorBird"
        case .wyzeRTSP: String(localized: "Wyze Cam v3 / Pan v3 (Official RTSP)")
        case .rtspURL: String(localized: "RTSP URL")
        case .unifiProtect: "UniFi Protect"
        case .ring: "Ring"
        case .googleNest: "Google Nest"
        case .wyzeCloud: String(localized: "Wyze (Other Models)")
        case .tuya: "Tuya / Smart Life"
        case .otherCloud: String(localized: "Other go2rtc Source")
        case .demo: String(localized: "Demo Camera")
        }
    }

    var summary: String {
        switch self {
        case .automatic: String(localized: "Any ONVIF camera or NVR channel. Camera Bridge tries Hikvision, Reolink, then ONVIF.")
        case .hikvision: String(localized: "Hikvision cameras and NVR channels through ISAPI.")
        case .reolink: String(localized: "Reolink cameras and doorbells through the Reolink API.")
        case .tapo: String(localized: "Tapo cameras through ONVIF and RTSP (not battery models).")
        case .amcrest: String(localized: "Amcrest and Dahua cameras and doorbells, with their own event stream.")
        case .doorbird: String(localized: "DoorBird video doorbells through the official LAN API.")
        case .wyzeRTSP: String(localized: "Wyze Cam v3 and Pan v3 with Wyze’s own RTSP feature turned on.")
        case .rtspURL: String(localized: "Any camera, from its RTSP stream URLs.")
        case .unifiProtect: String(localized: "A UniFi Protect console, with an API key from the console.")
        case .ring: String(localized: "Ring cameras and doorbells, with a Ring refresh token.")
        case .googleNest: String(localized: "Nest cameras and doorbells through Google’s official Device Access.")
        case .wyzeCloud: String(localized: "Wyze cameras without RTSP, over Wyze’s local P2P connection.")
        case .tuya: String(localized: "Tuya cameras from the Tuya Smart app.")
        case .otherCloud: String(localized: "Any other source go2rtc supports, such as Kasa, Xiaomi or Tapo cloud.")
        case .demo: String(localized: "A test pattern that reports motion every minute.")
        }
    }

    var symbol: String {
        switch self {
        case .automatic, .rtspURL: "video"
        case .hikvision, .reolink, .tapo, .amcrest: "web.camera"
        case .doorbird: "video.doorbell"
        case .wyzeRTSP: "camera"
        case .unifiProtect: "server.rack"
        case .ring: "video.doorbell"
        case .googleNest, .wyzeCloud, .tuya, .otherCloud: "icloud"
        case .demo: "play.rectangle"
        }
    }

    // MARK: What you get

    /// Live view in Camera Bridge and in the Home app.
    var live: Support { .yes }

    /// HomeKit Secure Video recording (made from the live stream by Camera Bridge, so every type with video has it).
    var recording: Support { self == .demo ? .partly(String(localized: "Test pattern only")) : .yes }

    /// Motion, detections and doorbell presses.
    var events: Support {
        switch self {
        case .automatic: .partly(String(localized: "Motion and detections from the camera over ONVIF; built-in detection otherwise"))
        case .hikvision: .yes
        case .reolink: .yes
        case .tapo: .partly(String(localized: "Over ONVIF where the model allows it; built-in detection otherwise"))
        case .amcrest: .yes
        case .doorbird: .yes
        case .wyzeRTSP: .partly(String(localized: "Built-in motion detection only"))
        case .rtspURL: .partly(String(localized: "Built-in motion detection or the webhook"))
        case .unifiProtect: .yes
        case .ring: .partly(String(localized: "Built-in motion detection only; doorbell presses are not detected"))
        case .googleNest: .partly(String(localized: "Built-in motion detection only; doorbell presses are not detected"))
        case .wyzeCloud: .partly(String(localized: "Built-in motion detection only"))
        case .tuya: .partly(String(localized: "Built-in motion detection only"))
        case .otherCloud: .partly(String(localized: "Built-in motion detection only"))
        case .demo: .yes
        }
    }

    /// What the events are, in a few words.
    var eventsDetail: String {
        switch self {
        case .hikvision: String(localized: "Motion, people, vehicles, tampering, alarm inputs")
        case .reolink: String(localized: "Motion, people, vehicles, animals, packages, visitors")
        case .amcrest: String(localized: "Motion, people, vehicles, tampering, sound; doorbell press on Amcrest and Dahua doorbells")
        case .doorbird: String(localized: "Doorbell press and motion")
        case .unifiProtect: String(localized: "Motion, people, vehicles, animals, packages, doorbell press")
        case .demo: String(localized: "Motion every minute")
        default: ""
        }
    }

    // MARK: Setup

    /// Numbered setup steps shown next to the list.
    var setupSteps: [String] {
        switch self {
        case .automatic:
            [String(localized: "Give the camera an address that doesn’t change (a reservation on your router), and turn on ONVIF in its settings if it has a switch."),
             String(localized: "Create a user for Camera Bridge on the camera (a viewer or operator account works)."),
             String(localized: "Next, pick the camera from the list or type its address.")]
        case .hikvision:
            [String(localized: "Turn on the camera’s web interface and create a user for Camera Bridge."),
             String(localized: "Use an admin or operator account for events; a viewer account can only see video."),
             String(localized: "Next, pick the camera or type its address.")]
        case .reolink:
            [String(localized: "In the Reolink app or client, turn on ONVIF and RTSP (Settings › Network › Advanced › Server Settings)."),
             String(localized: "Use the camera’s admin user. Battery cameras can’t be used: they don’t offer RTSP."),
             String(localized: "Next, pick the camera or type its address.")]
        case .tapo:
            [String(localized: "In the Tapo app: Camera Settings › Advanced Settings › Camera Account, and create a user name and password."),
             String(localized: "Use that account here (not your TP-Link login). Tapo’s ONVIF port is 2020, found automatically."),
             String(localized: "Battery-powered Tapo cameras don’t offer RTSP and can’t be used.")]
        case .amcrest:
            [String(localized: "On the camera’s web page, create a user for Camera Bridge (Setup › Account)."),
             String(localized: "Keep the camera on HTTP port 80 and RTSP port 554, or enter the ports you use."),
             String(localized: "Doorbells: the Amcrest app’s call button stops working while Camera Bridge holds the speaker, so two-way audio is not offered here.")]
        case .doorbird:
            [String(localized: "In the DoorBird app: Administration › Users, add a user for Camera Bridge."),
             String(localized: "Give it “Watch always” (otherwise video only works for a minute after a ring). It needs no other permission."),
             String(localized: "The DoorBird app has priority over Camera Bridge, and the doorbell answers one request a second.")]
        case .wyzeRTSP:
            [String(localized: "Update the camera to firmware 4.36.16.5654 (Cam v3) or 4.50.16.5654 (Pan v3) and the Wyze app to 3.9 or later."),
             String(localized: "In the Wyze app: open the camera, Settings › Advanced Settings › RTSP, turn it on and create a user name and password."),
             String(localized: "Enter the camera’s IP address and that user here. If the app shows a different address, use RTSP URL and paste it.")]
        case .rtspURL:
            [String(localized: "Find the camera’s RTSP address in its manual or settings, like rtsp://192.168.1.20:554/stream1."),
             String(localized: "Enter the main stream, and a sub stream if there is one. A user name and password typed into the URL are moved to the fields below.")]
        case .unifiProtect:
            [String(localized: "In UniFi Protect: Settings › Control Plane › Integrations, and create an API key."),
             String(localized: "Enter the console’s address and the key, then choose the camera. Camera Bridge asks the console for the camera’s RTSPS stream."),
             String(localized: "Needs the streaming helper (RTSPS is TLS-secured RTSP).")]
        case .ring:
            [String(localized: "Get a Ring refresh token. The easiest way: choose Open Sign-In Page, sign in to Ring in the go2rtc page that opens on this Mac (it asks for your 2FA code), and copy the Ring source it shows."),
             String(localized: "Or run “npx -y -p ring-client-api ring-auth-cli” in Terminal and build the source from the token (docs/integrations/ring.md)."),
             String(localized: "Paste the source here. Camera Bridge keeps it in your Keychain.")]
        case .googleNest:
            [String(localized: "Register for Device Access (a one-time US$5 fee to Google) and create a project and an OAuth client; the links below open Google’s pages."),
             String(localized: "Enter the project ID, client ID and client secret, open Google’s sign-in link and paste the code Google shows."),
             String(localized: "Choose the camera. Only the cameras and doorbells of your own home are listed.")]
        case .wyzeCloud:
            [String(localized: "This is for Wyze models without their own RTSP (Cam v4, v3 Pro, Pan v2, Outdoor, Doorbell). Models with Gwell hardware (OG, Pan v4) are not supported."),
             String(localized: "Choose Open Sign-In Page, sign in with your Wyze account and an API key from Wyze’s developer console on the go2rtc page, and copy the Wyze source it shows."),
             String(localized: "Paste the source here. Streaming is local; the internet is only used while loading your camera list.")]
        case .tuya:
            [String(localized: "Use the Tuya Smart app (Smart Life accounts are not supported: remove the camera there and add it again in Tuya Smart)."),
             String(localized: "Choose Open Sign-In Page, sign in on the go2rtc page, and copy the Tuya source it shows for your camera."),
             String(localized: "Paste the source here.")]
        case .otherCloud:
            [String(localized: "Build or copy a go2rtc source (ring:, nest:, tuya:, wyze:, tapo:, kasa:, xiaomi:, rtspx:…) from go2rtc’s documentation or its sign-in page."),
             String(localized: "Sources that run programs (exec:, echo:, ffmpeg:) are refused."),
             String(localized: "Paste the source here.")]
        case .demo:
            [String(localized: "Nothing to set up.")]
        }
    }

    /// Honest notes: limits, and the terms of service for unofficial access.
    var notes: [String] {
        switch self {
        case .ring:
            [String(localized: "Unofficial access to Ring’s cloud. It may break when Ring changes, Ring’s terms may not allow third-party access, and Ring can sign the token out. Use at your own risk."),
             String(localized: "Camera Bridge keeps the camera’s stream open to detect motion and to record, so the camera streams from Ring’s servers all the time. Use cameras on mains power; a battery camera or doorbell would drain in hours.")]
        case .googleNest:
            [String(localized: "Official Google API. Google limits each live session to five minutes, so the stream restarts now and then; battery cameras can’t extend a session."),
             String(localized: "Camera Bridge keeps the stream open to detect motion and to record: use cameras on mains power. Wired cameras and newer doorbells stream over WebRTC, older cameras over RTSP.")]
        case .wyzeCloud:
            [String(localized: "Unofficial: Wyze’s terms don’t allow apps other than Wyze’s to use its cameras without permission, and the connection can change with firmware. Use at your own risk."),
             String(localized: "Needs DTLS firmware. Cam v3 and Pan v3 can use Wyze’s official RTSP instead, which is the better choice.")]
        case .tuya:
            [String(localized: "Unofficial access to Tuya’s cloud. It may break when Tuya changes. Use at your own risk. Camera Bridge keeps the stream open to detect motion and to record: use cameras on mains power."),
             String(localized: "Some Tuya cameras offer ONVIF/RTSP in their settings; if yours does, use ONVIF / RTSP instead.")]
        case .otherCloud:
            [String(localized: "Whatever the source’s service allows. Unofficial sources may break and may be against the service’s terms.")]
        case .unifiProtect:
            [String(localized: "Uses Ubiquiti’s official API. The console’s certificate is self-signed and is accepted for the address you entered. Video needs the streaming helper."),
             String(localized: "The API key can see every camera on the console; it is kept in your Keychain.")]
        case .doorbird:
            [String(localized: "Uses DoorBird’s official LAN API. Two-way audio and the door relay are not offered yet.")]
        case .amcrest:
            [String(localized: "Uses the camera’s own HTTP interface. After a few wrong passwords the camera locks logins; Camera Bridge stops trying after the first rejection.")]
        case .tapo:
            [String(localized: "Uses Tapo’s official RTSP and ONVIF. Cloud storage, the SD card and NVR recording can compete for the camera’s streams.")]
        case .wyzeRTSP:
            [String(localized: "Wyze’s own feature. It sends no motion events, so built-in motion detection is used. Some cameras stop the RTSP feed after a few hours; Camera Bridge reconnects.")]
        default:
            []
        }
    }

    /// Names a URL path and port the type's preset uses, for the Wyze preset (tried in this order).
    static let wyzePaths = ["/stream0", "/live"]
}
