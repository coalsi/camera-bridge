import CameraAdapters
import Foundation

/// How a type of camera is added, as the Add Camera page lists it: the same types, words and steps as the Mac app's Camera Type page
/// (`CameraType`), so the two stay in step. ONVIF/RTSP with automatic detection, brand presets for cameras that speak a vendor API,
/// consoles and cloud services. Brand names are used here (and in the docs) only to say what is compatible.
public struct CameraTypeSpec: Sendable, Encodable, Equatable {
    public enum Group: String, Sendable, Encodable, CaseIterable {
        case network, console, cloud, demo

        var title: String {
            switch self {
            case .network: "Cameras on Your Network"
            case .console: "Consoles"
            case .cloud: "Cloud Cameras"
            case .demo: "Try Camera Bridge"
            }
        }

        var footer: String? {
            switch self {
            case .cloud:
                "These cameras have no RTSP or ONVIF address. Camera Bridge reaches them through its built-in streaming helper (go2rtc), which runs on this bridge."
            case .console:
                "The console’s own address and an API key you create in it; the video goes through the streaming helper."
            default:
                nil
            }
        }
    }

    /// What you get from Camera Bridge with this type.
    public struct Support: Sendable, Encodable, Equatable {
        /// "yes" or "partly".
        public var level: String
        public var note: String?

        static let yes = Support(level: "yes", note: nil)
        static func partly(_ note: String) -> Support { Support(level: "partly", note: note) }
    }

    public var id: String
    public var title: String
    public var summary: String
    public var group: Group
    public var groupTitle: String { group.title }
    public var groupFooter: String? { group.footer }
    /// The engine route: nil detects the camera (Hikvision, then Reolink, then ONVIF).
    public var vendor: String?
    /// The person searches the network for the camera first (ONVIF WS-Discovery) and picks it or types its address.
    public var usesDiscovery: Bool
    /// The camera is reached through the go2rtc helper.
    public var needsStreamingHelper: Bool
    public var setupSteps: [String]
    public var notes: [String]
    public var live: Support
    public var recording: Support
    public var events: Support
    public var eventsDetail: String
    /// The inputs the page shows, in order: host, username, password, apiKey, mainStreamURL, subStreamURL, source, nest.
    public var fields: [String]
    /// Inputs behind "More options".
    public var advancedFields: [String]
    public var defaultHTTPPort: Int
    public var defaultRTSPPort: Int
    public var defaultUseHTTPS: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, summary, group, groupTitle, groupFooter, vendor, usesDiscovery, needsStreamingHelper, setupSteps, notes
        case live, recording, events, eventsDetail, fields, advancedFields, defaultHTTPPort, defaultRTSPPort, defaultUseHTTPS
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(group, forKey: .group)
        try container.encode(groupTitle, forKey: .groupTitle)
        try container.encodeIfPresent(groupFooter, forKey: .groupFooter)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(usesDiscovery, forKey: .usesDiscovery)
        try container.encode(needsStreamingHelper, forKey: .needsStreamingHelper)
        try container.encode(setupSteps, forKey: .setupSteps)
        try container.encode(notes, forKey: .notes)
        try container.encode(live, forKey: .live)
        try container.encode(recording, forKey: .recording)
        try container.encode(events, forKey: .events)
        try container.encode(eventsDetail, forKey: .eventsDetail)
        try container.encode(fields, forKey: .fields)
        try container.encode(advancedFields, forKey: .advancedFields)
        try container.encode(defaultHTTPPort, forKey: .defaultHTTPPort)
        try container.encode(defaultRTSPPort, forKey: .defaultRTSPPort)
        try container.encode(defaultUseHTTPS, forKey: .defaultUseHTTPS)
    }

    /// The vendor the engine is asked to use (nil: detect).
    var cameraVendor: CameraVendor? { vendor.flatMap { CameraVendor(rawValue: $0) } }

    var isCloud: Bool { group == .cloud }

    /// The service of a cloud or console type (`IntegrationSettings.service`).
    var service: IntegrationService? {
        switch id {
        case "ring": .ring
        case "googleNest": .nest
        case "wyzeCloud": .wyze
        case "tuya": .tuya
        case "otherCloud": .other
        case "unifiProtect": .unifiProtect
        default: nil
        }
    }
}

public enum CameraTypeCatalog {
    public static let wyzePaths = ["/stream0", "/live"]

    private static let netFields = ["host", "username", "password"]
    private static let netAdvanced = ["httpPort", "rtspPort", "onvifPort", "useHTTPS"]

    public static func spec(id: String) -> CameraTypeSpec? {
        all.first { $0.id == id }
    }

    /// Every type, in the order the page lists them. The demo camera is last.
    public static let all: [CameraTypeSpec] = [
        CameraTypeSpec(
            id: "automatic", title: "ONVIF / RTSP Camera (Detect Automatically)",
            summary: "Any ONVIF camera or NVR channel. Camera Bridge tries Hikvision, Reolink, then ONVIF.", group: .network, vendor: nil,
            usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["Give the camera an address that doesn’t change (a reservation on your router), and turn on ONVIF in its settings if it has a switch.",
                         "Create a user for Camera Bridge on the camera (a viewer or operator account works).",
                         "Next, pick the camera from the list or type its address."],
            notes: [], live: .yes, recording: .yes,
            events: .partly("Motion and detections from the camera over ONVIF; built-in detection otherwise"), eventsDetail: "",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "hikvision", title: "Hikvision", summary: "Hikvision cameras and NVR channels through ISAPI.", group: .network, vendor: "hikvision",
            usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["Turn on the camera’s web interface and create a user for Camera Bridge.",
                         "Use an admin or operator account for events; a viewer account can only see video.",
                         "Next, pick the camera or type its address."],
            notes: [], live: .yes, recording: .yes, events: .yes, eventsDetail: "Motion, people, vehicles, tampering, alarm inputs",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "reolink", title: "Reolink", summary: "Reolink cameras and doorbells through the Reolink API.", group: .network, vendor: "reolink",
            usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["In the Reolink app or client, turn on ONVIF and RTSP (Settings › Network › Advanced › Server Settings).",
                         "Use the camera’s admin user. Battery cameras can’t be used: they don’t offer RTSP.",
                         "Next, pick the camera or type its address."],
            notes: [], live: .yes, recording: .yes, events: .yes, eventsDetail: "Motion, people, vehicles, animals, packages, visitors",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "tapo", title: "TP-Link Tapo", summary: "Tapo cameras through ONVIF and RTSP (not battery models).", group: .network, vendor: "onvif",
            usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["In the Tapo app: Camera Settings › Advanced Settings › Camera Account, and create a user name and password.",
                         "Use that account here (not your TP-Link login). Tapo’s ONVIF port is 2020, found automatically.",
                         "Battery-powered Tapo cameras don’t offer RTSP and can’t be used."],
            notes: ["Uses Tapo’s official RTSP and ONVIF. Cloud storage, the SD card and NVR recording can compete for the camera’s streams."],
            live: .yes, recording: .yes, events: .partly("Over ONVIF where the model allows it; built-in detection otherwise"), eventsDetail: "",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "amcrest", title: "Amcrest / Dahua", summary: "Amcrest and Dahua cameras and doorbells, with their own event stream.", group: .network,
            vendor: "amcrest", usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["On the camera’s web page, create a user for Camera Bridge (Setup › Account).",
                         "Keep the camera on HTTP port 80 and RTSP port 554, or enter the ports you use.",
                         "Doorbells: the Amcrest app’s call button stops working while Camera Bridge holds the speaker, so two-way audio is not offered here."],
            notes: ["Uses the camera’s own HTTP interface. After a few wrong passwords the camera locks logins; Camera Bridge stops trying after the first rejection."],
            live: .yes, recording: .yes, events: .yes,
            eventsDetail: "Motion, people, vehicles, tampering, sound; doorbell press on Amcrest and Dahua doorbells",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "doorbird", title: "DoorBird", summary: "DoorBird video doorbells through the official LAN API.", group: .network, vendor: "doorbird",
            usesDiscovery: true, needsStreamingHelper: false,
            setupSteps: ["In the DoorBird app: Administration › Users, add a user for Camera Bridge.",
                         "Give it “Watch always” (otherwise video only works for a minute after a ring). It needs no other permission.",
                         "The DoorBird app has priority over Camera Bridge, and the doorbell answers one request a second."],
            notes: ["Uses DoorBird’s official LAN API. Two-way audio and the door relay are not offered yet."],
            live: .yes, recording: .yes, events: .yes, eventsDetail: "Doorbell press and motion",
            fields: netFields, advancedFields: netAdvanced, defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "wyzeRTSP", title: "Wyze Cam v3 / Pan v3 (Official RTSP)",
            summary: "Wyze Cam v3 and Pan v3 with Wyze’s own RTSP feature turned on.", group: .network, vendor: "rtsp", usesDiscovery: false,
            needsStreamingHelper: false,
            setupSteps: ["Update the camera to firmware 4.36.16.5654 (Cam v3) or 4.50.16.5654 (Pan v3) and the Wyze app to 3.9 or later.",
                         "In the Wyze app: open the camera, Settings › Advanced Settings › RTSP, turn it on and create a user name and password.",
                         "Enter the camera’s IP address and that user here. If the app shows a different address, use RTSP URL and paste it."],
            notes: ["Wyze’s own feature. It sends no motion events, so built-in motion detection is used. Some cameras stop the RTSP feed after a few hours; Camera Bridge reconnects."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only"), eventsDetail: "",
            fields: netFields, advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "rtspURL", title: "RTSP URL", summary: "Any camera, from its RTSP stream URLs.", group: .network, vendor: "rtsp", usesDiscovery: false,
            needsStreamingHelper: false,
            setupSteps: ["Find the camera’s RTSP address in its manual or settings, like rtsp://192.0.2.20:554/stream1.",
                         "Enter the main stream, and a sub stream if there is one. A user name and password typed into the URL are moved to the fields below."],
            notes: [], live: .yes, recording: .yes, events: .partly("Built-in motion detection or the webhook"), eventsDetail: "",
            fields: ["mainStreamURL", "subStreamURL", "username", "password"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554,
            defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "unifiProtect", title: "UniFi Protect", summary: "A UniFi Protect console, with an API key from the console.", group: .console,
            vendor: "unifi", usesDiscovery: false, needsStreamingHelper: true,
            setupSteps: ["In UniFi Protect: Settings › Control Plane › Integrations, and create an API key.",
                         "Enter the console’s address and the key, then choose the camera. Camera Bridge asks the console for the camera’s RTSPS stream.",
                         "Needs the streaming helper (RTSPS is TLS-secured RTSP)."],
            notes: ["Uses Ubiquiti’s official API. The console’s certificate is self-signed and is accepted for the address you entered. Video needs the streaming helper.",
                    "The API key can see every camera on the console; it is kept encrypted on this bridge."],
            live: .yes, recording: .yes, events: .yes, eventsDetail: "Motion, people, vehicles, animals, packages, doorbell press",
            fields: ["host", "apiKey", "unifiCamera"], advancedFields: ["httpPort"], defaultHTTPPort: 443, defaultRTSPPort: 7441, defaultUseHTTPS: true),
        CameraTypeSpec(
            id: "ring", title: "Ring", summary: "Ring cameras and doorbells, with a Ring refresh token.", group: .cloud, vendor: "go2rtc", usesDiscovery: false,
            needsStreamingHelper: true,
            setupSteps: ["Get a Ring refresh token. On a computer, run “npx -y -p ring-client-api ring-auth-cli” in a terminal and sign in with your Ring account and 2FA code.",
                         "Build the source from the token as described in docs/integrations/ring.md (it looks like ring:?refresh_token=…&camera_id=…).",
                         "Paste the source here. Camera Bridge keeps it encrypted on this bridge."],
            notes: ["Unofficial access to Ring’s cloud. It may break when Ring changes, Ring’s terms may not allow third-party access, and Ring can sign the token out. Use at your own risk.",
                    "Camera Bridge keeps the camera’s stream open to detect motion and to record, so the camera streams from Ring’s servers all the time. Use cameras on mains power; a battery camera or doorbell would drain in hours."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only; doorbell presses are not detected"), eventsDetail: "",
            fields: ["source"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "googleNest", title: "Google Nest", summary: "Nest cameras and doorbells through Google’s official Device Access.", group: .cloud,
            vendor: "go2rtc", usesDiscovery: false, needsStreamingHelper: true,
            setupSteps: ["Register for Device Access (a one-time US$5 fee to Google) and create a project and an OAuth client; the links below open Google’s pages.",
                         "Enter the project ID, client ID and client secret, open Google’s sign-in link and paste the code Google shows.",
                         "Choose the camera. Only the cameras and doorbells of your own home are listed."],
            notes: ["Official Google API. Google limits each live session to five minutes, so the stream restarts now and then; battery cameras can’t extend a session.",
                    "Camera Bridge keeps the stream open to detect motion and to record: use cameras on mains power. Wired cameras and newer doorbells stream over WebRTC, older cameras over RTSP."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only; doorbell presses are not detected"), eventsDetail: "",
            fields: ["nest"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "wyzeCloud", title: "Wyze (Other Models)", summary: "Wyze cameras without RTSP, over Wyze’s local P2P connection.", group: .cloud,
            vendor: "go2rtc", usesDiscovery: false, needsStreamingHelper: true,
            setupSteps: ["This is for Wyze models without their own RTSP (Cam v4, v3 Pro, Pan v2, Outdoor, Doorbell). Models with Gwell hardware (OG, Pan v4) are not supported.",
                         "On a computer, run go2rtc (go2rtc.org), open its page, sign in with your Wyze account and an API key from Wyze’s developer console, and copy the Wyze source it shows.",
                         "Paste the source here. Streaming is local; the internet is only used while loading your camera list."],
            notes: ["Unofficial: Wyze’s terms don’t allow apps other than Wyze’s to use its cameras without permission, and the connection can change with firmware. Use at your own risk.",
                    "Needs DTLS firmware. Cam v3 and Pan v3 can use Wyze’s official RTSP instead, which is the better choice."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only"), eventsDetail: "",
            fields: ["source"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "tuya", title: "Tuya / Smart Life", summary: "Tuya cameras from the Tuya Smart app.", group: .cloud, vendor: "go2rtc", usesDiscovery: false,
            needsStreamingHelper: true,
            setupSteps: ["Use the Tuya Smart app (Smart Life accounts are not supported: remove the camera there and add it again in Tuya Smart).",
                         "On a computer, run go2rtc (go2rtc.org), open its page, sign in to Tuya, and copy the Tuya source it shows for your camera.",
                         "Paste the source here."],
            notes: ["Unofficial access to Tuya’s cloud. It may break when Tuya changes. Use at your own risk. Camera Bridge keeps the stream open to detect motion and to record: use cameras on mains power.",
                    "Some Tuya cameras offer ONVIF/RTSP in their settings; if yours does, use ONVIF / RTSP instead."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only"), eventsDetail: "",
            fields: ["source"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "otherCloud", title: "Other go2rtc Source", summary: "Any other source go2rtc supports, such as Kasa, Xiaomi or Tapo cloud.", group: .cloud,
            vendor: "go2rtc", usesDiscovery: false, needsStreamingHelper: true,
            setupSteps: ["Build or copy a go2rtc source (ring:, nest:, tuya:, wyze:, tapo:, kasa:, xiaomi:, rtspx:…) from go2rtc’s documentation or its sign-in page.",
                         "Sources that run programs (exec:, echo:, ffmpeg:) are refused.",
                         "Paste the source here."],
            notes: ["Whatever the source’s service allows. Unofficial sources may break and may be against the service’s terms."],
            live: .yes, recording: .yes, events: .partly("Built-in motion detection only"), eventsDetail: "",
            fields: ["source"], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554, defaultUseHTTPS: false),
        CameraTypeSpec(
            id: "demo", title: "Demo Camera", summary: "A test pattern that reports motion every minute.", group: .demo, vendor: "demo", usesDiscovery: false,
            needsStreamingHelper: false, setupSteps: ["Nothing to set up."], notes: [], live: .yes, recording: .partly("Test pattern only"),
            events: .yes, eventsDetail: "Motion every minute", fields: [], advancedFields: [], defaultHTTPPort: 80, defaultRTSPPort: 554,
            defaultUseHTTPS: false),
    ]
}
