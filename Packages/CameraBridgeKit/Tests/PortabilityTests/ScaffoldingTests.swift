import Foundation
import Testing

// Plan Wave 4 "Final cleanliness": the Wave-0 contract scaffolding (stubs throwing `StubError`, empty placeholder tests,
// suites gated on a stub probe) is gone and stays gone, and so are the duplicated bitstream parsers. Pure text scan of
// Sources/ and Tests/; this file is skipped.

private let thisFile = URL(fileURLWithPath: #filePath).standardizedFileURL
private let packageRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func swiftSources(in directory: String) -> [(path: String, text: String)] {
    let root = packageRoot.appending(path: directory, directoryHint: .isDirectory)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && $0.standardizedFileURL != thisFile }
        .compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (String(url.standardizedFileURL.path.dropFirst(packageRoot.standardizedFileURL.path.count + 1)), text)
        }
}

/// `file:line` for every line matching `pattern` (case-insensitive regular expression).
private func matches(_ pattern: String, in files: [(path: String, text: String)]) -> [String] {
    let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
    return files.filter { $0.text.range(of: pattern, options: options) != nil }.flatMap { file in
        file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            line.range(of: pattern, options: options) == nil ? nil : "\(file.path):\(index + 1): \(line)"
        }
    }
}

@Suite struct ScaffoldingTests {
    private let sources = swiftSources(in: "Sources")
    private let tests = swiftSources(in: "Tests")

    @Test func scannerSeesTheWholePackage() {
        #expect(sources.count > 50 && tests.count > 50)
        #expect(!tests.contains { $0.path.hasSuffix("ScaffoldingTests.swift") })
    }

    @Test func noContractStubsRemain() {
        #expect(matches(#"\bStubError\b|\.notImplemented\("#, in: sources + tests) == [])
    }

    @Test func noEmptyPlaceholderTests() {
        // The Wave-0 `@Test func moduleCompiles() {}`: passes while checking nothing.
        let placeholders = (sources + tests).flatMap { file in
            file.text.ranges(of: #/@Test\s+func\s+\w+\(\)\s*\{\s*\}/#).map { "\(file.path): \(file.text[$0])" }
        }
        #expect(placeholders == [])
    }

    @Test func noWaveZeroNamesOrStubGates() {
        // Suites named after the wave that scaffolded them, and suites enabled only once a stub is replaced.
        #expect(matches(#"wave-?0|wave ?zero"#, in: sources + tests) == [])
        #expect(tests.filter { $0.path.localizedCaseInsensitiveContains("WaveZero") }.map(\.path) == [])
        #expect(matches(#"isImplemented\(\)"#, in: tests) == [])
    }

    /// Review findings (rounds 1 and 2): bitstream parsing has one copy, in MediaCore (`BitReader`,
    /// `AudioSpecificConfig`, `NALUnits.h264SliceType`). The first consolidation missed BridgeEngine's `ExpGolombReader`
    /// (H.264 slice headers) and RTP's AAC-ELD config writer with its own sampling-frequency table.
    @Test func bitstreamParsersLiveOnlyInMediaCore() {
        let outside = sources.filter { !$0.path.hasPrefix("Sources/MediaCore/") }
        #expect(outside.count > 50 && outside.count < sources.count)
        // A bit reader or writer by name, or the MSB-first bit extraction `byte >> (7 - bit)` that one is built on.
        #expect(matches(#"\b(struct|class|enum|actor)\s+\w*(BitReader|BitCursor|BitWriter|BitStream|ExpGolomb)"#, in: outside) == [])
        #expect(matches(#">>\s*\(\s*7\s*-"#, in: outside) == [])
        // The AudioSpecificConfig sampling-frequency table (ISO/IEC 14496-3 Table 1.18).
        #expect(matches(#"96_?000\s*,\s*88_?200"#, in: outside) == [])
    }
}
