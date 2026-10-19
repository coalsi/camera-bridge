import BridgeSupport
import Foundation

/// Which kind of AI service writes the descriptions.
public enum AIProviderKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Claude, at Anthropic's own address.
    case anthropic
    /// Any service that speaks the OpenAI chat API (OpenAI, OpenRouter, or a model at home such as Ollama): needs an address.
    case openAICompatible
}

/// How the person chose to have events described (`BridgeSettings.ai`). Nothing secret: the key lives in the platform `SecretStore`
/// (`BridgeEngine.setAIKey(_:)`). Off until a provider is chosen; each camera also has its own switch (`CameraConfiguration.aiDescriptions`).
/// Decoding is lenient: a missing or unreadable value takes its default, and the others are read.
public struct AIDescriptionSettings: Codable, Sendable, Equatable {
    /// nil: no service chosen, nothing is described.
    public var provider: AIProviderKind?
    /// The model to ask for (`modelLengthRange` printable characters).
    public var model: String
    /// The OpenAI-compatible service's API address ("https://…/v1", "http://192.168.77.10:11434/v1"): http or https, a host, no user name or
    /// password in it, no query and no fragment. Needed when `provider` is `.openAICompatible`; ignored for Claude.
    public var baseURL: String?
    /// The most descriptions asked for per day (`dailyLimitRange`), counted in the bridge's time zone.
    public var dailyLimit: Int

    public static let dailyLimitRange = 1...5_000
    public static let modelLengthRange = 1...100
    /// The most characters of a key.
    public static let maximumKeyLength = 500
    static let maximumAddressLength = 500
    /// A key shorter than this has no hint: the last four characters would be most of it.
    static let shortestKeyWithHint = 8

    /// No provider, Claude's `claude-haiku-5-5`, no address, 200 a day.
    public init(provider: AIProviderKind? = nil, model: String = AnthropicVision.defaultModel, baseURL: String? = nil, dailyLimit: Int = 200) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.dailyLimit = dailyLimit
    }

    private enum CodingKeys: String, CodingKey { case provider, model, baseURL, dailyLimit }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String] = []
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                unreadable.append(key.stringValue)
                return fallback
            }
        }
        provider = value(.provider, default: nil)   // a provider this build does not know (a newer build wrote it): none
        // Values this build would refuse to save take their defaults, logged by key name (never the value: an address can be typed with a password).
        let model = value(.model, default: self.model)
        if Self.isValidModel(model) { self.model = model } else { unreadable.append(CodingKeys.model.stringValue) }
        if let address: String = value(.baseURL, default: nil) {
            if Self.isValidAddress(address) { baseURL = address } else { unreadable.append(CodingKeys.baseURL.stringValue) }
        }
        if provider == .openAICompatible, baseURL == nil {
            // What was loaded has to be savable: one unreadable address must not make every later change of the settings fail.
            provider = nil
            unreadable.append(CodingKeys.provider.stringValue)
        }
        let limit = value(.dailyLimit, default: dailyLimit)
        if Self.dailyLimitRange.contains(limit) { dailyLimit = limit } else { unreadable.append(CodingKeys.dailyLimit.stringValue) }
        if !unreadable.isEmpty {
            Log(category: "Engine").warning("Unreadable AI settings \(unreadable.joined(separator: ", ")) in the configuration; defaults are used")
        }
    }

    // MARK: Validation

    /// What is wrong with settings that cannot be saved: the field (`provider`, `model`, `baseURL`, `dailyLimit`) and the words for the person.
    public struct Problem: Equatable, Sendable {
        public var field: String
        public var message: String
    }

    /// The first thing wrong with these settings; nil when they can be saved. An OpenAI-compatible provider needs an address; an address that is
    /// there is checked whichever provider is chosen.
    public var validationProblem: Problem? {
        if !Self.isValidModel(model) {
            return Problem(field: "model", message: "Enter the model’s name, up to \(Self.modelLengthRange.upperBound) characters on one line.")
        }
        if let baseURL {
            if !Self.isValidAddress(baseURL) {
                return Problem(field: "baseURL", message: "Enter the service’s address, like https://example.com/v1: http or https, with no name or password in it, and nothing after a ? or #.")
            }
        } else if provider == .openAICompatible {
            return Problem(field: "baseURL", message: "Enter the service’s address, like http://192.168.77.10:11434/v1.")
        }
        if !Self.dailyLimitRange.contains(dailyLimit) {
            return Problem(field: "dailyLimit", message: "The daily limit is \(Self.dailyLimitRange.lowerBound) to \(Self.dailyLimitRange.upperBound) descriptions.")
        }
        return nil
    }

    /// A service address: http or https, a host, no user info, no query, no fragment, one line of at most `maximumAddressLength` characters.
    static func isValidAddress(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumAddressLength,
              !text.unicodeScalars.contains(where: { isControl($0) || $0.properties.isWhitespace }),
              let components = URLComponents(string: text), URL(string: text) != nil,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return false }
        return true
    }

    /// A key as it is stored: trimmed of the spaces, tabs and line breaks a paste brings along (a trailing newline would make an invalid
    /// header), then `1...maximumKeyLength` characters of visible ASCII (0x21 to 0x7E) and nothing else. nil for an empty key, a longer one, or
    /// one with anything else in it: an inner space, a control character or line break, and what a paste can hide, such as a zero-width space, a
    /// byte order mark, a bidi control or any non-ASCII text, at the ends too (only ASCII blanks are trimmed, so the answer is the same on every
    /// platform). Real keys are plain ASCII, and a header takes no more.
    public static func cleanedKey(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: asciiBlanks)
        guard !key.isEmpty, key.unicodeScalars.count <= maximumKeyLength,
              key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return key
    }

    private static let asciiBlanks = CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}")

    /// Whether a key saved while `old` was in force may still be sent to the service these settings name. It may not when the provider
    /// changed (including to or from none), nor, for an OpenAI-compatible service, when the address names another server: another scheme,
    /// host or port (the scheme's own port counts as the port when none is written). The path, the case of the host, and the model and the
    /// daily limit do not matter. Claude's address is Anthropic's own, so a leftover `baseURL` is not part of it. Two addresses that cannot be
    /// read (none among them) are never the same server.
    func keepsKey(from old: AIDescriptionSettings) -> Bool {
        guard provider == old.provider else { return false }
        guard provider == .openAICompatible else { return true }
        guard let new = Self.server(of: baseURL), new == Self.server(of: old.baseURL) else { return false }
        return true
    }

    /// "Claude", "the OpenAI-compatible service at 192.168.77.10", "no service": the service in words for a log line (the address's host only).
    var serviceForLog: String {
        switch provider {
        case nil: "no service"
        case .anthropic: "Claude"
        case .openAICompatible: "the OpenAI-compatible service at \(baseURL.flatMap { URLComponents(string: $0)?.host } ?? "an unreadable address")"
        }
    }

    /// "http://host:80": the scheme, host and port of an address, lowercased, the scheme's own port filled in; nil for one that cannot be read
    /// (which is never the same server as another).
    private static func server(of address: String?) -> String? {
        guard let address, let components = URLComponents(string: address), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// The model's name: `modelLengthRange` characters on one line, and not only blanks.
    static func isValidModel(_ text: String) -> Bool {
        modelLengthRange.contains(text.count) && !hasUnprintable(text) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The last four characters of a key, for the page to say which key is saved; nil for a key too short to show any of.
    static func hint(forKey key: String) -> String? {
        key.count >= shortestKeyWithHint ? String(key.suffix(4)) : nil
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
            || scalar.properties.generalCategory == .paragraphSeparator
    }

    /// Whether `text` holds a control character or a line break (a tab is one).
    private static func hasUnprintable(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isControl)
    }
}
