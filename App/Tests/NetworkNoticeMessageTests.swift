import BridgeEngine
import Foundation
import Testing

/// The VPN banner, menu bar line and Settings row (`NetworkNoticeMessage`), the once-a-day throttle and the model's use of both.
@Suite(.timeLimit(.minutes(1))) struct NetworkNoticeMessageTests {
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func controller(delivery: NetworkNotice.Delivery = .reached, fallback: Bool = true, camera: String? = "Driveway", device: String = "192.0.2.20",
                            at date: Date = t0, since: Date? = nil) -> NetworkNotice {
        NetworkNotice(kind: .controllerOnVPN, cameraName: camera, advertisedAddress: "10.5.0.2", peerAddress: device, usedFallback: fallback,
                      delivery: delivery, date: date, firstSeen: since)
    }

    // MARK: Text

    @Test func aDeviceOnAVPNGetsTheFallbackExplanation() throws {
        let message = try #require(NetworkNoticeMessage.make(for: controller()))
        #expect(message.severity == .info && message.kind == .controllerOnVPN)
        #expect(message.detail.contains("An iPhone or iPad watching Driveway seems to be on a VPN (asked for video at 10.5.0.2)."))
        #expect(message.detail.contains("Camera Bridge sent it to 192.0.2.20 instead."))
        #expect(message.detail.contains("If live view still doesn’t load, turn off the VPN on that device or allow local network access in the VPN app"))
        #expect(message.detail.contains("NordVPN: “Invisibility on LAN” off / “Local network” on"))
        #expect(message.menuTitle == "A Device Watching Driveway Is on a VPN — Learn More…")
        // Still waiting to hear whether video got through: the same information.
        #expect(NetworkNoticeMessage.make(for: controller(delivery: .pending))?.severity == .info)
    }

    @Test func aFailedLiveViewAfterTheFallbackIsAWarning() throws {
        let message = try #require(NetworkNoticeMessage.make(for: controller(delivery: .failed)))
        #expect(message.severity == .warning)
        #expect(message.title == "Live View to a Device on a VPN Failed")
        #expect(message.detail.hasPrefix("Live view to a device on a VPN failed — turn off the VPN on that device."))
        #expect(message.detail.contains("sent it to 192.0.2.20 instead, but nothing came back"))
        #expect(message.menuTitle == "Live View to a Device on a VPN Failed — Learn More…")
        // Worse is a new message: the throttle shows it again.
        #expect(message.id != NetworkNoticeMessage.make(for: controller(delivery: .reached))?.id)
        // No fallback was possible and nothing came back.
        let none = try #require(NetworkNoticeMessage.make(for: controller(delivery: .failed, fallback: false)))
        #expect(none.detail.contains("which isn’t on this network, and nothing came back"))
    }

    @Test func aStreamThatGotThroughWithoutHelpNeedsNoMessage() {
        #expect(NetworkNoticeMessage.make(for: controller(delivery: .reached, fallback: false)) == nil)
        #expect(NetworkNoticeMessage.make(for: controller(delivery: .pending, fallback: false)) != nil)
        #expect(NetworkNoticeMessage.make(for: controller(delivery: .failed, fallback: false)) != nil)
    }

    @Test func thisMacOnAVPNHasItsOwnMessage() throws {
        let message = try #require(NetworkNoticeMessage.make(for: NetworkNotice(kind: .macOnVPN, interfaceName: "utun4", date: Self.t0)))
        #expect(message.kind == .macOnVPN && message.title == "This Mac Is on a VPN")
        #expect(message.detail == "This Mac is connected to a VPN; Apple Home devices may not be able to reach Camera Bridge. Turn the VPN off or enable LAN access.")
        #expect(message.menuTitle == "This Mac Is on a VPN — Learn More…")
    }

    /// What the transport findings say (live view that did not arrive, a refused send, an Ethernet-and-Wi-Fi Mac).
    @Test func theTransportFindingsHaveTheirOwnMessages() throws {
        let blind = try #require(NetworkNoticeMessage.make(for: NetworkNotice(kind: .liveViewNotReceived, cameraName: "Driveway", peerAddress: "192.0.2.20",
                                                                              delivery: .failed, date: Self.t0)))
        #expect(blind.kind == .liveViewNotReceived && blind.severity == .warning && blind.title == "Live View Did Not Reach a Device")
        #expect(blind.detail.contains("Driveway") && blind.detail.contains("Local Network"))
        // Settled once a later live view got through.
        #expect(NetworkNoticeMessage.make(for: NetworkNotice(kind: .liveViewNotReceived, peerAddress: "192.0.2.20", delivery: .reached, date: Self.t0)) == nil)

        let denied = try #require(NetworkNoticeMessage.make(for: NetworkNotice(kind: .localNetworkDenied, detail: "EHOSTUNREACH (No route to host)", date: Self.t0)))
        #expect(denied.severity == .warning && denied.detail.contains("EHOSTUNREACH") && denied.detail.contains("Local Network"))

        let dual = try #require(NetworkNoticeMessage.make(for: NetworkNotice(kind: .dualHomedSubnet, interfaceName: "en0, en1",
                                                                            detail: "192.0.2.0/24 (en0 192.0.2.69, en1 192.0.2.25)", date: Self.t0)))
        #expect(dual.severity == .info && dual.title == "This Mac Is on Your Network Twice")
        #expect(dual.detail.contains("en0, en1") && dual.detail.contains("192.0.2.0/24") && dual.detail.contains("turning one of them off is more reliable"))
        // One message per device: three kinds, three ids.
        #expect(Set([blind.id, denied.id, dual.id]).count == 3)
    }

    @Test func messagesAreOrderedWorstFirstThenNewestAndExpiredOnesAreLeftOut() {
        let notices = [NetworkNotice(kind: .macOnVPN, interfaceName: "utun4", date: Self.t0),
                       controller(delivery: .reached, device: "192.0.2.20", at: Self.t0.addingTimeInterval(10)),
                       controller(delivery: .failed, device: "192.0.2.31", at: Self.t0.addingTimeInterval(5)),
                       controller(delivery: .reached, device: "192.0.2.77", at: Self.t0.addingTimeInterval(-4_000))]
        let now = Self.t0.addingTimeInterval(20)
        let messages = NetworkNoticeMessage.messages(for: notices, now: now)
        #expect(messages.map(\.severity) == [.warning, .info, .info])
        #expect(messages.map(\.kind) == [.controllerOnVPN, .controllerOnVPN, .macOnVPN])
        #expect(NetworkNoticeMessage.messages(for: []).isEmpty)
    }

    @Test func theHelpSheetCoversTheDeviceNordVPNAndTheMac() {
        #expect(VPNHelpContent.sections.map(\.title) == ["On the iPhone or iPad", "NordVPN", "On this Mac"])
        #expect(VPNHelpContent.sections.allSatisfy { !$0.steps.isEmpty })
        #expect(VPNHelpContent.sections[1].steps.contains { $0.contains("Invisibility on LAN") })
        #expect(VPNHelpContent.sections[1].steps.contains { $0.contains("Local network") })
    }

    /// Learn More used to open the VPN steps for every kind. Each kind now has its own page, in the order what happened, what
    /// CameraBridge did, what to do; the two VPN kinds keep the VPN page.
    @Test func everyNoticeKindHasItsOwnHelpPage() throws {
        let kinds: [NetworkNotice.Kind] = [.controllerOnVPN, .macOnVPN, .liveViewNotReceived, .localNetworkDenied, .dualHomedSubnet]
        for kind in kinds {
            let page = NetworkHelpContent.page(for: kind)
            #expect(!page.title.isEmpty && !page.summary.isEmpty && !page.sections.isEmpty, "\(kind)")
            #expect(page.sections.allSatisfy { !$0.steps.isEmpty && !$0.steps.contains(where: \.isEmpty) }, "\(kind)")
        }
        #expect(NetworkHelpContent.page(for: .controllerOnVPN) == NetworkHelpContent.page(for: .macOnVPN))
        #expect(NetworkHelpContent.page(for: .controllerOnVPN).sections == VPNHelpContent.sections)
        let own: [NetworkNotice.Kind] = [.liveViewNotReceived, .localNetworkDenied, .dualHomedSubnet]
        let titles = own.map { NetworkHelpContent.page(for: $0).title } + [NetworkHelpContent.vpn.title]
        #expect(Set(titles).count == 4, "\(titles)")
        // The page's title is the banner's, so Learn More continues what the banner said.
        for kind in own {
            let notice = NetworkNotice(kind: kind, interfaceName: "en0, en1", detail: "192.0.2.0/24", date: Self.t0)
            #expect(NetworkNoticeMessage.make(for: notice)?.title == NetworkHelpContent.page(for: kind).title, "\(kind)")
        }
    }

    @Test func theNewHelpPagesTellWhatHappenedWhatCameraBridgeDidAndWhatToDo() throws {
        func text(_ kind: NetworkNotice.Kind) -> String {
            let page = NetworkHelpContent.page(for: kind)
            return ([page.summary] + page.sections.flatMap(\.steps)).joined(separator: "\n")
        }
        let dual = NetworkHelpContent.page(for: .dualHomedSubnet)
        #expect(dual.sections.map(\.title) == ["What Camera Bridge Did", "What You Can Do"])
        #expect(text(.dualHomedSubnet).contains("Ethernet and Wi-Fi") && text(.dualHomedSubnet).contains("only one connection"))
        let denied = text(.localNetworkDenied)
        #expect(denied.contains("Privacy & Security") && denied.contains("Local Network") && denied.contains("turn it on"))
        let blind = NetworkHelpContent.page(for: .liveViewNotReceived)
        #expect(blind.sections.map(\.title) == ["What Camera Bridge Did", "What You Can Do"])
        let advice = text(.liveViewNotReceived)
        #expect(advice.contains("another network path") && advice.contains("VPN") && advice.contains("firewall") && advice.contains("isolation"))
        #expect(!blind.sections[0].numbered && blind.sections[1].numbered, "what was done is told, what to do is numbered")
    }

    // MARK: Throttle

    @Test func aBannerShowsOncePerDeviceAndDay() throws {
        let message = try #require(NetworkNoticeMessage.make(for: controller(since: Self.t0)))
        var throttle = NetworkNoticeThrottle()
        #expect(throttle.allows(message, now: Self.t0))
        throttle.noteShown(message, now: Self.t0)
        #expect(throttle.allows(message, now: Self.t0.addingTimeInterval(1_800)), "the same episode stays up until it clears")
        // It cleared an hour after its last report and came back an hour and a half later: a new episode within the day.
        let again = try #require(NetworkNoticeMessage.make(for: controller(at: Self.t0.addingTimeInterval(9_000), since: Self.t0.addingTimeInterval(9_000))))
        #expect(!throttle.allows(again, now: Self.t0.addingTimeInterval(9_000)))
        // A day after it was shown it may show again.
        #expect(throttle.allows(again, now: Self.t0.addingTimeInterval(86_401)))
        throttle.noteShown(again, now: Self.t0.addingTimeInterval(86_401))
        #expect(throttle.allows(again, now: Self.t0.addingTimeInterval(86_500)))
    }

    @Test func aDismissedBannerStaysHiddenForADay() throws {
        let message = try #require(NetworkNoticeMessage.make(for: controller(since: Self.t0)))
        var throttle = NetworkNoticeThrottle()
        throttle.noteShown(message, now: Self.t0)
        throttle.dismiss(message, now: Self.t0.addingTimeInterval(60))
        #expect(!throttle.allows(message, now: Self.t0.addingTimeInterval(120)))
        #expect(!throttle.allows(message, now: Self.t0.addingTimeInterval(80_000)))
        #expect(throttle.allows(message, now: Self.t0.addingTimeInterval(60 + 86_401)))
        // Another device, or the same one failing, is not covered by the dismissal.
        let other = try #require(NetworkNoticeMessage.make(for: controller(device: "192.0.2.31", since: Self.t0)))
        #expect(throttle.allows(other, now: Self.t0.addingTimeInterval(120)))
        let failed = try #require(NetworkNoticeMessage.make(for: controller(delivery: .failed, since: Self.t0)))
        #expect(throttle.allows(failed, now: Self.t0.addingTimeInterval(120)))
    }

    @Test func theThrottleSurvivesEncoding() throws {
        let message = try #require(NetworkNoticeMessage.make(for: controller(since: Self.t0)))
        var throttle = NetworkNoticeThrottle()
        throttle.dismiss(message, now: Self.t0)
        let decoded = try JSONDecoder().decode(NetworkNoticeThrottle.self, from: JSONEncoder().encode(throttle))
        #expect(decoded == throttle && !decoded.allows(message, now: Self.t0.addingTimeInterval(10)))
    }

    // MARK: The model

    @MainActor private func model(_ scenario: PreviewScenario, defaults: UserDefaults) -> AppModel {
        AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(scenario: scenario),
                 loginItems: InMemoryLoginItemService(), defaults: defaults, previewLatency: .zero)
    }

    @MainActor @Test func theModelShowsTheEnginesNoticeAndHidesItOnceDismissed() throws {
        let scratch = ScratchDefaults()
        let model = model(.vpn, defaults: scratch.defaults)
        let banner = try #require(model.networkBanner)
        #expect(banner.kind == .controllerOnVPN && banner.detail.contains("10.5.0.2") && banner.detail.contains("198.51.100.20"))
        #expect(model.networkMessages.count == 1)
        model.networkBannerAppeared(banner)
        #expect(model.networkBanner == banner)
        model.dismissNetworkBanner(banner)
        #expect(model.networkBanner == nil, "dismissed: no banner")
        #expect(model.networkMessages.count == 1, "the menu bar line and Settings keep saying it")
    }

    @MainActor @Test func aFailedStreamIsAWarningAndThisMacHasItsOwnBanner() throws {
        let scratch = ScratchDefaults()
        let failed = model(.vpnFailed, defaults: scratch.defaults)
        #expect(failed.networkBanner?.severity == .warning)
        let mac = model(.macVPN, defaults: scratch.defaults)
        #expect(mac.networkBanner?.kind == .macOnVPN)
        #expect(model(.standard, defaults: scratch.defaults).networkBanner == nil)
        #expect(model(.standard, defaults: scratch.defaults).networkMessages.isEmpty)
    }

    @MainActor @Test func learnMoreOpensTheHelpSheet() {
        let scratch = ScratchDefaults()
        let model = model(.vpn, defaults: scratch.defaults)
        model.windowOpener = {}
        model.presentVPNHelp()
        #expect(model.presentedSheet == .vpnHelp)
    }

    @MainActor @Test func learnMoreOpensTheHelpOfTheNoticesOwnKind() {
        let scratch = ScratchDefaults()
        let model = model(.vpn, defaults: scratch.defaults)
        model.windowOpener = {}
        for (kind, sheet) in [(NetworkNotice.Kind.dualHomedSubnet, ManagerSheet.networkHelp(.dualHomedSubnet)),
                              (.localNetworkDenied, .networkHelp(.localNetworkDenied)), (.liveViewNotReceived, .networkHelp(.liveViewNotReceived)),
                              (.macOnVPN, .vpnHelp), (.controllerOnVPN, .vpnHelp)] {
            model.presentedSheet = nil
            model.presentNetworkHelp(for: kind)
            #expect(model.presentedSheet == sheet, "\(kind)")
        }
        // One sheet at a time: a second request waits.
        model.presentedSheet = .localNetworkAccess
        model.presentNetworkHelp(for: .dualHomedSubnet)
        #expect(model.presentedSheet == .localNetworkAccess)
    }

    @MainActor @Test func previewModeKeepsNoThrottleBetweenLaunches() throws {
        let scratch = ScratchDefaults()
        // Live-app mode with the sample engine standing in is not possible in tests; the throttle's own encoding is checked above.
        let first = model(.vpn, defaults: scratch.defaults)
        let banner = try #require(first.networkBanner)
        first.dismissNetworkBanner(banner)
        #expect(scratch.defaults.data(forKey: AppModel.networkThrottleKey) == nil, "preview mode keeps nothing")
    }
}
