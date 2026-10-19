import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// "Change it by hand" (`CameraManualHelpText`): for each step of Set up for Camera Bridge that a camera of each family refuses or does
/// not support, one sentence of why and where to change it by hand, with the bridge's own address; for the Security card's findings the
/// setup can't change, the Internet guard's "not watched" among them. A menu path not confirmed on the camera's own pages or in its
/// maker's documents always carries "Menu names differ between models".
@Suite struct CameraManualHelpTests {
    static let bridge = "192.168.77.28"
    static let context = CameraManualHelpText.Context(timeServer: bridge, guardServer: bridge, timeZone: "America/Phoenix (UTC−7:00)")
    /// The camera's address, as the bridge reaches it and as its last reading showed it whole (a made-up hardware address).
    static let camera = "192.168.77.120"
    static let addressing = CameraAddressing(address: camera, subnetMask: "255.255.255.0", gateway: "192.168.77.1", hardwareAddress: "02:00:00:00:00:21")
    /// What the engine knows of a camera besides the bridge's addresses: its own page, its address, the DNS servers it asks now (the
    /// router and a public one) and its address whole.
    static let full = CameraManualHelpText.Context(timeServer: bridge, guardServer: bridge, timeZone: "America/Phoenix (UTC−7:00)",
                                                   webPage: "http://192.168.77.120/", cameraAddress: camera, currentDNS: ["192.168.77.1", "192.0.2.53"],
                                                   addressing: addressing)

    /// The steps a camera of `family` can answer "not supported" or "refused": all of them, but the IPCamera Web family's own two
    /// (video password, extra services) are not offered on the other families.
    static func possible(_ family: CameraFamily) -> [CameraSetupStepID] {
        CameraSetupStepID.allCases.filter { family == .ipcamWeb || ($0 != .videoPassword && $0 != .extraServices) }
    }

    /// Every help the table gives for a step that could not be done, with what it was asked for.
    static var everyHelp: [(family: CameraFamily, step: CameraSetupStepID, status: CameraSetupStepStatus, help: CameraManualHelp)] {
        CameraFamily.allCases.flatMap { family in
            CameraSetupStepID.allCases.flatMap { step in
                [CameraSetupStepStatus.notSupported, .refused].compactMap { status in
                    CameraManualHelpText.step(step, status: status, detail: nil, family: family, context: context).map { (family, step, status, $0) }
                }
            }
        }
    }

    private func help(_ step: CameraSetupStepID, _ status: CameraSetupStepStatus = .notSupported, family: CameraFamily, detail: String? = nil,
                      context: CameraManualHelpText.Context = CameraManualHelpTests.context, changes: [CameraSetupChange] = []) throws -> CameraManualHelp {
        try #require(CameraManualHelpText.step(step, status: status, detail: detail, family: family, context: context, changes: changes))
    }

    // MARK: The table

    @Test func everyStepThatCanFailOnEveryFamilySaysWhyAndWhereToChangeIt() {
        for family in CameraFamily.allCases {
            for step in Self.possible(family) {
                for status in [CameraSetupStepStatus.notSupported, .refused] {
                    let help = CameraManualHelpText.step(step, status: status, detail: nil, family: family, context: Self.context)
                    #expect(help != nil, "\(family) \(step) \(status): no help")
                    guard let help else { continue }
                    #expect(!help.why.isEmpty && help.why.hasSuffix("."), "\(family) \(step): one sentence of why")
                    #expect(!help.places.isEmpty || help.router != nil, "\(family) \(step): somewhere to change it")
                    for place in help.places {
                        #expect(!place.app.isEmpty && place.action.hasSuffix("."), "\(family) \(step): \(place)")
                    }
                }
            }
        }
    }

    @Test func onlyAStepThatCouldNotBeDoneGetsHelp() {
        for status in [CameraSetupStepStatus.willChange, .alreadyRight, .done, .notOffered, .notRun, .restored] {
            for step in CameraSetupStepID.allCases {
                #expect(CameraManualHelpText.step(step, status: status, detail: nil, family: .hikvision, context: Self.context) == nil, "\(step) \(status)")
            }
        }
    }

    @Test func theDNSAndTimeHelpCarryTheBridgesOwnAddress() throws {
        for family in CameraFamily.allCases {
            let watch = try help(.internetWatch, .refused, family: family)
            #expect(watch.values.contains(.init(label: "Preferred DNS server", value: Self.bridge, copy: true)), "\(family)")
            #expect(watch.values.contains(.init(label: "Alternate DNS server", value: Self.bridge, copy: true)), "\(family)")
            let router = try #require(watch.router, "\(family): Watch also has the router's way")
            #expect(router.contains(Self.bridge) && router.contains("DHCP reservation") && router.contains("block the camera’s internet"))
            #expect(router.contains("renews"), "a DNS server the router hands out can change: said")
            #expect(watch.then == "Then press Check again on the camera’s Security card.")
            let time = try help(.timeSource, family: family)
            #expect(time.values.contains(.init(label: "NTP server", value: Self.bridge, copy: true)), "\(family)")
            #expect(time.values.contains(.init(label: "Port", value: "123")))
            let zone = try help(.timeZone, .refused, family: family)
            #expect(zone.values == [.init(label: "Time zone", value: "America/Phoenix (UTC−7:00)")])
        }
        #expect(try help(.internetWatch, family: .ipcamWeb).places.first?.action.contains("Static DNS Server") == true)
    }

    @Test func withoutTheBridgesAddressThereIsNoDNSOrTimeHelp() {
        let none = CameraManualHelpText.Context(timeServer: nil, guardServer: nil, timeZone: nil)
        for family in CameraFamily.allCases {
            #expect(CameraManualHelpText.step(.internetWatch, status: .refused, detail: nil, family: family, context: none) == nil)
            #expect(CameraManualHelpText.step(.timeSource, status: .refused, detail: nil, family: family, context: none) == nil)
            #expect(CameraManualHelpText.step(.timeZone, status: .refused, detail: nil, family: family, context: none)?.values == [])
        }
    }

    @Test func aPathNotConfirmedAlwaysCarriesTheCaveat() {
        for entry in Self.everyHelp {
            let unconfirmed = entry.help.places.contains { !$0.confirmed }
            if unconfirmed {
                #expect(entry.help.caveat?.contains("Menu names differ between models") == true, "\(entry.family) \(entry.step)")
            } else {
                #expect(entry.help.caveat == nil, "\(entry.family) \(entry.step): only confirmed paths, no caveat")
            }
        }
        #expect(CameraManualHelpText.caveat.hasPrefix("Menu names differ between models"))
    }

    /// The paths confirmed from the camera's own pages (the IPCamera Web family's `weblg_en.xml` and menu, the IP camera web API's
    /// `custom_lang_English.txt` and `js_set.js`) or the maker's documents (TP-Link FAQs 688 and 4372; Reolink support articles
    /// 900000627963 and 4404480742425; for the DNS, the research's §4: Hikvision's manual 5.7.20, AXIS OS help, Hanwha's KB, Uniview's manual
    /// V3.00, Foscam FAQ 243, VIGI FAQ 4741). Anything else is shown as unconfirmed: Reolink's DNS switch, Amcrest's and Lorex's menus (the
    /// Dahua family's), XMEye's and a standalone UniFi camera's are best guesses.
    static let confirmed: Set<String> = [
        "hikvision internetWatch Configuration › Network › Basic Settings › TCP/IP",
        "axis internetWatch System › Network",
        "hanwha internetWatch Setup › Basic › IP & Port",
        "uniview internetWatch Setup › Network › DNS",
        "foscam internetWatch Settings › Network › IP Configuration",
        "foscam internetWatch (your camera, right-click) › Network Configuration",
        "vigi internetWatch Settings › Network Settings › Connect",
        "ipcamWeb timeZone Configuration › Network › Date & Time",
        "ipcamWeb timeSource Configuration › Network › Date & Time",
        "ipcamWeb cleanPicture Configuration › Media Setup › OSD",
        "ipcamWeb streams Configuration › Media Setup › Video Setup",
        "ipcamWeb cloud Configuration › Services Security › P2P",
        "ipcamWeb videoPassword Configuration › Services Security › Onvif",
        "ipcamWeb videoPassword Configuration › Services Security › RTSP",
        "ipcamWeb extraServices Configuration › Services Security › HIK",
        "ipcamWeb extraServices Configuration › Services Security › MEARI",
        "ipcamWeb internetWatch Configuration › Network › IP Address",
        "ipcWebAPI timeZone System › Date & Time",
        "ipcWebAPI timeSource System › Date & Time",
        "ipcWebAPI streams Camera › Video",
        "ipcWebAPI internetWatch Network › Basic",
        "tapo internetWatch (your camera) › Device Settings › Advanced Settings › Network Settings › Static IP",
        "reolink upnp Settings (the gear) › Network › Advanced › UPnP",
        "reolink upnp Camera Settings › Network › Advanced › Enable UPNP",
        "reolink cloud Camera Settings › Network › Advanced › UID",
    ]

    @Test func onlyThePathsTheResearchConfirmedAreShownAsConfirmed() {
        var shown: Set<String> = []
        for entry in Self.everyHelp {
            for place in entry.help.places where place.confirmed {
                let key = "\(entry.family.rawValue) \(entry.step.rawValue) \(place.path.joined(separator: " › "))"
                #expect(Self.confirmed.contains(key), "\(key) is shown as confirmed")
                #expect(!place.path.isEmpty, "a confirmed place names its menu")
                shown.insert(key)
            }
        }
        #expect(shown == Self.confirmed, "every confirmed path is used")
    }

    @Test func noHelpNamesAnyAddressButTheBridges() {
        let ipv4 = /\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/
        for entry in Self.everyHelp {
            let help = entry.help
            let texts = [help.why, help.router ?? "", help.note ?? "", help.then ?? "", help.caveat ?? ""] + help.values.flatMap { [$0.label, $0.value] }
                + help.places.flatMap { [$0.app, $0.action] + $0.path } + help.warnings
            for text in texts {
                for match in text.matches(of: ipv4) { #expect(String(match.output) == Self.bridge, "\(entry.family) \(entry.step): \(text)") }
            }
        }
    }

    // MARK: Why

    @Test func theWhyComesFromTheStepsOwnDetail() throws {
        #expect(try help(.timeSource, .refused, family: .reolink, detail: "the camera refused the login").why
                    == "The camera refused Camera Bridge’s login when it tried to change this.")
        let account = try help(.timeSource, .refused, family: .reolink,
                               detail: "the account Camera Bridge signs in with may not change this (use an administrator account)")
        #expect(account.why == "The account Camera Bridge signs in with may not change this setting: change it by hand, or sign Camera Bridge in "
                    + "with an administrator account.")
        #expect(try help(.cloud, .refused, family: .ipcamWeb, detail: "No Privilege").why.contains("administrator account"))
        #expect(try help(.streams, .refused, family: .onvif, detail: "the camera did not answer: the connection was refused").why
                    == "The camera didn’t answer when Camera Bridge tried.")
        #expect(try help(.cloud, .refused, family: .hikvision, detail: "the camera kept it on").why == "The camera didn’t take the change: the camera kept it on.")
        #expect(try help(.cleanPicture, family: .onvif, detail: "the camera has no ONVIF device service").why
                    == "Camera Bridge can’t change this on this camera: the camera has no ONVIF device service.")
        let cannot = "Camera Bridge can’t change this camera’s UPnP setting yet. If it has one, block the camera’s internet in your router (see Keep this camera local)."
        #expect(try help(.upnp, family: .tapo, detail: cannot).why == "Camera Bridge has no way to change this setting on this camera yet.")
        #expect(try help(.upnp, family: .onvif, detail: "not supported by this camera").why == "This camera doesn’t let Camera Bridge change this setting.")
        #expect(try help(.upnp, .refused, family: .onvif).why == "The camera didn’t take the change.")
    }

    // MARK: Families

    @Test func reolinksCloudOffSaysWhatStopsWorkingAndThatThePhoneAppHasNoSwitch() throws {
        let cloud = try help(.cloud, family: .reolink)
        #expect(cloud.places.first?.app == "The Reolink Client (on a computer)")
        #expect(cloud.values == [.init(label: "UID (P2P)", value: "off")])
        let note = try #require(cloud.note)
        #expect(note.contains("the Reolink app no longer reaches the camera away from home") && !note.contains("Doorbell"), "a camera is no doorbell")
        #expect(note.contains("The Reolink phone app has no switch for it"))
        var doorbell = Self.context
        doorbell.doorbell = true
        #expect(try help(.cloud, family: .reolink, context: doorbell).note?.contains("Doorbell rings still come through Apple Home.") == true)
        #expect(try help(.upnp, family: .reolink).note == "The Reolink phone app has no UPnP setting.")
    }

    /// Beside their DNS (research §4), Hikvision's, Dahua's and Amcrest's menus are only in other people's guides, the other makers' are not
    /// known, and the IP camera web API's OSD tab was not confirmed: they get the general instruction, with no menu path and the caveat; so
    /// does the DNS of a camera whose maker is not known.
    @Test func unconfirmedMenusGetTheGeneralInstruction() throws {
        for (family, step) in [(CameraFamily.hikvision, CameraSetupStepID.timeZone), (.hikvision, .timeSource), (.hikvision, .cleanPicture),
                               (.dahua, .timeSource), (.axis, .timeSource), (.foscam, .streams), (.vigi, .upnp), (.ipcWebAPI, .cleanPicture),
                               (.onvif, .internetWatch)] {
            let help = try help(step, .refused, family: family)
            #expect(help.places == [.init(app: "The camera’s web page", action: CameraManualHelpText.generalAction(step))], "\(family) \(step)")
            #expect(help.caveat == CameraManualHelpText.caveat, "\(family) \(step)")
        }
    }

    /// Where the camera has no place of its own (a Tapo's cloud and UPnP, the IPCamera Web family's UPnP), the router's way is the way,
    /// not "Or …" another.
    @Test func theRoutersWayAloneIsNotAnAlternative() throws {
        for (family, step) in [(CameraFamily.tapo, CameraSetupStepID.cloud), (.tapo, .upnp), (.ipcamWeb, .upnp)] {
            let help = try help(step, family: family)
            #expect(help.places.isEmpty, "\(family) \(step)")
            let router = try #require(help.router)
            #expect(!router.hasPrefix("Or ") && !router.contains("too"), "\(family) \(step): \(router)")
        }
        #expect(try help(.upnp, family: .ipcamWeb).why == "This camera has no UPnP setting of its own.")
        #expect(try help(.cloud, family: .reolink).router?.hasPrefix("Or block") == true, "beside a place of its own, the router is another way")
    }

    @Test func aTapoHasNoCloudSwitchSoTheRouterBlocksIt() throws {
        let cloud = try help(.cloud, family: .tapo)
        #expect(cloud.places.isEmpty && cloud.values.isEmpty)
        #expect(cloud.why == "Tapo cameras have no switch for TP-Link’s cloud that Camera Bridge knows of.")
        #expect(cloud.router == "Block the camera’s internet in your router (see Keep this camera local).")
    }

    // MARK: The DNS by hand, per maker (research §4)

    private func watch(_ family: CameraFamily, context: CameraManualHelpText.Context = CameraManualHelpTests.full) throws -> CameraManualHelp {
        try help(.internetWatch, .refused, family: family, context: context)
    }

    private static func web(_ path: [String], _ action: String, confirmed: Bool = true) -> CameraManualHelp.Place {
        .init(app: "The camera’s web page", path: path, action: action, confirmed: confirmed)
    }

    /// An ONVIF camera that says who made it.
    private static func maker(_ manufacturer: String, model: String = "") -> CameraConfiguration {
        var camera = CameraConfiguration(name: "Cam", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: Self.camera), username: "admin")
        camera.manufacturer = manufacturer
        camera.model = model
        return camera
    }

    /// Whether the help says to keep the camera's address as it is and reserve it in the router: a camera whose DNS stays only with a fixed
    /// address.
    private static func keepsItsAddress(_ help: CameraManualHelp) -> Bool { help.keep != nil && help.reserve != nil }

    @Test func hikvisionsDNSIsUnderTCPIPWithDHCPUnticked() throws {
        let watch = try watch(.hikvision)
        #expect(watch.places == [Self.web(["Configuration", "Network", "Basic Settings", "TCP/IP"],
                                          "Untick DHCP, keep the IPv4 address, subnet mask and default gateway as they are, and enter the Preferred DNS "
                                              + "Server and the Alternate DNS Server below.")])
        #expect(watch.caveat == nil && watch.note == nil && Self.keepsItsAddress(watch), "its OEMs too; likely kept only with a fixed address")
        #expect(CameraFamily.of(Self.maker("ANNKE"), webAPI: nil) == .hikvision, "an OEM's camera")
    }

    @Test func reolinksDNSIsOnItsNetworkPageInTheAppTheClientAndTheWebPage() throws {
        let watch = try watch(.reolink)
        #expect(watch.places == [
            .init(app: "The Reolink app", path: ["Settings", "(your camera)", "Network Information"],
                  action: "Set the DNS by hand (not automatic) and enter the DNS servers below."),
            .init(app: "The Reolink Client (on a computer)", path: ["Device Settings", "Network", "Network Information", "Network Settings"],
                  action: "Choose Static DNS instead of Auto DNS and enter the DNS servers below."),
            Self.web(["Settings (the gear)", "Network Settings", "Set Up"],
                     "Set the DNS by hand (not automatic) and enter the DNS servers below. On newer firmware it is under Device Settings › Network › Set up.",
                     confirmed: false),
        ])
        #expect(watch.caveat == CameraManualHelpText.caveat, "the pages are confirmed, the DNS switch's name is not")
        #expect(watch.note == "Battery cameras have no DNS setting." && !Self.keepsItsAddress(watch))
    }

    @Test func dahuasDNSIsUnderTCPIPAndChangesOnDHCPToo() throws {
        let watch = try watch(.dahua)
        #expect(watch.places == [Self.web(["Setup", "Network", "TCP/IP"],
                                          "Leave Mode as it is (the DNS can be changed on DHCP too) and enter the Preferred DNS and the Alternate DNS below.",
                                          confirmed: false)])
        #expect(watch.caveat != nil, "Dahua's own menu; Amcrest's and Lorex's cameras are a best guess")
        #expect(!Self.keepsItsAddress(watch))
        for maker in ["Amcrest", "LOREX", "Dahua"] {
            #expect(CameraFamily.of(Self.maker(maker), webAPI: nil) == .dahua, "\(maker)")
        }
    }

    @Test func axisTurnsAssignDNSAutomaticallyOff() throws {
        let watch = try watch(.axis)
        #expect(watch.places == [Self.web(["System", "Network"],
                                          "Under DNS, turn off Assign DNS automatically and add the DNS servers below. Leave Assign IPv4 automatically as it is.")])
        #expect(watch.caveat == nil && !Self.keepsItsAddress(watch))
    }

    @Test func hanwhaUnticksDNSSettingByDHCP() throws {
        let watch = try watch(.hanwha)
        #expect(watch.places == [Self.web(["Setup", "Basic", "IP & Port"],
                                          "Untick DNS setting by DHCP, enter the DNS servers below as DNS 1 and DNS 2, and press Apply.")])
        #expect(watch.caveat == nil && !Self.keepsItsAddress(watch))
    }

    @Test func univiewHasADNSPageOfItsOwn() throws {
        let watch = try watch(.uniview)
        #expect(watch.places == [Self.web(["Setup", "Network", "DNS"], "Enter the DNS servers below as its preferred and alternate DNS servers.")])
        #expect(watch.note == "If it won’t take them, set its address to static first under Setup › Network › Network, keeping the same address, "
                    + "mask and gateway, and reserve it in your router.")
        #expect(watch.caveat == nil && !Self.keepsItsAddress(watch), "its menu is confirmed; whether it needs a fixed address is not known")
    }

    @Test func foscamUnticksObtainIPFromDHCPAndRestarts() throws {
        let watch = try watch(.foscam)
        #expect(watch.places == [
            Self.web(["Settings", "Network", "IP Configuration"],
                     "Untick Obtain IP From DHCP, keep the IP address, subnet mask and gateway as they are, and enter the DNS servers below, starting "
                         + "with the Primary DNS Server."),
            .init(app: "Foscam’s Equipment Search Tool (on a computer)", path: ["(your camera, right-click)", "Network Configuration"],
                  action: "Untick Obtain IP From DHCP, keep the address as it is and enter the DNS servers below.", confirmed: true),
        ])
        #expect(watch.note == "The camera restarts when you save." && Self.keepsItsAddress(watch) && watch.caveat == nil)
        #expect(!watch.warnings.contains(CameraManualHelpText.restartWarning), "it restarts on its own")
    }

    @Test func vigiSetsIPv4ModeToStatic() throws {
        let watch = try watch(.vigi)
        #expect(watch.places == [Self.web(["Settings", "Network Settings", "Connect"],
                                          "Set IPv4 Mode to Static, keep the IP address, subnet mask and gateway as they are, and enter the Preferred DNS "
                                              + "and the Alternative DNS below.")])
        #expect(watch.note == "VIGI VMS and the VIGI Config Tool can change it too." && Self.keepsItsAddress(watch) && watch.caveat == nil)
        #expect(CameraFamily.of(Self.maker("TP-Link", model: "VIGI C340"), webAPI: nil) == .vigi, "TP-Link's VIGI line, not a Tapo")
    }

    @Test func aTapoIsChangedInTheTapoAppWithAFixedAddress() throws {
        let watch = try watch(.tapo)
        #expect(watch.places == [.init(app: "The Tapo app", path: ["(your camera)", "Device Settings", "Advanced Settings", "Network Settings", "Static IP"],
                                       action: "Choose Static IP, keep the camera’s IP address, subnet mask and gateway as they are, and enter the DNS "
                                           + "servers below.", confirmed: true)])
        #expect(watch.note == "Battery Tapo models, and the C100, C200, TC60 and TC70 at hardware versions 1 and 2, don’t have this setting.")
        #expect(watch.warnings.contains("Check every number before you save: a wrong fixed address on a Tapo can need a factory reset."))
        #expect(Self.keepsItsAddress(watch) && watch.link == nil, "a Tapo has no web page: the app's path instead")
        #expect(!watch.warnings.contains(CameraManualHelpText.recorderWarning), "no recorder runs a Tapo's network")
    }

    @Test func theIPCameraWebFamilyChoosesStaticDNSServer() throws {
        let watch = try watch(.ipcamWeb)
        #expect(watch.places == [Self.web(["Configuration", "Network", "IP Address"],
                                          "Under DNS, choose Static DNS Server, then enter the Preferred DNS Server and the Alternative DNS Server below.")])
        #expect(watch.caveat == nil && watch.note == nil && !Self.keepsItsAddress(watch), "its DNS stays on DHCP")
    }

    @Test func theIPCameraWebAPIsDNSNeedsAStaticAddressFirst() throws {
        let watch = try watch(.ipcWebAPI)
        #expect(watch.places == [Self.web(["Network", "Basic"],
                                          "Set Mode to Static and keep the camera’s IP address, subnet mask and gateway as they are, then enter the "
                                              + "Preferred DNS Server and the Alternate DNS Server below.")])
        #expect(watch.note == "The DNS fields can’t be changed while Mode is DHCP." && Self.keepsItsAddress(watch) && watch.caveat == nil)
    }

    @Test func xmeyeIsChangedOnTheRecorderOrInItsDesktopApp() throws {
        let watch = try watch(.xmeye)
        #expect(watch.places == [.init(app: "The recorder’s menu, or the CMS or VMS app on a computer", path: ["Setting", "System", "Network"],
                                       action: "Untick DHCP Enable, keep the IP address, subnet mask and gateway as they are, and enter the Primary DNS "
                                           + "and the Secondary DNS below.")])
        #expect(watch.caveat != nil && Self.keepsItsAddress(watch), "a best guess; likely kept only with a fixed address")
        #expect(watch.link == nil, "the help names no page of the camera's own")
        #expect(CameraFamily.of(Self.maker("Xiongmai"), webAPI: nil) == .xmeye)
    }

    @Test func aStandaloneUniFiCameraSignsInWithItsRecoveryCode() throws {
        let watch = try watch(.unifi)
        #expect(watch.places == [Self.web(["Network"], "Choose Static, keep the IP address, subnet mask and gateway as they are, and enter the DNS "
                                              + "servers below.", confirmed: false)])
        #expect(watch.note == "Sign in with ubnt and the camera’s recovery code." && Self.keepsItsAddress(watch) && watch.caveat != nil)
        #expect(CameraFamily.of(Self.maker("Ubiquiti Inc."), webAPI: nil) == .unifi)
    }

    /// Review focus 5: a camera whose maker Camera Bridge does not know gets the general instruction and the caveat, no link (its web page,
    /// if it has one, is not known to be at its web port), and still the values to copy, the warnings and the router's way.
    @Test func anUnknownCameraGetsTheGenericHelpWithoutALink() throws {
        let watch = try watch(.onvif)
        #expect(watch.places == [.init(app: "The camera’s web page", action: CameraManualHelpText.generalAction(.internetWatch))])
        #expect(watch.caveat == CameraManualHelpText.caveat && watch.link == nil)
        #expect(watch.values.filter(\.copy).map(\.value) == [Self.bridge, Self.bridge] && !watch.warnings.isEmpty && watch.router != nil)
        #expect(watch.current == ["192.168.77.1", "192.0.2.53"] && !Self.keepsItsAddress(watch))
    }

    // MARK: The camera's page, what it asks now, what to keep

    /// Ruling D1: the link is the camera's configured address and web port (http, or https where Camera Bridge reaches it so), never
    /// anything the camera says; the help has it only where it names the camera's own web page, and for a maker Camera Bridge knows.
    @Test func theHelpLinksTheCamerasOwnPage() throws {
        let link = CameraManualHelp.Link(label: "Open the camera’s web page", url: "http://192.168.77.120/")
        for family in [CameraFamily.hikvision, .reolink, .dahua, .axis, .hanwha, .uniview, .foscam, .vigi, .ipcamWeb, .ipcWebAPI, .unifi] {
            #expect(try watch(family).link == link, "\(family)")
        }
        #expect(try help(.upnp, family: .reolink, context: Self.full).link == link, "the UPnP help names its web page too")
        #expect(try help(.cloud, family: .reolink, context: Self.full).link == nil, "the Reolink Client alone")
        for family in [CameraFamily.tapo, .onvif, .xmeye] { #expect(try watch(family).link == nil, "\(family)") }
        var none = Self.full
        none.webPage = nil
        #expect(try watch(.hikvision, context: none).link == nil, "no page known")

        typealias Text = CameraManualHelpText
        #expect(Text.webPageURL(CameraEndpoint(host: "192.168.77.120")) == "http://192.168.77.120/")
        #expect(Text.webPageURL(CameraEndpoint(host: "192.168.77.120", httpPort: 8080)) == "http://192.168.77.120:8080/")
        #expect(Text.webPageURL(CameraEndpoint(host: "192.168.77.120", httpPort: 443, useHTTPS: true)) == "https://192.168.77.120/")
        #expect(Text.webPageURL(CameraEndpoint(host: "192.168.77.120", httpPort: 80, useHTTPS: true)) == "https://192.168.77.120:80/")
        #expect(Text.webPageURL(CameraEndpoint(host: "porch-cam.local")) == "http://porch-cam.local/")
        #expect(Text.webPageURL(CameraEndpoint(host: "2001:db8::20")) == "http://[2001:db8::20]/")
        #expect(Text.webPageURL(CameraEndpoint(host: "[2001:db8::20]", httpPort: 8000)) == "http://[2001:db8::20]:8000/")
        for host in ["", " ", "192.0.2.1/admin", "user@192.0.2.1", "192.0.2.1?x=1", "192.0.2.1#x", "javascript:alert(1)", "câmera.local", "192.0.2.1 x"] {
            #expect(Text.webPageURL(CameraEndpoint(host: host)) == nil, "\(host)")
        }
        #expect(Text.webPageURL(CameraEndpoint(host: "192.0.2.1", httpPort: 0)) == nil)
    }

    /// "Right now it asks A and B. Change both to C.": the Watch help carries the servers the camera asks now (the engine's last reading); a
    /// setup report's does not (its own change row says them, as the run read them), and no other help does.
    @Test func theHelpSaysWhatToChange() throws {
        #expect(try watch(.reolink).current == ["192.168.77.1", "192.0.2.53"])
        #expect(try help(.timeSource, family: .reolink, context: Self.full).current.isEmpty)
        #expect(try watch(.reolink, context: Self.context).current.isEmpty, "not read: nothing said")
        let report = CameraSetupReport(steps: [CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .refused)], state: nil, canRestore: true)
        let helped = try #require(CameraManualHelpText.withHelp(report, family: .reolink, context: Self.full).steps.first?.manualHelp)
        #expect(helped.current.isEmpty && helped.values.contains { $0.copy && $0.value == Self.bridge })
    }

    /// A camera whose DNS stays only with a fixed address (research §4 "Static first?", §5): "Keep its address as it is" with the address,
    /// mask and gateway its last reading showed, and the router reservation with its hardware address, each left out when not known; with
    /// nothing known of its address, the reservation in words.
    @Test func aStaticFirstCameraSaysKeepItsAddress() throws {
        let staticFirst: [CameraFamily] = [.hikvision, .foscam, .vigi, .tapo, .ipcWebAPI, .xmeye, .unifi]
        for family in CameraFamily.allCases {
            let watch = try watch(family)
            if staticFirst.contains(family) {
                #expect(watch.keep == .init(address: Self.camera, mask: "255.255.255.0", gateway: "192.168.77.1"), "\(family)")
                #expect(watch.reserve == .init(address: Self.camera, mac: "02:00:00:00:00:21"), "\(family)")
            } else {
                #expect(watch.keep == nil && watch.reserve == nil, "\(family): its DNS stays on DHCP")
            }
        }
        var bare = Self.full
        bare.addressing = nil
        let known = try watch(.hikvision, context: bare)
        #expect(known.keep == .init(address: Self.camera, mask: nil, gateway: nil) && known.reserve == .init(address: Self.camera, mac: nil),
                "only the address Camera Bridge reaches it at")
        #expect(!known.warnings.contains(CameraManualHelpText.reserveWarning))
        bare.cameraAddress = nil
        let unknown = try watch(.hikvision, context: bare)
        #expect(unknown.keep == nil && unknown.reserve == nil && unknown.warnings.contains(CameraManualHelpText.reserveWarning))
        #expect(try help(.upnp, family: .hikvision, context: Self.full).keep == nil, "the DNS alone")

        // A report's Watch step that offers to fix the address (or fixed it) shows the address it read just now, its hardware address too.
        let offered = CameraAddressing(address: Self.camera, subnetMask: "255.255.254.0", gateway: "192.168.76.1", hardwareAddress: "02:00:00:00:00:22")
        let step = CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .notSupported,
                                   fixAddress: CameraSetupFixAddress(addressing: offered, changes: [], method: .hikvisionISAPI))
        let report = CameraSetupReport(steps: [step], state: nil, canRestore: false)
        let helped = try #require(CameraManualHelpText.withHelp(report, family: .hikvision, context: Self.full).steps.first?.manualHelp)
        #expect(helped.keep == .init(address: Self.camera, mask: "255.255.254.0", gateway: "192.168.76.1"))
        #expect(helped.reserve == .init(address: Self.camera, mac: "02:00:00:00:00:22"))

        // A reading of another address than the one Camera Bridge reaches the camera at (a stale answer) is not the camera's address now.
        var elsewhere = Self.full
        elsewhere.addressing = CameraAddressing(address: "192.168.77.99", subnetMask: "255.255.255.0", gateway: "192.168.77.1", hardwareAddress: "02:00:00:00:00:23")
        let other = try watch(.hikvision, context: elsewhere)
        #expect(other.keep == .init(address: Self.camera, mask: nil, gateway: nil) && other.reserve == .init(address: Self.camera, mac: nil))
    }

    /// The warnings that apply (research §5): both slots the bridge, a restart when the camera asks for one, a recorder that runs the camera's
    /// network; Tapo's own; on the Watch help only.
    @Test func theDNSHelpWarnsOfASecondServerARestartAndARecorder() throws {
        typealias Text = CameraManualHelpText
        #expect(try watch(.hikvision).warnings == [Text.bothSlots, Text.restartWarning, Text.recorderWarning])
        #expect(Text.bothSlots == "Put Camera Bridge in both slots: with a public server, or none, as the second one, the camera can look names up "
                    + "without it.")
        #expect(Text.restartWarning == "If the camera asks to restart after you save, let it: it may keep its old DNS servers until then.")
        #expect(Text.recorderWarning == "If the camera is plugged into a recorder’s own ports, the recorder runs its network: set its DNS on the recorder "
                    + "instead.")
        #expect(try watch(.foscam).warnings == [Text.bothSlots, Text.recorderWarning])
        #expect(try watch(.tapo).warnings == [Text.bothSlots, "Check every number before you save: a wrong fixed address on a Tapo can need a factory reset.",
                                              Text.restartWarning])
        #expect(try help(.cloud, family: .hikvision, context: Self.full).warnings.isEmpty)
    }

    /// IPv6 on, as Camera Bridge last read it (ONVIF's `GetNetworkInterfaces`): the camera may take DNS servers from the router over IPv6
    /// too (router advertisements, DHCPv6), around the guard (research §5). The DNS help says so then, and only then.
    @Test func ipv6OnAddsTheWarning() throws {
        typealias Text = CameraManualHelpText
        #expect(Text.ipv6Warning == "IPv6 is on: the camera may get DNS servers from your router over IPv6 too. Turn IPv6 off on the camera.")
        var on = Self.full
        on.ipv6On = true
        #expect(try watch(.onvif, context: on).warnings == [Text.bothSlots, Text.ipv6Warning, Text.restartWarning, Text.recorderWarning])
        #expect(try watch(.hikvision, context: on).warnings.contains(Text.ipv6Warning))
        #expect(try watch(.onvif).warnings.contains(Text.ipv6Warning) == false, "off, or not read: no warning")
        #expect(try help(.cloud, family: .onvif, context: on).warnings.isEmpty, "the DNS help only")
        let notListed = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        let card = Text.withHelp(security([], guard: notListed), family: .onvif, context: on)
        #expect(card.findings.first { $0.feature == .internetGuard }?.manualHelp?.warnings.contains(Text.ipv6Warning) == true, "the Security card's too")
    }

    /// The router's way, honest per router (research §3.1, recommendation 7).
    @Test func theRouterSaysWhichRoutersCanHandTheCameraItsDNS() throws {
        let router = try #require(try watch(.reolink).router)
        #expect(router == "Or have your router hand this camera 192.168.77.28 as its DNS server, with a DHCP reservation: OpenWrt, pfSense, OPNsense, "
                    + "MikroTik, ASUS and Pi-hole can do that for one device; UniFi, Synology and Firewalla only for a whole network (such as a separate "
                    + "one for the cameras); eero, Google/Nest Wifi, Deco and Orbi can’t, so change it on the camera. The router’s way works only while the camera "
                    + "takes its DNS from DHCP (automatic), and only from the camera’s next DHCP renewal or restart. Or block the camera’s internet in "
                    + "your router (see Keep this camera local). A DNS server from the router counts too, but it can change when the router renews the "
                    + "camera’s address.")
    }

    @Test func theStreamsHelpTakesTheValuesTheSetupPlanned() throws {
        let planned = [CameraSetupChange(label: "Main stream", now: "H.265, 20 fps", after: "H.264, 20 fps, keyframe every 2 s")]
        #expect(try help(.streams, .refused, family: .ipcWebAPI, changes: planned).values == [.init(label: "Main stream", value: "H.264, 20 fps, keyframe every 2 s")])
        let general = try help(.streams, family: .onvif).values.map(\.label)
        #expect(general == ["Main stream", "Sub stream", "Smart codec (H.264+ or H.265+)"])
    }

    @Test func theFamilyComesFromTheVendorTheMakerAndWhatTheBridgeSawOfItsWebAPI() {
        func camera(_ vendor: CameraVendor, manufacturer: String = "", model: String = "", _ change: (inout CameraConfiguration) -> Void = { _ in }) -> CameraConfiguration {
            var camera = CameraConfiguration(name: "Cam", kind: .camera, vendor: vendor, endpoint: CameraEndpoint(host: "192.168.77.44"), username: "admin")
            camera.manufacturer = manufacturer
            camera.model = model
            change(&camera)
            return camera
        }
        #expect(CameraFamily.of(camera(.hikvision), webAPI: nil) == .hikvision)
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "HIKVISION"), webAPI: nil) == .hikvision)
        #expect(CameraFamily.of(camera(.reolink), webAPI: nil) == .reolink)
        #expect(CameraFamily.of(camera(.amcrest), webAPI: nil) == .dahua)
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "Dahua"), webAPI: nil) == .dahua)
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "tp-link", model: "C325WB"), webAPI: nil) == .tapo)
        // The maker an ONVIF camera says (any case, anywhere in its name).
        for (maker, family) in [("Annke", CameraFamily.hikvision), ("Amcrest Technologies", .dahua), ("LOREX", .dahua), ("AXIS", .axis),
                                ("Hanwha Vision", .hanwha), ("Wisenet", .hanwha), ("UNIVIEW", .uniview), ("Foscam", .foscam),
                                ("XiongMai Technologies", .xmeye), ("Ubiquiti", .unifi), ("Reolink", .reolink)] {
            #expect(CameraFamily.of(camera(.onvif, manufacturer: maker), webAPI: nil) == family, "\(maker)")
        }
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "TP-LINK", model: "VIGI C540-W"), webAPI: nil) == .vigi)
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "Annke"), webAPI: .ipcWebAPI) == .ipcWebAPI, "what its address showed comes first")
        #expect(CameraFamily.of(camera(.onvif, manufacturer: "A_ONVIF_CAMERA"), webAPI: .ipcamWeb) == .ipcamWeb)
        #expect(CameraFamily.of(camera(.onvif), webAPI: .ipcWebAPI) == .ipcWebAPI)
        #expect(CameraFamily.of(camera(.onvif), webAPI: nil) == .onvif)
        // What an earlier setup kept says it too (the bridge has not asked the camera's web page since it started).
        #expect(CameraFamily.of(camera(.onvif) { $0.setupBackup = CameraSetupBackup(version: 1, created: Date(), extraServices: .init(services: ["hik": ["on": "1"]])) },
                                webAPI: nil) == .ipcamWeb)
        #expect(CameraFamily.of(camera(.onvif) { $0.setupState = CameraSetupState(started: Date(), steps: [.init(id: .videoPassword, status: .refused)]) },
                                webAPI: nil) == .ipcamWeb)
        #expect(CameraFamily.of(camera(.onvif) { $0.cleanPictureBackup = CleanPictureBackup(method: .ipcWebAPI, document: "1") }, webAPI: nil) == .ipcWebAPI)
        #expect(CameraFamily.of(camera(.onvif) { $0.setupBackup = CameraSetupBackup(version: 1, created: Date(), cloud: .init(path: "getNetworkConfig", enabled: true, cloudType: "2")) },
                                webAPI: nil) == .ipcWebAPI)
    }

    // MARK: The Security card

    static let now = Date(timeIntervalSince1970: 1_792_224_000)

    private func security(_ readings: [RemoteAccessFinding], model: String? = nil, guard evidence: GuardEvidence?) -> CameraSecurity {
        CameraSecurity.assess(readings, cloudModel: model, internetGuard: evidence, checkedAt: Self.now)
    }

    @Test func theGuardsNotWatchedFindingSaysHowToPointTheDNSAtTheBridge() throws {
        let notListed = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        let helped = CameraManualHelpText.withHelp(security([RemoteAccessFinding(feature: .upnp, state: .off)], guard: notListed), family: .reolink, context: Self.context)
        let finding = try #require(helped.findings.first { $0.feature == .internetGuard })
        let help = try #require(finding.manualHelp)
        #expect(help.why == "The Internet guard sees a camera’s lookups only while its DNS asks Camera Bridge (192.168.77.28) and nothing else.")
        #expect(help.values.contains(.init(label: "Preferred DNS server", value: Self.bridge, copy: true)) && help.router != nil)
        #expect(help.places.allSatisfy { !$0.confirmed } && help.caveat != nil, "Reolink's DNS fields are not confirmed")
        let other = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true, asksBridge: false)
        #expect(CameraManualHelpText.withHelp(security([], guard: other), family: .hikvision, context: Self.context)
                    .findings.first { $0.feature == .internetGuard }?.manualHelp != nil, "its DNS asks another server")

        let watched = GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: 3_600)
        #expect(CameraManualHelpText.withHelp(security([], guard: watched), family: .reolink, context: Self.context)
                    .findings.allSatisfy { $0.feature != .internetGuard || $0.manualHelp == nil }, "a watched camera needs nothing")
        let mac = CameraManualHelpText.withHelp(security([], guard: nil), family: .reolink, context: Self.context)
        #expect(mac.findings.allSatisfy { $0.manualHelp == nil || $0.feature != .internetGuard }, "no guard here: nothing to point at")
        let elsewhere = CameraManualHelpText.withHelp(security([], guard: notListed), family: .reolink,
                                                      context: .init(timeServer: nil, guardServer: nil, timeZone: nil))
        #expect(elsewhere.findings.first { $0.feature == .internetGuard }?.manualHelp == nil, "a camera on another network can't be watched")
    }

    /// "Point its DNS at Camera Bridge yourself" only where the DNS is why the guard does not watch the camera: it asks other servers (not
    /// waiting for a restart that takes the bridge), or its DNS could not be read. Not while it already asks the bridge (the box has not
    /// started watching it yet), nor while a listed camera's box isn't running.
    @Test func theGuardsDNSHelpOnlyWhereTheDNSIsWhy() {
        typealias DNS = CameraManualHelpText.GuardDNS
        #expect(DNS(listed: false, asksBridge: false).wantsHelp, "asks other servers")
        #expect(DNS(listed: false, asksBridge: nil).wantsHelp && DNS(listed: true, asksBridge: nil).wantsHelp, "could not be read")
        #expect(DNS(listed: true, asksBridge: false).wantsHelp, "it no longer asks the bridge")
        #expect(!DNS(listed: false, asksBridge: true).wantsHelp && !DNS(listed: true, asksBridge: true).wantsHelp, "already asks the bridge")
        #expect(!DNS(listed: true, asksBridge: false, waitsForRestart: true).wantsHelp, "takes the bridge when it restarts")
        #expect(!DNS(listed: true, asksBridge: nil, available: false).wantsHelp && !DNS(listed: true, asksBridge: false, available: false).wantsHelp,
                "the box isn't running")
        #expect(DNS(listed: false, asksBridge: false, available: false).wantsHelp, "a camera not on the list: its DNS is why")

        let notListed = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
        func guardHelp(_ dns: DNS?) -> CameraManualHelp? {
            CameraManualHelpText.withHelp(security([], guard: notListed), family: .reolink, context: Self.context, guardDNS: dns)
                .findings.first { $0.feature == .internetGuard }?.manualHelp
        }
        #expect(guardHelp(nil) != nil && guardHelp(DNS(listed: false, asksBridge: false)) != nil)
        #expect(guardHelp(DNS(listed: false, asksBridge: true)) == nil)
        let waiting = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true, asksBridge: false,
                                    waitsForRestart: true)
        #expect(CameraManualHelpText.withHelp(security([], guard: waiting), family: .hikvision, context: Self.context,
                                              guardDNS: DNS(listed: true, asksBridge: false, waitsForRestart: true))
                    .findings.first { $0.feature == .internetGuard }?.manualHelp == nil)
    }

    @Test func whatTheSetupCantChangeOnTheCardGetsHelpAndWhatItCanDoesNot() throws {
        let readings = [RemoteAccessFinding(feature: .upnp, state: .on), RemoteAccessFinding(feature: .cloud, state: .on, linked: true, canChange: true),
                        RemoteAccessFinding(feature: .unauthenticatedVideo, state: .off)]
        let helped = CameraManualHelpText.withHelp(security(readings, guard: nil), family: .reolink, context: Self.context)
        let upnp = try #require(helped.findings.first { $0.feature == .upnp }?.manualHelp)
        #expect(upnp.why == "Camera Bridge can’t turn this off on this camera, so turn it off by hand.")
        #expect(upnp.places.contains { $0.path == ["Settings (the gear)", "Network", "Advanced", "UPnP"] })
        #expect(helped.findings.first { $0.feature == .cloud }?.manualHelp == nil, "Set up for Camera Bridge can change it")
        #expect(helped.findings.first { $0.feature == .unauthenticatedVideo }?.manualHelp == nil, "already right")
        let unknown = CameraManualHelpText.withHelp(security([RemoteAccessFinding(feature: .upnp, state: .unknown)], guard: nil), family: .onvif, context: Self.context)
        #expect(unknown.findings.first { $0.feature == .upnp }?.manualHelp?.why == "Camera Bridge can’t read this setting on this camera, so check it by hand.")
        let tapo = CameraManualHelpText.withHelp(security([], model: "TP-Link Tapo", guard: nil), family: .tapo, context: Self.context)
        #expect(tapo.findings.first { $0.feature == .cloud }?.manualHelp?.why == "Tapo cameras have no switch for TP-Link’s cloud that Camera Bridge knows of.")
    }

    @Test func aReportGetsHelpOnlyOnTheStepsThatCouldNotBeDone() throws {
        let report = CameraSetupReport(steps: [
            CameraSetupStep(id: .timeZone, title: "Time zone", status: .alreadyRight),
            CameraSetupStep(id: .timeSource, title: "Time from the bridge", status: .refused, detail: "the camera refused the login"),
            CameraSetupStep(id: .streams, title: "Streams", status: .refused, changes: [.init(label: "Main stream", now: "H.265", after: "H.264")]),
            CameraSetupStep(id: .upnp, title: "UPnP off", status: .notSupported, detail: "not supported by this camera"),
            CameraSetupStep(id: .internetWatch, title: "Watch its internet", status: .notRun),
        ], state: nil, canRestore: true)
        let helped = CameraManualHelpText.withHelp(report, family: .reolink, context: Self.context)
        #expect(helped.steps.map { $0.manualHelp != nil } == [false, true, true, true, false])
        #expect(helped.steps[1].manualHelp?.values.contains(.init(label: "NTP server", value: Self.bridge, copy: true)) == true)
        #expect(helped.steps[2].manualHelp?.values == [.init(label: "Main stream", value: "H.264")])
        #expect(helped.canRestore && helped.steps.map(\.status) == report.steps.map(\.status), "nothing else changes")
    }

    @Test func theHelpGoesToThePageAsPlainJSON() throws {
        let step = CameraSetupStep(id: .upnp, title: "UPnP off", status: .notSupported,
                                   manualHelp: CameraManualHelpText.step(.upnp, status: .notSupported, detail: nil, family: .reolink, context: Self.context))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(step)) as? [String: Any])
        let help = try #require(json["manualHelp"] as? [String: Any])
        #expect(help["why"] as? String == "This camera doesn’t let Camera Bridge change this setting.")
        let places = try #require(help["places"] as? [[String: Any]])
        #expect(places.first?["path"] as? [String] == ["Settings (the gear)", "Network", "Advanced", "UPnP"] && places.first?["confirmed"] as? Bool == true)
        #expect(help["link"] == nil && help["keep"] == nil && help["reserve"] == nil, "left out when there is none")
        #expect(help["current"] as? [String] == [] && help["warnings"] as? [String] == [])
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraSetupStep(id: .upnp, title: "UPnP off", status: .done))) as? [String: Any])
        #expect(plain["manualHelp"] == nil, "a step done needs none")
        #expect(try JSONDecoder().decode(CameraSetupStep.self, from: JSONEncoder().encode(step)) == step)

        let watch = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(try watch(.hikvision))) as? [String: Any])
        #expect(watch["link"] as? [String: String] == ["label": "Open the camera’s web page", "url": "http://192.168.77.120/"])
        #expect(watch["current"] as? [String] == ["192.168.77.1", "192.0.2.53"])
        #expect(watch["keep"] as? [String: String] == ["address": Self.camera, "mask": "255.255.255.0", "gateway": "192.168.77.1"])
        #expect(watch["reserve"] as? [String: String] == ["address": Self.camera, "mac": "02:00:00:00:00:21"])
        #expect((watch["warnings"] as? [String])?.count == 3)
        let values = try #require(watch["values"] as? [[String: Any]])
        #expect(values.map { $0["copy"] as? Bool } == [false, true, true], "the DNS servers can be copied, the mode is chosen")
    }

    // MARK: The page's fixtures

    /// The helps linux/web-tests/manual-help.test.mjs draws, by name, as this table writes them: the Reolink doorbell's guard (unconfirmed
    /// places, the router's way, what it asks now), a Hikvision's Watch (its menu confirmed, its page, keep and reserve), a Tapo's (the app,
    /// no page) and the IPCamera Web family's cloud (a confirmed path).
    static var webFixtures: [String: CameraManualHelp] {
        get throws {
            let notListed = GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: false)
            var doorbell = full
            doorbell.webPage = "http://192.168.77.31/"
            doorbell.cameraAddress = "192.168.77.31"
            doorbell.addressing = nil
            let guardHelp = CameraManualHelpText.withHelp(CameraSecurity.assess([], cloudModel: nil, internetGuard: notListed, checkedAt: now),
                                                          family: .reolink, context: doorbell).findings.first { $0.feature == .internetGuard }?.manualHelp
            var tapo = full
            tapo.webPage = nil
            return [
                "reolinkGuard": try #require(guardHelp),
                "hikvisionWatch": try #require(CameraManualHelpText.step(.internetWatch, status: .refused, detail: nil, family: .hikvision, context: full)),
                "tapoWatch": try #require(CameraManualHelpText.step(.internetWatch, status: .notSupported, detail: nil, family: .tapo, context: tapo)),
                "ipcamWebCloud": try #require(CameraManualHelpText.step(.cloud, status: .refused, detail: nil, family: .ipcamWeb, context: context)),
            ]
        }
    }

    struct WebFixtures: Codable {
        var note: String
        var helps: [String: CameraManualHelp]
    }

    static let webFixturesFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "linux/web-tests/support/manual-help-fixtures.json")

    /// The page's fixtures are this table's own words, so they can't drift from it. After changing the table, write them again with
    /// `CB_WRITE_WEB_FIXTURES=1 swift test --filter CameraManualHelpTests`.
    @Test func theWebPagesFixturesAreTheTablesOwnWords() throws {
        let expected = WebFixtures(note: "Written by BridgeEngine's CameraManualHelpTests (CB_WRITE_WEB_FIXTURES=1 swift test --filter CameraManualHelpTests); "
                                       + "theWebPagesFixturesAreTheTablesOwnWords checks every help against CameraManualHelpText.",
                                   helps: try Self.webFixtures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["CB_WRITE_WEB_FIXTURES"] == "1" {
            try (encoder.encode(expected) + Data("\n".utf8)).write(to: Self.webFixturesFile)
        }
        let file = try JSONDecoder().decode(WebFixtures.self, from: Data(contentsOf: Self.webFixturesFile))
        for (name, help) in expected.helps {
            #expect(file.helps[name] == help, "\(name) is not the table's: write the fixtures again (CB_WRITE_WEB_FIXTURES=1)")
        }
        #expect(Set(file.helps.keys) == Set(expected.helps.keys))
    }
}
