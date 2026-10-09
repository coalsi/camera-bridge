#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP

/// HTTP status, kTLVState and kTLVError of a pairing response.
private struct PairingReply: Equatable {
    var status: Int
    var state: UInt8?
    var error: UInt8?

    init(_ status: Int, _ state: UInt8?, _ error: UInt8?) {
        self.status = status
        self.state = state
        self.error = error
    }
}

/// Plan W1-1 items 6 (pair-setup), 7 (pair-verify) and 8 (/pairings).
@Suite(.timeLimit(.minutes(1))) struct PairingTests {
    @Test func pairSetupStoresAdminPairingAndFlipsStatusFlag() async throws {
        let hub = TestAccessories.sensorHub()
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let events = running.server.events
        #expect(running.advertiser.currentTXT?["sf"] == "1")

        let client = try await HAPTestClient.connect(port: running.port)
        // hap-controller sends Method 1 on M1; the server ignores the value.
        let pairing = try await client.pairSetup(code: running.setupCode, method: 1)
        #expect(pairing.accessoryPairingID == (try await running.server.deviceID.description))
        #expect(await running.server.isPaired)

        let state = try #require(try running.store.loadState())
        #expect(state.pairings.count == 1)
        #expect(state.pairings.first?.identifier == client.controllerID)
        #expect(state.pairings.first?.isAdmin == true)
        #expect(state.pairings.first?.publicKey == client.longTermKey.publicKey)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })

        var iterator = events.makeAsyncIterator()
        var sawPaired = false
        while let event = await iterator.next() {
            if event == .paired(controllerID: client.controllerID) { sawPaired = true; break }
        }
        #expect(sawPaired)
    }

    @Test func pairSetupWhenAlreadyPairedIsUnavailable() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        _ = try await running.pairedClient()
        let intruder = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.pairing(step: 2, error: 6)) {
            try await intruder.pairSetup(code: running.setupCode)
        }
    }

    @Test func wrongSetupCodeFailsAtM4WithAuthenticationError() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) {
            try await client.pairSetup(code: "111-22-333")
        }
        #expect(await running.server.isPaired == false)
        #expect(await running.server.failedPairSetupAttempts == 1)
        // The right code still works afterwards on a new connection.
        let retry = try await HAPTestClient.connect(port: running.port)
        try await retry.pairSetup(code: running.setupCode)
        #expect(await running.server.isPaired)
    }

    @Test func tooManyFailuresGiveMaxTries() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        await running.server.setFailedPairSetupAttempts(101)
        let client = try await HAPTestClient.connect(port: running.port)
        await #expect(throws: HAPTestClientError.pairing(step: 2, error: 5)) {
            try await client.pairSetup(code: running.setupCode)
        }
    }

    @Test func outOfOrderPairSetupStepIsRejected() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        var m3 = TLVBuilder()
        m3.add(0x06, uint8: 3)
        m3.add(0x03, Data(repeating: 1, count: 384))
        m3.add(0x04, Data(repeating: 2, count: 64))
        let response = try await client.request("POST", "/pair-setup", body: m3.data, contentType: "application/pairing+tlv8")
        let tlv = try response.tlv()
        #expect(tlv.uint8(0x06) == 4)
        #expect(tlv.uint8(0x07) == 1)
        let garbage = try await client.request("POST", "/pair-setup", body: Data([0x06]), contentType: "application/pairing+tlv8")
        #expect(garbage.status == 400)
    }

    /// M5 variants a controller that completed the SRP exchange (M1–M4) might send instead of an honest one.
    enum BadM5: CaseIterable, Sendable {
        /// The LTPK is the controller's, the signature another key's: the sender does not hold the LTPK's private key.
        case signedByAnotherKey
        /// Correct content, sealed under a key not derived from this SRP session.
        case sealedUnderAnotherKey
        case withoutEncryptedData
        /// Decrypts, but the plaintext is not a TLV.
        case malformedInnerTLV
        case withoutSignature

        /// Expected kTLVError at state 6: Authentication when the sender proved nothing, Unknown for a malformed M5.
        var expectedError: UInt8 {
            switch self {
            case .signedByAnotherKey, .sealedUnderAnotherKey, .withoutEncryptedData: 2
            case .malformedInnerTLV, .withoutSignature: 1
            }
        }

        func message(sessionKey: Data, controllerID: String, longTermKey: HAPLongTermKey) throws -> TLVBuilder {
            let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            let controllerX = HAPCrypto.hkdfSHA512(inputKey: sessionKey, salt: "Pair-Setup-Controller-Sign-Salt",
                                                   info: "Pair-Setup-Controller-Sign-Info")
            let idData = Data(controllerID.utf8)
            let signer = self == .signedByAnotherKey ? HAPLongTermKey() : longTermKey
            var inner = TLVBuilder()
            inner.add(0x01, idData)
            inner.add(0x03, longTermKey.publicKey)
            if self != .withoutSignature { inner.add(0x0A, try signer.signature(for: controllerX + idData + longTermKey.publicKey)) }
            let plaintext = self == .malformedInnerTLV ? Data([0x01, 0x05, 0x41]) : inner.data
            let sealingKey = self == .sealedUnderAnotherKey
                ? HAPCrypto.hkdfSHA512(inputKey: Data(repeating: 7, count: 64), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
                : encryptionKey
            var m5 = TLVBuilder()
            m5.add(0x06, uint8: 5)
            if self != .withoutEncryptedData {
                m5.add(0x05, try HAPCrypto.chachaSeal(plaintext, key: sealingKey, nonce: HAPCrypto.nonce(label: "PS-Msg05")))
            }
            return m5
        }
    }

    /// Review finding (W4 round 3): no test sent a pair-setup M5 the accessory must refuse, so its checks (above all the
    /// controller's signature over its LTPK) could be lost without a failing test, and the accessory would then store a
    /// controller key whose owner never proved it holds the private key. Each M5 follows an honest M1–M4 with the right
    /// setup code: refused at state 6, nothing stored, `sf` stays 1, and an honest pair-setup works afterwards.
    @Test(arguments: BadM5.allCases) func pairSetupRefusesBadM5(_ variant: BadM5) async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await HAPTestClient.connect(port: running.port)
        let sessionKey = try await client.pairSetupThroughM4(code: running.setupCode)
        let m5 = try variant.message(sessionKey: sessionKey, controllerID: client.controllerID, longTermKey: client.longTermKey)
        let m6 = try await client.pairingRequest("/pair-setup", m5)
        #expect(m6.uint8(0x06) == 6)
        #expect(m6.uint8(0x07) == variant.expectedError)
        #expect(m6.data(0x05) == nil, "no accessory credentials")
        #expect(await running.server.isPaired == false)
        #expect(try running.store.loadState()?.pairings.isEmpty ?? true)
        #expect(await running.server.pairSetupOwner == nil, "the pair-setup slot is released")
        #expect(await running.server.failedPairSetupAttempts == 0, "the setup code was right")
        try await Task.sleep(for: .milliseconds(100))   // TXT updates are debounced 20 ms in these tests
        #expect(running.advertiser.currentTXT?["sf"] == "1")

        // An honest pair-setup on the same connection pairs.
        try await client.pairSetup(code: running.setupCode)
        #expect(await running.server.isPaired)
        #expect(try running.store.loadState()?.pairings.map(\.publicKey) == [client.longTermKey.publicKey])
    }

    @Test func pairVerifyDerivesSessionKeysAndExposesSharedSecret() async throws {
        let hub = TestAccessories.sensorHub()
        let captured = Mutex<(secret: Data, controller: String, admin: Bool, local: String)?>(nil)
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            captured.withLock { $0 = (context.session.sharedSecret, context.session.controllerID, context.session.isAdmin,
                                      context.session.localAddress) }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(await running.server.sessionCount == 1)
        let result = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)])
        #expect(result.status == 204)
        let seen = try #require(captured.withLock { $0 })
        #expect(seen.secret == (await client.sharedSecret))
        #expect(seen.secret.count == 32)
        #expect(seen.controller == client.controllerID)
        #expect(seen.admin)
        #expect(seen.local == "127.0.0.1")
    }

    /// Review finding (W4 round 4): the session dropped the connection's IPv6 zone, so a link-local address the controller
    /// names (SetupEndpoints carries no scope) could not be reached: live view never started for such a controller.
    @Test func theSessionKeepsTheConnectionsZone() async throws {
        let hub = TestAccessories.sensorHub()
        let seen = Mutex<String??>(nil)
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            seen.withLock { $0 = .some(context.session.zone) }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory, transport: ZonedTransport(base: AppleNetworkTransport(), zone: "lo0"))
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)]).status == 204)
        #expect(seen.withLock { $0 } == .some("lo0"))
    }

    @Test func pairVerifyRejectsUnknownController() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let paired = try await running.pairedClient()
        let pairing = try #require(await paired.pairing)
        // Same accessory keys, but a controller identity the accessory never saw.
        let stranger = try await HAPTestClient.connect(port: running.port, pairing: pairing)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) { try await stranger.pairVerify() }
        #expect(try await stranger.request("GET", "/accessories").status == 470)
        // Known identifier, wrong long-term key: bad signature.
        let impostor = try await HAPTestClient.connect(port: running.port, controllerID: paired.controllerID, pairing: pairing)
        await #expect(throws: HAPTestClientError.pairing(step: 4, error: 2)) { try await impostor.pairVerify() }
        #expect(await running.server.sessionCount == 1)
    }

    /// Pair-verify M3 variants an unauthenticated peer might send after an honest M1/M2.
    enum BadM3: CaseIterable, Sendable {
        /// One ciphertext byte flipped: fails ChaCha20-Poly1305 authentication.
        case tamperedCiphertext
        /// Correct content, sealed under a key not derived from this pair-verify's shared secret.
        case sealedUnderAnotherKey
        /// Shorter than the Poly1305 tag.
        case truncatedEncryptedData
        case withoutEncryptedData
        /// Sealed correctly around an empty TLV.
        case emptyInnerTLV
        /// Decrypts, but the plaintext is not a TLV.
        case malformedInnerTLV
        case withoutIdentifier
        case withoutSignature
        case identifierNotUTF8

        /// Expected kTLVError at state 4: Authentication when the sealed data does not open, Unknown when it opens to a
        /// malformed TLV.
        var expectedError: UInt8 {
            switch self {
            case .tamperedCiphertext, .sealedUnderAnotherKey, .truncatedEncryptedData, .withoutEncryptedData: 2
            case .emptyInnerTLV, .malformedInnerTLV, .withoutIdentifier, .withoutSignature, .identifierNotUTF8: 1
            }
        }

        /// The M3 to send instead of `honest` (which `HAPTestClient.pairVerifyUpToM3` built for `sharedSecret`).
        func message(sharedSecret: Data, honest: TLVBuilder) throws -> TLVBuilder {
            let encryptionKey = HAPCrypto.hkdfSHA512(inputKey: sharedSecret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            guard let honestEncrypted = try TLVReader(honest.data).data(0x05) else { throw HAPTestClientError.unexpected("M3 without data") }
            let signature = Data(repeating: 0x5A, count: 64)
            func sealed(_ plaintext: Data, key: Data = encryptionKey) throws -> Data {
                try HAPCrypto.chachaSeal(plaintext, key: key, nonce: HAPCrypto.nonce(label: "PV-Msg03"))
            }
            func inner(_ items: [(UInt8, Data)]) -> Data {
                var builder = TLVBuilder()
                for (type, value) in items { builder.add(type, value) }
                return builder.data
            }
            let encrypted: Data? = switch self {
            case .tamperedCiphertext:
                Data(honestEncrypted.enumerated().map { $0.offset == 3 ? $0.element ^ 0x01 : $0.element })
            case .sealedUnderAnotherKey:
                try sealed(inner([(0x01, Data("controller".utf8)), (0x0A, signature)]),
                           key: HAPCrypto.hkdfSHA512(inputKey: Data(repeating: 7, count: 32), salt: "Pair-Verify-Encrypt-Salt",
                                                     info: "Pair-Verify-Encrypt-Info"))
            case .truncatedEncryptedData: Data(honestEncrypted.prefix(15))
            case .withoutEncryptedData: nil
            case .emptyInnerTLV: try sealed(Data())
            case .malformedInnerTLV: try sealed(Data([0x01, 0x05, 0x41]))
            case .withoutIdentifier: try sealed(inner([(0x0A, signature)]))
            case .withoutSignature: try sealed(inner([(0x01, Data("controller".utf8))]))
            case .identifierNotUTF8: try sealed(inner([(0x01, Data([0xC3, 0x28, 0xFF])), (0x0A, signature)]))
            }
            var m3 = TLVBuilder()
            m3.add(0x06, uint8: 3)
            if let encrypted { m3.add(0x05, encrypted) }
            return m3
        }
    }

    /// Review finding (W4 round 4): no test sent a pair-verify M3 that does not decrypt or that decrypts to a malformed
    /// TLV (any LAN peer can, before authentication), so a change that remapped those errors, or trapped on a short inner
    /// TLV, passed every suite. Each M3 follows an honest M1/M2 of a paired controller: refused at state 4, no session,
    /// the pair-verify is used up (its honest M3 is out of order now), and an honest pair-verify works afterwards.
    @Test(arguments: BadM3.allCases) func pairVerifyRefusesBadM3(_ variant: BadM3) async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let paired = try await running.pairedClient()
        let client = try await paired.reconnect(port: running.port)
        let (sharedSecret, honest) = try await client.pairVerifyUpToM3()
        let m4 = try await client.pairingRequest("/pair-verify", try variant.message(sharedSecret: sharedSecret, honest: honest))
        #expect(m4.uint8(0x06) == 4)
        #expect(m4.uint8(0x07) == variant.expectedError)
        #expect(try await client.request("GET", "/accessories").status == 470, "no session")
        #expect(await running.server.sessionCount == 1)

        let replay = try await client.request("POST", "/pair-verify", body: honest.data, contentType: "application/pairing+tlv8")
        #expect(replay.status == 400)
        #expect(try replay.tlv().uint8(0x06) == 4)
        #expect(try replay.tlv().uint8(0x07) == 1)
        #expect(try await client.request("GET", "/accessories").status == 470, "no session")

        try await client.pairVerify()
        #expect(try await client.request("GET", "/accessories").status == 200)
        #expect(await running.server.sessionCount == 2)
    }

    /// Review finding (W4 round 4): pair-verify bodies that are not a TLV, carry no state, start at M3 or name a step
    /// the controller never sends were never tested. Each is refused (HTTP 400, kTLVError Unknown at the step after the
    /// one sent), an out-of-order step ends the pair-verify in progress, and the connection can still pair-verify.
    @Test func pairVerifyRejectsMalformedAndOutOfOrderSteps() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let paired = try await running.pairedClient()
        let client = try await paired.reconnect(port: running.port)
        func post(_ body: Data) async throws -> PairingReply {
            let response = try await client.request("POST", "/pair-verify", body: body, contentType: "application/pairing+tlv8")
            let tlv = try response.tlv()
            return PairingReply(response.status, tlv.uint8(0x06), tlv.uint8(0x07))
        }
        let anyEncryptedData = Data(repeating: 0x33, count: 80)

        // Not a TLV, or a TLV without a state.
        #expect(try await post(Data([0x06])) == PairingReply(400, 2, 1))
        #expect(try await post(Data()) == PairingReply(400, 2, 1))
        #expect(try await post(tlv([(0x03, Data(repeating: 9, count: 32))])) == PairingReply(400, 2, 1))
        // M3 without M1, and steps only the accessory sends or that do not exist.
        #expect(try await post(tlv([(0x06, Data([3])), (0x05, anyEncryptedData)])) == PairingReply(400, 4, 1))
        #expect(try await post(tlv([(0x06, Data([2]))])) == PairingReply(400, 3, 1))
        #expect(try await post(tlv([(0x06, Data([4]))])) == PairingReply(400, 5, 1))
        #expect(try await post(tlv([(0x06, Data([5]))])) == PairingReply(400, 6, 1))
        #expect(try await post(tlv([(0x06, Data([0xFF]))])) == PairingReply(400, 0, 1))
        // M1 without a usable public key.
        #expect(try await post(tlv([(0x06, Data([1]))])) == PairingReply(200, 2, 1))
        #expect(try await post(tlv([(0x06, Data([1])), (0x03, Data(repeating: 9, count: 31))])) == PairingReply(200, 2, 1))

        // An out-of-order step after M1 ends that pair-verify: its M3 is refused afterwards.
        let (_, m3) = try await client.pairVerifyUpToM3()
        #expect(try await post(tlv([(0x06, Data([5]))])) == PairingReply(400, 6, 1))
        #expect(try await post(m3.data) == PairingReply(400, 4, 1))
        #expect(try await client.request("GET", "/accessories").status == 470)

        try await client.pairVerify()
        #expect(try await client.request("GET", "/accessories").status == 200)
    }

    /// Review finding (W4 round 4): an admin's `/pairings` requests were only ever well formed. Malformed ones (no TLV,
    /// no method or state, an unknown method, Add or Remove Pairing without a usable identifier, key or permissions)
    /// are refused with kTLVError Unknown and change nothing; the session stays usable.
    @Test func malformedPairingsRequestsAreRefused() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let admin = try await running.pairedClient()
        let key = HAPLongTermKey().publicKey
        let id = Data("hub-2".utf8)
        let notUTF8 = Data([0xC3, 0x28, 0xFF])
        let refused: [(name: String, body: Data)] = [
            ("not a TLV", Data([0x00])),
            ("empty", Data()),
            ("no method", tlv([(0x06, Data([1]))])),
            ("no state", tlv([(0x00, Data([5]))])),
            ("state 3", tlv([(0x06, Data([3])), (0x00, Data([5]))])),
            ("two-byte method", tlv([(0x06, Data([1])), (0x00, Data([5, 0]))])),
            ("method 9", tlv([(0x06, Data([1])), (0x00, Data([9]))])),
            ("method 0 (pair-setup)", tlv([(0x06, Data([1])), (0x00, Data([0]))])),
            ("add without identifier", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x03, key), (0x0B, Data([1]))])),
            ("add with an empty identifier", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x01, Data()), (0x03, key), (0x0B, Data([1]))])),
            ("add with an identifier not UTF-8", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x01, notUTF8), (0x03, key), (0x0B, Data([1]))])),
            ("add without public key", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x01, id), (0x0B, Data([1]))])),
            ("add with a 31-byte key", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x01, id), (0x03, key.prefix(31)), (0x0B, Data([1]))])),
            ("add without permissions", tlv([(0x06, Data([1])), (0x00, Data([3])), (0x01, id), (0x03, key)])),
            ("remove without identifier", tlv([(0x06, Data([1])), (0x00, Data([4]))])),
            ("remove with an identifier not UTF-8", tlv([(0x06, Data([1])), (0x00, Data([4])), (0x01, notUTF8)])),
        ]
        for (name, body) in refused {
            let response = try await admin.request("POST", "/pairings", body: body, contentType: "application/pairing+tlv8")
            #expect(response.status == 200, "\(name)")
            let reply = try response.tlv()
            #expect(reply.uint8(0x06) == 2 && reply.uint8(0x07) == 1, "\(name)")
            #expect(reply.data(0x01) == nil, "\(name): no pairing listed")
        }
        #expect(try running.store.loadState()?.pairings.map(\.identifier) == [admin.controllerID])
        let list = try await admin.pairings(method: 5)
        #expect(list.uint8(0x07) == nil && list.all(0x01) == [Data(admin.controllerID.utf8)])
        #expect(try await admin.request("GET", "/accessories").status == 200)
    }

    /// Review finding (W4 round 4): admin-only writes (the camera's HomeKitCameraActive, recording Active, selected
    /// recording configuration, stream Active) check the open session's admin flag, which `/pairings` Add Pairing
    /// updates for that controller's open connections. No test changed the permissions of a controller with an open
    /// session, so losing that update (a demoted controller keeping admin rights until it reconnects) passed every suite.
    @Test func permissionChangesReachTheControllersOpenSessions() async throws {
        let hub = TestAccessories.sensorHub()
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            guard context.session.isAdmin else { throw .insufficientPrivileges }   // as CameraController's admin-only writes
            return nil
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let admin = try await running.pairedClient()
        let keyB = HAPLongTermKey()
        #expect(try await admin.pairings(method: 3, identifier: "controller-b", publicKey: keyB.publicKey, permissions: 1).uint8(0x07) == nil)
        let b = try await HAPTestClient.connect(port: running.port, controllerID: "controller-b", longTermKey: keyB,
                                                pairing: running.accessoryPairing)
        try await b.pairVerify()
        let bSecond = try await running.verifiedConnection(like: b)
        func writeStatus(_ client: HAPTestClient) async throws -> HAPJSON? {
            let result = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)])
            return result.status == 204 ? 0 : result.json?["characteristics"]?[0]?["status"]
        }
        #expect(try await writeStatus(b) == 0)
        #expect(try await writeStatus(bSecond) == 0)

        // Demoted: both of B's open connections lose admin-only writes at once.
        #expect(try await admin.pairings(method: 3, identifier: "controller-b", publicKey: keyB.publicKey, permissions: 0).uint8(0x07) == nil)
        #expect(try await writeStatus(b) == -70401)
        #expect(try await writeStatus(bSecond) == -70401)
        #expect(try await b.pairings(method: 5).uint8(0x07) == 2)
        #expect(try await writeStatus(admin) == 0, "other controllers keep their rights")

        // Promoted again, on the same connections.
        #expect(try await admin.pairings(method: 3, identifier: "controller-b", publicKey: keyB.publicKey, permissions: 1).uint8(0x07) == nil)
        #expect(try await writeStatus(b) == 0)
        #expect(try await writeStatus(bSecond) == 0)
        #expect(try await b.pairings(method: 5).uint8(0x07) == nil)
        #expect(await b.isClosed == false)
        #expect(await bSecond.isClosed == false)
    }

    @Test func sessionOnCloseFiresWhenConnectionCloses() async throws {
        let hub = TestAccessories.sensorHub()
        let closed = Mutex(0)
        hub.lightOn.onWrite { _, context async throws(HAPStatus) -> HAPValue? in
            context.session.onClose { closed.withLock { $0 += 1 } }
            return nil
        }
        let running = try await startServer(accessory: hub.accessory)
        defer { await running.stop() }
        let events = running.server.events
        let client = try await running.pairedClient()
        _ = try await client.writeCharacteristics([writeItem(1, hub.lightOn, value: 1)])
        await client.close()
        #expect(await eventually { closed.withLock { $0 } == 1 })
        #expect(await eventually { await running.server.sessionCount == 0 })
        var iterator = events.makeAsyncIterator()
        var counts: [Int] = []
        while counts.last != 0, let event = await iterator.next() {
            if case .sessionsChanged(let count) = event { counts.append(count) }
        }
        #expect(counts == [1, 0])
    }

    @Test func pairingsListAddRemove() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let admin = try await running.pairedClient()

        let guestKey = HAPLongTermKey()
        let added = try await admin.pairings(method: 3, identifier: "guest-1", publicKey: guestKey.publicKey, permissions: 0)
        #expect(added.uint8(0x06) == 2 && added.uint8(0x07) == nil)

        let list = try await admin.pairings(method: 5)
        #expect(list.uint8(0x06) == 2)
        let entries = TLV8.splitList(list.items.filter { $0.type != 0x06 })
        #expect(entries.count == 2)
        let parsed = entries.map { TLVReader(items: $0) }
        #expect(Set(parsed.compactMap { $0.string(0x01) }) == [admin.controllerID, "guest-1"])
        #expect(parsed.first { $0.string(0x01) == "guest-1" }?.uint8(0x0B) == 0)
        #expect(parsed.first { $0.string(0x01) == admin.controllerID }?.uint8(0x0B) == 1)

        // Same identifier with a different key → Unknown error.
        let conflict = try await admin.pairings(method: 3, identifier: "guest-1", publicKey: HAPLongTermKey().publicKey, permissions: 1)
        #expect(conflict.uint8(0x07) == 1)
        // Same key: permission update.
        let promoted = try await admin.pairings(method: 3, identifier: "guest-1", publicKey: guestKey.publicKey, permissions: 1)
        #expect(promoted.uint8(0x07) == nil)
        #expect(try running.store.loadState()?.pairings.first { $0.identifier == "guest-1" }?.isAdmin == true)

        let removed = try await admin.pairings(method: 4, identifier: "guest-1")
        #expect(removed.uint8(0x06) == 2 && removed.uint8(0x07) == nil)
        #expect(try running.store.loadState()?.pairings.map(\.identifier) == [admin.controllerID])
        #expect(await running.server.isPaired)
    }

    @Test func nonAdminControllersCannotManagePairings() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let admin = try await running.pairedClient()
        let guestKey = HAPLongTermKey()
        _ = try await admin.pairings(method: 3, identifier: "guest-2", publicKey: guestKey.publicKey, permissions: 0)
        let adminPairing = try #require(await admin.pairing)
        let guest = try await HAPTestClient.connect(port: running.port, controllerID: "guest-2", longTermKey: guestKey, pairing: adminPairing)
        try await guest.pairVerify()
        #expect(try await guest.request("GET", "/accessories").status == 200)
        #expect(try await guest.pairings(method: 5).uint8(0x07) == 2)
        #expect(try await guest.pairings(method: 4, identifier: admin.controllerID).uint8(0x07) == 2)
        #expect(try running.store.loadState()?.pairings.count == 2)
    }

    @Test func removingLastAdminClearsEverythingAndClosesSessions() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let events = running.server.events
        let admin = try await running.pairedClient()
        let guestKey = HAPLongTermKey()
        _ = try await admin.pairings(method: 3, identifier: "guest-3", publicKey: guestKey.publicKey, permissions: 0)
        let pairing = try #require(await admin.pairing)
        let guest = try await HAPTestClient.connect(port: running.port, controllerID: "guest-3", longTermKey: guestKey, pairing: pairing)
        try await guest.pairVerify()
        let second = try await running.verifiedConnection(like: admin)
        #expect(await running.server.sessionCount == 3)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })

        let removed = try await admin.pairings(method: 4, identifier: admin.controllerID)
        #expect(removed.uint8(0x06) == 2 && removed.uint8(0x07) == nil)
        #expect(await admin.waitUntilClosed())
        #expect(await second.waitUntilClosed())
        #expect(await guest.waitUntilClosed())
        #expect(await running.server.isPaired == false)
        #expect(try running.store.loadState()?.pairings.isEmpty == true)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "1" })
        var iterator = events.makeAsyncIterator()
        var sawUnpaired = false
        while let event = await iterator.next() {
            if event == .unpaired { sawUnpaired = true; break }
        }
        #expect(sawUnpaired)
        // The accessory can be paired again.
        let fresh = try await HAPTestClient.connect(port: running.port)
        try await fresh.pairSetup(code: running.setupCode)
    }

    /// A TLV8 body from (type, value) items.
    private func tlv(_ items: [(UInt8, Data)]) -> Data {
        var builder = TLVBuilder()
        for (type, value) in items { builder.add(type, value) }
        return builder.data
    }

    @Test func resetPairingsClosesSessionsAndReadvertises() async throws {
        let running = try await startServer(accessory: TestAccessories.sensorHub().accessory)
        defer { await running.stop() }
        let client = try await running.pairedClient()
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "0" })
        try await running.server.resetPairings()
        #expect(await client.waitUntilClosed())
        #expect(await running.server.isPaired == false)
        #expect(await running.advertiser.waitForTXT { $0["sf"] == "1" })
    }
}
#endif
