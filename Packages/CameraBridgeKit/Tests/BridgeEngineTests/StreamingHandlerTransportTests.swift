#if canImport(Darwin)
import BridgeSupport
import Foundation
import HAPCamera
import RTP
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// How the streaming delegate ties a session's sockets to the network and what it tells the owner (`SendStrategy`,
/// `NetworkNotice`): the per-controller strategy ladder, the dual-homed subnet notice, the transport hooks and the VPN notice's
/// false positives. Sockets bind lo0's 127.0.0.1 (the only address every machine has) or fall back to the wildcard.
@Suite(.serialized) struct StreamingHandlerTransportTests {
    private static let loopback = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8)]

    private func makeSetup(interfaces: [InterfaceAddress] = StreamingHandlerTransportTests.loopback, routes: [MacVPNDetector.InterfaceRoute] = [],
                           strategyMemory: Duration = .seconds(3_600), liveTimings: LiveStreamTimings? = nil, controllerWait: Duration = .seconds(1),
                           notices: Box<[NetworkNotice]>? = nil) -> RuntimeLiveStreamTests.Setup {
        var sink: (@Sendable (NetworkNotice) -> Void)?
        if let notices { sink = { @Sendable (notice: NetworkNotice) in notices.update { $0.append(notice) } } }
        return RuntimeLiveStreamTests.setup(source: syntheticSource(width: 320, height: 180, fps: 10, audio: nil), controllerWait: controllerWait, loopbackOnly: false,
                                            interfaceAddresses: { interfaces }, routeTable: { routes }, strategyMemory: strategyMemory, liveTimings: liveTimings,
                                            networkNotices: sink)
    }

    private func prepare(_ setup: RuntimeLiveStreamTests.Setup, receiver: SRTPTestReceiver, controller: String = "127.0.0.1", peer: String? = nil,
                         local: String = "127.0.0.1", sessionID: UUID = UUID()) async throws -> PrepareStreamResponse {
        var request = RuntimeLiveStreamTests.request(sessionID: sessionID, controller: controller, ipv6: false, local: local, receiver: receiver)
        request.peerAddress = peer
        return try await setup.handler.prepareStream(request)
    }

    // MARK: The sending strategy ladder

    @Test func theFirstSessionToAControllerIsBoundAndScopedToTheInterfaceOfTheAddress() async throws {
        let setup = makeSetup()
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        _ = try await prepare(setup, receiver: receiver, sessionID: sessionID)
        let socketSetup = try #require(await setup.handler.socketSetup(sessionID))
        #expect(socketSetup.strategy == .boundAndScoped && socketSetup.interface == "lo0")
        let socket = try #require(await setup.handler.preparedVideoSocket(sessionID))
        let values = socket.transport.values
        #expect(values.boundSource == "127.0.0.1" && values.strategy.contains("scoped") && values.strategy.contains("lo0"))
        #expect(values.recoveryScopes == [nil], "nothing else to flip to on a Mac with one interface: the unscoped route")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// A session whose controller answered but never got the video moves that controller one step down for its next session,
    /// and only that controller; a network change (or an hour) takes the memory away.
    @Test func aSessionThatEndedBlindMovesItsControllerDownTheLadderUntilTheNetworkChanges() async throws {
        let setup = makeSetup()
        let receiver = try await SRTPTestReceiver.start()
        func next(peer: String? = nil) async throws -> (strategy: StreamingHandler.SendStrategy, interface: String?, id: UUID) {
            let id = UUID()
            _ = try await prepare(setup, receiver: receiver, peer: peer, sessionID: id)
            let socketSetup = try #require(await setup.handler.socketSetup(id))
            return (socketSetup.strategy, socketSetup.interface, id)
        }
        let first = try await next(peer: "127.0.0.1")
        #expect(first.strategy == .boundAndScoped)
        await setup.handler.rememberBlindEnd(first.id)
        let second = try await next(peer: "127.0.0.1")
        #expect(second.strategy == .bound && second.interface == nil, "bound to the address, no interface scope")
        let other = try await next(peer: "127.0.0.7")
        #expect(other.strategy == .boundAndScoped, "another controller is not affected")
        await setup.handler.rememberBlindEnd(second.id)
        let third = try await next(peer: "127.0.0.1")
        #expect(third.strategy == .wildcard)
        await setup.handler.rememberBlindEnd(third.id)
        #expect(try await next(peer: "127.0.0.1").strategy == .wildcard, "the last rung stays")
        await setup.handler.networkChanged()
        #expect(try await next(peer: "127.0.0.1").strategy == .boundAndScoped, "a network change clears the memory")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func theMemoryOfAStrategyExpires() async throws {
        let setup = makeSetup(strategyMemory: .milliseconds(300))
        let receiver = try await SRTPTestReceiver.start()
        let first = UUID()
        _ = try await prepare(setup, receiver: receiver, sessionID: first)
        await setup.handler.rememberBlindEnd(first)
        let second = UUID()
        _ = try await prepare(setup, receiver: receiver, sessionID: second)
        #expect(await setup.handler.socketSetup(second)?.strategy == .bound)
        try await Task.sleep(for: .milliseconds(400))
        let third = UUID()
        _ = try await prepare(setup, receiver: receiver, sessionID: third)
        #expect(await setup.handler.socketSetup(third)?.strategy == .boundAndScoped, "expired")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    /// The accessory address went away since the interface list was read: the ladder falls through to the wildcard, as before.
    @Test func anAddressThatCannotBeBoundFallsBackToTheWildcard() async throws {
        let lan = [InterfaceAddress(interface: "en9", address: "203.0.113.7", prefixLength: 24)]
        let setup = makeSetup(interfaces: lan)
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        let response = try await prepare(setup, receiver: receiver, controller: "203.0.113.20", local: "203.0.113.7", sessionID: sessionID)
        #expect(response.accessoryAddress == "203.0.113.7", "still what the controller is told")
        #expect(await setup.handler.socketSetup(sessionID)?.strategy == .wildcard)
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    // MARK: A blind controller, end to end

    private func fastTimings() -> LiveStreamTimings {
        var timings = LiveStreamTimings()
        timings.watchdogTick = .milliseconds(20)
        timings.blindAfter = .milliseconds(500)
        timings.endBlindAfter = .milliseconds(1_800)
        timings.interfaceFlipInterval = .milliseconds(400)
        timings.minimumSessionAge = .milliseconds(400)
        timings.minimumPacketsSent = 5
        return timings
    }

    /// A reported incident, whole: a controller that answers but gets no video. The session ends by itself through the owner (so
    /// HAP shows the stream available and Home asks again), the owner is told, and the controller's next session sends another way.
    @Test(.timeLimit(.minutes(3))) func aControllerThatReceivesNothingEndsTheSessionIsReportedAndGetsAnotherWayNextTime() async throws {
        let notices = Box<[NetworkNotice]>([])
        let setup = makeSetup(liveTimings: fastTimings(), notices: notices)
        #expect(await setup.feeder.waitUntilReady(timeout: .seconds(15)))
        let ended = Box<[UUID]>([])
        await setup.handler.setSessionEnder { id in
            ended.update { $0.append(id) }
            return false   // the handler ends the session itself
        }
        let receiver = try await SRTPTestReceiver.start()
        await receiver.setReportBlocks(.none)
        let sessionID = UUID()
        let response = try await prepare(setup, receiver: receiver, peer: "127.0.0.1", sessionID: sessionID)
        await RuntimeLiveStreamTests.connect(receiver, to: response)
        try await setup.handler.handleStreamRequest(.start(sessionID: sessionID, video: RuntimeLiveStreamTests.video(640, 360), audio: nil))
        #expect(await eventually(timeout: .seconds(20)) { notices.value.contains { $0.kind == .liveViewNotReceived } })
        let notice = try #require(notices.value.first { $0.kind == .liveViewNotReceived })
        #expect(notice.delivery == .failed && notice.peerAddress == "127.0.0.1" && notice.detail?.contains("receiver reports") == true)
        #expect(await eventually(timeout: .seconds(20)) { ended.value == [sessionID] }, "the session ended through the owner")
        // The controller's next session is bound but not scoped.
        let next = UUID()
        _ = try await prepare(setup, receiver: receiver, peer: "127.0.0.1", sessionID: next)
        #expect(await setup.handler.socketSetup(next)?.strategy == .bound)
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func theTransportHooksTurnIntoNotices() async throws {
        let notices = Box<[NetworkNotice]>([])
        let setup = makeSetup(notices: notices)
        let receiver = try await SRTPTestReceiver.start()
        let sessionID = UUID()
        _ = try await prepare(setup, receiver: receiver, peer: "127.0.0.1", sessionID: sessionID)
        let values = try #require(await setup.handler.preparedVideoSocket(sessionID)).transport.values
        // The controller answers but receives nothing.
        values.onControllerNotReceiving?("the controller's receiver reports do not mention our video")
        #expect(await eventually { notices.value.last?.kind == .liveViewNotReceived })
        #expect(notices.value.last?.delivery == .failed && notices.value.last?.peerAddress == "127.0.0.1")
        // A later session of that controller receives video: the notice is settled.
        values.onControllerReceiving?()
        #expect(await eventually { notices.value.last?.delivery == .reached }, "\(notices.value.map(\.delivery))")
        let settled = notices.value.count
        values.onControllerReceiving?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(notices.value.count == settled, "settled once")
        // Sending failed for good with the errno that means Local Network access is off (EHOSTUNREACH); not for the others.
        values.onFatalSendError?(EADDRNOTAVAIL, "EADDRNOTAVAIL (Can't assign requested address)", false)
        #expect(notices.value.count == settled)
        values.onFatalSendError?(EHOSTUNREACH, "EHOSTUNREACH (No route to host)", true)
        #expect(notices.value.last?.kind == .localNetworkDenied && notices.value.last?.detail?.contains("EHOSTUNREACH") == true)
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    // MARK: Two interfaces on one subnet

    private static let dualHomed = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                                    InterfaceAddress(interface: "en0", address: "198.51.100.69", prefixLength: 24),
                                    InterfaceAddress(interface: "en1", address: "198.51.100.25", prefixLength: 24)]

    @Test func aMacOnOneSubnetTwiceGetsOneNoticeAndTheSocketsKeepTheAdvertisedAddress() async throws {
        let notices = Box<[NetworkNotice]>([])
        let setup = makeSetup(interfaces: Self.dualHomed, notices: notices)
        let receiver = try await SRTPTestReceiver.start()
        let first = UUID()
        let response = try await prepare(setup, receiver: receiver, controller: "198.51.100.20", local: "198.51.100.25", sessionID: first)
        #expect(response.accessoryAddress == "198.51.100.25", "the address the controller connected to")
        let dual = try #require(notices.value.first { $0.kind == .dualHomedSubnet })
        #expect(dual.interfaceName == "en0, en1" && dual.detail?.contains("198.51.100.0/24") == true)
        #expect(dual.detail?.contains("en1 198.51.100.25") == true && dual.deviceKey == "mac")
        // 198.51.100.25 is no address of this machine: the bind falls back to the wildcard.
        let socket = try #require(await setup.handler.preparedVideoSocket(first))
        #expect(socket.transport.values.recoveryScopes.isEmpty, "the address could not be bound here: wildcard sockets, nothing to scope")
        // Said once per subnet.
        _ = try await prepare(setup, receiver: receiver, controller: "198.51.100.20", local: "198.51.100.69")
        #expect(notices.value.filter { $0.kind == .dualHomedSubnet }.count == 1)
        await setup.handler.networkChanged()
        _ = try await prepare(setup, receiver: receiver, controller: "198.51.100.20", local: "198.51.100.69")
        #expect(notices.value.filter { $0.kind == .dualHomedSubnet }.count == 2, "a network change may have changed it")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    @Test func oneInterfacePerSubnetIsNoNotice() async throws {
        let notices = Box<[NetworkNotice]>([])
        let separate = [InterfaceAddress(interface: "en0", address: "198.51.100.69", prefixLength: 24),
                        InterfaceAddress(interface: "en1", address: "198.51.101.25", prefixLength: 24),
                        InterfaceAddress(interface: "utun4", address: "198.51.100.5", prefixLength: 24)]
        let setup = makeSetup(interfaces: separate, notices: notices)
        let receiver = try await SRTPTestReceiver.start()
        _ = try await prepare(setup, receiver: receiver, controller: "198.51.100.20", local: "198.51.100.69")
        #expect(notices.value.isEmpty)
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }

    // MARK: The VPN notice's false positives

    private static let home = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                               InterfaceAddress(interface: "en0", address: "192.0.2.5", prefixLength: 24)]

    @Test func aControllerOnARoutedSubnetIsNotOnAVPN() async throws {
        // An IoT VLAN behind the router: no interface of the Mac is on it, but a static route through en0 reaches it.
        let notices = Box<[NetworkNotice]>([])
        let routes = [MacVPNDetector.InterfaceRoute(destination: [10, 20, 0, 0], prefixLength: 16, interface: "en0")]
        let routed = makeSetup(interfaces: Self.home, routes: routes, notices: notices)
        let receiver = try await SRTPTestReceiver.start()
        _ = try await prepare(routed, receiver: receiver, controller: "10.20.30.40", peer: "10.20.30.40", local: "192.0.2.5")
        #expect(notices.value.isEmpty, "\(notices.value)")
        await routed.handler.stopAll()
        // The same address with no such route (and a HAP peer on the LAN) is what a VPN client looks like.
        let unrouted = makeSetup(interfaces: Self.home, notices: notices)
        _ = try await prepare(unrouted, receiver: receiver, controller: "10.20.30.40", peer: "192.0.2.9", local: "192.0.2.5")
        #expect(notices.value.map(\.kind) == [.controllerOnVPN])
        await unrouted.handler.stopAll()
        await receiver.stop()
        await routed.feeder.stop()
        await unrouted.feeder.stop()
    }

    @Test func theHomeAppOnThisMacAndAnAddressTheHAPConnectionComesFromAreNotAVPN() async throws {
        let notices = Box<[NetworkNotice]>([])
        let setup = makeSetup(interfaces: Self.home, notices: notices)
        let receiver = try await SRTPTestReceiver.start()
        // The controller advertises this Mac's own LAN address (the Home app on this very Mac).
        _ = try await prepare(setup, receiver: receiver, controller: "192.0.2.5", peer: "192.0.2.5", local: "192.0.2.5")
        // The HAP connection itself comes from the advertised address, whatever the interface subnets say.
        _ = try await prepare(setup, receiver: receiver, controller: "172.20.1.9", peer: "172.20.1.9", local: "192.0.2.5")
        #expect(notices.value.isEmpty, "\(notices.value)")
        await setup.handler.stopAll()
        await receiver.stop()
        await setup.feeder.stop()
    }
}
#endif
