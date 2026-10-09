import Foundation
import Testing

// Enforces the contracts' "Portability rule" and module dependency graph
// (docs/superpowers/plans/2026-09-30-camerabridge-contracts.md) on the source text of every module except PlatformApple,
// keeps test targets compilable without Apple frameworks, and keeps PlatformApple a macOS-only dependency.
// Pure text scan; no module imports.

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sourcesDirectory = packageDirectory.appending(path: "Sources", directoryHint: .isDirectory)
private let testsDirectory = packageDirectory.appending(path: "Tests", directoryHint: .isDirectory)

/// Apple-only frameworks that portable modules must never import (plan Task 0.5).
let forbiddenModules: Set<String> = [
    "Network", "CryptoKit", "CoreMedia", "VideoToolbox", "AudioToolbox", "CoreImage", "ImageIO", "Security", "IOKit",
    "AppKit", "SwiftUI", "dnssd", "AVFoundation", "CoreVideo",
]

/// System modules any portable module may import. Those in `guardedModules` only inside `#if canImport(<module>)`, those in
/// `restrictedImportFiles` only in the files listed there.
let portableSystemModules: Set<String> = [
    "Foundation", "FoundationEssentials", "FoundationNetworking", "FoundationXML", "Dispatch", "Synchronization", "Observation",
    "Darwin", "Glibc", "Musl",
]

/// Package dependencies and restricted system modules → the only modules that may import them (contracts: dependency
/// graph; `os` is BridgeSupport's `Log` → `os.Logger`). SwiftPM would let any dependent import them transitively.
let externalModuleUsers: [String: Set<String>] = [
    "Crypto": ["BridgeSupport", "HAPCore", "RTP", "BridgeWeb"],
    "BigInt": ["HAPCore"],
    "_CryptoExtras": ["RTP"],
    "CommonCrypto": ["RTP"],   // and only in Sources/RTP/SRTP*
    "os": ["BridgeSupport"],
]

/// System modules allowed only in some files of the modules that may import them (contracts: portability rule). Each
/// entry is a path prefix relative to the package (`Sources/RTP/SRTP` = `SRTP*.swift`).
let restrictedImportFiles: [String: [String]] = [
    "CommonCrypto": ["Sources/RTP/SRTP"],
    "Darwin": bsdSocketFiles, "Glibc": bsdSocketFiles, "Musl": bsdSocketFiles,
]
/// The only portable files that use the BSD socket API directly: RTP/SRTP media, WS-Discovery multicast and the
/// interface addresses a live stream's accessory address is chosen from (`getifaddrs`).
private let bsdSocketFiles = ["Sources/BridgeDaemon/", "Sources/RTP/UDPSocket.swift", "Sources/CameraAdapters/ONVIF/ONVIFDiscovery.swift",
                              "Sources/BridgeEngine/Delegates/StreamAddress.swift"]

/// Modules that exist only on some platforms: allowed only inside `#if canImport(<module>)`.
let guardedModules: Set<String> = ["FoundationNetworking", "FoundationXML", "_CryptoExtras", "Darwin", "Glibc", "Musl", "os", "CommonCrypto"]

/// Package modules each module may import (contracts: module dependency graph).
private let allowedPackageImports: [String: Set<String>] = {
    var graph: [String: Set<String>] = [
        "BridgeSupport": [],
        "HAPCore": ["BridgeSupport"],
        "HAP": ["HAPCore", "BridgeSupport"],
        "HDS": ["HAP", "HAPCore", "BridgeSupport"],
        "HAPCamera": ["HAP", "HDS", "HAPCore", "BridgeSupport"],
        "MediaCore": ["BridgeSupport"],
        "FMP4": ["MediaCore"],
        "RTP": ["MediaCore", "BridgeSupport"],
        "RTSP": ["RTP", "MediaCore", "BridgeSupport"],
        "CameraAdapters": ["RTSP", "RTP", "MediaCore", "BridgeSupport"],
        "BridgeEngine": ["BridgeSupport", "HAPCore", "HAP", "HDS", "HAPCamera", "MediaCore", "FMP4", "RTP", "RTSP", "CameraAdapters", "PlatformApple", "PlatformLinux"],
        "TestSupport": ["HAPCore", "HAP", "HDS", "RTP", "RTSP", "MediaCore", "FMP4", "BridgeSupport", "PlatformApple", "PlatformLinux"],
    ]
    graph["BridgeWeb"] = ["BridgeEngine", "CameraAdapters", "RTSP", "MediaCore", "BridgeSupport"]   // the web interface over the engine (CONTRACT_CHANGES)
    graph["BridgeDaemon"] = ["BridgeWeb", "BridgeEngine", "CameraAdapters", "BridgeSupport", "PlatformLinux"]   // the Camera Bridge OS daemon (it prepares the Linux codecs)
    graph["camerabridged"] = ["BridgeDaemon"]   // its main
    graph["cbctl"] = (graph["TestSupport"] ?? []).union(["TestSupport"])   // dev tool on top of TestSupport (CONTRACT_CHANGES)
    return graph
}()
/// The platform implementations (each wrapped in its own `#if os(...)`) and the C module they use; not portable, not scanned.
let platformModules: Set<String> = ["PlatformApple", "PlatformLinux", "CDNSSD"]
let packageModules: Set<String> = Set(allowedPackageImports.keys).union(["PlatformApple", "PlatformLinux"])

/// Test-only modules may also use swift-testing.
private let extraAllowed: [String: Set<String>] = ["TestSupport": ["Testing"], "cbctl": []]

/// Modules a test file may import without a guard: everything a Linux build of the test targets also has.
private let linuxTestModules: Set<String> = portableSystemModules.subtracting(guardedModules)
    .union(["Crypto", "BigInt", "Testing"])
    .union(packageModules.subtracting(["PlatformApple"]))

struct ImportLine: Sendable, CustomStringConvertible {
    var file: String
    var line: Int
    var module: String
    /// Active `#if` conditions, innermost last; `#else` branches are recorded as `!(condition)`.
    var conditions: [String]

    var description: String { "\(file):\(line) import \(module)" }

    /// True if an enclosing `#if` requires `canImport(<module>)`.
    func isGuarded(by module: String) -> Bool {
        requires("canImport(\(module))")
    }

    /// True if an enclosing `#if` compiles this import only on Apple platforms or where `module` exists: `os(macOS)`,
    /// `canImport(Darwin)`, `canImport(<an Apple-only framework>)` or `canImport(<module>)`. PlatformApple builds (empty)
    /// on every platform, so `canImport(PlatformApple)` proves nothing.
    func isGuardedForApplePlatforms() -> Bool {
        let proofs = forbiddenModules.union(["Darwin", module]).subtracting(["PlatformApple"])
        return requires("os(macOS)") || proofs.contains { isGuarded(by: $0) }
    }

    /// True if some enclosing condition contains `atom` un-negated and is not a disjunction (an `#else` branch, a
    /// negation or an `||` does not guarantee the atom holds).
    func requires(_ atom: String) -> Bool {
        conditions.contains { condition in
            let text = condition.replacingOccurrences(of: " ", with: "")
            guard !text.hasPrefix("!"), !text.contains("||") else { return false }
            var start = text.startIndex
            while let range = text.range(of: atom, range: start..<text.endIndex) {
                if range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] != "!" { return true }
                start = range.upperBound
            }
            return false
        }
    }
}

/// Extracts `import` declarations (with attributes, access-level modifiers and import kinds) and their enclosing `#if`
/// conditions. Skips comments and multi-line string literals; good enough for import scanning.
func scanImports(in text: String, file: String) -> [ImportLine] {
    var result: [ImportLine] = []
    var conditions: [String] = []
    var inBlockComment = false
    /// Closing delimiter (`"""` plus as many `#` as the opening one) while inside a multi-line string literal.
    var stringDelimiter: String?
    let tripleQuote = String(repeating: "\"", count: 3)
    let importPattern = /^(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)/
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if let delimiter = stringDelimiter {
            if line.contains(delimiter) { stringDelimiter = nil }
            continue
        }
        if inBlockComment {
            guard let end = line.range(of: "*/") else { continue }
            line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            inBlockComment = false
        }
        if line.hasPrefix("/*") {
            if line.range(of: "*/") == nil { inBlockComment = true }
            continue
        }
        if line.hasPrefix("//") || line.isEmpty { continue }
        if let open = line.range(of: tripleQuote) {
            let hashes = line[..<open.lowerBound].reversed().prefix { $0 == "#" }.count
            stringDelimiter = tripleQuote + String(repeating: "#", count: hashes)
            continue
        }
        if line.hasPrefix("#if ") {
            conditions.append(String(line.dropFirst(4)))
        } else if line.hasPrefix("#elseif ") {
            if !conditions.isEmpty { conditions[conditions.count - 1] = String(line.dropFirst(8)) }
        } else if line == "#else" || line.hasPrefix("#else ") {
            if let last = conditions.last { conditions[conditions.count - 1] = "!(\(last))" }
        } else if line.hasPrefix("#endif") {
            _ = conditions.popLast()
        } else if let match = line.firstMatch(of: importPattern) {
            result.append(ImportLine(file: file, line: index + 1, module: String(match.output.1), conditions: conditions))
        }
    }
    return result
}

/// Dependency-graph and guard violations of one file of portable module `module` (Apple-only frameworks are reported
/// separately by `portableModulesImportNoAppleOnlyFrameworks`).
func sourceImportViolations(module: String, path: String, imports: [ImportLine]) -> [String] {
    var violations: [String] = []
    let allowedPackages = allowedPackageImports[module] ?? []
    for item in imports where !forbiddenModules.contains(item.module) {
        if packageModules.contains(item.module) {
            if !allowedPackages.contains(item.module) {
                violations.append("\(item) — \(module) may not depend on \(item.module)")
            } else if item.module == "PlatformApple", !item.isGuardedForApplePlatforms() {
                violations.append("\(item) — PlatformApple is macOS-only: import it inside #if canImport(Darwin)")
            } else if item.module == "PlatformApple", module == "BridgeEngine", !path.hasSuffix("BridgeEngine/Environment.swift") {
                violations.append("\(item) — in BridgeEngine only Environment.swift may import PlatformApple")
            } else if item.module == "PlatformLinux", !item.requires("os(Linux)") {
                violations.append("\(item) — PlatformLinux is Linux-only: import it inside #if os(Linux)")
            } else if item.module == "PlatformLinux", module == "BridgeEngine", !path.hasSuffix("BridgeEngine/Environment.swift") {
                violations.append("\(item) — in BridgeEngine only Environment.swift may import PlatformLinux")
            }
        } else if let users = externalModuleUsers[item.module], !users.contains(module) {
            violations.append("\(item) — \(module) may not depend on \(item.module)")
        } else if externalModuleUsers[item.module] == nil, !portableSystemModules.contains(item.module),
                  !(extraAllowed[module] ?? []).contains(item.module) {
            violations.append("\(item) — not a portable module")
        } else if let files = restrictedImportFiles[item.module], !files.contains(where: { path.hasPrefix($0) }) {
            let names = files.map { $0.hasSuffix(".swift") ? $0 : $0 + "*" }.joined(separator: ", ")
            violations.append("\(item) — \(item.module) is allowed only in \(names)")
        }
        if guardedModules.contains(item.module), !item.isGuarded(by: item.module) {
            violations.append("\(item) — must be inside #if canImport(\(item.module))")
        }
    }
    return violations
}

/// Imports in a test file that a Linux build of the test targets would not find.
func testImportViolations(imports: [ImportLine]) -> [String] {
    imports.compactMap { item in
        if linuxTestModules.contains(item.module) || item.isGuardedForApplePlatforms() { return nil }
        let guardText = item.module == "PlatformApple" ? "#if os(macOS)" : "#if os(macOS) or #if canImport(\(item.module))"
        return "\(item) — missing on Linux: wrap it and the code using it in \(guardText)"
    }
}

/// Lines that are neither blank nor `//` comments.
private func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("//") }
}

/// True if the whole file sits inside one `#if <condition>` … `#endif` block.
func isWrappedInConditionalCompilation(_ text: String, condition: String) -> Bool {
    let lines = codeLines(text)
    guard lines.first == "#if \(condition)", lines.last?.hasPrefix("#endif") == true else { return false }
    var depth = 0
    for (index, line) in lines.enumerated() {
        if line.hasPrefix("#if ") { depth += 1 } else if line.hasPrefix("#endif") { depth -= 1 }
        if depth == 0 { return index == lines.count - 1 }
    }
    return false
}

func swiftFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

/// Module name → every `.swift` file under `Sources/<module>/`.
func portableModuleSources() throws -> [String: [URL]] {
    var result: [String: [URL]] = [:]
    for module in try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path())
    where !platformModules.contains(module) && !module.hasPrefix(".") {
        result[module] = swiftFiles(under: sourcesDirectory.appending(path: module, directoryHint: .isDirectory))
    }
    return result
}

private func relative(_ url: URL) -> String {
    url.path().replacingOccurrences(of: packageDirectory.path(), with: "")
}

@Suite struct PortabilityTests {
    @Test func everyPortableModuleIsScanned() throws {
        let modules = try portableModuleSources()
        #expect(Set(modules.keys) == Set(allowedPackageImports.keys), "a module was added or removed: update PortabilityTests")
        #expect(modules.values.allSatisfy { !$0.isEmpty })
    }

    @Test func portableModulesImportNoAppleOnlyFrameworks() throws {
        var violations: [String] = []
        for (_, files) in try portableModuleSources() {
            for file in files {
                for item in scanImports(in: try String(contentsOf: file, encoding: .utf8), file: relative(file))
                where forbiddenModules.contains(item.module) {
                    violations.append(item.description)
                }
            }
        }
        #expect(violations.isEmpty, "Apple-only imports outside PlatformApple:\n\(violations.joined(separator: "\n"))")
    }

    @Test func importsFollowTheDependencyGraphAndGuards() throws {
        var violations: [String] = []
        for (module, files) in try portableModuleSources() {
            for file in files {
                let path = relative(file)
                violations += sourceImportViolations(module: module, path: path,
                                                     imports: scanImports(in: try String(contentsOf: file, encoding: .utf8), file: path))
            }
        }
        #expect(violations.isEmpty, "Portability violations:\n\(violations.joined(separator: "\n"))")
    }

    @Test func platformAppleSourcesCompileEmptyOffMacOS() throws {
        let files = swiftFiles(under: sourcesDirectory.appending(path: "PlatformApple", directoryHint: .isDirectory))
        #expect(!files.isEmpty)
        let unwrapped = try files.filter { !isWrappedInConditionalCompilation(try String(contentsOf: $0, encoding: .utf8), condition: "os(macOS)") }
        #expect(unwrapped.isEmpty, "not wrapped in #if os(macOS) … #endif:\n\(unwrapped.map(relative).joined(separator: "\n"))")
    }

    @Test func testTargetsGuardAppleOnlyImports() throws {
        var violations: [String] = []
        let files = swiftFiles(under: testsDirectory)
        #expect(!files.isEmpty)
        for file in files {
            violations += testImportViolations(imports: scanImports(in: try String(contentsOf: file, encoding: .utf8), file: relative(file)))
        }
        #expect(violations.isEmpty, "Test imports that break a Linux build:\n\(violations.joined(separator: "\n"))")
    }

    /// Security-relevant helpers exist once: SHA-256 and SHA-1 come from swift-crypto (`HAPCrypto.sha256`,
    /// BridgeSupport's Digest and `Hashes.sha1`), never a hand-written one (found by their first round constants,
    /// with or without digit separators), and the atomic 0600 file writer (temporary file + `replaceItemAt`) lives only
    /// in BridgeSupport's `PrivateFiles`.
    @Test func noDuplicatedCryptoOrPrivateFileWriters() throws {
        var handWrittenSHA256: [String] = []
        var handWrittenSHA1: [String] = []
        var fileWriters: [String] = []
        for module in try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path()) where !module.hasPrefix(".") {
            for file in swiftFiles(under: sourcesDirectory.appending(path: module, directoryHint: .isDirectory)) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let digits = text.replacingOccurrences(of: "_", with: "")
                if digits.localizedCaseInsensitiveContains("0x428a2f98") { handWrittenSHA256.append(relative(file)) }
                if digits.localizedCaseInsensitiveContains("0x5a827999") { handWrittenSHA1.append(relative(file)) }
                if text.contains("replaceItemAt(") { fileWriters.append(relative(file)) }
            }
        }
        #expect(handWrittenSHA256.isEmpty, "hand-written SHA-256; use HAPCrypto.sha256:\n\(handWrittenSHA256.joined(separator: "\n"))")
        #expect(handWrittenSHA1.isEmpty, "hand-written SHA-1; use BridgeSupport's Hashes.sha1:\n\(handWrittenSHA1.joined(separator: "\n"))")
        #expect(fileWriters.count == 1 && fileWriters.allSatisfy { $0.hasSuffix("Sources/BridgeSupport/PrivateFiles.swift") },
                "use BridgeSupport.PrivateFiles:\n\(fileWriters.joined(separator: "\n"))")
    }

    /// Review finding (W4 BridgeSupport): BridgeSupport holds the one copy of each shared helper, yet "URL without
    /// `user:password@`" (what keeps camera passwords out of config.json and StreamInfo) was copied into CameraAdapters,
    /// BridgeEngine, RTSP and the app, and modules converted `Duration` to seconds inline instead of `timeInterval`.
    /// Exceptions: the wizard's `moveCredentialsOutOfStreamURLs` moves typed user info into the credential fields (it
    /// reads it before dropping it), and FMP4's dependency graph has no BridgeSupport.
    @Test func noDuplicatedUserInfoStrippingOrDurationConversions() throws {
        let repository = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let modules = try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path()).filter { !$0.hasPrefix(".") }
        let files = modules.flatMap { swiftFiles(under: sourcesDirectory.appending(path: $0, directoryHint: .isDirectory)) }
            + swiftFiles(under: repository.appending(path: "App/Sources", directoryHint: .isDirectory))
        var userInfoStrippers: [String: Int] = [:]
        var durationConversions: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let path = file.path().replacingOccurrences(of: repository.path(), with: "")
            let strips = text.ranges(of: ".password = nil").count
            if strips > 0 { userInfoStrippers[path] = strips }
            if text.contains(/attoseconds\)?\s*(\*\s*1e-18|\/\s*1e18)/) { durationConversions.append(path) }
        }
        #expect(files.contains { $0.path().hasSuffix("App/Sources/Model/AddCameraWizardModel.swift") }, "the app's sources were not scanned")
        #expect(userInfoStrippers == ["Packages/CameraBridgeKit/Sources/BridgeSupport/URLUserInfo.swift": 1,
                                      "App/Sources/Model/AddCameraWizardModel.swift": 1],
                "use BridgeSupport's `URL.removingUserInfo`: \(userInfoStrippers)")
        #expect(durationConversions.sorted() == ["Packages/CameraBridgeKit/Sources/BridgeSupport/Backoff.swift",
                                                 "Packages/CameraBridgeKit/Sources/FMP4/GOPFragmenter.swift"],
                "use BridgeSupport's `Duration.timeInterval`:\n\(durationConversions.sorted().joined(separator: "\n"))")
    }

    /// Review finding (BridgeSupport, round 2): the sanitizer that keeps `AuthenticatingHTTPClient`'s failing URL (a
    /// Reolink `token=`, a `password=` query item) out of thrown and logged errors was copied into RTSP, CameraAdapters
    /// and BridgeEngine, so a fix to one (a new URL-carrying error) would not reach the others. Reading a URLError's code
    /// or a failing-URL user-info key is BridgeSupport's `URLFreeErrors` alone; `is URLError` (classifying) stays allowed.
    @Test func urlErrorSanitizingLivesOnlyInBridgeSupport() throws {
        let repository = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let modules = try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path()).filter { !$0.hasPrefix(".") }
        let files = modules.flatMap { swiftFiles(under: sourcesDirectory.appending(path: $0, directoryHint: .isDirectory)) }
            + swiftFiles(under: repository.appending(path: "App/Sources", directoryHint: .isDirectory))
        var sanitizers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(/\bas[?!]?\s+URLError\b|NSErrorFailingURL|NSURLErrorFailingURL/) {
                sanitizers.append(file.path().replacingOccurrences(of: repository.path(), with: ""))
            }
        }
        #expect(sanitizers == ["Packages/CameraBridgeKit/Sources/BridgeSupport/URLFreeErrors.swift"],
                "use BridgeSupport's `URLFreeErrors`:\n\(sanitizers.sorted().joined(separator: "\n"))")
    }

    @Test func everyDependencyOnPlatformAppleIsMacOSOnly() throws {
        let manifest = try String(contentsOf: packageDirectory.appending(path: "Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#"let platformApple: Target.Dependency = .target(name: "PlatformApple", condition: .when(platforms: [.macOS]))"#))
        let unconditional = manifest.matches(of: /dependencies:\s*\[[^\]]*"PlatformApple"/).map { String($0.output) }
        #expect(unconditional.isEmpty, "depend on PlatformApple through `platformApple`:\n\(unconditional.joined(separator: "\n"))")
    }
}

/// The scanner itself.
@Suite struct ImportScannerTests {
    @Test func findsImportsWithAttributesKindsAndSubmodules() {
        let text = """
            import Foundation
            @preconcurrency import Network
            @_exported import CryptoKit
            import struct CoreMedia.CMTime
            import IOKit.pwr_mgt
            // import AppKit
            /* import SwiftUI
               import VideoToolbox */
            let importantValue = 1
            """
        #expect(scanImports(in: text, file: "x").map(\.module) == ["Foundation", "Network", "CryptoKit", "CoreMedia", "IOKit"])
    }

    @Test func findsAccessLevelImports() {
        let text = """
            internal import Network
            public import CryptoKit
            package import CoreMedia
            private import VideoToolbox
            fileprivate import dnssd
            @preconcurrency internal import Security
            @_spi(Private) public import struct IOKit.io_object_t
            internal func importNothing() {}
            publicImport = 1
            """
        #expect(scanImports(in: text, file: "x").map(\.module) == ["Network", "CryptoKit", "CoreMedia", "VideoToolbox", "dnssd", "Security", "IOKit"])
    }

    @Test func skipsMultilineStringLiterals() {
        let text = ###"""
            import Foundation
            let fixture = """
                import Network
                #if canImport(Darwin)
                """
            let raw = #"""
                import CryptoKit
                """#
            let nested = ##"""
                let inner = """
                import AppKit
                """#
                import IOKit
                """##
            import Testing
            """###
        let imports = scanImports(in: text, file: "x")
        #expect(imports.map(\.module) == ["Foundation", "Testing"])
        #expect(imports.allSatisfy { $0.conditions.isEmpty })
    }

    @Test func tracksConditionalCompilation() {
        let text = """
            #if canImport(FoundationNetworking)
            import FoundationNetworking
            #endif
            #if canImport(Darwin)
            import Darwin
            #elseif canImport(Glibc)
            import Glibc
            #else
            import os
            #endif
            import CommonCrypto
            #if canImport(Glibc) && !canImport(Darwin)
            import Musl
            #endif
            #if canImport(Darwin) || os(Linux)
            import Network
            #endif
            """
        let imports = scanImports(in: text, file: "x")
        #expect(imports.map(\.module) == ["FoundationNetworking", "Darwin", "Glibc", "os", "CommonCrypto", "Musl", "Network"])
        #expect(imports[0].isGuarded(by: "FoundationNetworking"))
        #expect(imports[1].isGuarded(by: "Darwin"))
        #expect(imports[2].isGuarded(by: "Glibc") && !imports[2].isGuarded(by: "Darwin"))
        #expect(!imports[3].isGuarded(by: "os"))
        #expect(!imports[4].isGuarded(by: "CommonCrypto"))
        #expect(imports[5].isGuarded(by: "Glibc") && !imports[5].isGuardedForApplePlatforms())
        #expect(!imports[6].isGuardedForApplePlatforms())
    }

    @Test func detectsWholeFileWrapping() {
        #expect(isWrappedInConditionalCompilation("// header\n#if os(macOS)\nimport Network\n#if DEBUG\nlet a = 1\n#endif\n#endif\n", condition: "os(macOS)"))
        #expect(!isWrappedInConditionalCompilation("#if os(macOS)\nimport Network\n#endif\nlet a = 1\n", condition: "os(macOS)"))
        #expect(!isWrappedInConditionalCompilation("#if os(macOS)\n#endif\n#if DEBUG\n#endif\n", condition: "os(macOS)"))
        #expect(!isWrappedInConditionalCompilation("import Network\n", condition: "os(macOS)"))
    }
}

/// The rules, on synthetic sources.
@Suite struct PortabilityRuleTests {
    private func violations(_ module: String, _ text: String, path: String? = nil) -> [String] {
        let path = path ?? "Sources/\(module)/File.swift"
        return sourceImportViolations(module: module, path: path, imports: scanImports(in: text, file: path))
    }

    @Test func externalPackagesFollowTheDependencyGraph() {
        #expect(violations("HAPCore", "import BigInt\nimport Crypto\nimport BridgeSupport").isEmpty)
        #expect(violations("BridgeSupport", "import Crypto\n#if canImport(os)\nimport os\n#endif\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif").isEmpty)
        #expect(violations("MediaCore", "import Crypto").count == 1)
        #expect(violations("FMP4", "internal import BigInt").count == 1)
        #expect(violations("CameraAdapters", "@preconcurrency import Crypto").count == 1)
        #expect(violations("HAP", "#if canImport(os)\nimport os\n#endif").count == 1)
        #expect(violations("BridgeEngine", "import Crypto").count == 1)
        #expect(violations("BridgeSupport", "import os").count == 1)   // unguarded
    }

    @Test func srtpMayUseCommonCryptoOrCryptoExtras() {
        let srtp = "import Crypto\n#if canImport(CommonCrypto)\nimport CommonCrypto\n#elseif canImport(_CryptoExtras)\nimport _CryptoExtras\n#endif"
        #expect(violations("RTP", srtp, path: "Sources/RTP/SRTP.swift").isEmpty)
        #expect(violations("RTP", srtp, path: "Sources/RTP/RTPPacket.swift").count == 1)
        #expect(violations("RTSP", srtp, path: "Sources/RTSP/SRTP.swift").count == 3)
        // `#else` does not prove `_CryptoExtras` exists.
        #expect(violations("RTP", "#if canImport(CommonCrypto)\nimport CommonCrypto\n#else\nimport _CryptoExtras\n#endif", path: "Sources/RTP/SRTP.swift").count == 1)
    }

    /// Contracts: Darwin/Glibc (Musl) BSD-socket imports only in RTP's `UDPSocket` and CameraAdapters' `ONVIFDiscovery`.
    @Test func bsdSocketImportsOnlyInTheListedFiles() {
        let sockets = "#if canImport(Darwin)\nimport Darwin\n#elseif canImport(Glibc)\nimport Glibc\n#elseif canImport(Musl)\nimport Musl\n#endif"
        #expect(violations("RTP", sockets, path: "Sources/RTP/UDPSocket.swift").isEmpty)
        #expect(violations("CameraAdapters", sockets, path: "Sources/CameraAdapters/ONVIF/ONVIFDiscovery.swift").isEmpty)
        #expect(violations("RTP", sockets, path: "Sources/RTP/RTPPacket.swift").count == 3)
        #expect(violations("CameraAdapters", sockets, path: "Sources/CameraAdapters/Support/XMLTree.swift").count == 3)
        #expect(violations("BridgeSupport", "#if canImport(Darwin)\nimport Darwin\n#endif",
                           path: "Sources/BridgeSupport/AuthenticatingHTTPClient.swift").count == 1)
        // The file name alone does not count: the path must be the listed one.
        #expect(violations("RTSP", sockets, path: "Sources/RTSP/UDPSocket.swift").count == 3)
        // A listed file still needs the guard.
        #expect(violations("RTP", "import Darwin", path: "Sources/RTP/UDPSocket.swift").count == 1)
    }

    @Test func packageModulesFollowTheDependencyGraph() {
        #expect(violations("MediaCore", "import HAP").count == 1)
        #expect(violations("HAP", "public import HDS").count == 1)
        #expect(violations("RTSP", "import UnknownThing").count == 1)
        #expect(violations("TestSupport", "import Testing\nimport HAP").isEmpty)
    }

    @Test func platformAppleOnlyBehindADarwinGuard() {
        let guarded = "#if canImport(Darwin)\nimport PlatformApple\n#endif"
        #expect(violations("BridgeEngine", guarded, path: "Sources/BridgeEngine/Environment.swift").isEmpty)
        #expect(violations("BridgeEngine", guarded, path: "Sources/BridgeEngine/BridgeEngine.swift").count == 1)
        #expect(violations("BridgeEngine", "import PlatformApple", path: "Sources/BridgeEngine/Environment.swift").count == 1)
        #expect(violations("BridgeEngine", "#if canImport(PlatformApple)\nimport PlatformApple\n#endif", path: "Sources/BridgeEngine/Environment.swift").count == 1)
        #expect(violations("TestSupport", "#if os(macOS)\nimport PlatformApple\n#endif").isEmpty)
        #expect(violations("TestSupport", "import PlatformApple").count == 1)
        #expect(violations("RTSP", guarded).count == 1)
    }

    @Test func testFilesGuardImportsMissingOnLinux() {
        let text = """
            import Foundation
            import Testing
            import Crypto
            import BigInt
            @testable import HAPCore
            import PlatformApple
            #if canImport(PlatformApple)
            import PlatformApple
            #endif
            #if os(macOS)
            @testable import PlatformApple
            import Network
            #endif
            #if canImport(VideoToolbox)
            import VideoToolbox
            import CoreMedia
            #endif
            #if canImport(Darwin)
            import dnssd
            #endif
            #if canImport(Glibc) && !canImport(Darwin)
            import Security
            #endif
            #if os(macOS) || os(Linux)
            import CoreMedia
            #endif
            import CryptoKit
            import os
            """
        let found = testImportViolations(imports: scanImports(in: text, file: "x"))
        #expect(found.map { $0.split(separator: " ").first.map(String.init) ?? "" }
                == ["x:6", "x:8", "x:22", "x:25", "x:27", "x:28"])
    }
}
