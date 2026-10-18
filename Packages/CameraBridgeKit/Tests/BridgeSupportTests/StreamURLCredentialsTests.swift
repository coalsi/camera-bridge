import Foundation
import Testing
@testable import BridgeSupport

/// Credentials in a stream URL's query (`?user=…&password=…`, a password `hash=`, a `token=`) are secrets like the password: what is saved
/// and logged is the URL without them, and only the RTSP request line gets them back (`StreamURLCredentials.connectionURL(for:)`).
@Suite struct StreamURLCredentialsTests {
    static let password = "S3cretPW-7781"
    static let hash = "c0ffee00c0ffee00c0ffee00c0ffee00"

    @Test func credentialQueryItemsAreRemovedAndTheRestKeepsItsOrder() throws {
        let url = try #require(URL(string: "rtsp://192.0.2.31:554/stream0?channel=1&user=admin&password=\(Self.password)&stream=0.sdp"))
        #expect(url.hasStreamCredentials)
        #expect(url.removingStreamCredentials.absoluteString == "rtsp://192.0.2.31:554/stream0?channel=1&stream=0.sdp")
        #expect(!url.removingStreamCredentials.hasStreamCredentials)
    }

    @Test(arguments: ["user", "username", "usr", "password", "pwd", "passwd", "hash", "token", "auth", "PassWord", "pass%77ord", "pwdHash",
                      "access_token", "loginuse", "loginpas"])
    func everyCredentialNameIsRemoved(_ name: String) throws {
        let url = try #require(URL(string: "rtsp://192.0.2.31/live?\(name)=\(Self.hash)&profile=main"))
        #expect(url.hasStreamCredentials)
        #expect(url.removingStreamCredentials.absoluteString == "rtsp://192.0.2.31/live?profile=main")
    }

    @Test func aQueryOfOnlyCredentialsLosesItsQuestionMarkAndUserInfoGoesToo() throws {
        let url = try #require(URL(string: "rtsp://admin:\(Self.password)@192.0.2.31:554/stream1?user=admin&hash=\(Self.hash)&token"))
        #expect(url.removingStreamCredentials.absoluteString == "rtsp://192.0.2.31:554/stream1")
    }

    @Test func aURLWithoutQueryCredentialsIsOnlyStrippedOfUserInfo() throws {
        for text in ["rtsp://192.0.2.31:554/stream0", "rtsp://192.0.2.31/cam/realmonitor?channel=1&subtype=0",
                     "rtsp://192.0.2.31/live?userdata=1&hashtag=x", "rtsp://192.0.2.31/live?"] {
            let url = try #require(URL(string: text))
            #expect(!url.hasStreamCredentials, "\(text)")
            #expect(url.removingStreamCredentials == url, "\(text)")
        }
        let withUserInfo = try #require(URL(string: "rtsp://admin:\(Self.password)@192.0.2.31/live?channel=1"))
        #expect(!withUserInfo.hasStreamCredentials, "user info is the camera's username and password, not a query credential")
        #expect(withUserInfo.removingStreamCredentials.absoluteString == "rtsp://192.0.2.31/live?channel=1")
    }

    @Test func theConnectionURLPutsStoredCredentialsBackForTheirOwnAddressOnly() throws {
        let main = try #require(URL(string: "rtsp://192.0.2.31:554/stream0?user=admin&password=\(Self.password)&channel=1"))
        let sub = try #require(URL(string: "rtsp://192.0.2.31:554/stream1?hash=\(Self.hash)"))
        let stored = StreamURLCredentials(main: main, sub: sub)
        #expect(!stored.isEmpty && StreamURLCredentials.none.isEmpty)
        #expect(stored.connectionURL(for: main.removingStreamCredentials) == main)
        #expect(stored.connectionURL(for: sub.removingStreamCredentials) == sub)
        let other = try #require(URL(string: "rtsp://192.0.2.32:554/stream0?channel=1"))
        #expect(stored.connectionURL(for: other) == other, "another address never gets them")
        let own = try #require(URL(string: "rtsp://192.0.2.31:554/stream0?channel=1&password=other"))
        #expect(stored.connectionURL(for: own) == own, "a URL with credentials of its own keeps them")
        #expect(StreamURLCredentials.none.connectionURL(for: main.removingStreamCredentials) == main.removingStreamCredentials)
    }

    /// Some cameras take them in the path instead (XMEye `/user=admin&password=…`, its `_` variant, `;pwd=` segments): the assignments go,
    /// the rest of the segment keeps its order and separators, and a segment left empty goes with its `/`.
    @Test(arguments: [
        ("rtsp://192.0.2.31:554/user=admin&password=\(password)&channel=1&stream=0.sdp?", "rtsp://192.0.2.31:554/channel=1&stream=0.sdp?"),
        ("rtsp://192.0.2.31:554/user=admin_password=\(password)_channel=1_stream=0.sdp", "rtsp://192.0.2.31:554/channel=1_stream=0.sdp"),
        ("rtsp://192.0.2.31:554/user=admin_password=my_\(password)_channel=1_stream=0.sdp", "rtsp://192.0.2.31:554/channel=1_stream=0.sdp"),
        ("rtsp://192.0.2.31:554/channel=1&pass%77ord=\(password)&stream=0.sdp", "rtsp://192.0.2.31:554/channel=1&stream=0.sdp"),
        ("http://192.0.2.31/snapshot.cgi;pwd=\(password)", "http://192.0.2.31/snapshot.cgi"),
        ("rtsp://192.0.2.31/cam/realmonitor;passwd=\(password)?channel=1", "rtsp://192.0.2.31/cam/realmonitor?channel=1"),
        ("rtsp://192.0.2.31/token=\(hash)/live", "rtsp://192.0.2.31/live"),
        ("rtsp://192.0.2.31:554/user=admin&password=\(password)", "rtsp://192.0.2.31:554/"),
        ("rtsp://admin:pw@192.0.2.31:554/user=admin&password=\(password)?hash=\(hash)&channel=1", "rtsp://192.0.2.31:554/?channel=1"),
    ])
    func credentialAssignmentsInThePathAreRemoved(_ url: String, _ saved: String) throws {
        let url = try #require(URL(string: url))
        #expect(url.hasStreamCredentials)
        #expect(url.removingStreamCredentials.absoluteString == saved)
        #expect(!url.removingStreamCredentials.hasStreamCredentials)
        let stored = StreamURLCredentials(main: url.removingUserInfo)
        #expect(stored.connectionURL(for: url.removingStreamCredentials) == url.removingUserInfo, "the stored URL comes back whole")
    }

    @Test func pathsWithoutCredentialAssignmentsAreKept() throws {
        for text in ["rtsp://192.0.2.31:554/channel=1&stream=0.sdp", "rtsp://192.0.2.31/h264Preview_01_main", "rtsp://192.0.2.31/Streaming/Channels/101",
                     "rtsp://192.0.2.31/live_user=1", "rtsp://192.0.2.31/cam/realmonitor;channel=1", "rtsp://192.0.2.31/a//b/", "rtsp://192.0.2.31"] {
            let url = try #require(URL(string: text))
            #expect(!url.hasStreamCredentials, "\(text)")
            #expect(url.removingStreamCredentials == url, "\(text)")
        }
    }

    /// Odd paths (as `URL(string:)` accepts them) never trap, and the saved form never keeps the secret.
    @Test func fuzzedPathsNeverTrapOrKeepTheSecret() {
        var rng = SeededGenerator(state: 7)
        let alphabet = Array("aZ09%&=#?/@:;+,!$'()*[]{}|\\^`<>\" ~é_.-")
        var checked = 0
        for _ in 0..<3_000 {
            func noise() -> String {
                String((0..<Int.random(in: 0..<12, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            }
            let separator = ["&", ";", "/", "_"][Int.random(in: 0..<4, using: &rng)]
            guard let url = URL(string: "rtsp://192.0.2.31:554/p" + noise() + "/user=admin" + separator + "password=SECRETpw" + separator + noise()),
                  !url.absoluteString.contains("?"), !url.absoluteString.contains("#") else { continue }
            let saved = url.removingStreamCredentials.absoluteString
            #expect(!saved.contains("SECRET"), "\(url.absoluteString) -> \(saved)")
            checked += 1
        }
        #expect(checked > 100)
    }

    @Test func logsMaskTheUserNameAndTheHashToo() throws {
        let url = try #require(URL(string: "rtsp://192.0.2.31:554/stream0?user=admin&password=\(Self.password)&hash=\(Self.hash)&channel=1"))
        #expect(Redact.url(url) == "rtsp://192.0.2.31:554/stream0?user=***&password=***&hash=***&channel=1")
        let line = Redact.string("DESCRIBE \(url.absoluteString) failed")
        #expect(!line.contains(Self.password) && !line.contains(Self.hash), "\(line)")
    }
}
