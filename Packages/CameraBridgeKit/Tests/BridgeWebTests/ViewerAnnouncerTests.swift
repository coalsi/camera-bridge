import BridgeSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// `_camera-bridge._tcp`, how the Apple TV app finds the box: the announcer registers it through the platform's `ServiceAdvertiser` (a fake
/// here, so nothing is announced on the network), registers again under a new name, tries again when a registration fails and withdraws it
/// when the web interface stops. The instance name is cut to DNS-SD's 63 bytes on a character boundary; the TXT record is the contract with
/// the app.
@Suite(.timeLimit(.minutes(1))) struct ViewerAnnouncerTests {
    private static let identity = String(repeating: "0123456789abcdef", count: 2)
    private static let hallway = ViewerAnnouncer.Announcement(id: identity, name: "Hallway", version: "0.1.132", port: 80)
    /// A family: one character, 25 bytes of UTF-8.
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

    // MARK: The web interface announces itself

    @Test func itAnnouncesItselfOnceTheWebPortListens() async throws {
        let fake = FakeAdvertiser()
        let directory = try TemporaryDirectory(prefix: "cb-announce")
        defer { directory.remove() }
        var configuration = WebConfiguration(dataDirectory: directory.url, port: 0, loopbackOnly: true, version: "0.1", build: "test", passwordIterations: 1_000)
        configuration.viewerAdvertiser = fake
        let service = WebService(configuration: configuration, backend: FakeBackend(), system: FakeSystem(), logs: LogFeed(), transport: FakeNetworkTransport())
        try await service.app.auth.configure(password: "correct horse", bridgeName: "Hallway")
        #expect(fake.requests.isEmpty, "nothing is announced before the web interface listens")

        let port = try await service.start()
        #expect(await eventually { fake.services.count == 1 })
        let advertisement = try #require(fake.services.first).advertisement
        #expect(advertisement.type == "_camera-bridge._tcp" && advertisement.name == "Hallway" && advertisement.port == port)
        #expect(advertisement.txt == ["id": await service.app.auth.bridgeID(), "name": "Hallway", "v": "0.1", "api": "1"])
        #expect(fake.live.count == 1)

        await service.stop()
        #expect(fake.services.first?.isCancelled == true, "the announcement ends with the web interface")
    }

    @Test func aRenameAnnouncesAgainUnderTheNewName() async throws {
        let fake = FakeAdvertiser()
        let harness = try Harness { $0.viewerAdvertiser = fake }
        let owner = try await harness.signIn(name: "Hallway")
        harness.app.startAnnouncing(port: 8080)
        #expect(await eventually { fake.services.count == 1 })
        let first = try #require(fake.services.first)
        #expect(first.advertisement.name == "Hallway" && first.advertisement.port == 8080)

        let renamed = await owner.send("PATCH", "/api/v1/settings", json: ["bridgeName": "Garage"])
        #expect(renamed.status == 200, "\(renamed.text)")
        #expect(await eventually { fake.services.count == 2 })
        #expect(first.isCancelled, "the registration under the old name is withdrawn")
        let second = try #require(fake.services.last)
        #expect(second.advertisement.name == "Garage" && second.advertisement.txt["name"] == "Garage" && !second.isCancelled)
        #expect(second.advertisement.txt["id"] == first.advertisement.txt["id"] && second.advertisement.port == 8080, "the same box, found under a new name")

        // Saving the name it already has announces nothing again.
        #expect(await owner.send("PATCH", "/api/v1/settings", json: ["bridgeName": "Garage"]).status == 200)
        #expect(await owner.send("PATCH", "/api/v1/settings", json: ["motionShadowTest": true]).status == 200)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.services.count == 2 && fake.requests.count == 2)

        await harness.app.stopAnnouncing()
        #expect(fake.live.isEmpty)
    }

    @Test func theNameChosenInSetupIsAnnounced() async throws {
        let fake = FakeAdvertiser()
        let harness = try Harness { $0.viewerAdvertiser = fake }
        harness.app.startAnnouncing(port: 80)
        #expect(await eventually { fake.services.count == 1 })
        #expect(fake.services.first?.advertisement.name == AuthStore.defaultBridgeName, "a new box is found before anybody has named it")

        _ = try await harness.signIn(name: "Hallway")
        #expect(await eventually { fake.services.count == 2 })
        #expect(fake.services.first?.isCancelled == true)
        #expect(fake.services.last?.advertisement.name == "Hallway" && fake.services.last?.advertisement.txt["name"] == "Hallway")
        await harness.app.stopAnnouncing()
    }

    @Test func aStopRightAfterTheStartLeavesNothingAnnounced() async throws {
        let fake = FakeAdvertiser()
        let harness = try Harness { $0.viewerAdvertiser = fake }
        for _ in 0..<25 {
            harness.app.startAnnouncing(port: 80)
            await harness.app.stopAnnouncing()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.live.isEmpty, "the task still gathering the name when the web interface stopped does not announce it afterwards")
        let announcer = try #require(harness.app.announcer)
        #expect(await announcer.announced == nil)
    }

    @Test func withoutAnAdvertiserNothingIsAnnounced() async throws {
        let harness = try Harness()
        #expect(harness.app.announcer == nil)
        _ = try await harness.signIn()
        harness.app.startAnnouncing(port: 80)
        await harness.app.stopAnnouncing()
    }

    // MARK: Registering

    @Test func aRegistrationThatFailsIsTriedAgain() async throws {
        let fake = FakeAdvertiser()
        fake.failNext([.failed("avahi is not running"), .failed("avahi is not running")])
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .milliseconds(10), maximumRetryDelay: .milliseconds(40))
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.services.count == 1 }, "the third try registers")
        #expect(fake.requests.count == 3)
        #expect(await eventually { await announcer.announced == Self.hallway })
        let first = try #require(fake.services.first)

        // It fails later, on the service itself (avahi restarted and dropped the registration): withdrawn, and registered again.
        first.fail(.failed("avahi went away"))
        #expect(await eventually { fake.services.count == 2 })
        #expect(first.isCancelled)
        #expect(await eventually { await announcer.announced == Self.hallway })
        #expect(fake.live.count == 1)

        await announcer.stop()
        #expect(fake.live.isEmpty && fake.services.last?.isCancelled == true)
        #expect(await announcer.announced == nil)
    }

    @Test func theRetryDelayDoublesUpToItsMaximum() async throws {
        let fake = FakeAdvertiser()
        fake.failEvery(with: .failed("avahi is not running"))
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .milliseconds(10), maximumRetryDelay: .milliseconds(20))
        await announcer.start(Self.hallway)
        // Held at 20 ms, twelve tries take a fifth of a second. Doubling without the maximum would put 10 s (10 ms x 1,024) before the twelfth
        // alone and 20 s before it in all, so the wait itself shows that the maximum holds, and no single gap needs an upper bound that a slow
        // runner could break: it only has to stay well under the 8 s it is given.
        #expect(await eventually(timeout: .seconds(8)) { fake.requestTimes.count >= 12 }, "the maximum holds the later delays down")
        await announcer.stop()
        let times = fake.requestTimes
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        // Never sooner than the delay says: 10 ms for the first, then 20 ms.
        #expect(gaps.count >= 11 && gaps[0] >= .milliseconds(10) && gaps[1...].allSatisfy { $0 >= .milliseconds(20) }, "\(gaps)")
    }

    @Test func aStopEndsTheRetries() async throws {
        let fake = FakeAdvertiser()
        fake.failEvery(with: .failed("avahi is not running"))
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .milliseconds(10), maximumRetryDelay: .milliseconds(40))
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count >= 3 }, "it keeps trying")

        await announcer.stop()
        try await Task.sleep(for: .milliseconds(40))   // a call that was out when it stopped
        let settled = fake.requests.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.requests.count == settled, "no attempt after stop")
        #expect(fake.services.isEmpty)
    }

    @Test func aStopDuringRegistrationWins() async throws {
        let fake = FakeAdvertiser()
        let gate = fake.holdNext()
        let announcer = ViewerAnnouncer(advertiser: fake)
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count == 1 }, "the call is out and not answered")
        await announcer.stop()
        gate.open()
        #expect(await eventually { fake.services.count == 1 })
        #expect(await eventually { fake.services.first?.isCancelled == true }, "the late registration is withdrawn, not kept")
        #expect(await announcer.announced == nil)
        #expect(fake.requests.count == 1)
    }

    @Test func aStopDuringAFailingRegistrationReportsNothingAndTriesNothing() async throws {
        let lines = AnnouncerLog()
        let token = LogHub.addSink(lines)
        defer { LogHub.removeSink(token) }
        let reason = "no avahi \(UUID().uuidString)"
        let fake = FakeAdvertiser()
        fake.failNext([.failed(reason)])
        let gate = fake.holdNext()
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .milliseconds(10), maximumRetryDelay: .milliseconds(40))
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count == 1 })
        await announcer.stop()
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.requests.count == 1, "the failure of an announcement nobody wants any more starts no retry")
        #expect(!lines.messages.contains { $0.contains(reason) }, "and is not reported")
    }

    @Test func aRenameDuringARegistrationRegistersAgain() async throws {
        let fake = FakeAdvertiser()
        let gate = fake.holdNext()
        let announcer = ViewerAnnouncer(advertiser: fake)
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count == 1 })
        await announcer.rename(to: "Garage")
        #expect(fake.requests.count == 1, "one registration at a time")
        gate.open()
        #expect(await eventually { fake.services.count == 2 })
        #expect(fake.services.first?.isCancelled == true, "the registration under the old name is not kept")
        #expect(fake.services.last?.advertisement.name == "Garage" && fake.services.last?.isCancelled == false)
        #expect(await eventually { await announcer.announced?.name == "Garage" })
        #expect(fake.requests.count == 2)
        await announcer.stop()
    }

    @Test func aRenameDuringAFailingRegistrationTriesTheNewNameAtOnce() async throws {
        let fake = FakeAdvertiser()
        fake.failNext([.failed("avahi is not running")])
        let gate = fake.holdNext()
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .seconds(30), maximumRetryDelay: .seconds(60))
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count == 1 })
        await announcer.rename(to: "Garage")
        gate.open()
        #expect(await eventually { fake.services.count == 1 }, "the failure was the old name's; the new one does not wait for a retry")
        #expect(fake.services.first?.advertisement.name == "Garage")
        await announcer.stop()
    }

    @Test func aRenameDoesNotWaitForTheRetryDelay() async throws {
        let fake = FakeAdvertiser()
        fake.failNext([.failed("avahi is not running")])
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .seconds(30), maximumRetryDelay: .seconds(60))
        await announcer.start(Self.hallway)
        #expect(await eventually { fake.requests.count == 1 }, "it failed, and the next try is 30 s away")
        await announcer.rename(to: "Garage")
        #expect(await eventually { fake.services.count == 1 }, "a rename is tried at once")
        #expect(fake.services.first?.advertisement.name == "Garage")
        await announcer.stop()
    }

    @Test func startingAgainWithTheSameThingRegistersNothingNew() async throws {
        let fake = FakeAdvertiser()
        let announcer = ViewerAnnouncer(advertiser: fake)
        await announcer.start(Self.hallway)
        #expect(await eventually { await announcer.announced == Self.hallway })
        await announcer.start(Self.hallway)
        await announcer.rename(to: "Hallway")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requests.count == 1 && fake.live.count == 1)

        // A new port is a new registration.
        var moved = Self.hallway
        moved.port = 8080
        await announcer.start(moved)
        #expect(await eventually { fake.services.count == 2 })
        #expect(fake.services.first?.isCancelled == true && fake.services.last?.advertisement.port == 8080)
        await announcer.stop()
    }

    @Test func aRenameWithNothingAnnouncedChangesNothing() async throws {
        let fake = FakeAdvertiser()
        let announcer = ViewerAnnouncer(advertiser: fake)
        await announcer.rename(to: "Garage")   // before it started
        await announcer.start(Self.hallway)
        #expect(await eventually { await announcer.announced == Self.hallway })
        await announcer.stop()
        await announcer.rename(to: "Garage")   // after it stopped
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requests.count == 1 && fake.live.isEmpty && fake.services.first?.advertisement.name == "Hallway")

        await announcer.start(Self.hallway)    // and it starts again
        #expect(await eventually { fake.services.count == 2 })
        #expect(fake.live.count == 1)
        await announcer.stop()
    }

    @Test func theSameFailureIsLoggedOnce() async throws {
        let lines = AnnouncerLog()
        let token = LogHub.addSink(lines)
        defer { LogHub.removeSink(token) }
        let reason = "no avahi \(UUID().uuidString)"
        let name = "Hallway \(UUID().uuidString.prefix(8))"
        let fake = FakeAdvertiser()
        fake.failNext([.failed(reason), .failed(reason), .failed(reason + " (again)")])
        let announcer = ViewerAnnouncer(advertiser: fake, retryDelay: .milliseconds(5), maximumRetryDelay: .milliseconds(20))
        await announcer.start(ViewerAnnouncer.Announcement(id: Self.identity, name: name, version: "0.1", port: 80))
        #expect(await eventually { lines.messages.contains { $0.contains("“\(name)”") } }, "registered at the fourth try, and said so")
        #expect(fake.requests.count == 4)
        #expect(lines.messages.filter { $0.contains(reason) }.count == 2, "the second failure is the first again; the third differs")
        #expect(lines.messages.contains { $0.contains("Apple TVs can find this bridge: “\(name)” (_camera-bridge._tcp) on port 80") })
        await announcer.stop()
    }

    // MARK: What is announced

    @Test func instanceNamesFitDNSSD() {
        #expect(ViewerAnnouncer.instanceName(for: "Camera Bridge") == "Camera Bridge")
        #expect(ViewerAnnouncer.instanceName(for: "Hallway") == "Hallway")

        let accented = String(repeating: "\u{E9}", count: 60)   // 120 bytes
        let cut = ViewerAnnouncer.instanceName(for: accented)
        #expect(!cut.isEmpty && cut.utf8.count <= 63 && accented.hasPrefix(cut), "a prefix of the name that fits")
        #expect(cut.count == 31, "as much of it as fits: 31 letters of 2 bytes")

        let families = String(repeating: Self.family, count: 10)   // 250 bytes
        let cutFamilies = ViewerAnnouncer.instanceName(for: families)
        #expect(!cutFamilies.isEmpty && cutFamilies.utf8.count <= 63)
        #expect(cutFamilies == String(repeating: Self.family, count: cutFamilies.count), "whole characters only: nobody is cut in two")
        #expect(cutFamilies.count == 2)

        let sixtyThree = String(repeating: "a", count: 63)
        #expect(ViewerAnnouncer.instanceName(for: sixtyThree) == sixtyThree, "63 bytes fit")
        #expect(ViewerAnnouncer.instanceName(for: sixtyThree + "a") == sixtyThree)
        #expect(ViewerAnnouncer.instanceName(for: String(repeating: "a", count: 62) + " bcd") == String(repeating: "a", count: 62), "no space at the end of the cut")
        #expect(ViewerAnnouncer.instanceName(for: "  Hallway ") == "Hallway")

        #expect(ViewerAnnouncer.instanceName(for: "   ") == "Camera Bridge")
        #expect(ViewerAnnouncer.instanceName(for: "") == "Camera Bridge")
        #expect(ViewerAnnouncer.instanceName(for: "\n\t ") == "Camera Bridge")
    }

    @Test func theTXTRecordIsTheContractWithTheApp() {
        let txt = ViewerAnnouncer.txt(for: Self.hallway)
        #expect(txt == ["id": Self.identity, "name": "Hallway", "v": "0.1.132", "api": "1"])

        // The whole name, however it is cut for the instance name.
        let long = String(repeating: "\u{E9}", count: 60)
        #expect(ViewerAnnouncer.txt(for: ViewerAnnouncer.Announcement(id: Self.identity, name: long, version: "0.1", port: 80))["name"] == long)

        // 60 families are 1,500 bytes, and a TXT entry is 255 at most (DNS-SD refuses the whole registration): cut, whole characters only.
        let families = String(repeating: Self.family, count: 60)
        let cut = ViewerAnnouncer.txt(for: ViewerAnnouncer.Announcement(id: Self.identity, name: families, version: "0.1", port: 80))
        for (key, value) in cut { #expect("\(key)=\(value)".utf8.count <= 255, "\(key)") }
        let name = cut["name"] ?? ""
        #expect(!name.isEmpty && name == String(repeating: Self.family, count: name.count))
    }

    @Test func theAdvertisementIsTheInstanceNameTheTypeThePortAndTheRecord() async throws {
        let fake = FakeAdvertiser()
        let announcer = ViewerAnnouncer(advertiser: fake)
        let long = ViewerAnnouncer.Announcement(id: Self.identity, name: String(repeating: "\u{E9}", count: 60), version: "0.1.132", port: 8080)
        await announcer.start(long)
        #expect(await eventually { fake.services.count == 1 })
        let advertisement = try #require(fake.services.first).advertisement
        #expect(advertisement.name == ViewerAnnouncer.instanceName(for: long.name) && advertisement.name.utf8.count <= 63)
        #expect(advertisement.type == ViewerAnnouncer.serviceType && ViewerAnnouncer.serviceType == "_camera-bridge._tcp")
        #expect(advertisement.port == 8080 && advertisement.txt == ViewerAnnouncer.txt(for: long))
        await announcer.stop()
    }
}

// MARK: - Fakes

/// A `ServiceAdvertiser` that records what it is asked and never touches the network. It fails the next calls on request, can hold a call open
/// until a gate opens, and hands out services that record their withdrawal and can report a failure later (like HAPTests' `RecordingAdvertiser`).
private final class FakeAdvertiser: ServiceAdvertiser {
    private struct State {
        var requests: [ServiceAdvertisement] = []
        var requestTimes: [ContinuousClock.Instant] = []
        var services: [FakeService] = []
        var failures: [TransportError] = []
        var alwaysFails: TransportError?
        var holds: [AsyncGate] = []
    }

    private let state = Mutex(State())

    /// Every `advertise` call so far, the failed ones and the one held open included.
    var requests: [ServiceAdvertisement] { state.withLock { $0.requests } }
    /// When each of them came.
    var requestTimes: [ContinuousClock.Instant] { state.withLock { $0.requestTimes } }
    /// The registrations that worked, in order.
    var services: [FakeService] { state.withLock { $0.services } }
    /// The registrations not withdrawn.
    var live: [FakeService] { services.filter { !$0.isCancelled } }

    /// The next calls throw these errors, in order.
    func failNext(_ errors: [TransportError]) {
        state.withLock { $0.failures.append(contentsOf: errors) }
    }

    /// Every call throws `error` once the queued ones are used; nil stops it.
    func failEvery(with error: TransportError?) {
        state.withLock { $0.alwaysFails = error }
    }

    /// The next call does not answer until the gate opens (a call held open is also the one that fails, when `failNext` has one).
    func holdNext() -> AsyncGate {
        let gate = AsyncGate()
        state.withLock { $0.holds.append(gate) }
        return gate
    }

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        let (failure, hold) = state.withLock { state -> (TransportError?, AsyncGate?) in
            state.requests.append(advertisement)
            state.requestTimes.append(.now)
            return (state.failures.isEmpty ? state.alwaysFails : state.failures.removeFirst(), state.holds.isEmpty ? nil : state.holds.removeFirst())
        }
        await hold?.wait()
        if let failure { throw failure }
        let service = FakeService(advertisement)
        state.withLock { $0.services.append(service) }
        return service
    }
}

private final class FakeService: AdvertisedService {
    let advertisement: ServiceAdvertisement
    private let stream = AsyncStream<TransportError>.makeStream()
    private let cancellations = Mutex(0)

    init(_ advertisement: ServiceAdvertisement) {
        self.advertisement = advertisement
    }

    var failures: AsyncStream<TransportError> { stream.stream }
    var isCancelled: Bool { cancellations.withLock { $0 > 0 } }

    func updateTXT(_ txt: [String: String]) async throws {}

    func cancel() {
        cancellations.withLock { $0 += 1 }
        stream.continuation.finish()
    }

    /// A failure after the registration worked (avahi restarted and dropped it).
    func fail(_ error: TransportError) {
        stream.continuation.yield(error)
    }
}

/// What the announcer said in the log (category `bonjour`).
private final class AnnouncerLog: LogSink {
    private let storage = Mutex<[String]>([])

    func record(_ entry: LogEntry) {
        guard entry.category == "bonjour" else { return }
        storage.withLock { $0.append(entry.message) }
    }

    var messages: [String] { storage.withLock { $0 } }
}
