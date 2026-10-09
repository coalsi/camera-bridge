import Foundation
import Testing
@testable import HAP

@Suite struct HAPJSONTests {
    @Test func parsesScalarsKeepingIntegerAndBoolDistinct() throws {
        let json = try HAPJSON.parse(Data(#"{"a":1,"b":true,"c":1.5,"d":"x\"\u00e9\n","e":null,"f":[1,false],"g":-7,"h":18446744073709551615,"i":1e3}"#.utf8))
        #expect(json["a"] == .int(1))
        #expect(json["b"] == .bool(true))
        #expect(json["c"] == .double(1.5))
        #expect(json["d"] == .string("x\"é\n"))
        #expect(json["e"] == .null)
        #expect(json["f"] == [1, false])
        #expect(json["g"] == .int(-7))
        #expect(json["h"] == .uint(UInt64.max))
        #expect(json["i"]?.doubleValue == 1000)
        #expect(json["missing"] == nil)
    }

    @Test func parsesSurrogatePairs() throws {
        #expect(try HAPJSON.parse(Data(#""\ud83d\ude00""#.utf8)) == .string("😀"))
    }

    @Test func rejectsMalformedInput() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"abc", "01x", "{\"a\":1}x", "[\"\\ud800\"]", "nan", "--1", "1.", "\"\u{01}\""] {
            #expect(throws: HAPJSONError.self, "\(text)") { try HAPJSON.parse(Data(text.utf8)) }
        }
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: HAPJSONError.self) { try HAPJSON.parse(Data(deep.utf8)) }
    }

    @Test func serializesDeterministically() {
        let value: HAPJSON = ["b": 1, "a": ["x": .double(0.5), "y": .null], "c": "q\"\\\n\u{01}", "d": .double(100_000), "e": .bool(false)]
        #expect(String(decoding: value.serialized(), as: UTF8.self)
            == #"{"b":1,"a":{"x":0.5,"y":null},"c":"q\"\\\n\u0001","d":100000,"e":false}"#)
        #expect(String(decoding: value.serialized(sortedKeys: true), as: UTF8.self)
            == #"{"a":{"x":0.5,"y":null},"b":1,"c":"q\"\\\n\u0001","d":100000,"e":false}"#)
        #expect(String(decoding: HAPJSON.double(0.0001).serialized(), as: UTF8.self) == "0.0001")
        #expect(String(decoding: HAPJSON.double(.nan).serialized(), as: UTF8.self) == "null")
    }

    @Test func roundTrips() throws {
        let value: HAPJSON = ["characteristics": [["aid": 1, "iid": 10, "value": "AQID", "ev": true]], "pid": 12_345_678_901]
        #expect(try HAPJSON.parse(value.serialized()) == value)
    }

    @Test func objectEqualityIgnoresKeyOrder() {
        let a: HAPJSON = ["x": 1, "y": 2]
        let b: HAPJSON = ["y": 2, "x": 1]
        #expect(a == b)
        #expect(a != ["x": 1])
    }
}
