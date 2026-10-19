import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// The security levels (owner decision, 2026-10-17) as a pure function of what the camera reported, the cloud-dependent models and the
/// Internet guard's evidence: red "Outside access possible", yellow "Needs work", green "Good", gold "Local only", each with its findings.
@Suite struct CameraSecurityTests {
    static let now = Date(timeIntervalSince1970: 1_792_224_000)
    /// Watched for two days, its DNS asking the bridge, no internet lookups (the box saw it ask names of the home network: it asks the bridge).
    static let watchedQuiet = GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, localLookups: 3,
                                            watchedFor: 2 * 86_400)

    private func finding(_ feature: RemoteAccessFeature, _ state: RemoteAccessState, linked: Bool? = nil, service: String? = nil,
                         canChange: Bool = false) -> RemoteAccessFinding {
        RemoteAccessFinding(feature: feature, state: state, linked: linked, service: service, canChange: canChange)
    }

    /// Everything Camera Bridge knows for a Hikvision camera off, and its video locked.
    private var allOff: [RemoteAccessFinding] {
        [finding(.cloud, .off, linked: false, service: "Hik-Connect", canChange: true), finding(.upnp, .off, canChange: true), finding(.ddns, .absent),
         finding(.unauthenticatedVideo, .off)]
    }

    private func assess(_ findings: [RemoteAccessFinding], model: String? = nil, guard evidence: GuardEvidence? = nil) -> CameraSecurity {
        CameraSecurity.assess(findings, cloudModel: model, internetGuard: evidence, checkedAt: Self.now)
    }

    // MARK: Red

    @Test func aCloudLinkedToAnAccountIsRed() throws {
        let security = assess([finding(.cloud, .on, linked: true, service: "Hik-Connect", canChange: true), finding(.upnp, .off), finding(.unauthenticatedVideo, .off)])
        #expect(security.level == .red && security.title == "Outside access possible")
        #expect(security.summary == "Something on this camera can let it be reached from outside your home.")
        #expect(security.checkedAt == Self.now)
        let cloud = try #require(security.findings.first)
        #expect(cloud == CameraSecurityFinding(feature: .cloud, state: .on, level: .red,
                                               sentence: "Hik-Connect is on and linked to an account, so the camera can be reached from outside your home.",
                                               canChange: true, linked: true, service: "Hik-Connect"))
    }

    @Test func aCloudWhoseLinkIsUnknownIsRed() {
        let security = assess([finding(.cloud, .on, service: "VisionEye cloud", canChange: true)])
        #expect(security.level == .red)
        #expect(security.findings.first?.sentence == "VisionEye cloud is on, and Camera Bridge can’t tell whether it is linked to an account. "
            + "If it is, the camera can be reached from outside your home.")
    }

    @Test func upnpDDNSOrRTMPOnIsRed() {
        for (feature, sentence) in [(RemoteAccessFeature.upnp, "UPnP is on, so the camera can open ports on your router to the internet."),
                                    (.ddns, "Dynamic DNS is on, so the camera keeps a name on the internet that leads to your home."),
                                    (.rtmp, "RTMP push is on, so the camera can send its video to a server on the internet.")] {
            var findings = allOff.filter { $0.feature != feature }
            findings.append(finding(feature, .on))
            let security = assess(findings, guard: Self.watchedQuiet)
            #expect(security.level == .red, "\(feature)")
            #expect(security.findings.first { $0.feature == CameraSecurityFeature(feature) }?.sentence == sentence)
            #expect(security.findings.first?.level == .red, "the worst first")
        }
    }

    @Test func aCloudDependentModelIsRedWithoutReadingTheCamera() {
        let security = assess([], model: "Wyze", guard: Self.watchedQuiet)
        #expect(security.level == .red)
        #expect(security.findings.first == CameraSecurityFinding(feature: .cloud, state: .on, level: .red,
                                                                 sentence: "Wyze cameras work through Wyze’s cloud, so they can be reached from outside your home.",
                                                                 canChange: false, linked: true, service: "Wyze"))
        #expect(security.findings.filter { $0.feature == .cloud }.count == 1, "the model's cloud replaces the unknown one")
    }

    // MARK: Yellow

    @Test func aCloudOnButNotLinkedIsYellow() {
        let security = assess([finding(.cloud, .on, linked: false, service: "Hik-Connect", canChange: true), finding(.upnp, .off), finding(.unauthenticatedVideo, .off)])
        #expect(security.level == .yellow && security.title == "Needs work")
        #expect(security.summary == "Nothing Camera Bridge read opens this camera to the outside, but something needs work.")
        #expect(security.findings.first?.sentence == "Hik-Connect is on but not linked to an account.")
    }

    @Test func aCameraWithoutAReaderHasItsCloudUnknownAndIsYellow() {
        let security = assess([])
        #expect(security.level == .yellow)
        #expect(security.findings.map(\.feature) == [.cloud, .unauthenticatedVideo, .internetGuard])
        #expect(security.findings[0] == CameraSecurityFinding(feature: .cloud, state: .unknown, level: .yellow,
                                                              sentence: "Camera Bridge can’t read whether the maker’s cloud is on.", canChange: false))
        #expect(security.findings[1].sentence == "Camera Bridge couldn’t check whether its video needs a password." && security.findings[1].level == .green)
    }

    @Test func videoThatPlaysWithoutAPasswordIsYellow() {
        var findings = allOff
        findings.append(finding(.unauthenticatedVideo, .on, canChange: true))
        let security = assess(findings, guard: Self.watchedQuiet)
        #expect(security.level == .yellow)
        let video = security.findings.first { $0.feature == .unauthenticatedVideo }
        #expect(video?.state == .on && video?.canChange == true, "seen open by either reading: open")
        #expect(video?.sentence == "Its video plays without a password on your home network.")
    }

    @Test func aWatchedCameraThatKeepsTryingToReachTheInternetIsYellow() {
        let evidence = GuardEvidence(watched: true, outsideLookups24h: 12, lastLookupNames: ["p2p.example.com", "api.example.com", "time.example.net", "x.example.org"],
                                     available: true)
        let security = assess(allOff, guard: evidence)
        #expect(security.level == .yellow)
        #expect(security.findings.first == CameraSecurityFinding(
            feature: .internetGuard, state: .on, level: .yellow,
            sentence: "The Internet guard blocked 12 lookups of internet names in the last 24 hours (p2p.example.com, api.example.com, time.example.net), "
                + "but the camera may have another way out.", canChange: false))
        let one = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 1, lastLookupNames: [], available: true, watchedFor: 3600))
        #expect(one.level == .yellow && one.findings.first?.sentence == "The Internet guard blocked 1 lookup of an internet name in the last 24 hours, "
            + "but the camera may have another way out.", "seen at once, also before a full day")
    }

    @Test func anExtraServiceWithoutAPasswordIsYellowAndNamed() {
        let security = assess(allOff + [finding(.unauthenticatedVideo, .on, service: "Hikvision protocol (port 8000)", canChange: true)], guard: Self.watchedQuiet)
        #expect(security.level == .yellow)
        #expect(security.findings.first?.sentence == "Its Hikvision protocol (port 8000) answers without a password on your home network.")
        #expect(security.findings.filter { $0.feature == .unauthenticatedVideo }.count == 2, "RTSP's own finding stays")
    }

    // MARK: Green and gold

    @Test func everythingOffWithoutTheGuardIsGreenAtBest() {
        let security = assess(allOff)
        #expect(security.level == .green && security.title == "Good")
        #expect(security.summary == "Camera Bridge found no cloud turned on, but it can’t confirm everything, so a way out is still possible.")
        #expect(security.findings.first == CameraSecurityFinding(
            feature: .internetGuard, state: .absent, level: .green,
            sentence: "This bridge can’t watch the camera’s internet traffic, so Camera Bridge can’t confirm that nothing gets out.", canChange: false))
        let notWatched = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true))
        #expect(notWatched.level == .green && notWatched.findings.first?.state == .off)
        #expect(notWatched.findings.first?.sentence == "The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.")
        let down = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: false))
        #expect(down.level == .green && down.findings.first?.state == .unknown)
        #expect(down.findings.first?.sentence == "The Internet guard isn’t running, so Camera Bridge can’t confirm that nothing gets out.")
        // A box that watches no camera has its DNS off: that is no reason to say so of a camera it was never asked to watch.
        let idle = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: false))
        #expect(idle.findings.first?.sentence == "The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.")
    }

    /// Gold rests on the camera asking the bridge for its names, now, and on a full day of watching.
    @Test func goldNeedsTheCamerasDNSAndADayOfWatching() {
        let fresh = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: 2 * 3600 + 120))
        #expect(fresh.level == .green && fresh.findings.first?.state == .on)
        #expect(fresh.findings.first?.sentence == "The Internet guard has watched it for 2 hours and seen no internet lookups yet. It takes a full day to confirm.")
        let minutes = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: 60))
        #expect(minutes.findings.first?.sentence == "The Internet guard has watched it for less than an hour and seen no internet lookups yet. "
            + "It takes a full day to confirm.")
        let unknownStart = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true))
        #expect(unknownStart.level == .green, "a box that does not say since when it watches")

        let elsewhere = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true,
                                                            asksBridge: false, watchedFor: 2 * 86_400))
        #expect(elsewhere.level == .green && elsewhere.findings.first?.state == .off)
        #expect(elsewhere.findings.first?.sentence == "The camera no longer asks Camera Bridge for its lookups, so the Internet guard can’t see them. "
            + "Run Set up for Camera Bridge again to watch it.")
        // A Hikvision that answered "Reboot Required": it takes the bridge as its DNS server once it restarts (Camera Bridge never restarts it).
        let restart = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true,
                                                          asksBridge: false, waitsForRestart: true))
        #expect(restart.level == .green && restart.findings.first?.sentence == "The camera takes Camera Bridge as its DNS server when it restarts. "
            + "Until then the Internet guard can’t see its lookups.")
        let unread = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true))
        #expect(unread.level == .green && unread.findings.first?.state == .unknown)
        #expect(unread.findings.first?.sentence == "Camera Bridge couldn’t read which DNS servers the camera asks, so it can’t confirm that the Internet guard "
            + "sees its lookups.")
        let notYet = assess(allOff, guard: GuardEvidence(watched: false, outsideLookups24h: 0, lastLookupNames: [], available: true, listed: true, asksBridge: true))
        #expect(notYet.level == .green && notYet.findings.first?.sentence == "The Internet guard hasn’t started watching this camera yet.")
    }

    @Test func everythingConfirmedOffAndWatchedQuietIsGold() {
        let security = assess(allOff, guard: Self.watchedQuiet)
        #expect(security.level == .gold && security.title == "Local only")
        #expect(security.summary == "Every outside feature Camera Bridge knows for this camera is off, its video needs a password, and the Internet guard "
            + "saw it make no internet lookups in the last 24 hours.")
        #expect(security.findings.allSatisfy { $0.level == .gold })
        #expect(security.findings.first { $0.feature == .ddns }?.sentence == "The camera has no dynamic DNS.")
        #expect(security.findings.first { $0.feature == .internetGuard }?.sentence
            == "The Internet guard has watched it for the last 24 hours and saw it make no internet lookups.")
    }

    /// Silence is no proof (research §5, recommendation 6): a camera that asks a DNS server of its own (built in) is as quiet as one that
    /// asks nothing. A full day watched without a single lookup seen from it stays green, and says so.
    @Test func quietAloneIsNotGold() throws {
        let silent = assess(allOff, guard: GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, watchedFor: 2 * 86_400))
        #expect(silent.level == .green && silent.title == "Good")
        let finding = try #require(silent.findings.first { $0.feature == .internetGuard })
        #expect(finding == CameraSecurityFinding(feature: .internetGuard, state: .on, level: .green,
                                                 sentence: "No lookups seen yet; Camera Bridge can’t rule out a built-in DNS server.", canChange: false))
        let router = CameraSecurity.guardFinding(GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true,
                                                               watchedFor: 2 * 86_400, dnsFromRouter: true))
        #expect(router.level == .green)
        #expect(router.sentence == "No lookups seen yet; Camera Bridge can’t rule out a built-in DNS server. " + CameraSecurity.dnsFromRouterNote)
    }

    /// One lookup seen from the camera, of any name, shows it asks Camera Bridge: one the guard blocked earlier in the box's week, or a
    /// question that never leaves the home network (the box counts those but never names them). Then a quiet day is gold.
    @Test func oneLookupSeenThenQuietIsGold() throws {
        let earlier = Self.now.addingTimeInterval(-3 * 86_400)
        let blockedBefore = GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true,
                                          names: [GuardReport.Lookup(name: "p2p.example.com", count: 1, first: earlier, last: earlier)], watchedFor: 4 * 86_400)
        #expect(blockedBefore.lookupSeen)
        #expect(assess(allOff, guard: blockedBefore).level == .gold)
        let local = GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true, localLookups: 1, watchedFor: 2 * 86_400)
        let gold = assess(allOff, guard: local)
        #expect(gold.level == .gold)
        #expect(gold.findings.first { $0.feature == .internetGuard }?.sentence
            == "The Internet guard has watched it for the last 24 hours and saw it make no internet lookups.")
        var young = local
        young.watchedFor = 3600
        #expect(assess(allOff, guard: young).level == .green, "a lookup seen does not shorten the day")
        #expect(!GuardEvidence(watched: true, outsideLookups24h: 0, lastLookupNames: [], available: true).lookupSeen)
    }

    @Test func anythingUnknownOrAnotherServiceKeepsItGreen() {
        for extra in [finding(.ddns, .unknown), finding(.rtmp, .unknown), finding(.extraService, .on, service: "Meari service (port 10000)", canChange: true),
                      finding(.extraService, .unknown, service: "Hikvision protocol")] {
            let security = assess(allOff.filter { $0.feature != extra.feature } + [extra], guard: Self.watchedQuiet)
            #expect(security.level == .green, "\(extra)")
        }
        let meari = assess(allOff + [finding(.extraService, .on, service: "Meari service (port 10000)", canChange: true)])
        #expect(meari.findings.contains { $0.sentence == "Meari service (port 10000) is on, and Camera Bridge can’t tell whether it reaches the internet." })
        let unchecked = assess(allOff.filter { $0.feature != .unauthenticatedVideo }, guard: Self.watchedQuiet)
        #expect(unchecked.level == .green, "the video was not checked: not confirmed")
    }

    @Test func absentFeaturesCountAsConfirmed() {
        let security = assess([finding(.cloud, .off, service: "VisionEye cloud", canChange: true), finding(.cloud, .absent, service: "P2P service"),
                               finding(.upnp, .absent), finding(.ddns, .off), finding(.rtmp, .off), finding(.extraService, .off, service: "Meari service"),
                               finding(.unauthenticatedVideo, .off)], guard: Self.watchedQuiet)
        #expect(security.level == .gold)
        #expect(security.findings.contains { $0.sentence == "The camera has no P2P service." })
    }

    @Test func twoReadingsOfOneFeatureAreOne() {
        // The camera's API says the video asks for a password, the RTSP check found it open: open.
        let security = assess(allOff.filter { $0.feature != .unauthenticatedVideo } + [finding(.unauthenticatedVideo, .off, canChange: true),
                                                                                         finding(.unauthenticatedVideo, .on)])
        let video = security.findings.filter { $0.feature == .unauthenticatedVideo }
        #expect(video.count == 1 && video.first?.state == .on && video.first?.canChange == true)
        // A check that could not tell, and an API that says it asks: confirmed.
        let confirmed = assess([finding(.unauthenticatedVideo, .unknown), finding(.unauthenticatedVideo, .off)])
        #expect(confirmed.findings.filter { $0.feature == .unauthenticatedVideo }.map(\.state) == [.off])
    }

    @Test func levelsAreOrderedFromRedToGold() {
        #expect(CameraSecurityLevel.allCases.sorted() == [.red, .yellow, .green, .gold])
        #expect(CameraSecurityLevel.allCases.map(\.title) == ["Outside access possible", "Needs work", "Good", "Local only"])
    }

    // MARK: Cloud-dependent models

    @Test func cloudDependentModelsAreKnownByPluginIntegrationOrMaker() {
        #expect(CloudDependentModels.brand(integration: .wyze, manufacturer: "Wyze", model: "HL_CAM4") == "Wyze")
        #expect(CloudDependentModels.brand(integration: .eufy, manufacturer: "eufy", model: "T8134") == "eufy")
        #expect(CloudDependentModels.brand(integration: .ring, manufacturer: "", model: "") == "Ring")
        #expect(CloudDependentModels.brand(integration: .nest, manufacturer: "", model: "") == "Google Nest")
        #expect(CloudDependentModels.brand(integration: .tuya, manufacturer: "", model: "") == "Tuya (Smart Life)")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "TP-LINK", model: "Tapo C200") == "TP-Link Tapo")
        #expect(CloudDependentModels.brand(integration: .other, manufacturer: "tapo", model: "C310") == "TP-Link Tapo")
        // Tapo firmware's ONVIF device information: the maker as "tp-link", the model alone.
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "tp-link", model: "C200") == "TP-Link Tapo")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "TPLINK", model: "C520WS") == "TP-Link Tapo")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Ring LLC", model: "Stick Up Cam") == "Ring")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Google", model: "Nest Cam (battery)") == "Google Nest")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Blink", model: "Mini") == "Blink")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Arlo", model: "Pro 4") == "Arlo")
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "SimpliSafe", model: "SimpliCam") == "SimpliSafe")
        // Others are not: a VIGI is TP-Link's local line, "Springfield" only contains "ring", Wyze and eufy only through their plugins.
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "TP-LINK", model: "VIGI C340") == nil)
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Springfield Cameras", model: "Earring 2") == nil)
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "Wyze", model: "WYZE_CAKP2JFUS") == nil)
        #expect(CloudDependentModels.brand(integration: .unifiProtect, manufacturer: "Ubiquiti", model: "G4 Bullet") == nil)
        #expect(CloudDependentModels.brand(integration: nil, manufacturer: "A_ONVIF_CAMERA", model: "N801B-RB-IRC-WM701") == nil)
    }
}
