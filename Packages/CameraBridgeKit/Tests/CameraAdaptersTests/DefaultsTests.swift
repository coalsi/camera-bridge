import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// The production timings required by the plan / research brief (tests shorten them elsewhere).
@Suite struct DefaultTimingTests {
    @Test func onvifPullPointDefaults() {
        let timing = ONVIFEventTiming()
        #expect(timing.initialTerminationTime == "PT2M")
        #expect(timing.pullTimeout == "PT1M")
        #expect(timing.messageLimit == 10)
        #expect(timing.replyTimeout == .seconds(80))
        #expect(timing.renewTerminationTime == "PT2M")
        #expect(timing.pulseHold == .seconds(20))
        #expect(timing.ringDedupe == .seconds(3))
        #expect(timing.policy.healthyAfter == .seconds(30), "Tapo drops a PullPoint request after 10 s: that is not a healthy session")
    }

    @Test func hikvisionDefaults() {
        let timing = HikvisionEventTiming()
        #expect(timing.pulseHold == .seconds(20))
        #expect(timing.idleTimeout == .seconds(300))
        #expect(timing.policy.healthyAfter == .seconds(10))
        #expect(timing.policy.minimumDelayAfterFailure == .seconds(10))
    }

    @Test func reolinkDefaults() {
        let timing = ReolinkEventTiming()
        #expect(timing.pollInterval == .seconds(1))
        #expect(timing.ringDedupe == .seconds(3))
        #expect(timing.useONVIFEvents)
        #expect(ReolinkDriver.defaultONVIFPort == 8000)
    }

    @Test func reconnectBackoffIsOneToSixtySeconds() {
        var backoff = ReconnectPolicy().backoff
        let first = backoff.next()
        #expect(first >= .milliseconds(800) && first <= .milliseconds(1200))
        for _ in 0..<20 { _ = backoff.next() }
        #expect(backoff.next() <= .seconds(60))
    }

    @Test func reolinkAbilityAIKinds() throws {
        let ability = try #require(try JSONValue.parse(fixture("reolink/GetAbility.json"))[0]?["value"])
        #expect(ReolinkDriver.aiKinds(fromAbility: ability, channel: 0) == [.person, .vehicle, .animal])
        #expect(ReolinkDriver.onvifEnabled(ability: ability) == true)
        #expect(ReolinkDriver.aiKinds(fromAbility: .null, channel: 0).isEmpty)
    }
}
