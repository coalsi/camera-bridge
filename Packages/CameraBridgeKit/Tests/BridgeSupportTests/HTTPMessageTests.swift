import Foundation
import Testing
@testable import BridgeSupport

@Suite struct HTTPHeadersTests {
    @Test func caseInsensitiveLookupAndReplace() {
        var headers = HTTPHeaders([("Content-Type", "application/hap+json"), ("X-Dup", "1")])
        headers.add("x-dup", "2")
        #expect(headers["content-type"] == "application/hap+json")
        #expect(headers["X-DUP"] == "1")
        headers["X-Dup"] = "3"
        #expect(Array(headers).filter { $0.name.lowercased() == "x-dup" }.map(\.value) == ["3"])
        headers["x-dup"] = nil
        #expect(headers["X-Dup"] == nil)
        #expect(Array(headers).count == 1)
    }

    @Test func equalityIgnoresNameCase() {
        #expect(HTTPHeaders([("A", "1")]) == HTTPHeaders([("a", "1")]))
        #expect(HTTPHeaders([("A", "1")]) != HTTPHeaders([("A", "2")]))
    }
}

@Suite struct HTTPRequestParserTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesSimpleGetWithQuery() throws {
        var parser = HTTPRequestParser()
        let out = try parser.feed(bytes("GET /characteristics?id=1.9,2.14&meta=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(out.count == 1)
        let head = try #require(out.first).head
        #expect(head.method == "GET")
        #expect(head.target == "/characteristics?id=1.9,2.14&meta=1")
        #expect(head.version == "HTTP/1.1")
        #expect(head.path == "/characteristics")
        #expect(head.queryItems == [URLQueryItem(name: "id", value: "1.9,2.14"), URLQueryItem(name: "meta", value: "1")])
        #expect(head.headers["host"] == "x")
        #expect(out[0].body.isEmpty)
    }

    @Test func parsesPipelinedRequests() throws {
        var parser = HTTPRequestParser()
        let wire = "PUT /characteristics HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
            + "POST /pair-verify HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 3\r\n\r\n\u{06}\u{01}\u{01}"
        let out = try parser.feed(bytes(wire))
        #expect(out.map(\.head.method) == ["PUT", "POST"])
        #expect(out[0].body == bytes("{\"a\":1}"))
        #expect(out[1].body == Data([6, 1, 1]))
    }

    @Test func handlesRequestsSplitAcrossFeeds() throws {
        var parser = HTTPRequestParser()
        let wire = bytes("POST /identify HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdGET / HTTP/1.1\r\n\r\n")
        var results: [(head: HTTPRequestHead, body: Data)] = []
        for byte in wire { results += try parser.feed(Data([byte])) }
        #expect(results.count == 2)
        #expect(results[0].body == bytes("abcd"))
        #expect(results[1].head.path == "/")
    }

    /// Review finding (W4 round 4): the parser searched the whole buffer for the end of the head, and parsed the head
    /// again, on every read until the request was complete: a peer trickling a large head and body one byte per read
    /// cost a server (the webhook, before any token check) work in proportion to the bytes times the reads. The work
    /// now grows with the bytes.
    @Test func tricklingARequestCostsLinearWork() throws {
        var parser = HTTPRequestParser(maxBodySize: 64 * 1024)
        let headers = String(repeating: "a: b\r\n", count: 1_000)
        let body = Data(repeating: 0x2A, count: 1_024)
        let wire = Data("POST /x HTTP/1.1\r\nContent-Length: \(body.count)\r\n\(headers)\r\n".utf8) + body
        var requests: [(head: HTTPRequestHead, body: Data)] = []
        for byte in wire { requests += try parser.feed(Data([byte])) }
        #expect(requests.count == 1)
        #expect(requests.first?.body == body)
        #expect(requests.first?.head.headers.values(for: "a").count == 1_000)
        #expect(parser.bytesExamined <= 4 * wire.count, "\(parser.bytesExamined) bytes examined for a \(wire.count)-byte request")
    }

    /// Pipelined requests in one read are each examined once (no copy of the rest of the buffer per request).
    @Test func pipelinedRequestsCostLinearWork() throws {
        var parser = HTTPRequestParser()
        let one = Data("GET /a HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let wire = (0..<500).reduce(into: Data()) { data, _ in data.append(one) }
        let requests = try parser.feed(wire)
        #expect(requests.count == 500)
        #expect(parser.bytesExamined <= 4 * wire.count)
        #expect(try parser.feed(one).count == 1)
    }

    /// A server any peer reaches before authenticating (the webhook) limits the head's size and its header lines.
    @Test func headLimitsAreConfigurable() throws {
        func parser() -> HTTPRequestParser { HTTPRequestParser(maxBodySize: 1024, maxHeadSize: 256, maxHeaderCount: 4) }
        var small = parser()
        #expect(try small.feed(Data("GET / HTTP/1.1\r\na: 1\r\nb: 2\r\nc: 3\r\nd: 4\r\n\r\n".utf8)).count == 1)
        var many = parser()
        #expect(throws: HTTPParseError.headTooLarge) { try many.feed(Data("GET / HTTP/1.1\r\na: 1\r\nb: 2\r\nc: 3\r\nd: 4\r\ne: 5\r\n\r\n".utf8)) }
        var long = parser()
        #expect(throws: HTTPParseError.headTooLarge) { try long.feed(Data(("GET / HTTP/1.1\r\na: " + String(repeating: "x", count: 300)).utf8)) }
        var complete = parser()
        #expect(throws: HTTPParseError.headTooLarge) {
            try complete.feed(Data(("GET / HTTP/1.1\r\na: " + String(repeating: "x", count: 300) + "\r\n\r\n").utf8))
        }
    }

    /// The head of a request whose body is still to come is available (a server can refuse it before reading the body).
    @Test func pendingHeadIsAvailableBeforeTheBody() throws {
        var parser = HTTPRequestParser()
        #expect(try parser.feed(Data("POST /x HTTP/1.1\r\nAuthorization: Bearer t\r\nContent-Length: 4\r\n\r\nab".utf8)).isEmpty)
        #expect(parser.pendingHead?.path == "/x")
        #expect(parser.pendingHead?.headers["authorization"] == "Bearer t")
        let out = try parser.feed(Data("cd".utf8))
        #expect(out.first?.body == Data("abcd".utf8))
        #expect(parser.pendingHead == nil)
        var malformed = HTTPRequestParser()
        #expect(throws: HTTPParseError.malformedRequestLine) { try malformed.feed(Data("GARBAGE\r\nContent-Length: 9\r\n\r\n".utf8)) }
    }

    @Test func rejectsOversizeBody() {
        var parser = HTTPRequestParser(maxBodySize: 16)
        #expect(throws: HTTPParseError.bodyTooLarge) {
            try parser.feed(bytes("PUT / HTTP/1.1\r\nContent-Length: 17\r\n\r\n"))
        }
    }

    @Test func rejectsOversizeHead() {
        var parser = HTTPRequestParser()
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000)
        #expect(throws: HTTPParseError.headTooLarge) { try parser.feed(bytes(huge)) }
    }

    @Test func rejectsMalformedInput() {
        var p1 = HTTPRequestParser()
        #expect(throws: HTTPParseError.malformedRequestLine) { try p1.feed(bytes("GARBAGE\r\n\r\n")) }
        var p2 = HTTPRequestParser()
        #expect(throws: HTTPParseError.malformedHeader) { try p2.feed(bytes("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n")) }
        var p3 = HTTPRequestParser()
        #expect(throws: HTTPParseError.invalidContentLength) { try p3.feed(bytes("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) }
        var p4 = HTTPRequestParser()
        #expect(throws: HTTPParseError.unsupportedTransferEncoding) {
            try p4.feed(bytes("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
        }
    }
}

@Suite struct HTTPResponseParserTests {
    @Test func parsesHAPEventAndNormalResponse() throws {
        var parser = HTTPResponseParser()
        let wire = "EVENT/1.0 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: 2\r\n\r\n{}"
            + "HTTP/1.1 204 No Content\r\n\r\n"
        let out = try parser.feed(Data(wire.utf8))
        #expect(out.count == 2)
        #expect(out[0].head.version == "EVENT/1.0")
        #expect(out[0].head.status == 200)
        #expect(out[0].head.reason == "OK")
        #expect(out[0].body == Data("{}".utf8))
        #expect(out[1].head.status == 204)
        #expect(out[1].body.isEmpty)
    }
}

@Suite struct HTTPSerializerTests {
    @Test func serializesResponseWithContentLength() {
        let data = HTTPSerializer.response(status: 200, headers: HTTPHeaders([("Content-Type", "application/hap+json")]), body: Data("{}".utf8))
        #expect(String(decoding: data, as: UTF8.self) == "HTTP/1.1 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: 2\r\n\r\n{}")
    }

    @Test func serializesNoContentWithoutLength() {
        let data = HTTPSerializer.response(status: 204, headers: HTTPHeaders(), body: Data())
        #expect(String(decoding: data, as: UTF8.self) == "HTTP/1.1 204 No Content\r\n\r\n")
    }

    @Test func serializesCustomVersionAndReason() {
        let data = HTTPSerializer.response(status: 470, reason: "Connection Authorization Required", headers: HTTPHeaders(), body: Data(), version: "HTTP/1.1")
        #expect(String(decoding: data, as: UTF8.self) == "HTTP/1.1 470 Connection Authorization Required\r\nContent-Length: 0\r\n\r\n")
        let event = HTTPSerializer.response(status: 200, headers: HTTPHeaders(), body: Data("x".utf8), version: "EVENT/1.0")
        #expect(String(decoding: event, as: UTF8.self).hasPrefix("EVENT/1.0 200 OK\r\n"))
    }

    @Test func serializesRequestAndParsesItBack() throws {
        let head = HTTPRequestHead(method: "POST", target: "/pair-setup", version: "HTTP/1.1",
                                   headers: HTTPHeaders([("Content-Type", "application/pairing+tlv8")]))
        let wire = HTTPSerializer.request(head, body: Data([0, 1, 0, 6, 1, 1]))
        #expect(String(decoding: wire.prefix(22), as: UTF8.self) == "POST /pair-setup HTTP/")
        var parser = HTTPRequestParser()
        let out = try parser.feed(wire)
        #expect(out.count == 1)
        #expect(out[0].head.method == "POST")
        #expect(out[0].head.headers["content-length"] == "6")
        #expect(out[0].body == Data([0, 1, 0, 6, 1, 1]))
    }
}

/// Deterministic generator for reproducible fuzzing (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HTTPRequestTargetTests {
    private func head(_ target: String) throws -> HTTPRequestHead {
        var parser = HTTPRequestParser()
        let out = try parser.feed(Data("GET \(target) HTTP/1.1\r\n\r\n".utf8))
        return try #require(out.first).head
    }

    /// Targets the parser accepts from any LAN peer; `URLComponents.percentEncodedQuery` used to `fatalError` on them.
    @Test func malformedQueriesDecodeLeniently() throws {
        #expect(try head("/a?x=%zz").queryItems == [URLQueryItem(name: "x", value: "%zz")])
        #expect(try head("/a?x=%").queryItems == [URLQueryItem(name: "x", value: "%")])
        #expect(try head("/a?x=%4").queryItems == [URLQueryItem(name: "x", value: "%4")])
        #expect(try head("/a?x=\"q\"").queryItems == [URLQueryItem(name: "x", value: "\"q\"")])
        #expect(try head("/a?x=<>").queryItems == [URLQueryItem(name: "x", value: "<>")])
        #expect(try head("/a?%%%").queryItems == [URLQueryItem(name: "%%%", value: nil)])
        #expect(try head("/a?x=%C3").queryItems == [URLQueryItem(name: "x", value: "\u{FFFD}")])   // not UTF-8
        #expect(try head("/a?x=%41%zz%42").queryItems == [URLQueryItem(name: "x", value: "A%zzB")])
    }

    @Test func fragmentIsNotPartOfPathOrQuery() throws {
        let withQuery = try head("/a?x=a#b")
        #expect(withQuery.path == "/a")
        #expect(withQuery.queryItems == [URLQueryItem(name: "x", value: "a")])
        let withoutQuery = try head("/a#b?c=d")
        #expect(withoutQuery.path == "/a")
        #expect(withoutQuery.queryItems.isEmpty)
    }

    /// On well-formed queries the result is exactly `URLComponents.queryItems`.
    @Test func matchesURLComponentsOnValidQueries() throws {
        let queries = ["", "a", "a=", "a&&b", "=v", "a=b=c", "a+b=c+d", "%20=%41", "a=%E2%82%AC", "&", "a&",
                       "id=1.9,2.14&meta=1&perms=1&type=1&ev=1", "x=%2B", "x;y=1", "x=%25zz"]
        for query in queries {
            var components = URLComponents()
            components.percentEncodedQuery = query
            let expected = components.queryItems ?? []
            #expect(try head("/p?" + query).queryItems == expected, "query \(query.debugDescription)")
        }
        #expect(try head("/p").queryItems.isEmpty)
    }

    /// Random printable targets (what `HTTPRequestParser` lets through) never trap.
    @Test func fuzzedTargetsNeverTrap() throws {
        var rng = SeededGenerator(state: 0xC0FFEE)
        let alphabet = Array("abcXYZ019%?&=#/+;:@!$'()*,[]{}|\\^`<>\"~\u{7F}é€")
        for _ in 0..<5_000 {
            let length = Int.random(in: 0..<24, using: &rng)
            let target = "/" + String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            let parsed = HTTPRequestHead(method: "GET", target: target)
            _ = parsed.queryItems
            #expect(!parsed.path.contains("?") && !parsed.path.contains("#"))
        }
    }
}
