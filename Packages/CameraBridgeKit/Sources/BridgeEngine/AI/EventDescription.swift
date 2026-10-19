import Foundation

/// One brief description of a camera event, as an AI vision service gave it: a single plain sentence, what sort of thing it saw, and how much
/// the owner should care. Stored with the event; the pictures it came from are never kept.
public struct EventDescription: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case person, vehicle, animal, delivery, other, nothing
    }

    public enum Concern: String, Codable, Sendable, Equatable, CaseIterable {
        case routine, unusual, alarm
    }

    /// At most `maximumSummaryLength` characters and `maximumSummaryBytes` UTF-8 bytes, one line, without control or format characters.
    public var summary: String
    public var kind: Kind
    public var concern: Concern
    /// The model that wrote it (as the bridge asked for it).
    public var model: String
    public var at: Date

    /// The most of a summary that is stored and shown; the model is asked for about 12 words.
    public static let maximumSummaryLength = 140
    /// The most of a summary in UTF-8 bytes: a character can be many bytes (a letter with a pile of combining marks is one), and the event log
    /// keeps a description's line to 2 KiB. Cut at a word like the character limit.
    public static let maximumSummaryBytes = 600
    /// The summary of an event the model found nothing in (shadows, trees moving, rain), whatever words it used.
    public static let nothingNotable = "Nothing notable"

    public init(summary: String, kind: Kind, concern: Concern, model: String, at: Date) {
        self.summary = summary
        self.kind = kind
        self.concern = concern
        self.model = model
        self.at = at
    }

    /// The description in a model's answer, read leniently: the first `{…}` object in the text that holds a summary, wherever it sits (after
    /// a sentence of prose, in a code fence). The summary is cut to its first line, stripped of control and format characters (bidi overrides,
    /// zero-width marks; the joiner inside an emoji stays), trimmed, and capped at `maximumSummaryLength` characters and `maximumSummaryBytes`
    /// bytes at a word, ending "…". An unknown kind becomes `.other`, an unknown concern `.routine`; kind `.nothing` always reads "Nothing notable",
    /// and needs no summary to do so (`{"kind":"nothing"}` is a description: the model said there is nothing to say). That is a deliberate
    /// choice; every other kind without a usable summary gives nil.
    public static func parse(_ text: String, model: String, at: Date) -> EventDescription? {
        let bytes = Array(text.utf8.prefix(maximumParsedBytes))
        var starts = 0
        var index = 0
        while index < bytes.count, starts < maximumObjectStarts {
            guard bytes[index] == UInt8(ascii: "{") else {
                index += 1
                continue
            }
            starts += 1
            if let end = endOfObject(in: bytes, startingAt: index),
               let fields = (try? JSONSerialization.jsonObject(with: Data(bytes[index...end]))) as? [String: Any],
               let description = EventDescription(fields: fields, model: model, at: at) {
                return description
            }
            index += 1
        }
        return nil
    }

    /// The description in the fields of a JSON object (a provider's tool call, or a parsed answer). Same rules as `parse`.
    init?(fields: [String: Any], model: String, at: Date) {
        let kind = Self.word(fields["kind"]).flatMap(Kind.init(rawValue:)) ?? .other
        let concern = Self.word(fields["concern"]).flatMap(Concern.init(rawValue:)) ?? .routine
        let summary: String
        if kind == .nothing {
            summary = Self.nothingNotable
        } else if let text = fields["summary"] as? String, let line = Self.firstLine(of: text) {
            summary = Self.capped(line)
        } else {
            return nil
        }
        self.init(summary: summary, kind: kind, concern: concern, model: model, at: at)
    }

    // MARK: Reading an answer

    /// The most of an answer that is searched (a description is far shorter), and the most `{` it tries: bounded work for any text.
    private static let maximumParsedBytes = 16_384
    private static let maximumObjectStarts = 32

    private static func word(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The index of the `}` that closes the object opened at `start`; braces inside JSON strings do not count. Nil when it never closes.
    private static func endOfObject(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }

    /// The first line of `text` with something in it once its control and format characters are taken out, trimmed; nil when there is none.
    private static func firstLine(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let cleaned = withoutControlCharacters(String(line)).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// `text` without its control (Cc) and format (Cf) characters: bidi overrides and isolates, zero-width marks, a byte order mark, the null
    /// and the bell. The zero-width joiner (U+200D) stays, for the emoji made of several; a tab becomes a space, so it opens no hole in a word.
    static func withoutControlCharacters(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                kept.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control: continue
            case .format where scalar.value != 0x200D: continue
            default: kept.append(scalar)
            }
        }
        return String(kept)
    }

    /// `line` itself when it fits both limits, else its first words that fit with a "…": at most `maximumSummaryLength` characters and
    /// `maximumSummaryBytes` bytes in all.
    private static func capped(_ line: String) -> String {
        guard line.count > maximumSummaryLength || line.utf8.count > maximumSummaryBytes else { return line }
        // The room before the "…": whole characters (never half of one), as many as both limits leave.
        var characters = 0, bytes = 0
        var end = line.startIndex
        for index in line.indices {
            let next = line.index(after: index)
            let size = line[index..<next].utf8.count
            guard characters + 1 <= maximumSummaryLength - 1, bytes + size <= maximumSummaryBytes - "…".utf8.count else { break }
            characters += 1
            bytes += size
            end = next
        }
        let room = line[..<end]
        var kept = room
        // Keep every whole word before the cut: when the character after it is whitespace the cut already falls between two words; otherwise
        // it falls inside one, which goes with the last whitespace before it (the last character of the room itself, when that is a space, so
        // nothing but the space is lost). A word longer than the limits is cut inside.
        if end < line.endIndex, !line[end].isWhitespace, let space = room.lastIndex(where: \.isWhitespace) {
            kept = room[..<space]
        }
        while let last = kept.last, last.isWhitespace || ",;:-–—".contains(last) { kept = kept.dropLast() }
        return (kept.isEmpty ? String(room) : String(kept)) + "…"
    }
}
