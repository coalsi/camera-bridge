import BridgeSupport
import Foundation
import Testing
@testable import HAPCore

private func hex(_ s: String) -> Data {
    guard let d = Data(hex: s) else { Issue.record("bad hex literal"); return Data() }
    return d
}

@Suite struct HKDFTests {
    // Expected values computed independently with Node.js `crypto.hkdfSync("sha512", …)`.
    private let ikm = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

    @Test func controlReadKey() {
        let key = HAPCrypto.hkdfSHA512(inputKey: ikm, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        #expect(key.hexString == "c09403ef8aa6c5045cbd8cf9bf3e665b2caed623af2be0e87c8f80f519914d3d")
    }

    @Test func pairSetupEncryptKey() {
        let key = HAPCrypto.hkdfSHA512(inputKey: ikm, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        #expect(key.hexString == "52890146745a52e57b82b859a7a3679c7f3d40bb295b055a0c8fa8af92a3746d")
    }

    @Test func binarySaltAndCustomLength() {
        let key = HAPCrypto.hkdfSHA512(inputKey: ikm, salt: Data(repeating: 0xAB, count: 64), info: "HDS-Read-Encryption-Key", outputByteCount: 42)
        #expect(key.hexString == "e649e170b979c0391c44adde9686943e67861241c2efe068f1f75b78a263fd10d90a5a9a4a207c033105")
    }
}

/// SHA-256 from swift-crypto (configuration and recording-configuration hashes; replaced the hand-written `HAPSHA256`).
@Suite struct SHA256Tests {
    /// FIPS 180-2 examples.
    @Test func knownVectors() {
        #expect(HAPCrypto.sha256(Data("abc".utf8)).hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(HAPCrypto.sha256(Data()).hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(HAPCrypto.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hexString
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(HAPCrypto.sha256(Data(repeating: 0x61, count: 1_000_000)).hexString
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func blockBoundariesAndSlices() {
        // 55, 56 and 64 byte messages exercise the padding edge cases.
        #expect(HAPCrypto.sha256(Data(repeating: 0x61, count: 55)).hexString == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(HAPCrypto.sha256(Data(repeating: 0x61, count: 56)).hexString == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(HAPCrypto.sha256(Data(repeating: 0x61, count: 64)).hexString == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        let padded = Data("xxabc".utf8)
        #expect(HAPCrypto.sha256(padded[2...]) == HAPCrypto.sha256(Data("abc".utf8)))
        #expect(HAPCrypto.sha256(Data()).count == 32)
    }
}

@Suite struct ChaChaPolyTests {
    // RFC 8439 §2.8.2 AEAD test vector.
    private let key = Data((0x80...0x9F).map { UInt8($0) })
    private let nonce = hex("070000004041424344454647")
    private let aad = hex("50515253c0c1c2c3c4c5c6c7")
    private let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
    private let expected = hex("""
        d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b\
        1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc\
        3ff4def08e4b7a9de576d26586cec64b6116
        """ + "1ae10b594f09e26a7e902ecbd0600691")

    @Test func sealMatchesRFC8439() throws {
        #expect(try HAPCrypto.chachaSeal(plaintext, key: key, nonce: nonce, aad: aad) == expected)
    }

    @Test func openMatchesRFC8439() throws {
        #expect(try HAPCrypto.chachaOpen(expected, key: key, nonce: nonce, aad: aad) == plaintext)
    }

    @Test func tamperingFails() {
        var tampered = expected
        tampered[5] ^= 0x01
        #expect(throws: HAPCryptoError.authenticationFailed) { try HAPCrypto.chachaOpen(tampered, key: key, nonce: nonce, aad: aad) }
        #expect(throws: HAPCryptoError.authenticationFailed) { try HAPCrypto.chachaOpen(expected, key: key, nonce: nonce, aad: Data()) }
        #expect(throws: HAPCryptoError.truncated) { try HAPCrypto.chachaOpen(Data(count: 15), key: key, nonce: nonce) }
        #expect(throws: HAPCryptoError.invalidKeyLength) { try HAPCrypto.chachaSeal(Data(), key: Data(count: 16), nonce: nonce) }
        #expect(throws: HAPCryptoError.invalidNonceLength) { try HAPCrypto.chachaSeal(Data(), key: key, nonce: Data(count: 8)) }
    }

    @Test func hapNonces() {
        #expect(HAPCrypto.nonce(label: "PS-Msg05") == Data([0, 0, 0, 0]) + Data("PS-Msg05".utf8))
        #expect(HAPCrypto.nonce(label: "PV-Msg02").count == 12)
        #expect(HAPCrypto.nonce(counter: 1).hexString == "000000000100000000000000")
        #expect(HAPCrypto.nonce(counter: 0x0102030405060708).hexString == "000000000807060504030201")
    }

    @Test func hapFrameRoundTrip() throws {
        // Encrypted HAP frame: AAD = 2-byte LE length, nonce = counter.
        let sessionKey = Data(repeating: 7, count: 32)
        let body = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
        let aad = Data([UInt8(body.count & 0xFF), UInt8(body.count >> 8)])
        let sealed = try HAPCrypto.chachaSeal(body, key: sessionKey, nonce: HAPCrypto.nonce(counter: 0), aad: aad)
        #expect(sealed.count == body.count + 16)
        #expect(try HAPCrypto.chachaOpen(sealed, key: sessionKey, nonce: HAPCrypto.nonce(counter: 0), aad: aad) == body)
        #expect(throws: HAPCryptoError.authenticationFailed) {
            try HAPCrypto.chachaOpen(sealed, key: sessionKey, nonce: HAPCrypto.nonce(counter: 1), aad: aad)
        }
    }
}

@Suite struct CurveTests {
    // RFC 7748 §6.1
    @Test func x25519RFC7748() throws {
        let alice = try X25519KeyPair(rawRepresentation: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try X25519KeyPair(rawRepresentation: hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        #expect(alice.publicKey.hexString == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(bob.publicKey.hexString == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        #expect(try alice.sharedSecret(with: bob.publicKey).hexString == shared)
        #expect(try bob.sharedSecret(with: alice.publicKey).hexString == shared)
        #expect(throws: (any Error).self) { try alice.sharedSecret(with: Data(count: 5)) }
    }

    @Test func x25519RandomAgreement() throws {
        let a = X25519KeyPair(), b = X25519KeyPair()
        #expect(try a.sharedSecret(with: b.publicKey) == b.sharedSecret(with: a.publicKey))
        #expect(a.publicKey.count == 32)
        #expect(try X25519KeyPair(rawRepresentation: a.rawRepresentation).publicKey == a.publicKey)
    }

    // RFC 8032 §7.1 TEST 1 (empty message). CryptoKit signatures are randomized, so verify rather than compare.
    @Test func ed25519RFC8032() throws {
        let key = try HAPLongTermKey(rawRepresentation: hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        #expect(key.publicKey.hexString == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let rfcSignature = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        #expect(HAPLongTermKey.isValidSignature(rfcSignature, for: Data(), publicKey: key.publicKey))
        #expect(!HAPLongTermKey.isValidSignature(rfcSignature, for: Data([0]), publicKey: key.publicKey))
    }

    @Test func ed25519SignVerify() throws {
        let key = HAPLongTermKey()
        let message = Data("accessory-sign ‖ CC:22:3D:E3:CE:F3 ‖ ltpk".utf8)
        let signature = try key.signature(for: message)
        #expect(signature.count == 64)
        #expect(HAPLongTermKey.isValidSignature(signature, for: message, publicKey: key.publicKey))
        #expect(!HAPLongTermKey.isValidSignature(signature, for: message + Data([1]), publicKey: key.publicKey))
        #expect(!HAPLongTermKey.isValidSignature(signature, for: message, publicKey: Data(count: 3)))
        let restored = try HAPLongTermKey(rawRepresentation: key.rawRepresentation)
        #expect(restored.publicKey == key.publicKey)
        #expect(throws: (any Error).self) { try HAPLongTermKey(rawRepresentation: Data(count: 7)) }
    }
}
