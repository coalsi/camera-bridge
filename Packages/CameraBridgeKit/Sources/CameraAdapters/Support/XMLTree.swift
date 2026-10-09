import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum XMLTreeError: Error, Equatable, Sendable {
    case malformed(String)
    case tooDeep
}

/// A small, namespace-agnostic XML element tree built with Foundation's `XMLParser`.
///
/// Camera firmwares mix namespaces freely (Hikvision alternates `hikvision.com/ver20` and `isapi.org/ver20`, ONVIF
/// devices use arbitrary prefixes), so lookups match the **local name** case-insensitively and ignore prefixes.
/// The qualified name and namespace URI are kept so a fragment can be echoed back (`serialized()`), e.g. WS-Addressing
/// reference parameters.
struct XMLTree: Sendable, Equatable {
    /// Local name (prefix stripped).
    var name: String
    /// Prefix of the qualified name, if any.
    var prefix: String?
    /// Namespace URI resolved from the in-scope declarations (nil when undeclared).
    var namespaceURI: String?
    /// Attributes by local name (prefixes and `xmlns` declarations removed).
    var attributes: [String: String]
    /// Direct character data, trimmed.
    var text: String
    var children: [XMLTree]

    static let maximumDepth = 128

    // MARK: Parsing

    static func parse(_ data: Data) throws -> XMLTree {
        guard !data.isEmpty else { throw XMLTreeError.malformed("empty document") }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        let ok = parser.parse()
        if let error = builder.error { throw error }
        guard ok, let root = builder.root else {
            throw XMLTreeError.malformed(parser.parserError.map { String(describing: $0) } ?? "no root element")
        }
        return root
    }

    // MARK: Lookup (local names, case-insensitive)

    func matches(_ localName: String) -> Bool {
        name.caseInsensitiveCompare(localName) == .orderedSame
    }

    func child(_ localName: String) -> XMLTree? {
        children.first { $0.matches(localName) }
    }

    func children(_ localName: String) -> [XMLTree] {
        children.filter { $0.matches(localName) }
    }

    /// Follows a path of direct children.
    func element(_ path: String...) -> XMLTree? { element(path: path) }

    func element(path: [String]) -> XMLTree? {
        var node = self
        for component in path {
            guard let next = node.child(component) else { return nil }
            node = next
        }
        return node
    }

    /// Text at a path of direct children (nil when the element is missing).
    func string(_ path: String...) -> String? { element(path: path)?.text }

    /// First descendant (depth-first, pre-order, excluding self) with the local name.
    func firstDescendant(_ localName: String) -> XMLTree? {
        for child in children {
            if child.matches(localName) { return child }
            if let found = child.firstDescendant(localName) { return found }
        }
        return nil
    }

    /// Every descendant (depth-first, pre-order, excluding self) with the local name.
    func descendants(_ localName: String) -> [XMLTree] {
        var result: [XMLTree] = []
        for child in children {
            if child.matches(localName) { result.append(child) }
            result.append(contentsOf: child.descendants(localName))
        }
        return result
    }

    func attribute(_ localName: String) -> String? {
        if let value = attributes[localName] { return value }
        return attributes.first { $0.key.caseInsensitiveCompare(localName) == .orderedSame }?.value
    }

    /// A copy with the text of the element at `path` (direct children, local names) replaced; nil when the path is missing.
    func setting(path: [String], to value: String) -> XMLTree? {
        guard let first = path.first, let index = children.firstIndex(where: { $0.matches(first) }) else { return nil }
        var copy = self
        if path.count == 1 {
            copy.children[index].text = value
            return copy
        }
        guard let updated = children[index].setting(path: Array(path.dropFirst()), to: value) else { return nil }
        copy.children[index] = updated
        return copy
    }

    // MARK: Serialization

    /// Re-serializes this element with its qualified name, declaring its own namespace inline so the fragment is
    /// well-formed out of context. Attributes are written by local name.
    func serialized() -> String {
        let qualified = prefix.map { "\($0):\(name)" } ?? name
        var out = "<\(qualified)"
        if let namespaceURI {
            out += prefix.map { " xmlns:\($0)=\"\(XMLTree.escape(namespaceURI))\"" } ?? " xmlns=\"\(XMLTree.escape(namespaceURI))\""
        }
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            out += " \(key)=\"\(XMLTree.escape(value))\""
        }
        if children.isEmpty && text.isEmpty { return out + "/>" }
        out += ">" + XMLTree.escape(text)
        for child in children { out += child.serialized() }
        return out + "</\(qualified)>"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Builder

    private final class Builder: NSObject, XMLParserDelegate {
        struct Frame {
            var element: XMLTree
            var text: String
            var namespaces: [String: String]
        }
        var stack: [Frame] = []
        var root: XMLTree?
        var error: XMLTreeError?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard stack.count < XMLTree.maximumDepth else {
                error = .tooDeep
                parser.abortParsing()
                return
            }
            var namespaces = stack.last?.namespaces ?? [:]
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                if key == "xmlns" {
                    namespaces[""] = value
                } else if key.hasPrefix("xmlns:") {
                    namespaces[String(key.dropFirst(6))] = value
                } else {
                    attributes[XMLTree.localName(key)] = value
                }
            }
            let prefix = XMLTree.prefix(elementName)
            let element = XMLTree(name: XMLTree.localName(elementName), prefix: prefix, namespaceURI: namespaces[prefix ?? ""],
                                  attributes: attributes, text: "", children: [])
            stack.append(Frame(element: element, text: "", namespaces: namespaces))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard var frame = stack.popLast() else { return }
            frame.element.text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty {
                root = frame.element
            } else {
                stack[stack.count - 1].element.children.append(frame.element)
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if error == nil { error = .malformed(String(describing: parseError)) }
        }
    }

    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    static func prefix(_ qualified: String) -> String? {
        guard let colon = qualified.firstIndex(of: ":") else { return nil }
        return String(qualified[..<colon])
    }
}
