import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// Away from home's service (`AwayService`) over fakes the test steers: the system (`FakeSystem`), the website (`FakeBoxServer`, reached through
/// a real `SecureAddressService` that is registered already), the paired devices (a real `AuthStore` with one iPhone) and the box's network
/// (`FakeAwayNetwork`), all on a clock the test moves.
@Suite(.timeLimit(.minutes(1))) struct AwayServiceTests {
    static let base = URL(string: "https://www.example.test/api/v1/box/")!
    /// 2026-10-17 08:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_792_224_000)
    static let secureHost = "k7f2q9.box.camera-bridge.app"
    static let awayName = "abcdefghij0123456789.away.camera-bridge.app"
    /// The box's own global address. It must be one the website takes, and the documentation prefixes (2001:db8::/32, 3fff::/20) are among the
    /// ranges it refuses (`AwayRules.websiteTakes`), so the home's prefix is in 3fff:1000::/36: just past 3fff::/20, in space IANA has given to
    /// nobody. Endpoints from away stay documentation addresses.
    static let homeAddress = "3fff:1000:4:7000::1"
    static let homePrefix = "3fff:1000:4:7000::/64"
    static let interfaceDown = "The VPN interface isn’t up."

    static func global(_ address: String) -> AwayAddress {
        AwayAddress(address: address, prefixLength: 64, preferredLifetime: .max)
    }

    struct Rig {
        let directory: TemporaryDirectory
        let clock: Box<Date>
        let backend: FakeBackend
        let system: FakeSystem
        let server: FakeBoxServer
        let auth: AuthStore
        let iPhone: AuthStore.ViewerInfo
        let network: FakeAwayNetwork
        let secureAddress: SecureAddressService
        let away: AwayService

        /// The daemon after a restart: a new secure address and a new service on the same folder, with the same system, website and clock.
        func restarted() -> AwayService {
            let secureAddress = AwayServiceTests.secureAddress(directory: directory.url, backend: backend, system: system, server: server, clock: clock)
            return AwayService(system: system, secureAddress: secureAddress, auth: auth, network: network, directory: directory.url, now: { [clock] in clock.value })
        }
    }

    static func secureAddress(directory: URL, backend: FakeBackend, system: FakeSystem, server: any BoxTransport, clock: Box<Date>) -> SecureAddressService {
        SecureAddressService(backend: backend, system: system, directory: directory, client: BoxClient(base: base, transport: server, now: { clock.value }),
                             resolver: { _ in [] }, now: { clock.value })
    }

    /// The rig: a system with Away from home and a ready certificate, a secure address registered as `k7f2q9` whose home address is 192.0.2.10
    /// (`secureState`, saved before the services start), one paired iPhone, and a network holding `addresses` on the home's two prefixes. The
    /// website is `server`, reached through `transport` when one is given (a test that holds a call).
    static func rig(secureState: SecureAddressState? = SecureAddressState(name: "k7f2q9", host: Self.secureHost, address: "192.0.2.10"),
                    addresses: [AwayAddress] = [Self.global(Self.homeAddress)], supportsAway: Bool = true, hasNetwork: Bool = true,
                    server: FakeBoxServer = FakeBoxServer(), transport: (any BoxTransport)? = nil) async throws -> Rig {
        let directory = try TemporaryDirectory(prefix: "cb-away")
        let clock = Box(start)
        let backend = FakeBackend()
        let system = FakeSystem()
        if supportsAway { system.supportAway() }
        system.certificate.set(CertificateStatus(state: "ready", host: secureHost, notAfter: start.addingTimeInterval(60 * 86_400)))
        secureState?.save(to: directory.url)
        let secureAddress = Self.secureAddress(directory: directory.url, backend: backend, system: system, server: transport ?? server, clock: clock)
        let auth = AuthStore(directory: directory.url, iterations: 1_000, now: { clock.value })
        try await auth.configure(password: "long enough", bridgeName: nil)
        let iPhone = try await pair(auth, name: "iPhone", address: "192.0.2.41")
        let network = FakeAwayNetwork()
        network.addresses.set(addresses)
        network.prefixes.set(["192.0.2.0/24", homePrefix])
        let away = AwayService(system: system, secureAddress: secureAddress, auth: auth, network: hasNetwork ? network : nil, directory: directory.url,
                               now: { clock.value })
        return Rig(directory: directory, clock: clock, backend: backend, system: system, server: server, auth: auth, iPhone: iPhone, network: network,
                   secureAddress: secureAddress, away: away)
    }

    /// A phone that asks to be added, is approved by the owner and collects its key, as the app does.
    static func pair(_ auth: AuthStore, name: String, address: String) async throws -> AuthStore.ViewerInfo {
        let request = try await auth.beginPairing(name: name, device: "iPhone", address: address)
        _ = try await auth.approvePairing(code: request.code)
        var viewer: AuthStore.ViewerInfo?
        if case .approved(_, let approved) = await auth.pairingStatus(request: request.request, secret: request.secret) { viewer = approved }
        return try #require(viewer, "the phone should collect its key")
    }

    /// The addresses the website was sent for the away name, in order.
    static func published(_ server: FakeBoxServer) -> [String] {
        server.seen.value.filter { $0.method == "POST" && $0.path == "/api/v1/box/away" }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["ip"] as? String
        }
    }

    /// "10.A.B." of the subnet the system was last asked for.
    static func stem(_ rig: Rig) throws -> String {
        String(try #require(rig.system.awayRequests.value.last?.subnet).dropLast("0/24".count))
    }

    static func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(value)) as? [String: Any])
    }

    // MARK: On and off

    @Test func turningOnAppliesTheSystemAndTurnsTheSecureAddressOn() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        await rig.secureAddress.setEnabled(false)
        #expect(await rig.away.isOn == false)

        let card = try await rig.away.setOn(true)
        #expect(await rig.secureAddress.report().enabled, "the phone talks HTTPS to the secure name through the tunnel")
        let request = try #require(rig.system.awayRequests.value.last)
        #expect(request.on && request.peers.isEmpty && request.port == 51820)
        #expect(try #require(request.subnet).wholeMatch(of: /10\.\d{1,3}\.\d{1,3}\.0\/24/) != nil)
        #expect(card == AwayCard(on: true, state: "setup", problem: nil, port: 51820, address: Self.homeAddress, name: Self.awayName, router: nil,
                                 addressChangedAt: nil, devices: []))
        #expect(await rig.away.isOn)
    }

    @Test func theSubnetIsKeptAcrossOffAndOn() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let subnet = try #require(rig.system.awayRequests.value.last?.subnet)
        _ = try await rig.away.setOn(false)
        #expect(AwayState.load(from: rig.directory.url).subnet == subnet)
        _ = try await rig.away.setOn(true)
        #expect(rig.system.awayRequests.value.last?.subnet == subnet)
        _ = try await rig.away.setOn(false)
        _ = try await rig.restarted().setOn(true)
        #expect(rig.system.awayRequests.value.last?.subnet == subnet, "also after a restart")
    }

    @Test func offRemovesEveryDeviceAndTheRecord() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let subnet = rig.system.awayRequests.value.last?.subnet
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: AwayKeyPair().publicKey)
        _ = try await rig.away.addWireGuardDevice(name: "Laptop")
        let sent = rig.server.seen.value.count

        let card = try await rig.away.setOn(false)
        #expect(rig.system.awayRequests.value.last == AwayRequest(on: false, subnet: subnet, peers: []))
        let calls = rig.server.seen.value.dropFirst(sent)
        #expect(calls.map(\.method) == ["DELETE"] && calls.first?.path == "/api/v1/box/away")
        #expect(card == AwayCard(on: false, state: "off", problem: nil, port: 51820, address: nil, name: nil, router: nil, addressChangedAt: nil, devices: []))
        #expect(await rig.away.isOn == false)
        let state = AwayState.load(from: rig.directory.url)
        #expect(state.devices.isEmpty && state.lastAddress == nil && state.publishedAddress == nil && state.addressChangedAt == nil && !state.withdrawPending)
        #expect(state.subnet == subnet && state.name == Self.awayName, "the subnet and the name stay")
        await #expect(throws: AwayFailure.off) { try await rig.away.addWireGuardDevice(name: "Laptop") }
    }

    // MARK: The address on the website

    @Test func theAddressIsPublishedOnChangeAtMostOnceAMinuteAndRefreshedTwiceADay() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        let logs = LogCapture()
        defer { logs.stop() }
        let second = "3fff:1000:4:7001::1", third = "3fff:1000:4:7002::1", fourth = "3fff:1000:4:7003::1"
        _ = try await rig.away.setOn(true)
        #expect(Self.published(rig.server) == [Self.homeAddress])
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress], "an address the website has is not sent again")

        // A new address 30 seconds after a publish is noted at once and sent once a minute has passed.
        rig.clock.set(Self.start.addingTimeInterval(30))
        rig.network.addresses.set([Self.global(second)])
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress])
        var state = AwayState.load(from: rig.directory.url)
        #expect(state.addressChangedAt == Self.start.addingTimeInterval(30) && state.changes.map(\.address) == [second])
        #expect(!logs.text.contains { $0.contains(second) }, "the notice of a change leaves the address out")
        rig.clock.set(Self.start.addingTimeInterval(60))
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress, second])

        // Twelve hours later the same address is sent again, which is no change.
        rig.clock.set(Self.start.addingTimeInterval(60 + 12 * 3600))
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress, second, second])
        state = AwayState.load(from: rig.directory.url)
        #expect(state.changes.count == 1 && state.addressChangedAt == Self.start.addingTimeInterval(30))

        // Started, the service looks at once, then whenever the network says the addresses may have changed.
        rig.clock.update { $0 = $0.addingTimeInterval(60) }
        rig.network.addresses.set([Self.global(third)])
        await rig.away.start()
        #expect(await eventually { AwayState.load(from: rig.directory.url).publishedAddress == third })
        rig.network.addresses.set([Self.global(fourth)])
        rig.clock.update { $0 = $0.addingTimeInterval(60) }
        rig.network.changed()
        #expect(await eventually(timeout: .seconds(2)) { Self.published(rig.server) == [Self.homeAddress, second, second, third, fourth] })
        await rig.away.stop()
    }

    @Test func aRefusedAddressIsAProblemAndOtherFailuresWait() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        rig.server.awayAnswer.set((400, #"{"error":"That isn’t a global IPv6 address."}"#))
        let card = try await rig.away.setOn(true)
        #expect(card.state == "problem" && card.problem?.contains("That isn’t a global IPv6 address.") == true)

        // A refused signature is the website saying no too.
        rig.server.awayAnswer.set((401, #"{"error":"bad signature"}"#))
        rig.clock.set(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == 2)
        #expect(try await rig.away.card().problem?.contains("bad signature") == true)

        // Any other failure is no problem for the card, and nothing is sent before the wait is over.
        rig.server.awayAnswer.set((503, #"{"error":"no DNS token"}"#))
        rig.clock.set(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == 3)
        let notReady = try await rig.away.card()
        #expect(notReady.state == "setup" && notReady.problem == nil)
        let wait = try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil)
        #expect(wait > rig.clock.value)
        rig.clock.set(wait.addingTimeInterval(-1))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == 3)

        // A server error (the website's 500 when its database or its DNS provider fails, or a gateway's 502) goes by itself: it is waited for
        // like a website out of reach, and the card stays as it was.
        var sent = 3
        for status in [500, 502] {
            rig.server.awayAnswer.set((status, #"{"error":"Something went wrong on the server."}"#))
            rig.clock.set(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil))
            await rig.away.tick()
            sent += 1
            #expect(Self.published(rig.server).count == sent, "\(status)")
            let serverError = try await rig.away.card()
            #expect(serverError.state == "setup" && serverError.problem == nil, "\(status)")
            let after = try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil)
            #expect(after > rig.clock.value, "\(status)")
            rig.clock.set(after.addingTimeInterval(-1))
            await rig.away.tick()
            #expect(Self.published(rig.server).count == sent, "nothing is sent during the wait after a \(status)")
        }

        // Too many requests waits for the website's next day.
        rig.server.awayAnswer.set((429, #"{"error":"too many changes today"}"#))
        rig.clock.set(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == sent + 1)
        let midnight = Date(timeIntervalSince1970: 1_792_281_600)   // 2026-10-18 00:00 UTC
        #expect(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil) > midnight)
        rig.clock.set(midnight.addingTimeInterval(-60))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == sent + 1)
    }

    /// The card's Try again turns Away from home on again. Like the secure address's own Try again it forgets the website's refusal and the
    /// wait after it, so the address is sent at once; the minute between two sends still holds.
    @Test func turningOnAgainForgetsTheWebsitesRefusalAndItsWait() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        rig.server.awayAnswer.set((400, #"{"error":"That isn’t a global IPv6 address."}"#))
        let refused = try await rig.away.setOn(true)
        #expect(refused.state == "problem" && Self.published(rig.server).count == 1)
        #expect(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil) > rig.clock.value, "a wait of 10 minutes")

        rig.server.awayAnswer.set((200, #"{"name":"\#(Self.awayName)"}"#))
        rig.clock.set(Self.start.addingTimeInterval(30))
        let again = try await rig.away.setOn(true)
        #expect(Self.published(rig.server).count == 2, "sent at once, within the wait")
        #expect(again.state == "setup" && again.problem == nil && again.name == Self.awayName)
        #expect(AwayState.load(from: rig.directory.url).websiteWaitUntil == nil)

        // A server error is no problem for the card, and Try again doesn't send a new address within a minute of the last send.
        rig.server.awayAnswer.set((500, #"{"error":"Something went wrong on the server."}"#))
        rig.network.addresses.set([Self.global("3fff:1000:4:7001::1")])
        rig.clock.set(Self.start.addingTimeInterval(60))
        let early = try await rig.away.setOn(true)
        #expect(Self.published(rig.server).count == 2, "30 s after the last send")
        #expect(early.problem == nil)
        rig.clock.set(Self.start.addingTimeInterval(90))
        await rig.away.tick()
        #expect(Self.published(rig.server).count == 3, "a minute after the last send")
        #expect(try await rig.away.card().problem == nil, "a server error waits; it isn't the card's problem")
    }

    /// A last send that lies in the future means the clock was set back since: a changed address is not held up until the clock catches up.
    @Test func aClockSetBackDoesNotHoldUpAChangedAddress() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        rig.clock.set(Self.start.addingTimeInterval(-3600))
        rig.network.addresses.set([Self.global("3fff:1000:4:7001::1")])
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress, "3fff:1000:4:7001::1"])
    }

    /// While a look's website call is under way (held at the website here), another look leaves the website alone.
    @Test func aLookLeavesTheWebsiteAloneWhileACallIsUnderWay() async throws {
        let gate = SecureAddressTests.GatedBoxServer()
        let rig = try await Self.rig(server: gate.inner, transport: gate)
        defer { rig.directory.remove() }
        let on = Task { try await rig.away.setOn(true) }
        #expect(await eventually { Self.published(rig.server).count == 1 })
        let second = Task { await rig.away.tick() }
        try await Task.sleep(for: .milliseconds(100))
        gate.released.set(true)
        _ = try await on.value
        await second.value
        #expect(Self.published(rig.server) == [Self.homeAddress])
    }

    /// The website's answer to a call made before Away from home was turned off is not kept: turned on again, the box sends its address again,
    /// since the delete took the record away.
    @Test func anAnswerToACallFromBeforeATurnIsDropped() async throws {
        let gate = SecureAddressTests.GatedBoxServer()
        let rig = try await Self.rig(server: gate.inner, transport: gate)
        defer { rig.directory.remove() }
        let on = Task { try await rig.away.setOn(true) }
        #expect(await eventually { Self.published(rig.server).count == 1 })
        let off = Task { try await rig.away.setOn(false) }
        #expect(await eventually { rig.system.awayRequests.value.last?.on == false })
        gate.released.set(true)
        _ = try await (on.value, off.value)
        let state = AwayState.load(from: rig.directory.url)
        #expect(!state.on && state.publishedAddress == nil && !state.withdrawPending)
        _ = try await rig.away.setOn(true)
        #expect(Self.published(rig.server) == [Self.homeAddress, Self.homeAddress])
    }

    /// `.notRegistered` sent nothing (the secure address has no TLS front or no name yet), so the website is not waited for.
    @Test func aPublishTheSecureAddressCantSignYetIsTriedAtTheNextLook() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        rig.system.certificate.set(nil)
        let card = try await rig.away.setOn(true)
        #expect(Self.published(rig.server).isEmpty && card.problem == nil && card.name == nil)
        let state = AwayState.load(from: rig.directory.url)
        #expect(state.websiteFailures == 0 && state.websiteWaitUntil == nil)
        rig.system.certificate.set(CertificateStatus(state: "ready", host: Self.secureHost, notAfter: Self.start.addingTimeInterval(60 * 86_400)))
        await rig.away.tick()
        #expect(Self.published(rig.server) == [Self.homeAddress])
        #expect(try await rig.away.card().name == Self.awayName)
    }

    @Test func aWithdrawThatFailedIsSentLaterEvenAfterARestart() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        rig.server.unreachable.set(true)
        _ = try await rig.away.setOn(false)
        #expect(AwayState.load(from: rig.directory.url).withdrawPending)

        // While the website can't be reached, nothing gets through: neither during the wait nor after it.
        await rig.away.tick()
        rig.clock.set(Self.start.addingTimeInterval(601))
        await rig.away.tick()
        #expect(AwayState.load(from: rig.directory.url).withdrawPending)

        // After a restart, once the website can be reached and the wait is over, the record goes, once.
        rig.server.unreachable.set(false)
        rig.clock.set(try #require(AwayState.load(from: rig.directory.url).websiteWaitUntil))
        let sent = rig.server.seen.value.count
        let restarted = rig.restarted()
        await restarted.tick()
        await restarted.tick()
        let calls = rig.server.seen.value.dropFirst(sent)
        #expect(calls.map(\.method) == ["DELETE"] && calls.first?.path == "/api/v1/box/away")
        #expect(!AwayState.load(from: rig.directory.url).withdrawPending)
    }

    // MARK: Devices

    @Test func anAppDeviceKeepsItsAddressAndItsKeyChangesNothingTwice() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let stem = try Self.stem(rig)
        let first = AwayKeyPair().publicKey, second = AwayKeyPair().publicKey
        let before = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: first)
        let after = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: second)
        #expect(before.address == after.address)
        #expect(rig.system.awayRequests.value.last?.peers == [AwayRequest.Peer(publicKey: second, address: "\(stem)2")])
        #expect(try await rig.away.card().devices.map(\.id) == [rig.iPhone.id], "a phone's device is named by its pairing")

        let count = rig.system.awayRequests.value.count
        let again = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: second)
        #expect(rig.system.awayRequests.value.count == count, "the same key runs no job")
        let expected = TunnelDocument(boxPublicKey: FakeSystem.awayBoxKey, endpoint: .init(host: Self.awayName, port: 51820, addresses: [Self.homeAddress]),
                                      address: "\(stem)2/32", routes: ["\(stem)1/32", "192.0.2.10/32"], secureURL: "https://\(Self.secureHost)", mtu: 1280)
        #expect(again == expected)
        #expect(try await rig.away.tunnelDocument(viewerID: rig.iPhone.id) == expected)
        #expect(try await rig.restarted().tunnelDocument(viewerID: rig.iPhone.id) == expected, "after a restart, before the first look too")
    }

    @Test func thePhonesRefusals() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        let key = AwayKeyPair().publicKey
        await #expect(throws: AwayFailure.off) { try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key) }
        await #expect(throws: AwayFailure.off) { try await rig.away.tunnelDocument(viewerID: rig.iPhone.id) }
        _ = try await rig.away.setOn(true)
        await #expect(throws: AwayFailure.badKey) { try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: "abc") }
        await #expect(throws: AwayFailure.badKey, "the box's own key") { try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: FakeSystem.awayBoxKey) }
        await #expect(throws: AwayFailure.notSetUp) { try await rig.away.tunnelDocument(viewerID: rig.iPhone.id) }

        // Without the box's key the system isn't ready to be reached.
        rig.system.away.update { $0?.publicKey = nil }
        await #expect(throws: AwayFailure.notReady) { try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key) }
        _ = try await rig.away.setOn(true)
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)
        let iPad = try await Self.pair(rig.auth, name: "iPad", address: "192.0.2.42")
        await #expect(throws: AwayFailure.badKey, "another device's key") { try await rig.away.setAppDevice(viewer: iPad, publicKey: key) }

        // A secure address without its home address (F31): the document would have no route to the name the phone uses.
        SecureAddressState(name: "k7f2q9", host: Self.secureHost, address: nil).save(to: rig.directory.url)
        let unrouted = rig.restarted()
        await #expect(throws: AwayFailure.secureAddressOff) { try await unrouted.tunnelDocument(viewerID: rig.iPhone.id) }
        await #expect(throws: AwayFailure.secureAddressOff) { try await unrouted.setAppDevice(viewer: rig.iPhone, publicKey: AwayKeyPair().publicKey) }

        // No secure host at all.
        let unnamed = try await Self.rig(secureState: nil)
        defer { unnamed.directory.remove() }
        _ = try await unnamed.away.setOn(true)
        await #expect(throws: AwayFailure.secureAddressOff) { try await unnamed.away.setAppDevice(viewer: unnamed.iPhone, publicKey: key) }
    }

    @Test func aWireGuardDeviceKeepsOnlyItsPublicKey() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        let logs = LogCapture()
        defer { logs.stop() }
        _ = try await rig.away.setOn(true)
        let stem = try Self.stem(rig)
        let (device, config) = try await rig.away.addWireGuardDevice(name: "Laptop")
        #expect(device.kind == "wireguard" && device.name == "Laptop" && device.lastHandshake == nil && device.lastAwayAt == nil)
        #expect(device.id.wholeMatch(of: /[0-9a-f]{32}/) != nil, "a path segment of the page's Remove: \(device.id)")

        let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("PrivateKey = ") })
        let privateKey = String(line.dropFirst("PrivateKey = ".count))
        let publicKey = try #require(AwayKeyPair(privateKey: privateKey)?.publicKey)
        #expect(rig.system.awayRequests.value.last?.peers == [AwayRequest.Peer(publicKey: publicKey, address: "\(stem)2")])
        #expect(config == """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(stem)2/32
        MTU = 1280

        [Peer]
        PublicKey = \(FakeSystem.awayBoxKey)
        AllowedIPs = \(stem)1/32, 192.0.2.10/32
        Endpoint = [\(Self.homeAddress)]:51820

        """)
        let file = try String(contentsOf: rig.directory.url.appending(path: AwayState.fileName), encoding: .utf8)
        #expect(file.contains(publicKey) && !file.contains(privateKey), "only the public half is kept")
        #expect(!logs.text.contains { $0.contains(privateKey) })
        #expect(try await rig.away.card().devices.map(\.id) == [device.id])

        await #expect(throws: AwayFailure.badName) { try await rig.away.addWireGuardDevice(name: "  ") }
        await #expect(throws: AwayFailure.badName) { try await rig.away.addWireGuardDevice(name: nil) }
        for number in 2...20 { _ = try await rig.away.addWireGuardDevice(name: "Device \(number)") }
        await #expect(throws: AwayFailure.tooManyDevices) { try await rig.away.addWireGuardDevice(name: "Device 21") }

        // Without the box's global address there is no endpoint to give, and the website gave no name either.
        let bare = try await Self.rig(addresses: [])
        defer { bare.directory.remove() }
        let card = try await bare.away.setOn(true)
        #expect(card.state == "no_ipv6" && card.address == nil && card.name == nil)
        await #expect(throws: AwayFailure.noAddress) { try await bare.away.addWireGuardDevice(name: "Laptop") }
    }

    @Test func aLapsedViewerLosesItsKeyAtTheNextLook() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let key = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)
        #expect(rig.system.awayRequests.value.last?.peers.map(\.publicKey) == [key])

        #expect(await rig.auth.removeViewer(id: rig.iPhone.id), "removed behind the service's back")
        await rig.away.tick()
        #expect(rig.system.awayRequests.value.last?.peers.isEmpty == true)
        #expect(try await rig.away.card().devices.isEmpty)
        await #expect(throws: AwayFailure.notSetUp, "a phone that is no longer paired gets no key") {
            try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)
        }

        // Removed through the service, the key goes at once.
        let iPad = try await Self.pair(rig.auth, name: "iPad", address: "192.0.2.42")
        _ = try await rig.away.setAppDevice(viewer: iPad, publicKey: AwayKeyPair().publicKey)
        let count = rig.system.awayRequests.value.count
        await rig.away.removeAppDevice(viewerID: iPad.id)
        #expect(rig.system.awayRequests.value.count == count + 1)
        #expect(rig.system.awayRequests.value.last?.peers.isEmpty == true)
    }

    @Test func handshakesFromAwayMakeItWorkingAndAnAddressChangeAsksAgain() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let key = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)
        #expect(try await rig.away.card().state == "setup")
        let t0 = Int(Self.start.timeIntervalSince1970)
        let reached = Date(timeIntervalSince1970: TimeInterval(t0 + 10))

        rig.system.awayHandshake(key, at: t0 + 10, from: "2001:db8:99::5")
        rig.clock.set(Self.start.addingTimeInterval(20))
        await rig.away.tick()
        var card = try await rig.away.card()
        #expect(card.state == "working" && card.devices.first?.lastAwayAt == reached && card.devices.first?.lastHandshake == reached)

        // A handshake from the home's own prefix is not from away.
        rig.system.awayHandshake(key, at: t0 + 30, from: "3fff:1000:4:7000::50")
        rig.clock.set(Self.start.addingTimeInterval(40))
        await rig.away.tick()
        card = try await rig.away.card()
        #expect(card.state == "working" && card.devices.first?.lastAwayAt == reached)
        #expect(card.devices.first?.lastHandshake == Date(timeIntervalSince1970: TimeInterval(t0 + 30)))

        // A new address may break a router rule that names the old one: the card asks again until a device reaches the box from away.
        rig.network.addresses.set([Self.global("3fff:1000:4:7001::1")])
        rig.clock.set(Self.start.addingTimeInterval(100))
        await rig.away.tick()
        card = try await rig.away.card()
        #expect(card.state == "address_changed" && card.address == "3fff:1000:4:7001::1" && card.addressChangedAt == Self.start.addingTimeInterval(100))

        rig.system.awayHandshake(key, at: t0 + 110, from: "2001:db8:99::5")
        rig.clock.set(Self.start.addingTimeInterval(120))
        await rig.away.tick()
        #expect(try await rig.away.card().state == "working")

        // After a while without IPv6 at home, the next address is still compared with the last one the box had.
        rig.network.addresses.set([])
        rig.clock.set(Self.start.addingTimeInterval(130))
        await rig.away.tick()
        #expect(try await rig.away.card().state == "no_ipv6")
        rig.network.addresses.set([Self.global("3fff:1000:4:7002::1")])
        rig.clock.set(Self.start.addingTimeInterval(140))
        await rig.away.tick()
        #expect(try await rig.away.card().state == "address_changed")
    }

    @Test func theCardListsWhoReachedTheBoxFromAwayFirst() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let iPad = try await Self.pair(rig.auth, name: "iPad", address: "192.0.2.42")
        let phoneKey = AwayKeyPair().publicKey
        let laptop = try await rig.away.addWireGuardDevice(name: "Laptop").device
        rig.clock.set(Self.start.addingTimeInterval(1))
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: phoneKey)
        rig.clock.set(Self.start.addingTimeInterval(2))
        let tablet = try await rig.away.addWireGuardDevice(name: "Tablet").device
        rig.clock.set(Self.start.addingTimeInterval(3))
        _ = try await rig.away.setAppDevice(viewer: iPad, publicKey: AwayKeyPair().publicKey)
        let tabletKey = try #require(rig.system.awayRequests.value.last?.peers.first { $0.address.hasSuffix(".4") }?.publicKey)

        let t0 = Int(Self.start.timeIntervalSince1970)
        rig.system.awayHandshake(tabletKey, at: t0 + 100, from: "198.51.100.7")
        rig.system.awayHandshake(phoneKey, at: t0 + 200, from: "2001:db8:99::5")
        rig.clock.set(Self.start.addingTimeInterval(300))
        await rig.away.tick()
        #expect(try await rig.away.card().devices.map(\.id) == [rig.iPhone.id, tablet.id, laptop.id, iPad.id],
                "from away, the newest first, then the others as they were added")
    }

    @Test func changesAreMadeOneAtATime() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let before = rig.system.awayRequests.value.count
        rig.system.awayDelay.set(.milliseconds(200))
        let first = Task { try await rig.away.addWireGuardDevice(name: "Laptop") }
        #expect(await eventually { rig.system.awayRequests.value.count == before + 1 })
        // The second change would finish first if it were let through: the system would be left with the older list.
        rig.system.awayDelay.set(.zero)
        let second = Task { try await rig.away.addWireGuardDevice(name: "Tablet") }
        _ = try await (first.value, second.value)

        let devices = AwayState.load(from: rig.directory.url).devices
        #expect(devices.count == 2 && Set(devices.map(\.address)).count == 2)
        let keys = Set(devices.map(\.publicKey))
        #expect(Set(rig.system.awayRequests.value.last?.peers.map(\.publicKey) ?? []) == keys)
        #expect(Set(rig.system.away.value?.peers.map(\.publicKey) ?? []) == keys, "the system holds both devices")
    }

    // MARK: Keeping the system in step

    @Test func aFailedApplyIsAProblemUntilItWorks() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        rig.system.awayFailure.set(Self.interfaceDown)
        let card = try await rig.away.setOn(true)
        #expect(card.on && card.state == "problem" && card.problem == Self.interfaceDown, "the owner's choice is kept and the card says what failed")
        #expect(AwayState.load(from: rig.directory.url).applyPending)

        rig.system.awayFailure.set(nil)
        await rig.away.tick()
        let fixed = try await rig.away.card()
        #expect(fixed.state == "setup" && fixed.problem == nil)
        #expect(!AwayState.load(from: rig.directory.url).applyPending)
    }

    @Test func aDeviceWhoseChangeFailsIsTakenOutAgainButARemovalStays() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let first = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: first)
        rig.system.awayFailure.set(Self.interfaceDown)
        await #expect(throws: AwayFailure.system(Self.interfaceDown)) { try await rig.away.addWireGuardDevice(name: "Laptop") }
        await #expect(throws: AwayFailure.system(Self.interfaceDown)) {
            try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: AwayKeyPair().publicKey)
        }
        #expect(AwayState.load(from: rig.directory.url).devices.map(\.publicKey) == [first], "the new device is gone and the phone's earlier key is back")

        // A removed key must never come back with a later try, so a removal is kept. It still fails, so the page doesn't take the device for gone:
        // the system still holds its key, and the card says the device can connect until a retry goes through.
        let pending = "The VPN interface isn’t up. A removed device can still connect until the box’s retry goes through."
        await #expect(throws: AwayFailure.system(Self.interfaceDown)) { try await rig.away.removeDevice(id: rig.iPhone.id) }
        #expect(AwayState.load(from: rig.directory.url).devices.isEmpty)
        #expect(try await rig.away.card().problem == pending)
        rig.system.awayFailure.set(nil)
        await rig.away.tick()
        #expect(rig.system.awayRequests.value.last?.peers.isEmpty == true)
        #expect(try await rig.away.card().problem == nil)
        await #expect(throws: AwayFailure.noSuchDevice) { try await rig.away.removeDevice(id: rig.iPhone.id) }

        // Turning off removes every device's key, so the off card says the same while the system still holds them.
        _ = try await rig.away.addWireGuardDevice(name: "Laptop")
        rig.system.awayFailure.set(Self.interfaceDown)
        let off = try await rig.away.setOn(false)
        #expect(!off.on && off.state == "problem" && off.problem == pending)
    }

    @Test func atStartTheSystemIsMadeToMatchTheState() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        // Off in the state, but the system still has a tunnel with a device: the first look turns it off, and later looks don't compare.
        rig.system.away.set(AwayStatus(state: "ok", message: nil, publicKey: FakeSystem.awayBoxKey, port: 51820, router: nil,
                                       peers: [.init(publicKey: AwayKeyPair().publicKey, latestHandshake: 0, endpoint: nil)], updated: 0))
        await rig.away.tick()
        #expect(rig.system.awayRequests.value.map(\.on) == [false] && rig.system.awayRequests.value.last?.peers.isEmpty == true)
        await rig.away.tick()
        #expect(rig.system.awayRequests.value.count == 1)

        // On in the state, but the system is off: a new service's first look turns it on with the kept devices.
        let laptop = AwayKeyPair().publicKey
        var state = AwayState()
        state.on = true
        state.subnet = "10.77.12.0/24"
        state.devices = [AwayDevice(id: String(repeating: "a", count: 32), kind: .wireguard, name: "Laptop", publicKey: laptop, address: "10.77.12.2",
                                    created: Self.start)]
        state.save(to: rig.directory.url)
        await rig.restarted().tick()
        #expect(rig.system.awayRequests.value.last == AwayRequest(on: true, subnet: "10.77.12.0/24", peers: [.init(publicKey: laptop, address: "10.77.12.2")]))

        // A tunnel the system reports as failed is the card's problem while on, and a new service's first look applies again.
        let firewall = "The firewall doesn’t let the VPN’s port in."
        rig.system.away.update { $0?.state = "failed"; $0?.message = firewall }
        let again = rig.restarted()
        #expect(try await again.card().problem == firewall)
        let count = rig.system.awayRequests.value.count
        await again.tick()
        #expect(rig.system.awayRequests.value.count == count + 1)
        #expect(try await again.card().problem == nil)
        rig.system.away.update { $0?.state = "failed"; $0?.message = firewall }
        await again.tick()
        #expect(rig.system.awayRequests.value.count == count + 1, "only the first look applies for it")
        #expect(try await again.card().state == "problem")
    }

    /// A state that is on without a subnet (written by hand, or by an older version) gets one at the first look, since the request needs one.
    @Test func aStateOnWithoutASubnetGetsOneAtTheFirstLook() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        try Data(#"{"on":true}"#.utf8).write(to: rig.directory.url.appending(path: AwayState.fileName))
        await rig.restarted().tick()
        let request = try #require(rig.system.awayRequests.value.last)
        #expect(request.on && request.subnet?.wholeMatch(of: /10\.\d{1,3}\.\d{1,3}\.0\/24/) != nil)
        #expect(AwayState.load(from: rig.directory.url).subnet == request.subnet)
    }

    @Test func withoutTheSystemOrTheNetworkItIsUnavailable() async throws {
        let older = try await Self.rig(supportsAway: false)
        defer { older.directory.remove() }
        await #expect(throws: AwayFailure.unavailable) { try await older.away.card() }
        await #expect(throws: AwayFailure.unavailable) { try await older.away.setOn(true) }
        await #expect(throws: AwayFailure.unavailable) { try await older.away.addWireGuardDevice(name: "Laptop") }
        await #expect(throws: AwayFailure.unavailable) { try await older.away.setAppDevice(viewer: older.iPhone, publicKey: AwayKeyPair().publicKey) }
        await #expect(throws: AwayFailure.unavailable) { try await older.away.tunnelDocument(viewerID: older.iPhone.id) }
        await older.away.tick()
        #expect(older.system.awayRequests.value.isEmpty && older.server.seen.value.isEmpty)

        let networkless = try await Self.rig(hasNetwork: false)
        defer { networkless.directory.remove() }
        await #expect(throws: AwayFailure.unavailable) { try await networkless.away.card() }
        await #expect(throws: AwayFailure.unavailable) { try await networkless.away.setOn(true) }
        await networkless.away.start()
        await networkless.away.tick()
        try await Task.sleep(for: .milliseconds(100))
        #expect(networkless.system.awayRequests.value.isEmpty && networkless.server.seen.value.isEmpty)
        await networkless.away.stop()
    }

    // MARK: The documents

    @Test func theDocumentsWriteEveryKeyWithNullForWhatIsMissing() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        let off = try Self.json(try await rig.away.card())
        #expect(Set(off.keys) == ["on", "state", "problem", "port", "address", "name", "router", "addressChangedAt", "devices"])
        for key in ["problem", "address", "name", "router", "addressChangedAt"] { #expect(off[key] is NSNull, "\(key)") }
        #expect(off["on"] as? Bool == false && off["state"] as? String == "off" && off["port"] as? Int == 51820 && (off["devices"] as? [Any])?.isEmpty == true)

        _ = try await rig.away.setOn(true)
        let device = try Self.json(try await rig.away.addWireGuardDevice(name: "Laptop").device)
        #expect(Set(device.keys) == ["id", "kind", "name", "lastHandshake", "lastAwayAt"])
        #expect(device["lastHandshake"] is NSNull && device["lastAwayAt"] is NSNull)

        let document = try Self.json(try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: AwayKeyPair().publicKey))
        #expect(Set(document.keys) == ["boxPublicKey", "endpoint", "address", "routes", "secureURL", "mtu"])
        #expect(Set(try #require(document["endpoint"] as? [String: Any]).keys) == ["host", "port", "addresses"])
        let unnamed = TunnelDocument(boxPublicKey: FakeSystem.awayBoxKey, endpoint: .init(host: nil, port: 51820, addresses: []), address: "10.77.12.2/32",
                                     routes: ["10.77.12.1/32", "192.0.2.10/32"], secureURL: "https://\(Self.secureHost)", mtu: 1280)
        #expect((try Self.json(unnamed)["endpoint"] as? [String: Any])?["host"] is NSNull)

        // Dates are ISO 8601.
        let key = try #require(rig.system.awayRequests.value.last?.peers.first?.publicKey)
        rig.system.awayHandshake(key, at: Int(Self.start.timeIntervalSince1970) + 10, from: "2001:db8:99::5")
        await rig.away.tick()
        let on = try Self.json(try await rig.away.card())
        let listed = try #require((on["devices"] as? [[String: Any]])?.first)
        #expect(listed["lastAwayAt"] as? String == "2026-10-17T08:00:10Z" && listed["lastHandshake"] as? String == "2026-10-17T08:00:10Z")
    }

    // MARK: Removals that wait for their answer

    @Test func aKeyTakenOutForItsAnswerStaysInEveryRequestUntilItSettles() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let key = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)

        let hold = await rig.away.takeOutAppDevice(viewerID: rig.iPhone.id)
        await rig.away.tick()
        _ = try await rig.away.addWireGuardDevice(name: "Laptop")
        #expect(rig.system.awayRequests.value.allSatisfy { $0.peers.contains { $0.publicKey == key } || $0.peers.isEmpty }, "a look or another change doesn't drop it")
        #expect(rig.system.awayRequests.value.last?.peers.contains { $0.publicKey == key } == true)

        await rig.away.settleRemoval(try #require(hold))
        let last = try #require(rig.system.awayRequests.value.last)
        #expect(!last.peers.contains { $0.publicKey == key } && last.peers.count == 1)
    }

    /// Two removals answered from inside the tunnel at about the same time: each key stays until its own answer is out, so the answer to one
    /// never drops the other's key while that answer is still on its way.
    @Test func eachRemovalIsHeldUntilItsOwnAnswerIsOut() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let phoneKey = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: phoneKey)
        let laptop = try await rig.away.addWireGuardDevice(name: "Laptop").device
        let laptopKey = try #require(rig.system.awayRequests.value.last?.peers.first { $0.publicKey != phoneKey }?.publicKey)

        let phoneHold = try #require(await rig.away.takeOutAppDevice(viewerID: rig.iPhone.id))
        let laptopHold = try await rig.away.takeOutDevice(id: laptop.id)
        #expect(phoneHold != laptopHold)
        await rig.away.settleRemoval(phoneHold)
        #expect(rig.system.awayRequests.value.last?.peers.map(\.publicKey) == [laptopKey], "the phone's answer is out, the laptop's isn't yet")
        await rig.away.tick()
        #expect(rig.system.awayRequests.value.last?.peers.map(\.publicKey) == [laptopKey], "nor does a look drop it")
        await rig.away.settleRemoval(laptopHold)
        #expect(rig.system.awayRequests.value.last?.peers.isEmpty == true)
        #expect(await rig.away.takeOutAppDevice(viewerID: rig.iPhone.id) == nil, "nothing left to hold")
    }

    @Test func aRemovalStillOwedAfterARestartIsAppliedAtTheFirstLook() async throws {
        let rig = try await Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.away.setOn(true)
        let key = AwayKeyPair().publicKey
        _ = try await rig.away.setAppDevice(viewer: rig.iPhone, publicKey: key)
        await rig.away.takeOutAppDevice(viewerID: rig.iPhone.id)
        await rig.away.stop()   // the daemon ends before the answer's settle ran

        let restarted = rig.restarted()
        await restarted.tick()
        let last = try #require(rig.system.awayRequests.value.last)
        #expect(!last.peers.contains { $0.publicKey == key }, "the key left the system")
    }
}
