import Testing
@testable import BridgeEngine

/// Review Oct 31 (adapters F4): video that comes back after a real outage tells the event channel to reconnect; a short reconnect does not.
@Suite struct VideoOutageTests {
    @Test func onlyAnOutageLongEnoughCounts() {
        let start = ContinuousClock.now
        var outage = VideoOutage()
        #expect(outage.online(at: start) == nil, "online without an outage")

        outage.offline(at: start)
        outage.offline(at: start + .seconds(5))   // still the same outage: its start stays
        #expect(outage.online(at: start + .seconds(8)) == nil, "a dropped session that came back within seconds")

        outage.offline(at: start + .seconds(10))
        outage.offline(at: start + .seconds(30))
        #expect(outage.online(at: start + .seconds(70)) == start + .seconds(10), "a camera that rebooted")
        #expect(outage.online(at: start + .seconds(80)) == nil, "said once")
    }
}
