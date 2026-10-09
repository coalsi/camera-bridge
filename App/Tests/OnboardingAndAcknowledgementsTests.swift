import BridgeEngine
import Foundation
import Testing

@Suite struct OnboardingContentTests {
    private var allText: String {
        OnboardingContent.prerequisites.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")
    }

    @Test func prerequisitesCoverHubsOSPlansAndTheAddAnywayPrompt() {
        let text = allText
        for phrase in ["Apple TV 4K", "HomePod mini", "HomePod (2nd generation)", "macOS 15", "iCloud+", "50 GB", "200 GB", "2 TB",
                       "Summarize Videos", "Add Anyway"] {
            #expect(text.contains(phrase), "missing \(phrase)")
        }
        #expect(Set(OnboardingContent.prerequisites.map(\.id)).count == OnboardingContent.prerequisites.count)
    }

    @Test func localNetworkGuidance() {
        #expect(OnboardingContent.localNetworkStatus(.granted) == "Local Network access is allowed.")
        #expect(OnboardingContent.localNetworkStatus(.unknown).contains("Check Access"))
        let denied = OnboardingContent.localNetworkStatus(.denied)
        #expect(denied.contains("denied"))
        #expect(OnboardingContent.localNetworkFixSteps.joined(separator: " ").contains("Privacy & Security"))
        #expect(OnboardingContent.localNetworkFixSteps.joined(separator: " ").contains("Local Network"))
    }
}

@Suite struct AcknowledgementsTests {
    private var resourceText: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/Acknowledgements.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func bundledNoticesCoverEveryShippedDependency() throws {
        let text = try resourceText
        #expect(text.contains("not affiliated with, endorsed by, or sponsored by Apple Inc."))
        #expect(text.contains("HAP-NodeJS") && text.contains("Apache License"))
        #expect(text.contains("BigInt") && text.contains("MIT License"))
        #expect(text.contains("swift-crypto") && text.contains("swift-asn1"))
        #expect(text.contains("go2rtc") && text.contains("Alexey Khit"))
    }

    @Test func parsesSectionsFromMarkdown() throws {
        let sections = Acknowledgements.sections(fromMarkdown: try resourceText)
        #expect(sections.map(\.title) == ["HAP-NodeJS", "swift-crypto", "swift-asn1", "BigInt", "Sparkle", "go2rtc"])
        #expect(sections.allSatisfy { !$0.body.isEmpty })
        #expect(sections[0].body.contains("Apache License"))
    }

    @Test func fallsBackWhenTheResourceIsMissing() {
        #expect(Acknowledgements.load(from: Bundle(for: FakeSetupService.self)).isEmpty == false)
        #expect(Acknowledgements.notAffiliated == "Camera Bridge is not affiliated with Apple Inc.")
    }
}
