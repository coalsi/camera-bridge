#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import Testing
@testable import HAP

@Suite(.timeLimit(.minutes(1))) struct HardeningTests {
    @Test func repeatedPairVerifyEndsThePreviousSession() async throws {
        let hub = TestAccessories.sensorHub()
        let closed = Mutex<[UUID]>([])
        let sessions = Mutex<[UUID]>([])
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            let id = context.session.id
            sessions.withLock { $0.append(id) }
            context.session.onClose { closed.withLock { $0.append(id) } }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
        try await client.pairVerify()   // again, over the encrypted connection
        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 0)]).status == 204)
        let seen = sessions.withLock { $0 }
        #expect(seen.count == 2 && seen[0] != seen[1])
        #expect(closed.withLock { $0 } == [seen[0]])
        #expect(await running.server.sessionCount == 1)
    }

    @Test func slowHandlersAreReported() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let hub = TestAccessories.sensorHub()
        hub.lightOn.onRead { _ async throws(HAPStatus) -> HAPValue in
            try? await Task.sleep(for: .milliseconds(200))   // past the 100 ms warning, before the 300 ms timeout
            return .bool(true)
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        let read = try await client.getJSON("/characteristics?id=1.\(hub.lightOn.iid)")
        #expect(read.status == 200)
        #expect(read.json?["characteristics"]?[0]?["value"] == 1)
        #expect(sink.messages.contains { $0.contains("Read of On handler is slow") })
    }

    @Test func pairingNeverLogsSecrets() async throws {
        let sink = CapturingSink()
        let token = LogHub.addSink(sink)
        defer { LogHub.removeSink(token) }
        let previous = LogHub.minimumLevel
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.self) { try await client.pairSetup(code: "111-22-333") }
        let paired = try await running.pairedClientViaSetup()
        _ = try await paired.pairings(method: 4, identifier: paired.controllerID)
        #expect(LogHub.minimumLevel == previous)
        let identity = try #require(try running.store.loadIdentity())
        let secrets = [identity.setupCode.formatted, identity.setupCode.digits, identity.longTermKey.base64EncodedString(),
                       identity.longTermKey.hexString]
        for message in sink.messages {
            for secret in secrets { #expect(!message.contains(secret)) }
        }
        #expect(sink.messages.contains { $0.contains("wrong setup code") })
    }

    @Test func frameCodecRoundTripAndLimits() throws {
        let key = Data(repeating: 0x42, count: 32)
        var encryptor = HAPFrameEncryptor(key: key)
        var decryptor = HAPFrameDecryptor(key: key)
        let message = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try encryptor.seal(message)
        #expect(sealed.count == message.count + 3 * (2 + 16))
        #expect(Int(sealed[0]) | Int(sealed[1]) << 8 == 1024)
        // Delivered in awkward pieces.
        var opened = Data()
        var offset = 0
        for size in [1, 5, 700, 1500, 10_000] where offset < sealed.count {
            let end = min(offset + size, sealed.count)
            opened.append(try decryptor.open(Data(sealed[offset..<end])))
            offset = end
        }
        #expect(opened == message)
        #expect(encryptor.counter == 3 && decryptor.counter == 3)
        #expect(try encryptor.seal(Data()).count == 2 + 16)

        var strict = HAPFrameDecryptor(key: key)
        #expect(throws: HAPFrameError.oversizedFrame(1025)) { try strict.open(Data([0x01, 0x04]) + Data(count: 1041)) }
        var tampered = HAPFrameDecryptor(key: key)
        var other = HAPFrameEncryptor(key: key)
        var bad = try other.seal(Data("hi".utf8))
        bad[bad.count - 1] ^= 0xFF
        #expect(throws: HAPFrameError.authenticationFailed) { try tampered.open(bad) }
    }
}
#endif
