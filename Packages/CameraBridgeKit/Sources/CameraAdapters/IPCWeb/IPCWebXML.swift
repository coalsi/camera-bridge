import Foundation

/// Reading and editing the IP camera web API's XML as the camera wrote it. A write sends an element back exactly as it was read, with
/// only the changed attribute values replaced (the camera's attributes run over several lines, and it may have ones this code does not
/// know), so this works on the text itself instead of parsing and serializing it again. Scans Unicode scalars: tolerant of what
/// `XMLParser` would refuse, linear in the text's length.
enum IPCWebXML {
    /// The first `name` element in `text`, whole (its start tag to its end tag, or the empty-element tag) and as it is in the text.
    /// Elements of the same name nested inside it are not expected (the first end tag closes it).
    static func element(_ name: String, in text: String) -> Substring? {
        let scalars = text.unicodeScalars
        var search = scalars.startIndex
        while let open = scalars[search...].firstRange(of: ("<" + name).unicodeScalars) {
            search = open.upperBound
            guard open.upperBound < scalars.endIndex else { return nil }
            let next = scalars[open.upperBound]
            guard next == ">" || next == "/" || isSpace(next) else { continue }
            guard let close = tagEnd(scalars, from: open.upperBound) else { return nil }
            if scalars[scalars.index(before: close)] == "/" { return text[open.lowerBound..<scalars.index(after: close)] }
            var scan = scalars.index(after: close)
            while let end = scalars[scan...].firstRange(of: ("</" + name).unicodeScalars) {
                var after = end.upperBound
                while after < scalars.endIndex, isSpace(scalars[after]) { after = scalars.index(after: after) }
                if after < scalars.endIndex, scalars[after] == ">" { return text[open.lowerBound..<scalars.index(after: after)] }
                scan = end.upperBound
            }
            return nil
        }
        return nil
    }

    /// The value of the attribute `name` on `element`'s start tag (not on its children), unescaped; nil when it has none.
    static func attribute(_ name: String, of element: some StringProtocol) -> String? {
        let text = String(element)
        return attributes(of: text).first { $0.name == name }.map { unescape(String(text[$0.value])) }
    }

    /// `element` with each named attribute's value on its start tag replaced (escaped), every other character as it was. nil when the
    /// start tag lacks one of them.
    static func replacingAttributes(_ values: [String: String], in element: some StringProtocol) -> String? {
        var text = String(element)
        let found = attributes(of: text)
        var ranges: [(Range<String.Index>, String)] = []
        for (name, value) in values {
            guard let attribute = found.first(where: { $0.name == name }) else { return nil }
            ranges.append((attribute.value, escape(value)))
        }
        // From the end, so earlier ranges stay valid; scalar by scalar, so nothing around a value is touched.
        for (range, value) in ranges.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            text.unicodeScalars.replaceSubrange(range, with: value.unicodeScalars)
        }
        return text
    }

    /// The attributes of the start tag that opens `text` (names, and where each value sits between its quotes).
    static func attributes(of text: String) -> [(name: String, value: Range<String.Index>)] {
        let scalars = text.unicodeScalars
        guard let open = scalars.firstIndex(of: "<") else { return [] }
        var index = scalars.index(after: open)
        while index < scalars.endIndex, !isSpace(scalars[index]), scalars[index] != ">", scalars[index] != "/" { index = scalars.index(after: index) }
        var result: [(name: String, value: Range<String.Index>)] = []
        while true {
            while index < scalars.endIndex, isSpace(scalars[index]) { index = scalars.index(after: index) }
            guard index < scalars.endIndex, scalars[index] != ">", scalars[index] != "/" else { return result }
            let nameStart = index
            while index < scalars.endIndex, scalars[index] != "=", !isSpace(scalars[index]), scalars[index] != ">" { index = scalars.index(after: index) }
            let name = String(scalars[nameStart..<index])
            while index < scalars.endIndex, isSpace(scalars[index]) { index = scalars.index(after: index) }
            guard index < scalars.endIndex, scalars[index] == "=" else { return result }
            index = scalars.index(after: index)
            while index < scalars.endIndex, isSpace(scalars[index]) { index = scalars.index(after: index) }
            guard index < scalars.endIndex, scalars[index] == "\"" || scalars[index] == "'" else { return result }
            let quote = scalars[index]
            let valueStart = scalars.index(after: index)
            guard let valueEnd = scalars[valueStart...].firstIndex(of: quote) else { return result }
            result.append((name, valueStart..<valueEnd))
            index = scalars.index(after: valueEnd)
        }
    }

    /// An attribute value as XML writes it (`&`, `<`, `>`, both quotes).
    static func escape(_ text: String) -> String {
        XMLTree.escape(text)
    }

    /// The five named entities and numeric character references; anything else is kept as written.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semicolon) <= 10 else {
                out += rest[amp...]
                return out
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            let named = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'"][String(entity)]
            var numeric: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                numeric = UInt32(entity.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                numeric = UInt32(entity.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            }
            if let replacement = named ?? numeric {
                out += replacement
            } else {
                out += rest[amp...semicolon]
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return out + rest
    }

    /// The `>` that ends the tag whose name ends before `from` (quoted `>` skipped).
    private static func tagEnd(_ scalars: String.UnicodeScalarView, from: String.Index) -> String.Index? {
        var quote: Unicode.Scalar?
        var index = from
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }
}
