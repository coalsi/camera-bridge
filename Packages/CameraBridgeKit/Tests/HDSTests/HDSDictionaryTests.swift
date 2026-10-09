import Foundation
import Testing
@testable import HDS

@Suite struct HDSDictionaryTests {
    @Test func subscriptKeepsOrderAndReplacesInPlace() {
        var dict = HDSDictionary([("protocol", .string("dataSend")), ("event", .string("data"))])
        dict["protocol"] = .string("control")
        dict["id"] = .int(1)
        #expect(dict.pairs.map(\.0) == ["protocol", "event", "id"])
        #expect(dict["protocol"] == .string("control"))
        dict["event"] = nil
        #expect(dict.pairs.map(\.0) == ["protocol", "id"])
        #expect(Array(dict).count == 2)
        #expect(dict["missing"] == nil)
    }

    /// Encoding order matters on the wire (goldens), so equality is order-sensitive.
    @Test func equalityIsOrderSensitive() {
        let a = HDSDictionary([("a", .int(1)), ("b", .bool(true))])
        let b = HDSDictionary([("b", .bool(true)), ("a", .int(1))])
        #expect(a != b)
        #expect(HDSValue.dictionary(a) != .dictionary(b))
        #expect(a == HDSDictionary([("a", .int(1)), ("b", .bool(true))]))
        #expect(a != HDSDictionary([("a", .int(2)), ("b", .bool(true))]))
        #expect(a != HDSDictionary([("a", .int(1))]))
        #expect(HDSDictionary() == HDSDictionary([]))
    }

    @Test func equalityWithDuplicateKeysComparesEveryPairInOrder() {
        #expect(HDSDictionary([("a", .int(1)), ("a", .int(1))]) != HDSDictionary([("a", .int(1)), ("b", .int(2))]))
        #expect(HDSDictionary([("a", .int(1)), ("a", .int(2))]) != HDSDictionary([("a", .int(2)), ("a", .int(1))]))
        #expect(HDSDictionary([("a", .int(1)), ("a", .int(2))]) == HDSDictionary([("a", .int(1)), ("a", .int(2))]))
        #expect(HDSDictionary([("a", .int(1))]) != HDSDictionary([("a", .int(1)), ("a", .int(1))]))
    }

    /// Duplicate keys only come from a decoder. Like HAP-NodeJS (a JavaScript object), the last value wins; setting
    /// the key leaves one entry, at the first occurrence's position.
    @Test func duplicateKeysReadAsTheLastValue() {
        var dict = HDSDictionary([("id", .int(1)), ("protocol", .string("a")), ("id", .int(2))])
        #expect(dict["id"] == .int(2))
        #expect(dict.count == 3)
        dict["id"] = .int(3)
        #expect(dict.pairs.map(\.0) == ["id", "protocol"])
        #expect(dict["id"] == .int(3))
        var removed = HDSDictionary([("a", .int(1)), ("b", .int(2)), ("a", .int(3))])
        removed["a"] = nil
        #expect(removed == HDSDictionary([("b", .int(2))]))
    }

    @Test func nestedEqualityIsOrderSensitive() {
        let inner1 = HDSValue.dictionary(HDSDictionary([("x", .int(1)), ("y", .int(2))]))
        let inner2 = HDSValue.dictionary(HDSDictionary([("y", .int(2)), ("x", .int(1))]))
        #expect(HDSValue.array([inner1]) != .array([inner2]))
        #expect(HDSValue.array([inner1]) == .array([inner1]))
    }
}
