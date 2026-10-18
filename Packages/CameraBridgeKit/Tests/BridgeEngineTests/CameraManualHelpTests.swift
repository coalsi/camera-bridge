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
            #expect(watch.values.contains(.init(label: "Preferred DNS server", value: Self.bridge)), "\(family)")
            #expect(watch.values.contains(.init(label: "Alternate DNS server", value: Self.bridge)), "\(family)")
            let router = try #require(watch.router, "\(family): Watch also has the router's way")
            #expect(router.contains(Self.bridge) && router.contains("DHCP reservation") && router.contains("block the camera’s internet"))
            #expect(router.contains("renews"), "a DNS server the router hands out can change: said")
            #expect(watch.then == "Then press Check again on the camera’s Security card.")
            let time = try help(.timeSource, family: family)
            #expect(time.values.contains(.init(label: "NTP server", value: Self.bridge)), "\(family)")
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
    /// `custom_lang_English.txt` and `js_set.js`) or the maker's documents (TP-Link FAQ 4372; Reolink support articles 900000627963 and
    /// 4404480742425). Anything else is shown as unconfirmed.
    static let confirmed: Set<String> = [
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
                + help.places.flatMap { [$0.app, $0.action] + $0.path }
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

    /// Hikvision's, Dahua's and Amcrest's menus are only in other people's guides, and the IP camera web API's OSD tab was not confirmed:
    /// they get the general instruction, with no menu path and the caveat.
    @Test func unconfirmedMenusGetTheGeneralInstruction() throws {
        for (family, step) in [(CameraFamily.hikvision, CameraSetupStepID.timeZone), (.hikvision, .timeSource), (.hikvision, .internetWatch),
                               (.hikvision, .cleanPicture), (.dahua, .internetWatch), (.dahua, .timeSource), (.ipcWebAPI, .cleanPicture)] {
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
        let watch = try help(.internetWatch, family: .tapo)
        #expect(watch.places.first?.app == "The Tapo app" && watch.places.first?.confirmed == true)
        #expect(watch.note?.contains("reserve that address in your router") == true)
    }

    @Test func theIPCameraWebAPIsDNSNeedsAStaticAddressFirst() throws {
        let watch = try help(.internetWatch, family: .ipcWebAPI)
        #expect(watch.places.first?.path == ["Network", "Basic"])
        #expect(watch.places.first?.action.contains("Mode") == true && watch.note?.contains("DHCP") == true)
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
        #expect(help.values.contains(.init(label: "Preferred DNS server", value: Self.bridge)) && help.router != nil)
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
        #expect(helped.steps[1].manualHelp?.values.contains(.init(label: "NTP server", value: Self.bridge)) == true)
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
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraSetupStep(id: .upnp, title: "UPnP off", status: .done))) as? [String: Any])
        #expect(plain["manualHelp"] == nil, "a step done needs none")
        #expect(try JSONDecoder().decode(CameraSetupStep.self, from: JSONEncoder().encode(step)) == step)
    }
}
