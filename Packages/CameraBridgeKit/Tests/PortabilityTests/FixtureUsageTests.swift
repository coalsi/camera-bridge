import Foundation
import Testing

// Every file in a test target's `Fixtures/` directory is read by that target's tests. Fixtures are read through
// `#filePath` (no SwiftPM resources), so the build never notices a file nothing opens: the W1-9 HAP-NodeJS goldens
// `HDSTests/Fixtures/hds-codec.json` and `hds-frames.json` were regenerated and documented as consumed for a long time
// while no test loaded them. A fixture counts as used when a `.swift` file of the same target names it, by its path
// below `Fixtures/` or by its file name (`fixture("reolink/GetAbility.json")`, `signals("Pull-Tamper.xml")`).
// `README.md` files describe a directory and are not fixtures. Pure text scan, like the rest of this target.

private let testsRoot = packageDirectory.appending(path: "Tests", directoryHint: .isDirectory)

struct FixtureFile: Sendable, CustomStringConvertible {
    /// Test target directory name, e.g. `HDSTests`.
    var target: String
    /// Path below the target's `Fixtures/`, e.g. `reolink/GetAbility.json`.
    var path: String

    var name: String { String(path.split(separator: "/").last ?? Substring(path)) }
    var description: String { "Tests/\(target)/Fixtures/\(path)" }
}

/// Every regular file under `Tests/<target>/Fixtures/` (recursive) except `README.md`.
func fixtureFiles() throws -> [FixtureFile] {
    var result: [FixtureFile] = []
    for target in try FileManager.default.contentsOfDirectory(atPath: testsRoot.path()).sorted() where !target.hasPrefix(".") {
        let fixtures = testsRoot.appending(path: "\(target)/Fixtures", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
        let prefix = fixtures.standardizedFileURL.path()
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent != "README.md", !url.lastPathComponent.hasPrefix(".") else { continue }
            let full = url.standardizedFileURL.path()
            let path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
            result.append(FixtureFile(target: target, path: path.hasPrefix("/") ? String(path.dropFirst()) : path))
        }
    }
    return result.sorted { $0.description < $1.description }
}

/// The fixtures that no `.swift` file of their own target names.
func unreferencedFixtures(_ fixtures: [FixtureFile], swiftText: (String) -> String) -> [FixtureFile] {
    var textByTarget: [String: String] = [:]
    return fixtures.filter { fixture in
        let text = textByTarget[fixture.target] ?? swiftText(fixture.target)
        textByTarget[fixture.target] = text
        return !text.contains(fixture.path) && !text.contains(fixture.name)
    }
}

/// All `.swift` files of `Tests/<target>/`, concatenated.
private func swiftText(ofTarget target: String) -> String {
    swiftFiles(under: testsRoot.appending(path: target, directoryHint: .isDirectory))
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
}

@Suite struct FixtureUsageTests {
    @Test func scannerSeesTheFixtureDirectories() throws {
        let fixtures = try fixtureFiles()
        #expect(fixtures.count > 30)
        #expect(Set(fixtures.map(\.target)).isSuperset(of: ["HAPCoreTests", "HDSTests", "HAPCameraTests", "CameraAdaptersTests"]))
        #expect(fixtures.contains { $0.target == "HDSTests" && $0.path == "hds-codec.json" })
        #expect(fixtures.contains { $0.target == "CameraAdaptersTests" && $0.path == "reolink/GetAbility.json" && $0.name == "GetAbility.json" })
        #expect(!fixtures.contains { $0.name == "README.md" })
    }

    @Test func detectsAFixtureNoTestNames() {
        let fixtures = [FixtureFile(target: "T", path: "a/used.json"), FixtureFile(target: "T", path: "byName.xml"),
                        FixtureFile(target: "T", path: "dead.json")]
        let text = #"fixture("a/used.json"); signals("byName.xml")"#
        #expect(unreferencedFixtures(fixtures, swiftText: { _ in text }).map(\.path) == ["dead.json"])
    }

    @Test func everyFixtureIsReadByItsTarget() throws {
        let unused = unreferencedFixtures(try fixtureFiles(), swiftText: swiftText(ofTarget:))
        let list = unused.map(\.description).joined(separator: "\n")
        #expect(unused.isEmpty, "fixtures no test of their target reads (load them via #filePath or delete them):\n\(list)")
    }
}
