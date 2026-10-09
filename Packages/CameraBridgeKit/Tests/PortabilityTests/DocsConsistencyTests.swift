import Foundation
import Testing

// Keeps the repository's normative docs in sync with the code and with each other: the contracts' portability rule and
// dependency graph against what `PortabilityTests` enforces and what the sources import (and Package.swift's framework
// comment), docs/CONTRACT_CHANGES.md row statuses against the statuses its header defines and the contract text pending
// rows quote, additive API against the module READMEs, the app's HAP-NodeJS licence notice against the Interop pin, and
// the cbctl pointer README. Pure text scan, like the rest of this target (no module imports).

private let repositoryDirectory = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
private let contractsPath = "docs/superpowers/plans/2026-09-30-camerabridge-contracts.md"
private let contractChangesPath = "docs/CONTRACT_CHANGES.md"

private func repositoryText(_ path: String) throws -> String {
    try String(contentsOf: repositoryDirectory.appending(path: path), encoding: .utf8)
}

/// Identifier-like words of `text`: "Darwin/Glibc" → Darwin, Glibc; "`_CryptoExtras`" → _CryptoExtras.
func identifierWords(_ text: some StringProtocol) -> Set<String> {
    Set(String(text).matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) })
}

/// The contracts' "Portability rule" section: the rule paragraph and the dependency graph (heading to the next `---`).
private func portabilitySection() throws -> String {
    let text = try repositoryText(contractsPath)
    let start = try #require(text.range(of: "### Portability rule"), "contracts: no \"### Portability rule\" heading")
    let end = try #require(text.range(of: "\n---\n", range: start.upperBound..<text.endIndex))
    return String(text[start.lowerBound..<end.lowerBound])
}

/// The rule paragraph split into what portable modules may import (before "**No**") and the forbidden-framework
/// sentence ("**No** …" up to its full stop).
private func portabilityRuleParts() throws -> (allowed: String, forbidden: String) {
    let section = try portabilitySection()
    let rule = try #require(section.split(separator: "\n").first { $0.hasPrefix("Every module except `PlatformApple`") },
                            "contracts: the portability rule paragraph starts with \"Every module except `PlatformApple`\"")
    let no = try #require(rule.range(of: "**No**"), "contracts: the portability rule has no \"**No** …\" sentence")
    let rest = rule[no.lowerBound...]
    let stop = rest.firstRange(of: /\.(\s|$)/)?.lowerBound ?? rest.endIndex
    return (String(rule[..<no.lowerBound]), String(rest[..<stop]))
}

/// The dependency-graph line for `module` (`<module>   → …`).
private func graphLine(for module: String) throws -> String {
    let section = try portabilitySection()
    let line = section.split(separator: "\n").first { line in
        line.hasPrefix(module + " ") && line.dropFirst(module.count).trimmingCharacters(in: .whitespaces).hasPrefix("→")
    }
    return String(try #require(line, "contracts: no dependency-graph line for \(module)"))
}

/// Markdown files under `directory` (recursive), skipping build output and node_modules.
private func markdownFiles(under directory: String) -> [URL] {
    let root = repositoryDirectory.appending(path: directory, directoryHint: .isDirectory)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
        if [".build", "node_modules", "DerivedData", "build"].contains(url.lastPathComponent) {
            enumerator.skipDescendants()
        } else if url.pathExtension == "md" {
            files.append(url)
        }
    }
    return files
}

/// Line numbers of fenced code blocks (``` or longer fences) with nothing but blank lines inside.
func emptyCodeBlocks(in text: String) -> [Int] {
    var result: [Int] = []
    var open: (line: Int, fence: Int, blank: Bool)?
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let ticks = line.prefix { $0 == "`" }.count
        if let block = open {
            if ticks >= block.fence, line.allSatisfy({ $0 == "`" }) {
                if block.blank { result.append(block.line) }
                open = nil
            } else if !line.isEmpty {
                open?.blank = false
            }
        } else if ticks >= 3 {
            open = (index + 1, ticks, true)
        }
    }
    return result
}

/// One `docs/CONTRACT_CHANGES.md` table row (escaped `\|` kept inside its cell).
struct ContractChangeRow {
    var line: Int
    var cells: [String]
    var module: String { cells.count > 1 ? cells[1] : "" }
    var status: String { cells.count == 5 ? cells[4] : "" }
}

func contractChangeRows(_ text: String) -> [ContractChangeRow] {
    text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
        guard line.hasPrefix("| 20") else { return nil }
        var cells: [String] = []
        var cell = ""
        var previous: Character?
        for character in line.dropFirst() {
            if character == "|", previous != "\\" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            previous = character
        }
        return ContractChangeRow(line: index + 1, cells: cells)
    }
}

/// Text that says an approval is still outstanding ("still need … approval", "awaits approval", "to confirm").
private var awaitingApproval: some RegexComponent {
    /\b(still|yet)\b[^.|]*\bapproval\b|\bawait(s|ing)?\b[^.|]*\bapproval\b|\bto confirm\b/.ignoresCase()
}

/// The statuses the header of docs/CONTRACT_CHANGES.md (the text before the table) defines: its bold terms, lowercased.
func definedContractChangeStatuses(_ text: String) -> [String] {
    let header = text.range(of: "\n| Date").map { String(text[..<$0.lowerBound]) } ?? text
    return header.matches(of: /\*\*([^*]+)\*\*/).map { String($0.output.1).lowercased() }
}

/// The public symbols a row lists under "**Additive API:**" (up to the next bold label or "Internal"): each backticked
/// name outside parentheses, cut to its dotted name ("`FMP4Muxer.accepts(video:)`" → "FMP4Muxer.accepts").
func additiveAPISymbols(in change: String) -> [String] {
    guard let start = change.range(of: "**Additive API:**") else { return [] }
    var section = change[start.upperBound...]
    if let end = section.range(of: "**") { section = section[..<end.lowerBound] }
    if let end = section.range(of: "Internal") { section = section[..<end.lowerBound] }
    var symbols: [String] = []
    var depth = 0          // parentheses outside code spans
    var span: String?      // the code span being read
    for character in section {
        if character == "`" {
            if let code = span {
                if depth == 0, let name = code.firstMatch(of: /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/) {
                    symbols.append(String(name.output.0))
                }
                span = nil
            } else {
                span = ""
            }
        } else if span != nil {
            span?.append(character)
        } else if character == "(" {
            depth += 1
        } else if character == ")" {
            depth = max(0, depth - 1)
        }
    }
    return symbols
}

/// Identifier words of each module README's "Additions beyond the contract" text (from each heading or bullet that says
/// so to the next heading), keyed by module.
private func readmeAdditions() throws -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    let modules = try FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
    for module in modules {
        let readme = module.appending(path: "README.md")
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { continue }
        var words: Set<String> = []
        var collecting = false
        for line in text.split(separator: "\n") {
            if line.lowercased().contains("additions beyond the contract") {
                collecting = true
            } else if line.hasPrefix("#") {
                collecting = false
            }
            if collecting { words.formUnion(identifierWords(line)) }
        }
        result[module.lastPathComponent] = words
    }
    return result
}

/// Frameworks PlatformApple imports beyond the package's own modules and the portable system modules.
private func platformAppleFrameworks() throws -> Set<String> {
    var frameworks: Set<String> = []
    for file in swiftFiles(under: sourcesDirectory.appending(path: "PlatformApple", directoryHint: .isDirectory)) {
        for item in scanImports(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent) {
            frameworks.insert(item.module)
        }
    }
    return frameworks.subtracting(packageModules.union(portableSystemModules))
}

@Suite struct DocsConsistencyTests {
    // MARK: Contracts portability rule and dependency graph

    @Test func contractsAllowEveryModuleThePortabilityScanAllows() throws {
        let allowed = identifierWords(try portabilityRuleParts().allowed)
        let scanned = portableSystemModules.union(externalModuleUsers.keys)
        let missing = scanned.subtracting(allowed).sorted()
        #expect(missing.isEmpty, "PortabilityTests allows these in portable modules, but the contracts' portability rule does not name them: \(missing)")
    }

    @Test func contractsForbidEveryAppleOnlyFrameworkTheScanRejects() throws {
        let forbidden = identifierWords(try portabilityRuleParts().forbidden)
        let missing = forbiddenModules.subtracting(forbidden).sorted()
        #expect(missing.isEmpty, "PortabilityTests rejects these in portable modules, but the contracts' \"**No** …\" list omits them: \(missing)")
    }

    /// Every portable file with Darwin/Glibc/Musl-only code, and every file a restricted import is confined to, is named
    /// in the contracts' portability section (paragraph or graph).
    @Test func contractsNameEveryPlatformConditionalFile() throws {
        let section = identifierWords(try portabilitySection())
        var names: [String: String] = [:]   // file name → why
        for (_, files) in try portableModuleSources() {
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                let conditional = text.split(separator: "\n").contains { line in
                    let line = line.trimmingCharacters(in: .whitespaces)
                    return (line.hasPrefix("#if ") || line.hasPrefix("#elseif "))
                        && line.contains(/canImport\((Darwin|Glibc|Musl)\)/)
                }
                if conditional { names[file.deletingPathExtension().lastPathComponent] = "has Darwin/Glibc/Musl-only code" }
            }
        }
        for (module, prefixes) in restrictedImportFiles {
            for prefix in prefixes {
                let name = String(prefix.split(separator: "/").last ?? "").replacingOccurrences(of: ".swift", with: "")
                names[name] = "is where PortabilityTests allows \(module)"
            }
        }
        let missing = names.filter { !section.contains($0.key) }.map { "\($0.key) (\($0.value))" }.sorted()
        #expect(missing.isEmpty, "the contracts' portability rule does not name: \(missing)")
    }

    @Test func platformAppleFrameworksAreListedInTheGraphAndREADME() throws {
        let frameworks = try platformAppleFrameworks()
        #expect(frameworks.contains("VideoToolbox"), "scan found no PlatformApple frameworks")

        let graph = identifierWords(try graphLine(for: "PlatformApple"))
        let missingInGraph = frameworks.subtracting(graph).sorted()
        #expect(missingInGraph.isEmpty, "PlatformApple imports these, but the contracts' dependency graph does not list them: \(missingInGraph)")

        let readme = try String(contentsOf: sourcesDirectory.appending(path: "PlatformApple/README.md"), encoding: .utf8)
        let intro = readme.range(of: "\n## ").map { String(readme[..<$0.lowerBound]) } ?? readme
        let missingInREADME = frameworks.subtracting(identifierWords(intro)).sorted()
        #expect(missingInREADME.isEmpty, "PlatformApple imports these, but its README's framework list omits them: \(missingInREADME)")
    }

    /// The comment above the PlatformApple target in Package.swift lists its Apple-only frameworks (by module name).
    @Test func packageManifestCommentListsThePlatformAppleFrameworks() throws {
        let frameworks = try platformAppleFrameworks()
        let manifest = try String(contentsOf: packageDirectory.appending(path: "Package.swift"), encoding: .utf8)
        let lines = manifest.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let target = try #require(lines.firstIndex { $0.hasPrefix(".target(name: \"PlatformApple\"") },
                                  "Package.swift: no PlatformApple target")
        let comment = try #require(target > 0 ? lines[target - 1] : nil)
        #expect(comment.hasPrefix("// macOS only:"), "Package.swift: the PlatformApple target has no \"// macOS only: …\" comment")
        let missing = frameworks.subtracting(identifierWords(comment)).sorted()
        #expect(missing.isEmpty, "PlatformApple imports these, but Package.swift's \"// macOS only:\" comment omits them: \(missing)")
    }

    @Test func markdownHasNoEmptyCodeBlocks() throws {
        let files = ["docs", "App", "Tools", "Interop", "Packages/CameraBridgeKit/Sources", "Packages/CameraBridgeKit/Tests"]
            .flatMap(markdownFiles(under:))
        #expect(files.contains { $0.lastPathComponent == "2026-09-30-camerabridge-contracts.md" })
        var found: [String] = []
        for file in files {
            let path = file.path().replacingOccurrences(of: repositoryDirectory.path(), with: "")
            found += emptyCodeBlocks(in: try String(contentsOf: file, encoding: .utf8)).map { "\(path):\($0)" }
        }
        #expect(found.isEmpty, "empty fenced code blocks:\n\(found.joined(separator: "\n"))")
    }

    @Test func emptyCodeBlockDetector() {
        #expect(emptyCodeBlocks(in: "a\n```swift\n```\nb") == [2])
        #expect(emptyCodeBlocks(in: "```\n  \n```") == [1])
        #expect(emptyCodeBlocks(in: "```swift\nlet a = 1\n```\n```text\nx\n```").isEmpty)
        #expect(emptyCodeBlocks(in: "````md\n```\n````").isEmpty)   // a longer fence quotes a bare ```
    }

    // MARK: CONTRACT_CHANGES

    @Test func contractChangeRowsHaveFiveCells() throws {
        let rows = contractChangeRows(try repositoryText(contractChangesPath))
        #expect(rows.count > 40)
        let malformed = rows.filter { $0.cells.count != 5 }.map { "line \($0.line): \($0.cells.count) cells" }
        #expect(malformed.isEmpty, "rows need Date | Module | Change | Reason | Status:\n\(malformed.joined(separator: "\n"))")
    }

    /// A row whose text still asks for approval must be **pending**; an approved row must not say it waits.
    @Test func contractChangeStatusesMatchTheirText() throws {
        let rows = contractChangeRows(try repositoryText(contractChangesPath))
        var contradictions: [String] = []
        for row in rows {
            let text = row.cells.dropLast().joined(separator: " | ")
            guard let match = text.firstMatch(of: awaitingApproval) else { continue }
            let phrase = text[match.range]
            let status = row.status.lowercased()
            if !status.contains("pending") || status.contains("approved") {
                contradictions.append("line \(row.line) (\(row.module)): says \"\(phrase)\" but its status is \"\(row.status)\"")
            }
        }
        #expect(contradictions.isEmpty, "\(contradictions.joined(separator: "\n"))")

        // The W3-3 engine change (sensors bridge only while a camera exists) was approved with the W3-3 review row
        // (commit 7491cf6); its status must say so.
        let w33 = try #require(rows.first { $0.module.hasSuffix("(W3-3)") })
        #expect(w33.status.contains("approved"), "line \(w33.line): \(w33.status)")
    }

    /// Every status starts with a term the header defines, so a contract change cannot hide under an undefined word
    /// (an orchestrator approving **pending** rows would skip a row marked "proposed").
    @Test func contractChangeStatusesAreDefinedInTheHeader() throws {
        let text = try repositoryText(contractChangesPath)
        let defined = definedContractChangeStatuses(text)
        #expect(defined.contains("pending"), "the header of docs/CONTRACT_CHANGES.md defines no **pending** status")
        let undefined = contractChangeRows(text).filter { row in
            let status = row.status.lowercased()
            return !defined.contains { status.hasPrefix($0) }
        }.map { "line \($0.line) (\($0.module)): \"\($0.status)\"" }
        #expect(undefined.isEmpty, "statuses the header does not define (it defines \(defined)):\n\(undefined.joined(separator: "\n"))")
    }

    @Test func definedStatusesAreTheHeadersBoldTerms() {
        let text = "Status **pending** means …; **additive**: …\n\n| Date | Module |\n|---|---|\n| 2026 | **Additive API:** x |"
        #expect(definedContractChangeStatuses(text) == ["pending", "additive"])
    }

    /// Until the orchestrator approves a **pending** row, the contract text it quotes says that a change is pending (and
    /// where), so the contracts never silently disagree with merged code.
    @Test func contractTextQuotedByPendingRowsIsMarkedPending() throws {
        let contracts = try repositoryText(contractsPath).split(separator: "\n", omittingEmptySubsequences: false)
        var unmarked: [String] = []
        for row in contractChangeRows(try repositoryText(contractChangesPath))
        where row.cells.count == 5 && row.status.lowercased().hasPrefix("pending") {
            for match in row.cells[2].matches(of: /"([^"]{12,})"/) {
                let phrase = String(match.output.1)
                for (index, line) in contracts.enumerated() where line.contains(phrase) {
                    if !(line.contains("pending") && line.contains("CONTRACT_CHANGES")) {
                        unmarked.append("contracts line \(index + 1): \"\(phrase)\" (CONTRACT_CHANGES line \(row.line), \(row.module))")
                    }
                }
            }
        }
        #expect(unmarked.isEmpty, "contract text a pending row changes needs a \"pending … CONTRACT_CHANGES\" note:\n\(unmarked.joined(separator: "\n"))")
    }

    /// Public API a row lists as **Additive API** is in its module README's "Additions beyond the contract" (the
    /// header's convention for non-breaking additions); a `Type.member` needs both names in the same README section.
    @Test func additiveAPIIsListedInTheModuleREADMEs() throws {
        let additions = try readmeAdditions()
        #expect(additions["BridgeSupport"]?.contains("LogSinkToken") == true, "no \"Additions beyond the contract\" found in the READMEs")
        var missing: [String] = []
        for row in contractChangeRows(try repositoryText(contractChangesPath)) where row.cells.count == 5 {
            for symbol in additiveAPISymbols(in: row.cells[2]) {
                let names = symbol.split(separator: ".").map(String.init)
                if !additions.values.contains(where: { words in names.allSatisfy(words.contains) }) {
                    missing.append("line \(row.line) (\(row.module)): \(symbol)")
                }
            }
        }
        #expect(missing.isEmpty, "additive API missing from every README's \"Additions beyond the contract\":\n\(missing.joined(separator: "\n"))")
    }

    @Test func additiveAPISymbolParsing() {
        let change = "Semantics. **Additive API:** `A.b(x:)` (`NotThis` here) / `c(d:)`; `E: Error`. Internal: `F`. **Other:** `G`."
        #expect(additiveAPISymbols(in: change) == ["A.b", "c", "E"])
        #expect(additiveAPISymbols(in: "no additions `X`").isEmpty)
    }

    @Test func approvalDetectorWording() {
        #expect("The previous row's change still needs the orchestrator's explicit approval.".contains(awaitingApproval))
        #expect("additive — orchestrator to confirm".contains(awaitingApproval))
        #expect("waits for orchestrator approval".contains(awaitingApproval) == false)   // the table header's wording
        #expect("approved (orchestrator, 2026-09-30)".contains(awaitingApproval) == false)
        #expect("W2-1/W3-1 need defined socket ownership. Approval".contains(awaitingApproval) == false)
    }

    // MARK: Licence notice and tool READMEs

    /// The derived Swift files and the definitions generator follow the HAP-NodeJS TypeScript sources of the version
    /// Interop/node pins (research brief: the 2.1.6 build is dist-only); the notice must name that version.
    @Test func acknowledgementsNameThePinnedHAPNodeJSVersion() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(try repositoryText("Interop/node/package.json").utf8)) as? [String: Any]
        let dependencies = manifest?["dependencies"] as? [String: String]
        let pin = try #require(dependencies?["@homebridge/hap-nodejs"], "Interop/node/package.json pins no @homebridge/hap-nodejs")
        let notice = try repositoryText("App/Resources/Acknowledgements.md")
        let named = notice.matches(of: /HAP-NodeJS\s+v?([0-9]+\.[0-9]+\.[0-9]+)/).map { String($0.output.1) }
        #expect(!named.isEmpty, "Acknowledgements names no HAP-NodeJS version")
        #expect(named.allSatisfy { $0 == pin }, "Acknowledgements names HAP-NodeJS \(named), Interop/node pins \(pin)")
    }

    @Test func cbctlPointerREADMELinksTheCommandReference() throws {
        let readme = try repositoryText("Tools/cbctl/README.md")
        let links = readme.matches(of: /\]\(([^)#\s]+)(#[^)\s]*)?\)/).map { String($0.output.1) }.filter { !$0.contains("://") }
        #expect(links.contains { $0.hasSuffix("Packages/CameraBridgeKit/Sources/cbctl/README.md") },
                "Tools/cbctl/README.md should link the command reference (Packages/CameraBridgeKit/Sources/cbctl/README.md)")
        let base = repositoryDirectory.appending(path: "Tools/cbctl", directoryHint: .isDirectory)
        for link in links {
            #expect(FileManager.default.fileExists(atPath: base.appending(path: link).standardizedFileURL.path()), "broken link \(link)")
        }
        let planWording = readme.firstMatch(of: /implemented in (task )?W[0-9]/).map { String($0.output.0) }
        #expect(planWording == nil, "Tools/cbctl/README.md still describes the commands as plan work")
    }
}
