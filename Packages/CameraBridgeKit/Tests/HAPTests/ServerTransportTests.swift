#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

/// Plan W1-1 item 5: routing before pair-verify and the encrypted frame layer.
@Suite(.timeLimit(.minutes(1))) struct ServerTransportTests {
    @Test func startEmitsListeningAndExposesSetupInfo() async throws {
        let hub = TestAccessories.sensorHub(category: .ipCamera)
        let configuration = AccessoryServerConfiguration(port: 0, advertise: false, serviceName: "Transport", loopbackOnly: true)
        let server = AccessoryServer(accessory: hub.accessory, configuration: configuration, store: InMemoryHAPStore(),
                                     transport: AppleNetworkTransport(), advertiser: RecordingAdvertiser())
        let events = server.events
        try await server.start()
        defer { await server.stop() }
        let port = try #require(await server.port)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .listening(port: port))
        let code = try await server.setupCode
        let deviceID = try await server.deviceID
        #expect(!code.isTrivial)
        #expect(try await server.setupURI.hasPrefix("X-HM://"))
        #expect(try await server.setupURI.count == "X-HM://".count + 9 + 4)
        #expect(deviceID.description.count == 17)
        #expect(await server.isPaired == false)
        #expect(await server.sessionCount == 0)
    }

    @Test func setupInfoAvailableBeforeStartAndPersisted() async throws {
        let store = InMemoryHAPStore()
        let server = AccessoryServer(accessory: TestAccessories.sensorHub().accessory,
                                     configuration: AccessoryServerConfiguration(serviceName: "x", loopbackOnly: true), store: store,
                                     transport: AppleNetworkTransport(), advertiser: RecordingAdvertiser())
        let code = try await server.setupCode
        #expect(try store.loadIdentity()?.setupCode == code)
        #expect(await server.port == nil)
    }

    @Test func requestsBeforeVerifyAreRejectedWith470() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        for (method, path) in [("GET", "/accessories"), ("GET", "/characteristics?id=1.2"), ("PUT", "/characteristics"),
                               ("PUT", "/prepare"), ("POST", "/resource"), ("POST", "/pairings"), ("GET", "/nope")] {
            let response = try await client.request(method, path, body: method == "GET" ? Data() : Data("{}".utf8))
            #expect(response.status == 470, "\(method) \(path)")
            #expect(try response.json() == ["status": -70401])
        }
        #expect(await client.isClosed == false)
    }

    @Test func identifyOnlyWhileUnpaired() async throws {
        let hub = TestAccessories.sensorHub()
        let identified = Mutex(0)
        hub.accessory.onIdentify { identified.withLock { $0 += 1 } }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let anonymous = try await HAPTestClient.connect(port: running.port)
        #expect(try await anonymous.request("POST", "/identify").status == 204)
        #expect(identified.withLock { $0 } == 1)

        _ = try await running.pairedClient()
        let late = try await HAPTestClient.connect(port: running.port)
        let refused = try await late.request("POST", "/identify")
        #expect(refused.status == 400)
        #expect(try refused.json() == ["status": -70401])
        #expect(identified.withLock { $0 } == 1)
    }

    @Test func encryptedFramesAreAtMost1024Bytes() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let response = try await client.request("GET", "/accessories")
        #expect(response.status == 200)
        #expect(response.body.count > 2048)
        let frames = await client.receivedFrameLengths
        #expect(frames.count >= 3)
        #expect(frames.allSatisfy { $0 > 0 && $0 <= 1024 })
        #expect(frames.dropLast().allSatisfy { $0 == 1024 } || frames.count > 3)

        // Several requests in a row keep both counters in step.
        for _ in 0..<5 { #expect(try await client.request("GET", "/accessories").status == 200) }
        let unknown = try await client.request("GET", "/unknown")
        #expect(unknown.status == 404)
        #expect(try unknown.json() == ["status": -70409])
    }

    @Test func tamperedFrameClosesTheConnection() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(await running.server.sessionCount == 1)
        // A frame claiming 16 bytes of plaintext with a garbage tag.
        try await client.sendUnencrypted(Data([16, 0]) + Data(repeating: 0xAB, count: 32))
        #expect(await client.waitUntilClosed())
        #expect(await eventually { await running.server.sessionCount == 0 })
    }

    @Test func malformedHTTPClosesTheConnection() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        try await client.sendUnencrypted(Data("GARBAGE\r\n\r\n".utf8))
        #expect(await client.waitUntilClosed())
    }

    @Test func stopClosesConnectionsAndListener() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        let client = try await running.pairedClient()
        let closed = Mutex(false)
        await running.server.stop()
        #expect(await client.waitUntilClosed())
        #expect(await running.server.port == nil)
        do {
            _ = try await HAPTestClient.connect(port: running.port)
            closed.withLock { $0 = false }
        } catch {
            closed.withLock { $0 = true }
        }
        #expect(closed.withLock { $0 })
    }

    @Test func restartAfterStopKeepsIdentityAndPairings() async throws {
        let store = InMemoryHAPStore()
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory, store: store)
        let client = try await running.pairedClient()
        await running.stop()
        #expect(await client.waitUntilClosed())

        try await running.server.start()
        defer { await running.stop() }
        let port = try #require(await running.server.port)
        #expect(await running.server.isPaired)
        let again = try await client.reconnect(port: port)
        try await again.pairVerify()
        #expect(try await again.request("GET", "/accessories").status == 200)
    }
}
#endif
