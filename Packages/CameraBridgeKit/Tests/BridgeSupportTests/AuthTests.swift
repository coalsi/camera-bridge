import Crypto
import Foundation
import Synchronization
import Testing
@testable import BridgeSupport

/// Extracts `key=value` / `key="value"` parameters from a Digest header (test-side, independent of the parser under test).
func digestParameters(_ header: String) -> [String: String] {
    var result: [String: String] = [:]
    let body = header.hasPrefix("Digest ") ? String(header.dropFirst(7)) : header
    let regex = /([A-Za-z0-9_-]+)=(?:"((?:[^"\\]|\\.)*)"|([^,\s]*))/
    for match in body.matches(of: regex) {
        result[String(match.1).lowercased()] = String(match.2 ?? match.3 ?? "")
    }
    return result
}

@Suite struct DigestTests {
    @Test func parsesRFC2617Challenge() throws {
        let header = #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        let challenge = try #require(DigestChallenge.parse(header))
        #expect(challenge.realm == "testrealm@host.com")
        #expect(challenge.nonce == "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        #expect(challenge.opaque == "5ccc069c403ebaf9f0171e9517f40e41")
        #expect(challenge.qop == ["auth", "auth-int"])
        #expect(challenge.algorithm == "MD5")
        #expect(challenge.stale == false)
    }

    @Test func parsesDigestAmongOtherSchemesAndFlags() throws {
        let header = #"Basic realm="cam", Digest realm="IP Camera(C1234)", nonce="abc\"def", stale=TRUE, algorithm=SHA-256, qop=auth"#
        let challenge = try #require(DigestChallenge.parse(header))
        #expect(challenge.realm == "IP Camera(C1234)")
        #expect(challenge.nonce == "abc\"def")
        #expect(challenge.stale)
        #expect(challenge.algorithm == "SHA-256")
        #expect(challenge.qop == ["auth"])
        #expect(challenge.opaque == nil)
    }

    @Test func rejectsNonDigestOrIncompleteChallenges() {
        #expect(DigestChallenge.parse(#"Basic realm="x""#) == nil)
        #expect(DigestChallenge.parse(#"Digest realm="x""#) == nil)          // no nonce
        #expect(DigestChallenge.parse("") == nil)
    }

    @Test func rfc2617Section3_5Vector() throws {
        let challenge = try #require(DigestChallenge.parse(
            #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        var auth = DigestAuthenticator(credentials: HTTPCredentials(username: "Mufasa", password: "Circle Of Life"), cnonce: { "0a4f113b" })
        let header = auth.authorization(for: challenge, method: "GET", uri: "/dir/index.html")
        #expect(header.hasPrefix("Digest "))
        let p = digestParameters(header)
        #expect(p["response"] == "6629fae49393a05397450978507c4ef1")
        #expect(p["username"] == "Mufasa")
        #expect(p["realm"] == "testrealm@host.com")
        #expect(p["uri"] == "/dir/index.html")
        #expect(p["qop"] == "auth")
        #expect(p["nc"] == "00000001")
        #expect(p["cnonce"] == "0a4f113b")
        #expect(p["opaque"] == "5ccc069c403ebaf9f0171e9517f40e41")
    }

    @Test func rfc7616Section3_9_1Vectors() throws {
        let base = #"realm="http-auth@example.org", qop="auth, auth-int", nonce="7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS""#
        let credentials = HTTPCredentials(username: "Mufasa", password: "Circle of Life")
        let cnonce = "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"

        let sha = try #require(DigestChallenge.parse("Digest " + base + ", algorithm=SHA-256"))
        var a1 = DigestAuthenticator(credentials: credentials, cnonce: { cnonce })
        let p1 = digestParameters(a1.authorization(for: sha, method: "GET", uri: "/dir/index.html"))
        #expect(p1["response"] == "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1")
        #expect(p1["algorithm"] == "SHA-256")

        let md5 = try #require(DigestChallenge.parse("Digest " + base + ", algorithm=MD5"))
        var a2 = DigestAuthenticator(credentials: credentials, cnonce: { cnonce })
        let p2 = digestParameters(a2.authorization(for: md5, method: "GET", uri: "/dir/index.html"))
        #expect(p2["response"] == "8ca523f5e9506fed4657c9700eebdbec")
    }

    @Test func nonceCountIncrementsAndResets() throws {
        let c1 = try #require(DigestChallenge.parse(#"Digest realm="r", nonce="n1", qop="auth""#))
        let c2 = try #require(DigestChallenge.parse(#"Digest realm="r", nonce="n2", qop="auth""#))
        var auth = DigestAuthenticator(credentials: HTTPCredentials(username: "u", password: "p"))
        #expect(digestParameters(auth.authorization(for: c1, method: "GET", uri: "/")) ["nc"] == "00000001")
        #expect(digestParameters(auth.authorization(for: c1, method: "GET", uri: "/")) ["nc"] == "00000002")
        #expect(digestParameters(auth.authorization(for: c2, method: "GET", uri: "/")) ["nc"] == "00000001")
        let cn = digestParameters(auth.authorization(for: c2, method: "GET", uri: "/"))["cnonce"] ?? ""
        #expect(cn.count >= 16)
    }

    @Test func legacyDigestWithoutQop() throws {
        // RFC 2069 style: response = MD5(HA1:nonce:HA2)
        let challenge = try #require(DigestChallenge.parse(#"Digest realm="r", nonce="xyz""#))
        var auth = DigestAuthenticator(credentials: HTTPCredentials(username: "u", password: "p"))
        let p = digestParameters(auth.authorization(for: challenge, method: "DESCRIBE", uri: "rtsp://cam/stream"))
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let expected = md5(md5("u:r:p") + ":xyz:" + md5("DESCRIBE:rtsp://cam/stream"))
        #expect(p["response"] == expected)
        #expect(p["qop"] == nil)
        #expect(p["nc"] == nil)
    }

    /// Servers offering only qop=auth-int (expected values computed independently with Python hashlib).
    @Test func authIntOnlyChallengeHashesTheEntityBody() throws {
        let challenge = try #require(DigestChallenge.parse(
            #"Digest realm="testrealm@host.com", qop="auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093""#))
        let credentials = HTTPCredentials(username: "Mufasa", password: "Circle Of Life")

        var post = DigestAuthenticator(credentials: credentials, cnonce: { "0a4f113b" })
        let p1 = digestParameters(post.authorization(for: challenge, method: "POST", uri: "/dir/index.html", body: Data("a=1&b=2".utf8)))
        #expect(p1["qop"] == "auth-int")
        #expect(p1["nc"] == "00000001" && p1["cnonce"] == "0a4f113b")
        #expect(p1["response"] == "3d78e823e1d6f158751dc9888331c4f5")

        // The contract overload (no body) hashes an empty entity body.
        var get = DigestAuthenticator(credentials: credentials, cnonce: { "0a4f113b" })
        let p2 = digestParameters(get.authorization(for: challenge, method: "GET", uri: "/dir/index.html"))
        #expect(p2["qop"] == "auth-int")
        #expect(p2["response"] == "5e6610ecf9ba3017a4870ad48e3ad30b")

        let sha = try #require(DigestChallenge.parse(
            #"Digest realm="http-auth@example.org", qop="auth-int", algorithm=SHA-256, nonce="7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v""#))
        var a3 = DigestAuthenticator(credentials: HTTPCredentials(username: "Mufasa", password: "Circle of Life"),
                                     cnonce: { "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ" })
        let p3 = digestParameters(a3.authorization(for: sha, method: "GET", uri: "/dir/index.html", body: Data()))
        #expect(p3["response"] == "8bdf6f15638e260831e905028de5450562816d093c9bfc5c13d3a46adcdde940")
        #expect(p3["qop"] == "auth-int" && p3["algorithm"] == "SHA-256")
    }

    @Test func prefersAuthWhenBothAreOfferedAndIgnoresBodyThen() throws {
        let challenge = try #require(DigestChallenge.parse(#"Digest realm="r", nonce="n", qop="auth-int, auth""#))
        var a1 = DigestAuthenticator(credentials: HTTPCredentials(username: "u", password: "p"), cnonce: { "c" })
        var a2 = DigestAuthenticator(credentials: HTTPCredentials(username: "u", password: "p"), cnonce: { "c" })
        let withBody = digestParameters(a1.authorization(for: challenge, method: "POST", uri: "/x", body: Data("payload".utf8)))
        let without = digestParameters(a2.authorization(for: challenge, method: "POST", uri: "/x"))
        #expect(withBody["qop"] == "auth")
        #expect(withBody["response"] == without["response"])
    }

    @Test func unsupportedQopFallsBackToLegacyResponse() throws {
        let challenge = try #require(DigestChallenge.parse(#"Digest realm="r", nonce="xyz", qop="auth-conf""#))
        var auth = DigestAuthenticator(credentials: HTTPCredentials(username: "u", password: "p"))
        let p = digestParameters(auth.authorization(for: challenge, method: "GET", uri: "/"))
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(p["qop"] == nil && p["nc"] == nil && p["cnonce"] == nil)
        #expect(p["response"] == md5(md5("u:r:p") + ":xyz:" + md5("GET:/")))
    }

    @Test func basicHeader() {
        #expect(BasicAuth.header(HTTPCredentials(username: "Aladdin", password: "open sesame")) == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }
}

/// FIPS 180-4 / RFC 3174 SHA-1 vectors for the swift-crypto helper the ONVIF WS-UsernameToken digest uses (W4
/// review: replaced CameraAdapters' hand-written SHA-1).
@Suite struct HashesTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    @Test func sha1Vectors() {
        #expect(hex(Hashes.sha1(Data())) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(hex(Hashes.sha1(Data("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(hex(Hashes.sha1(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
                == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(hex(Hashes.sha1(Data(repeating: UInt8(ascii: "a"), count: 1_000_000))) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        #expect(Hashes.sha1(Data([0x61, 0x62, 0x63]).dropFirst()) == Hashes.sha1(Data("bc".utf8)), "slices hash their own bytes")
    }
}

@Suite struct RedactTests {
    @Test func stripsUserInfoFromURL() throws {
        let url = try #require(URL(string: "rtsp://admin:s3cr3t@10.0.0.2:554/Streaming/Channels/101"))
        let redacted = Redact.url(url)
        #expect(redacted == "rtsp://10.0.0.2:554/Streaming/Channels/101")
    }

    @Test func masksPasswordLikeQueryItems() throws {
        let url = try #require(URL(string: "http://cam.local/api.cgi?cmd=Login&user=admin&password=hunter2&token=abc123"))
        let redacted = Redact.url(url)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("abc123"))
        #expect(redacted.contains("cmd=Login"))
        #expect(redacted.contains("password=***"))
        #expect(redacted.contains("token=***"))
    }

    @Test func masksSecretsInFreeText() {
        let s = Redact.string("GET /cgi-bin/api.cgi?cmd=Snap&user=admin&password=hunter2&pwd=xyz token=abc rtsp://bob:pw@host/x")
        #expect(!s.contains("hunter2"))
        #expect(!s.contains("xyz"))
        #expect(!s.contains("abc"))
        #expect(!s.contains("bob:pw"))
        #expect(s.contains("password=***"))
        #expect(s.contains("pwd=***"))
        #expect(s.contains("token=***"))
        #expect(s.contains("cmd=Snap"))
    }
}

@Suite struct RedactEdgeCaseTests {
    @Test func passwordContainingAtSignDoesNotLeak() {
        let s = Redact.string("connecting to rtsp://admin:pa@ss@10.0.0.2/stream")
        #expect(!s.contains("pa@ss") && !s.contains("ss@10"))
        #expect(s.contains("rtsp://***@10.0.0.2/stream"))
    }

    @Test func nestedAssignmentsAreMasked() {
        #expect(Redact.string("GET /a?x=b?password=hunter2&c=d") == "GET /a?x=b?password=***&c=d")
        #expect(Redact.string("token=abc== user=bob") == "token=*** user=bob")
        #expect(Redact.string("oauth_token=q;pwd=w,apikey='z z'") == "oauth_token=***;pwd=***,apikey='***'")
        #expect(Redact.string("login password=\"a b\" ok; secret=\"unterminated\nnext") == "login password=\"***\" ok; secret=\"***\nnext")
        #expect(Redact.string("a=b=c") == "a=b=c")
        #expect(Redact.string("=password=x") == "=password=***")
    }

    @Test func passwordContainingWhitespaceDoesNotLeak() {
        #expect(Redact.string("rtsp://user:pa ss@host/x") == "rtsp://***@host/x")
        #expect(Redact.string("open rtsp://user:p\tw d@10.0.0.2:554/s failed") == "open rtsp://***@10.0.0.2:554/s failed")
        // User info never spans lines (LF, CRLF, U+2028).
        #expect(Redact.string("rtsp://cam\nmail admin@example.com") == "rtsp://cam\nmail admin@example.com")
        #expect(Redact.string("rtsp://cam\r\nmail admin@example.com") == "rtsp://cam\r\nmail admin@example.com")
        #expect(Redact.string("rtsp://cam\u{2028}mail admin@example.com") == "rtsp://cam\u{2028}mail admin@example.com")
    }

    @Test func urlQueryMaskingHandlesOddQueriesAndFragments() throws {
        let encodedName = try #require(URL(string: "http://cam/api?cmd=Login&pass%77ord=hunter2&x=%25zz#frag?token=t"))
        #expect(Redact.url(encodedName) == "http://cam/api?cmd=Login&pass%77ord=***&x=%25zz#frag?token=***")
        let fragmentOnly = try #require(URL(string: "http://u:p@cam/a#b?password=c"))
        #expect(Redact.url(fragmentOnly) == "http://cam/a#b?password=***")
        let nested = try #require(URL(string: "http://cam/p?x=a?password=hunter2&y=1"))
        #expect(Redact.url(nested) == "http://cam/p?x=a?password=***&y=1")
        let pathAssignment = try #require(URL(string: "http://cam/token=abc/x"))
        #expect(Redact.url(pathAssignment) == "http://cam/token=***/x")   // a secret in the path ends at the next `/`
        let noQuery = try #require(URL(string: "rtsp://admin:pw@10.0.0.2/h264Preview_01_main"))
        #expect(Redact.url(noQuery) == "rtsp://10.0.0.2/h264Preview_01_main")
        let emptySegments = try #require(URL(string: "http://cam/?&token&=x&token=&a=b=c"))
        #expect(Redact.url(emptySegments) == "http://cam/?&token&=x&token=***&a=b=c")
    }

    /// Odd URLs (as `URL(string:)` accepts them) never trap and never leak the password.
    @Test func fuzzedURLsNeverTrapOrLeak() {
        var rng = SeededGenerator(state: 42)
        let alphabet = Array("aZ09%&=#?/@:;+,!$'()*[]{}|\\^`<>\" ~é")
        var checked = 0
        for _ in 0..<3_000 {
            let noise = String((0..<Int.random(in: 0..<16, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            guard let url = URL(string: "rtsp://admin:SECRETpw@cam.local:554/p" + noise + "?password=SECRETq&" + noise) else { continue }
            let redacted = Redact.url(url)
            #expect(!redacted.contains("SECRET"), "\(url.absoluteString) -> \(redacted)")
            checked += 1
        }
        #expect(checked > 100)
    }

    /// Review finding (W4 BridgeSupport): `Redact.url` kept the path as is, so credentials carried in the path (the
    /// common Xiongmai/XMEye generic-RTSP URL, `;pwd=` snapshot URLs) reached the logs that RTSPClient writes at info.
    @Test func pathCredentialsAreMasked() throws {
        let xiongmai = try #require(URL(string: "rtsp://192.168.1.10:554/user=admin&password=S3cretPW&channel=1&stream=0.sdp?"))
        #expect(Redact.url(xiongmai) == "rtsp://192.168.1.10:554/user=admin&password=***&channel=1&stream=0.sdp?")
        let underscored = try #require(URL(string: "rtsp://192.168.1.10:554/user=admin_password=S3cretPW_channel=1_stream=0.sdp"))
        #expect(!Redact.url(underscored).contains("S3cretPW"))
        #expect(Redact.url(underscored).hasPrefix("rtsp://192.168.1.10:554/user=admin_password=***"))
        let semicolon = try #require(URL(string: "http://192.168.1.10/snapshot.cgi;pwd=S3cretPW"))
        #expect(Redact.url(semicolon) == "http://192.168.1.10/snapshot.cgi;pwd=***")
        let both = try #require(URL(string: "rtsp://admin:pw@cam:554/user=admin&password=S3cretPW?pwd=S3cretQ&channel=1#f;token=S3cretR"))
        #expect(Redact.url(both) == "rtsp://cam:554/user=admin&password=***?pwd=***&channel=1#f;token=***")
        let segments = try #require(URL(string: "http://cam/auth=S3cretPW/snap.jpg?size=1"))
        #expect(Redact.url(segments) == "http://cam/auth=***/snap.jpg?size=1")
        // Paths without secrets are kept.
        let plain = try #require(URL(string: "rtsp://cam:554/channel=1&stream=0.sdp"))
        #expect(Redact.url(plain) == "rtsp://cam:554/channel=1&stream=0.sdp")
        // `Redact.string` already masked them; both agree now.
        #expect(Redact.string(xiongmai.absoluteString) == Redact.url(xiongmai))
    }

    @Test func masksPrefixedSecretNames() throws {
        let s = Redact.string("user_password=hunter2&adminPwd=abc&access_token=xyz&cmd=Login")
        #expect(!s.contains("hunter2") && !s.contains("abc") && !s.contains("xyz"))
        #expect(s.contains("cmd=Login"))
        let url = try #require(URL(string: "http://cam/api.cgi?cmd=Login&user_password=hunter2&channel=1"))
        let redacted = Redact.url(url)
        #expect(!redacted.contains("hunter2") && redacted.contains("channel=1"))
    }
}

/// Review finding (W4 BridgeSupport, round 4): the clients moved from Digest to Basic whenever a 401 asked for it.
@Suite struct BasicDowngradeGuardTests {
    private final class Entries: LogSink {
        let entries = Mutex<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.withLock { $0.append(entry) } }
    }

    @Test func basicIsRefusedOnlyForHostsThatAskedForDigest() {
        let router = LogRouter()
        let sink = Entries()
        router.addSink(sink)
        let log = Log(category: "test", router: router)
        let guardian = BasicDowngradeGuard()
        let basicHost = "http:basic-\(UUID().uuidString):80"   // unique: the "uses Basic" note is process-wide
        #expect(guardian.mayAnswerBasic(from: basicHost, log: log))
        #expect(guardian.mayAnswerBasic(from: basicHost, log: log))
        guardian.digestRequested(by: "rtsp:cam:554")
        #expect(!guardian.mayAnswerBasic(from: "rtsp:cam:554", log: log))
        #expect(!guardian.mayAnswerBasic(from: "rtsp:cam:554", log: log))
        #expect(guardian.mayAnswerBasic(from: "rtsp:cam:8554", log: log), "per host and port")
        #expect(BasicDowngradeGuard().mayAnswerBasic(from: "rtsp:cam:554", log: log), "per guard: never shared between cameras")

        let entries = sink.entries.withLock { $0 }
        #expect(entries.filter { $0.level == .warning }.map(\.message).count == 1, "one warning per refused host")
        #expect(entries.contains { $0.level == .warning && $0.message.hasPrefix("rtsp:cam:554 asked for Basic authentication after using Digest") })
        #expect(entries.filter { $0.level == .notice && $0.message.hasPrefix(basicHost) }.count == 1, "Basic use is noted once per host")
    }
}
