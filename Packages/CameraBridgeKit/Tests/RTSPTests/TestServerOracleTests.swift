import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing

/// The test server's own building blocks are checked against published vectors, so it can serve as an oracle.
@Suite struct TestServerOracleTests {
    @Test func md5MatchesRFC1321() {
        #expect(TestDigest.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(TestDigest.md5Hex("a") == "0cc175b9c0f1b6a831c399e269772661")
        #expect(TestDigest.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(TestDigest.md5Hex("message digest") == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(TestDigest.md5Hex(String(repeating: "1234567890", count: 8)) == "57edf4a22be3c955ac49da2e2107b67a")
    }

    @Test func digestVerificationMatchesRFC2617Example() {
        let header = """
        Digest username="Mufasa", realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", uri="/dir/index.html", \
        qop=auth, nc=00000001, cnonce="0a4f113b", response="6629fae49393a05397450978507c4ef1", opaque="5ccc069c403ebaf9f0171e9517f40e41"
        """
        let credentials = HTTPCredentials(username: "Mufasa", password: "Circle Of Life")
        #expect(TestDigest.verify(authorization: header, method: "GET", credentials: credentials, realm: "testrealm@host.com",
                                  nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093"))
        #expect(!TestDigest.verify(authorization: header, method: "GET", credentials: HTTPCredentials(username: "Mufasa", password: "x"),
                                   realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093"))
        #expect(!TestDigest.verify(authorization: header, method: "POST", credentials: credentials, realm: "testrealm@host.com",
                                   nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093"))
    }

    @Test func basicVerification() {
        let credentials = HTTPCredentials(username: "admin", password: "p@ss:word")
        #expect(TestDigest.verifyBasic(authorization: BasicAuth.header(credentials), credentials: credentials))
        #expect(!TestDigest.verifyBasic(authorization: "Basic Zm9vOmJhcg==", credentials: credentials))
        #expect(!TestDigest.verifyBasic(authorization: nil, credentials: credentials))
    }

    @Test func syntheticFramesNeverEmulateStartCodes() {
        for index in [0, 1, 127, 128, 16_384, 1 << 21] {
            for codec in [VideoCodec.h264, .hevc] {
                let nal = [UInt8](SyntheticNALSource.videoNAL(index: index, isKeyframe: index % 2 == 0, size: 3000, codec: codec))
                #expect(!zip(nal, nal.dropFirst()).contains { $0 == 0 && $1 == 0 })
            }
        }
        let format = AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1)
        let unit = SyntheticNALSource.audioUnit(index: 300, format: format)
        #expect(SyntheticNALSource.audioIndex(of: unit) == 300)
        #expect(unit.data.count == 160 && unit.sampleCount == 160)
        #expect(unit.pts == MediaTime(value: 300 * 160, timescale: 8000))
    }
}
