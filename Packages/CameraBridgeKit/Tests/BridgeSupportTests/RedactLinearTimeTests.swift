import Foundation
import Testing
@testable import BridgeSupport

/// Review finding (W4 BridgeSupport, round 4): `Redact.string` found user info with the backtracking regex
/// `([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\/\v]*@`, which rescans every run of scheme characters that has no `://` from each
/// of its start positions. That is quadratic time (about 5 s for 16k letters, hours for 1 MiB) on camera-supplied text
/// such as an SDP codec name or a SOAP fault, which pinned the main actor (Add Camera, Check Connection) or a camera's
/// ingest loop.
@Suite(.timeLimit(.minutes(1))) struct RedactLinearTimeTests {
    static let size = 1 << 20
    #if DEBUG
    /// Unoptimized build, other suites running in parallel: 0.1–0.5 s each when alone here (1.4 s at most under load).
    static let limit: Duration = .seconds(5)
    #else
    static let limit: Duration = .seconds(1)
    #endif

    /// About 1 MiB each: long runs of the characters each pattern of `Redact.string` scans.
    static let inputs: [(name: String, text: String)] = {
        var rng = SeededGenerator(state: 0xBADC0DE)
        let hexDigits = Array("0123456789abcdef")
        let hex = String((0..<size).map { _ in hexDigits[Int.random(in: 0..<16, using: &rng)] })
        return [
            ("letters", String(repeating: "a", count: size)),
            ("hex", hex),
            ("scheme characters", String(repeating: "Ab1+.-", count: size / 6)),
            ("schemes without user info", String(repeating: "abcdefgh://", count: size / 11)),
            ("unterminated user info", "rtsp://" + String(repeating: "u", count: size)),
            ("user info runs", String(repeating: "a://b@", count: size / 6)),
            ("unterminated JSON value", "\"password\": \"" + String(repeating: "a", count: size)),
            ("assignments", String(repeating: "a=", count: size / 2)),
            ("codec error", "unsupported video (" + String(repeating: "H", count: size) + ")"),
        ]
    }()

    @Test func megabyteOfCameraTextIsRedactedQuickly() async throws {
        for (name, text) in Self.inputs {
            let started = ContinuousClock.now
            // The regex needed hours for the letters: give up (and fail) long before.
            let redacted = try await withDeadline(.seconds(20)) { Redact.string(text) }
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < Self.limit, "\(name): \(elapsed)")
            #expect(redacted.count >= text.count / 2, "\(name)")
        }
        #expect(Redact.string("rtsp://admin:pw@cam/" + String(repeating: "a", count: Self.size)).hasPrefix("rtsp://***@cam/aaa"))
    }

    /// `Redact.string` as it was (user-info regex, then assignments, then JSON members): the oracle for short texts.
    private static func regexRedact(_ s: String) -> String {
        let userInfo = /([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\/\v]*@/
        var result = s.replacing(userInfo) { match in "\(match.1)***@" }
        result = Redact.maskAssignments(result)
        let json = /("([A-Za-z0-9_.\-]+)"\s*:\s*)"(?:[^"\\]|\\.)*"/
        return result.replacing(json) { match in
            Redact.isSecret(String(match.2)) ? "\(match.1)\"***\"" : String(match.0)
        }
    }

    /// The linear scan masks exactly what the regex masked (scheme start, user info to the last `@` before `/` or a line
    /// break, matches after a previous match's end only).
    @Test func masksExactlyWhatTheRegexMasked() {
        var rng = SeededGenerator(state: 7)
        let pieces = ["a", "Z", "q", "0", "9", "+", ".", "-", "_", ":", "/", "//", "://", "@", " ", "\t", "\n", "\r\n", "\u{2028}",
                      "\u{85}", "\u{0B}", "é", "e\u{301}", "/\u{301}", "😀", "rtsp", "http://", "1x://", "+s://", "u:p@", "?", "=",
                      "password=", "\"", "\"pw\":\"", "x\u{301}://"]
        var checked = 0
        for _ in 0..<5_000 {
            let text = (0..<Int.random(in: 0..<14, using: &rng)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
            let expected = Self.regexRedact(text)
            #expect(Redact.string(text) == expected, "\(text.debugDescription)")
            checked += 1
        }
        #expect(checked == 5_000)
        // Hand-picked cases.
        for text in ["xrtsp://a@b", "1abc://u:p@h/x", "-+a.b://u@h", "a://b@c://d@e/f", "rtsp://a@b\nhttp://c@d", "://u@h", "9://u@h",
                     "rtsp://a:b@c/d@e", "rtsp://a@b@c", "a.://@", "rtsp:/x@y", "rtsp://a\r\nb@c"] {
            #expect(Redact.string(text) == Self.regexRedact(text), "\(text.debugDescription)")
        }
    }
}

/// Same finding: camera-supplied text reached errors and logs unbounded and with its line breaks (an SDP codec name, a
/// SOAP fault, a transport). `Redact.cameraText` is the one place that cuts it and replaces control characters.
@Suite struct RedactCameraTextTests {
    @Test func shortPrintableTextIsKept() {
        #expect(Redact.cameraText("JPEG") == "JPEG")
        #expect(Redact.cameraText("") == "")
        #expect(Redact.cameraText("H.264 Main@L4 🎥 Kamera-Ü") == "H.264 Main@L4 🎥 Kamera-Ü")
        #expect(Redact.cameraText(String(repeating: "a", count: 200)) == String(repeating: "a", count: 200))
    }

    @Test func longTextIsCutToTheLimit() {
        let cut = Redact.cameraText(String(repeating: "a", count: 201))
        #expect(cut.count == 200 && cut.hasSuffix("a…"))
        #expect(Redact.cameraText("abcdef", limit: 3) == "ab…")
        #expect(Redact.cameraText("abc", limit: 3) == "abc")
        #expect(Redact.cameraText("abcdef", limit: 0) == "…")
        #expect(Redact.cameraText(Substring(String(repeating: "x", count: 1 << 22))).count == Redact.cameraTextLimit)
    }

    @Test func controlFormatAndSeparatorCharactersBecomeSpaces() {
        #expect(Redact.cameraText("a\nb\r\nc\td\u{1B}[2Je\u{7}f\u{0}g\u{85}h\u{2028}i\u{2029}j\u{202E}k\u{FEFF}l\u{7F}m")
                == "a b c d [2Je f g h i j k l m")
        #expect(Redact.cameraText("line\nforged: entry", limit: 7) == "line f…")
    }
}
