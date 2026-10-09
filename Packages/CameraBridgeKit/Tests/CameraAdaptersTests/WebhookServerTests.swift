// Real loopback listener (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct WebhookServerTests {
    private let token = "0123456789abcdef0123456789abcdef"
    private let camera = UUID(uuidString: "7D444840-9DC0-11D1-B245-5FFDCE74FAD2")!

    /// Sends raw HTTP requests over one connection and returns the responses.
    private func send(port: UInt16, _ requests: [HTTPRequestHead]) async throws -> [HTTPResponseHead] {
        let connection = try await AppleNetworkTransport().connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        defer { connection.close() }
        var parser = HTTPResponseParser()
        var responses: [HTTPResponseHead] = []
        for (index, head) in requests.enumerated() {
            try await connection.send(HTTPSerializer.request(head, body: Data()))
            while responses.count <= index {
                guard let data = try await connection.receive(maximumLength: 65_536) else { return responses }
                responses += try parser.feed(data).map(\.head)
            }
        }
        return responses
    }

    private func post(_ path: String, token: String?) -> HTTPRequestHead {
        var headers = HTTPHeaders([("Host", "127.0.0.1")])
        if let token { headers.add("Authorization", "Bearer \(token)") }
        return HTTPRequestHead(method: "POST", target: path, headers: headers)
    }

    private func startServer() async throws -> (WebhookServer, UInt16) {
        let server = WebhookServer(port: 0, token: token, loopbackOnly: true, transport: AppleNetworkTransport())
        try await server.start()
        let port = try #require(await server.boundPort)
        return (server, port)
    }

    @Test func authorizedEventsArePublished() async throws {
        let (server, port) = try await startServer()
        let recorder = Recorder(server.events)
        let id = camera.uuidString
        let paths = ["motion", "motion/stop", "doorbell", "person", "person/stop", "vehicle", "animal/stop", "package", "face", "tamper",
                     "tamper/stop"]
        let responses = try await send(port: port, paths.map { post("/cameras/\(id)/\($0)", token: token) })
        #expect(responses.map(\.status) == Array(repeating: 204, count: paths.count))
        #expect(await recorder.wait { $0.count == paths.count })
        #expect(recorder.values.map(\.cameraID) == Array(repeating: camera, count: paths.count))
        #expect(recorder.values.map(\.event) == [.motion(true), .motion(false), .doorbellPressed, .object(.person, true), .object(.person, false),
                                                 .object(.vehicle, true), .object(.animal, false), .object(.package, true), .object(.face, true),
                                                 .tamper(true), .tamper(false)])
        await server.stop()
    }

    @Test func badTokenIs401AndUnknownPathIs404() async throws {
        let (server, port) = try await startServer()
        let recorder = Recorder(server.events)
        let id = camera.uuidString
        let responses = try await send(port: port, [
            post("/cameras/\(id)/motion", token: "wrong"),
            post("/cameras/\(id)/motion", token: nil),
            post("/cameras/\(id)/explode", token: token),
            post("/cameras/not-a-uuid/motion", token: token),
            post("/elsewhere", token: token),
            HTTPRequestHead(method: "GET", target: "/cameras/\(id)/motion", headers: HTTPHeaders([("Authorization", "Bearer \(token)")])),
        ])
        #expect(responses.map(\.status) == [401, 401, 404, 404, 404, 405])
        #expect(responses[0].headers["WWW-Authenticate"]?.hasPrefix("Bearer") == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.isEmpty)
        await server.stop()
    }

    /// Review finding (W4 round 3): any well-formed camera ID was answered 204 and the event then dropped by the engine,
    /// so a Frigate / Home Assistant automation with a stale or mistyped ID never learned that nothing happened. With a
    /// camera lookup, an ID that names no configured camera is 404 and a disabled camera 409; neither is published.
    @Test func unknownCamerasAre404AndDisabledOnes409() async throws {
        let disabled = UUID()
        let enabled = camera
        let asked = Box<[UUID]>([])
        let server = WebhookServer(port: 0, token: token, loopbackOnly: true, transport: AppleNetworkTransport()) { id in
            asked.update { $0.append(id) }
            return id == enabled ? .enabled : id == disabled ? .disabled : .unknown
        }
        try await server.start()
        let port = try #require(await server.boundPort)
        let recorder = Recorder(server.events)
        let stranger = UUID()
        let responses = try await send(port: port, [
            post("/cameras/\(stranger.uuidString)/doorbell", token: token),
            post("/cameras/\(disabled.uuidString)/motion", token: token),
            post("/cameras/\(camera.uuidString)/motion", token: token),
            post("/cameras/\(stranger.uuidString)/motion", token: "wrong"),
            post("/cameras/\(stranger.uuidString)/explode", token: token),
        ])
        #expect(responses.map(\.status) == [404, 409, 204, 401, 404])
        #expect(await recorder.wait { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.map(\.cameraID) == [camera])
        #expect(asked.value == [stranger, disabled, camera], "only authorized, well-formed events are looked up")
        await server.stop()
    }

    @Test func stopClosesTheListenerAndRestartWorks() async throws {
        let (server, port) = try await startServer()
        await server.stop()
        await #expect(throws: (any Error).self) { _ = try await send(port: port, [post("/cameras/\(camera.uuidString)/motion", token: token)]) }
        try await server.start()
        let newPort = try #require(await server.boundPort)
        let recorder = Recorder(server.events)
        let responses = try await send(port: newPort, [post("/cameras/\(camera.uuidString)/doorbell", token: token)])
        #expect(responses.map(\.status) == [204])
        #expect(await recorder.wait { $0.map(\.event) == [.doorbellPressed] })
        await server.stop()
    }

    @Test func concurrentStartsBindOnce() async throws {
        let transport = SlowListenTransport(delay: .milliseconds(150))
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        async let first: Void = server.start()
        async let second: Void = server.start()
        _ = try await (first, second)
        #expect(transport.listens.value == 1, "a second listener would leak (port 0) or fail with addressInUse (fixed port)")
        #expect(await server.boundPort == 4242)
        try await server.start()
        #expect(transport.listens.value == 1)
        await server.stop()
        #expect(transport.listeners.value.allSatisfy { $0.closed.value })
    }

    @Test func stopDuringStartLeavesNothingListening() async throws {
        let transport = SlowListenTransport(delay: .milliseconds(200))
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        let starting = Task { try await server.start() }
        try await Task.sleep(for: .milliseconds(50))
        await server.stop()
        try await starting.value
        #expect(await server.boundPort == nil)
        #expect(transport.listeners.value.count == 1 && transport.listeners.value.allSatisfy { $0.closed.value })
    }

    @Test func releasedServerClosesItsListener() async throws {
        let transport = SlowListenTransport(delay: .zero)
        var server: WebhookServer? = WebhookServer(port: 4242, token: token, transport: transport)
        try await server?.start()
        let listener = try #require(transport.listeners.value.first)
        #expect(!listener.closed.value)
        server = nil
        #expect(await eventually { listener.closed.value })
    }

    @Test func slowTricklingRequestsAreCutOff() async throws {
        let server = WebhookServer(port: 0, token: token, loopbackOnly: true, transport: AppleNetworkTransport(), idleTimeout: .seconds(30),
                                   requestTimeout: .milliseconds(300))
        try await server.start()
        let port = try #require(await server.boundPort)
        let connection = try await AppleNetworkTransport().connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        defer { connection.close() }
        let trickle = Task {
            for byte in Data("POST /cameras/\(camera.uuidString)/motion HTTP/1.1\r\nHost: x\r\n".utf8) {
                do { try await connection.send(Data([byte])) } catch { return }
                try? await Task.sleep(for: .milliseconds(100))   // under the idle timeout every time
            }
        }
        let started = ContinuousClock.now
        let closed: Bool
        do { closed = try await connection.receive(maximumLength: 4096) == nil } catch { closed = true }
        trickle.cancel()
        #expect(closed)
        #expect(ContinuousClock.now - started < .seconds(3), "the whole request must arrive within the request timeout")
        await server.stop()
    }

    @Test func malformedRequestsGet400AndClose() async throws {
        let (server, port) = try await startServer()
        let connection = try await AppleNetworkTransport().connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        defer { connection.close() }
        try await connection.send(Data("NOT HTTP\r\n\r\n".utf8))
        var parser = HTTPResponseParser()
        var responses: [HTTPResponseHead] = []
        while responses.isEmpty, let data = try await connection.receive(maximumLength: 4096) {
            responses += try parser.feed(data).map(\.head)
        }
        #expect(responses.first?.status == 400)
        await server.stop()
    }

    // MARK: - Listener failure (W4 review)

    /// The platform stops a listener on its own (AppleTCPListener on `.waiting` / `.failed` after `.ready`: interface
    /// change, sleep/wake, Local Network access revoked): the webhook must listen again on its port, with the same
    /// `events` stream, instead of silently losing every later event until the bridge restarts.
    @Test func listenerFailureListensAgainOnTheSamePort() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let recorder = Recorder(server.events)
        let first = try #require(transport.listeners.value.first)
        first.fail()
        #expect(await eventually { transport.listeners.value.count == 2 }, "the webhook must listen again after its listener failed")
        let second = try #require(transport.listeners.value.last)
        #expect(second !== first && second.port == 4242 && !second.closed.value)
        #expect(await server.boundPort == 4242)
        let client = FakeConnection(incoming: [request(post("/cameras/\(camera.uuidString)/doorbell", token: token))])
        second.deliver(client)
        #expect(await recorder.wait { $0.map(\.event) == [.doorbellPressed] }, "events still reach the existing subscribers")
        #expect(await eventually { client.response.hasPrefix("HTTP/1.1 204") })
        await server.stop()
        #expect(transport.listeners.value.allSatisfy { $0.closed.value })
    }

    /// While the port cannot be bound again (network still down, port taken), the server keeps retrying with backoff
    /// and reports no port; it listens again as soon as an attempt succeeds.
    @Test func relistenRetriesWithBackoffUntilItSucceeds() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport, timing: fastTiming)
        try await server.start()
        let first = try #require(transport.listeners.value.first)
        transport.refusals.set((1000, .addressInUse))
        first.fail()
        #expect(await eventually { transport.listens.value >= 4 }, "refused attempts are retried")
        #expect(await server.boundPort == nil, "no port while not listening")
        transport.refusals.set((0, .addressInUse))
        #expect(await eventually { transport.listeners.value.count == 2 })
        #expect(await server.boundPort == 4242)
        let attempts = transport.listens.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.listens.value == attempts, "no attempts once listening again")
        await server.stop()
    }

    /// Review finding (W4 round 3): the owner never learned that the listener stopped and could not listen again (only
    /// the log said so). `listenerStates` reports it, the recovery and the stop.
    @Test func listenerStatesReportFailedAttemptsToListenAgain() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport, timing: fastTiming)
        let states = server.listenerStates
        let seen = Box<[WebhookServer.ListenerState]>([])
        let reader = Task { for await state in states { seen.update { $0.append(state) } } }
        try await server.start()
        transport.refusals.set((2, .addressInUse))
        try #require(transport.listeners.value.first).fail()
        #expect(await eventually { seen.value.filter { $0 == .listening(port: 4242) }.count == 2 })
        await server.stop()
        #expect(await eventually { seen.value.last == .stopped })
        #expect(seen.value == [.listening(port: 4242), .relistenFailed(.addressInUse), .relistenFailed(.addressInUse), .listening(port: 4242), .stopped],
                "\(seen.value)")
        reader.cancel()
    }

    /// `stop()` ends the retries; a later `start()` binds at once.
    @Test func stopEndsRelistening() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport, timing: fastTiming)
        try await server.start()
        transport.refusals.set((1000, .failed("network down")))
        try #require(transport.listeners.value.first).fail()
        #expect(await eventually { transport.listens.value >= 3 })
        await server.stop()
        let attempts = transport.listens.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.listens.value == attempts, "no attempt after stop()")
        transport.refusals.set((0, .addressInUse))
        try await server.start()
        #expect(await server.boundPort == 4242)
        #expect(transport.listeners.value.count == 2)
        await server.stop()
    }

    /// A server released while it retries is not kept alive by the retry loop.
    @Test func releasedServerStopsRelistening() async throws {
        let transport = SlowListenTransport(delay: .zero)
        var server: WebhookServer? = WebhookServer(port: 4242, token: token, transport: transport, timing: fastTiming)
        try await server?.start()
        transport.refusals.set((1000, .failed("network down")))
        try #require(transport.listeners.value.first).fail()
        #expect(await eventually { transport.listens.value >= 3 })
        weak let released = server
        server = nil
        #expect(await eventually { released == nil })
        let attempts = transport.listens.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.listens.value <= attempts + 1)
    }

    private var fastTiming: WebhookServer.Timing {
        var timing = WebhookServer.Timing()
        timing.relistenDelay = .milliseconds(10)
        timing.relistenMaximumDelay = .milliseconds(20)
        return timing
    }

    // MARK: - Connection slots (W4 review)

    /// A socket that never sends a byte gives its slot back after `firstByteTimeout`, not the 30 s idle timeout.
    @Test func silentConnectionsCloseAfterTheFirstByteTimeout() async throws {
        let transport = SlowListenTransport(delay: .zero)
        var timing = WebhookServer.Timing()
        timing.firstByteTimeout = .milliseconds(200)
        let server = WebhookServer(port: 4242, token: token, transport: transport, timing: timing)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let silent = FakeConnection()
        let started = ContinuousClock.now
        listener.deliver(silent)
        #expect(await eventually { silent.isClosed })
        #expect(ContinuousClock.now - started < .seconds(3))
        var drained = false
        for _ in 0..<300 where !drained {
            drained = await server.connectionCount == 0
            if !drained { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(drained, "its slot is free again")
        // A client that sent a request is idle-timed out only after `idleTimeout`.
        let client = FakeConnection(incoming: [request(post("/cameras/\(camera.uuidString)/motion", token: token))])
        listener.deliver(client)
        #expect(await eventually { client.response.hasPrefix("HTTP/1.1 204") })
        try await Task.sleep(for: .milliseconds(400))
        #expect(!client.isClosed)
        await server.stop()
    }

    /// 32 sockets that never send a byte (any LAN peer, no token needed) must not lock out Frigate / Home Assistant:
    /// the newcomer is admitted by closing the oldest connection that has not sent an authorized request.
    @Test func idleSocketsCannotLockOutAuthorizedClients() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let recorder = Recorder(server.events)
        let idle = (0..<WebhookServer.maximumConnections).map { _ in FakeConnection() }
        for connection in idle { listener.deliver(connection) }
        let client = FakeConnection(incoming: [request(post("/cameras/\(camera.uuidString)/doorbell", token: token))])
        listener.deliver(client)
        #expect(await recorder.wait { $0.map(\.event) == [.doorbellPressed] }, "an authorized doorbell must get through")
        #expect(await eventually { client.response.hasPrefix("HTTP/1.1 204") })
        #expect(idle[0].isClosed, "the oldest idle socket makes room")
        #expect(idle.dropFirst().allSatisfy { !$0.isClosed })
        await server.stop()
    }

    /// The same over real loopback sockets (the review's probe): 32 idle TCP connections, then an authorized doorbell.
    @Test func idleLoopbackSocketsCannotLockOutAuthorizedClients() async throws {
        let (server, port) = try await startServer()
        let recorder = Recorder(server.events)
        var idle: [any TCPConnection] = []
        defer { for connection in idle { connection.close() } }
        for _ in 0..<WebhookServer.maximumConnections {
            idle.append(try await AppleNetworkTransport().connect(host: "127.0.0.1", port: port, timeout: .seconds(5)))
        }
        var full = false
        for _ in 0..<500 where !full {
            full = await server.connectionCount == WebhookServer.maximumConnections
            if !full { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(full, "every slot is held by an idle socket")
        let responses = try await send(port: port, [post("/cameras/\(camera.uuidString)/doorbell", token: token)])
        #expect(responses.map(\.status) == [204])
        #expect(await recorder.wait { $0.map(\.event) == [.doorbellPressed] })
        await server.stop()
    }

    /// Only connections that sent a request with the right token keep their slot: a connection whose request was
    /// refused (401) is evicted before newer idle ones, and an authorized one is never evicted for a newcomer.
    @Test func onlyAuthorizedConnectionsKeepTheirSlot() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let path = "/cameras/\(camera.uuidString)/motion"
        let unauthorized = FakeConnection(incoming: [request(post(path, token: "wrong"))])
        listener.deliver(unauthorized)
        #expect(await eventually { unauthorized.response.hasPrefix("HTTP/1.1 401") })
        let authorized = FakeConnection(incoming: [request(post(path, token: token))])
        listener.deliver(authorized)
        #expect(await eventually { authorized.response.hasPrefix("HTTP/1.1 204") })
        let idle = (0..<(WebhookServer.maximumConnections - 2)).map { _ in FakeConnection() }
        for connection in idle { listener.deliver(connection) }

        let newcomer = FakeConnection()
        listener.deliver(newcomer)
        #expect(await eventually { unauthorized.isClosed }, "a refused token earns no slot")
        #expect(!authorized.isClosed && !newcomer.isClosed && idle.allSatisfy { !$0.isClosed })
        let another = FakeConnection()
        listener.deliver(another)
        #expect(await eventually { idle[0].isClosed })
        #expect(!authorized.isClosed && !another.isClosed)
        await server.stop()
    }

    /// When every slot holds an authorized client, a newcomer is refused (nothing authorized is evicted).
    @Test func newcomerIsRefusedWhenEverySlotIsAuthorized() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let clients = (0..<WebhookServer.maximumConnections).map { _ in
            FakeConnection(incoming: [request(post("/cameras/\(camera.uuidString)/motion", token: token))])
        }
        for client in clients { listener.deliver(client) }
        #expect(await eventually { clients.allSatisfy { $0.response.hasPrefix("HTTP/1.1 204") } })
        let newcomer = FakeConnection()
        listener.deliver(newcomer)
        #expect(await eventually { newcomer.isClosed })
        #expect(clients.allSatisfy { !$0.isClosed })
        await server.stop()
    }

    private func request(_ head: HTTPRequestHead) -> Data {
        HTTPSerializer.request(head, body: Data())
    }

    // MARK: - Unauthenticated parse cost (W4 review round 4)

    /// Review finding (W4 round 4): the token was checked only once a whole request had arrived, and the head was parsed
    /// again on every read until then: any LAN peer could trickle a large head and body without the token and keep
    /// many cores busy. A request whose head shows a wrong token is answered 401 and closed before its body is read.
    @Test func aWrongTokenIsRefusedBeforeTheBody() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        for presented in ["wrong", nil] {
            var head = post("/cameras/\(camera.uuidString)/motion", token: presented)
            head.headers.add("Content-Length", "60000")
            let client = FakeConnection(incoming: [request(head)])   // the body never comes
            listener.deliver(client)
            #expect(await eventually(timeout: .seconds(3)) { client.isClosed }, "closed at once, not after the request timeout")
            #expect(client.response.hasPrefix("HTTP/1.1 401"), "\(client.response)")
            #expect(client.response.contains("WWW-Authenticate: Bearer"))
        }
        await server.stop()
    }

    /// The body of a request with the right token is still read.
    @Test func anAuthorizedRequestsBodyIsRead() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let recorder = Recorder(server.events)
        var head = post("/cameras/\(camera.uuidString)/doorbell", token: token)
        head.headers.add("Content-Length", "15")
        let client = FakeConnection(incoming: [request(head), Data(#"{"source":"ha"}"#.utf8)])
        listener.deliver(client)
        #expect(await eventually { client.response.hasPrefix("HTTP/1.1 204") })
        #expect(await recorder.wait { $0.map(\.event) == [.doorbellPressed] })
        await server.stop()
    }

    /// Heads are at most 8 KiB with at most 64 header lines (the request line not counted), so an unauthenticated peer
    /// cannot make the server parse large heads; an automation's request is far below both.
    @Test func largeHeadsAreRefused() async throws {
        let transport = SlowListenTransport(delay: .zero)
        let server = WebhookServer(port: 4242, token: token, transport: transport)
        try await server.start()
        let listener = try #require(transport.listeners.value.first)
        let recorder = Recorder(server.events)
        let path = "/cameras/\(camera.uuidString)/motion"
        var long = post(path, token: token)
        long.headers.add("X-Padding", String(repeating: "a", count: 9 * 1024))
        var many = post(path, token: token)   // Host and Authorization, plus 63 more lines
        for index in 0..<63 { many.headers.add("X-\(index)", "1") }
        for head in [long, many] {
            let client = FakeConnection(incoming: [request(head)])
            listener.deliver(client)
            #expect(await eventually { client.isClosed }, "\(head.headers.values(for: "X-0"))")
            #expect(client.response.hasPrefix("HTTP/1.1 400"), "\(client.response)")
        }
        var fits = post(path, token: token)   // 64 lines
        for index in 0..<61 { fits.headers.add("X-\(index)", "1") }
        fits.headers.add("X-Padding", String(repeating: "a", count: 6 * 1024))
        let client = FakeConnection(incoming: [request(fits)])
        listener.deliver(client)
        #expect(await eventually { client.response.hasPrefix("HTTP/1.1 204") }, "\(client.response)")
        #expect(await recorder.wait { $0.map(\.event) == [.motion(true)] })
        await server.stop()
    }
}

/// An accepted connection for `SlowListenTransport.Listener.deliver`: `receive` hands out `incoming`, then waits
/// until the connection is closed; `send` records the response bytes.
final class FakeConnection: TCPConnection {
    private struct State {
        var incoming: [Data]
        var sent = Data()
        var closed = false
        var waiter: CheckedContinuation<Data?, any Error>?
    }

    let id = UUID()
    let localAddress = "192.0.2.1"
    let remoteAddress = "192.0.2.77"
    let isIPv6 = false
    private let state: Mutex<State>

    init(incoming: [Data] = []) {
        state = Mutex(State(incoming: incoming))
    }

    var isClosed: Bool { state.withLock { $0.closed } }
    var response: String { String(decoding: state.withLock { $0.sent }, as: UTF8.self) }

    func receive(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data?, any Error>? = state.withLock { state in
                if state.closed { return .failure(TransportError.closed) }
                if !state.incoming.isEmpty { return .success(state.incoming.removeFirst()) }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func send(_ data: Data) async throws {
        try state.withLock { state in
            if state.closed { throw TransportError.closed }
            state.sent.append(data)
        }
    }

    func close() {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: TransportError.closed)
    }
}

/// A transport whose `listen` takes `delay` and hands out recording fake listeners.
final class SlowListenTransport: NetworkTransport {
    final class Listener: TCPListener {
        let port: UInt16
        let connections: AsyncStream<any TCPConnection>
        private let continuation: AsyncStream<any TCPConnection>.Continuation
        let closed = Box(false)

        init(port: UInt16) {
            self.port = port
            (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self)
        }

        func close() {
            closed.set(true)
            continuation.finish()
        }

        /// Hands `connection` to the server as an accepted one.
        func deliver(_ connection: any TCPConnection) {
            continuation.yield(connection)
        }

        /// Ends `connections` without `close()`, as `AppleTCPListener` does when its listener fails after `.ready`.
        func fail() {
            continuation.finish()
        }
    }

    let delay: Duration
    let listens = Box(0)
    let listeners = Box<[Listener]>([])
    /// `listen` calls still to refuse with this error.
    let refusals = Box<(count: Int, error: TransportError)>((0, .addressInUse))

    init(delay: Duration) { self.delay = delay }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        listens.update { $0 += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        let refusal: TransportError? = refusals.update { refusals in
            guard refusals.count > 0 else { return nil }
            refusals.count -= 1
            return refusals.error
        }
        if let refusal { throw refusal }
        let listener = Listener(port: port)
        listeners.update { $0.append(listener) }
        return listener
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection { throw TransportError.connectionRefused }
}
#endif
