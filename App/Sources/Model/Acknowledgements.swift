import Foundation

/// Licence notices for Settings › Acknowledgements, read from the bundled `Acknowledgements.md`.
enum Acknowledgements {
    struct Section: Identifiable, Equatable {
        var id: String { title }
        var title: String
        /// Plain text (Markdown code fences removed).
        var body: String
    }

    static let notAffiliated = String(localized: "Camera Bridge is not affiliated with Apple Inc.")
    static let trademarks = String(localized: "Apple, Apple Home, HomeKit and HomePod are trademarks of Apple Inc.")
    /// The About window's one-line notice.
    static let aboutDisclaimer = String(localized: "Not affiliated with Apple. HomeKit and Apple Home are trademarks of Apple Inc.")

    /// The bundled notices, or a short built-in summary if the resource is missing.
    static func load(from bundle: Bundle = .main) -> [Section] {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        let sections = sections(fromMarkdown: text)
        return sections.isEmpty ? fallback : sections
    }

    /// One section per level-2 heading (`## Title`); text before the first heading is dropped.
    static func sections(fromMarkdown text: String) -> [Section] {
        var sections: [Section] = []
        var title: String?
        var lines: [Substring] = []

        func flush() {
            guard let title else { return }
            let body = lines.filter { !$0.hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(Section(title: title, body: body))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                lines = []
            } else if title != nil {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    static let fallback: [Section] = [
        Section(title: "HAP-NodeJS", body: "Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for Camera Bridge."),
        Section(title: "swift-crypto", body: "https://github.com/apple/swift-crypto — Apache License 2.0. Copyright 2019 The SwiftCrypto Project."),
        Section(title: "swift-asn1", body: "https://github.com/apple/swift-asn1 — Apache License 2.0. Copyright 2022 The SwiftASN1 Project."),
        Section(title: "BigInt", body: "https://github.com/attaswift/BigInt — MIT License. Copyright (c) 2016-2017 Károly Lőrentey."),
        Section(title: "Sparkle", body: "https://github.com/sparkle-project/Sparkle — MIT License. Copyright (c) 2006-2017 Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński, Mayur Pawashe and others. Includes bsdiff, sais-lite, ed25519 and SUSignatureVerifier under their own licenses."),
        Section(title: "go2rtc", body: "https://github.com/AlexxIT/go2rtc — MIT License. Copyright (c) 2022 Alexey Khit. Bundled unmodified as a helper program."),
    ]
}
