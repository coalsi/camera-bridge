import BigInt
import BridgeSupport
import Foundation
import Testing
@testable import HAPCore

struct SRPVector: Decodable, Sendable, CustomTestStringConvertible {
    var username: String
    var password: String
    var salt: String
    var a: String
    var b: String
    var v: String
    var A: String
    var B: String
    var K: String
    var M1: String
    var M2: String
    var testDescription: String { "\(username)/\(password)" }
}

private struct SRPFixture: Decodable { var vectors: [SRPVector] }

/// Read relative to this file (no SwiftPM resources): Tests/HAPCoreTests/Fixtures/srp.json.
private func loadVectors() -> [SRPVector] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/srp.json")
    guard let data = try? Data(contentsOf: url),
          let fixture = try? JSONDecoder().decode(SRPFixture.self, from: data) else { return [] }
    return fixture.vectors
}

private func hex(_ s: String) throws -> Data { try #require(Data(hex: s)) }

@Suite struct SRPTests {
    @Test func fixtureIsPresent() {
        #expect(loadVectors().count >= 2)
    }

    /// Golden values produced by fast-srp-hap (the SRP used by HAP-NodeJS); see Fixtures/srp.json.
    @Test(arguments: loadVectors())
    func serverMatchesGolden(_ vector: SRPVector) throws {
        let server = SRPServer(username: vector.username, password: vector.password, salt: try hex(vector.salt), privateValue: try hex(vector.b))
        #expect(server.salt.hexString == vector.salt)
        #expect(server.publicKey.hexString == vector.B)
        #expect(server.sessionKey == nil)
        try server.setClientPublicKey(try hex(vector.A))
        #expect(server.sessionKey?.hexString == vector.K)
        let m2 = try server.verifyClientProof(try hex(vector.M1))
        #expect(m2.hexString == vector.M2)
    }

    @Test(arguments: loadVectors())
    func clientMatchesGolden(_ vector: SRPVector) throws {
        let client = try SRPClient(username: vector.username, password: vector.password, salt: try hex(vector.salt),
                                   serverPublicKey: try hex(vector.B), privateValue: try hex(vector.a))
        #expect(client.publicKey.hexString == vector.A)
        #expect(client.sessionKey.hexString == vector.K)
        #expect(client.proof.hexString == vector.M1)
        #expect(client.verifyServerProof(try hex(vector.M2)))
        #expect(!client.verifyServerProof(Data(count: 64)))
    }

    @Test func randomRoundTripWithSetupCode() throws {
        let code = SetupCode.random()
        let server = SRPServer(password: code.formatted)
        #expect(server.salt.count == 16)
        #expect(server.publicKey.count == 384)
        let client = try SRPClient(password: code.formatted, salt: server.salt, serverPublicKey: server.publicKey)
        #expect(client.publicKey.count == 384)
        try server.setClientPublicKey(client.publicKey)
        let m2 = try server.verifyClientProof(client.proof)
        #expect(client.verifyServerProof(m2))
        #expect(server.sessionKey == client.sessionKey)
        #expect(client.sessionKey.count == 64)
    }

    @Test func wrongPasswordIsRejected() throws {
        let server = SRPServer(password: "031-45-154")
        let client = try SRPClient(password: "031-45-155", salt: server.salt, serverPublicKey: server.publicKey)
        try server.setClientPublicKey(client.publicKey)
        #expect(throws: SRPError.proofMismatch) { try server.verifyClientProof(client.proof) }
    }

    @Test func invalidPublicKeysAreRejected() throws {
        let server = SRPServer(password: "031-45-154")
        #expect(throws: SRPError.invalidPublicKey) { try server.setClientPublicKey(Data(count: 384)) }
        let n = SRPGroup.modulusBytes
        #expect(throws: SRPError.invalidPublicKey) { try server.setClientPublicKey(n) }
        #expect(throws: SRPError.invalidPublicKey) { try server.setClientPublicKey(Data()) }
        #expect(throws: SRPError.invalidPublicKey) {
            try SRPClient(password: "x", salt: Data(count: 16), serverPublicKey: Data(count: 384))
        }
    }

    @Test func proofBeforePublicKeyIsNotReady() {
        let server = SRPServer(password: "031-45-154")
        #expect(throws: SRPError.notReady) { try server.verifyClientProof(Data(count: 64)) }
    }
}

@Suite struct MontgomeryTests {
    @Test func matchesBigIntModularPower() {
        // Small odd modulus cross-checked against BigInt's reference implementation.
        let modulus = BigUInt("F123456789ABCDEF0123456789ABCDEF1", radix: 16) ?? 1
        let context = MontgomeryContext(modulus: modulus)
        for (base, exponent) in [(BigUInt(5), BigUInt(0)), (BigUInt(5), BigUInt(1)), (BigUInt(2), BigUInt(1000)),
                                 (modulus - 1, BigUInt(2)), (modulus + 7, BigUInt(123_456_789)), (BigUInt(0), BigUInt(3))] {
            #expect(context.power(base, exponent) == base.power(exponent, modulus: modulus))
        }
    }

    @Test func groupPowerMatchesBigIntOnce() {
        let exponent = BigUInt(Data(repeating: 0xA5, count: 32))
        #expect(SRPGroup.power(SRPGroup.g, exponent) == SRPGroup.g.power(exponent, modulus: SRPGroup.N))
    }

    /// Fixed-window scanning must not depend on zero windows: exponents with zero nibbles, zero low words and
    /// leading zero nibbles in the top word. The 2^127 + 29 modulus exercises the single-subtraction reduction
    /// (top limb bit set); inputs ≥ modulus exercise it with a borrow-free and a borrowing path.
    @Test func fixedWindowHandlesZeroNibblesAndReduction() {
        let highBitModulus = (BigUInt(1) << 127) + 29
        let smallModulus = BigUInt("F123456789ABCDEF0123456789ABCDEF1", radix: 16) ?? 1
        let exponents: [BigUInt] = [0, 1, 0x10, 0x1000_0000_0000_0001, (BigUInt(1) << 64) + 1, BigUInt(1) << 64, (BigUInt(1) << 130) + 0xF00F,
                                    BigUInt("8000000000000000000000000000000000000000000000000000000000000001", radix: 16) ?? 0]
        for modulus in [highBitModulus, smallModulus] {
            let context = MontgomeryContext(modulus: modulus)
            let bases: [BigUInt] = [0, 1, 2, modulus - 1, modulus, modulus + 1, (BigUInt(1) << 128) - 1, BigUInt(0xDEAD_BEEF)]
            for base in bases {
                for exponent in exponents {
                    #expect(context.power(base, exponent) == base.power(exponent, modulus: modulus),
                            "\(base)^\(exponent) mod \(modulus)")
                }
            }
        }
    }

    @Test func modularMultiplyAndAddMatchBigInt() {
        let n = SRPGroup.N
        let values: [BigUInt] = [0, 1, 5, n - 1, n, n + 1, (BigUInt(1) << 3072) - 1, SRPGroup.k,
                                 BigUInt(Data(repeating: 0x5A, count: 384)), BigUInt(Data(repeating: 0xC3, count: 200))]
        for a in values {
            for b in values {
                #expect(SRPGroup.multiply(a, b) == (a * b) % n)
                #expect(SRPGroup.add(a, b) == (a % n + b % n) % n)
            }
        }
    }
}
