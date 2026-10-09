import Foundation
import Testing
@testable import CameraAdapters

@Suite struct CameraProfileFeedTests {
    private func feed(_ json: String) throws -> CameraProfileFeed {
        try #require(CameraProfileFeed.decode(Data(json.utf8)))
    }

    private let sample = """
    {"version": 3, "updated": "2026-10-01", "profiles": [
      {"vendor": "Hikvision", "modelPattern": "^DS-2CD2\\\\d{3}G2", "firmwarePattern": "^V5\\\\.7",
       "preferredConfigMethod": "hikvisionISAPI", "notes": "ISAPI first",
       "manualSteps": {"smartCodec": ["Turn off H.264+"]}},
      {"vendor": "hikvision", "modelPattern": "DS-2CD", "preferredConfigMethod": "onvifFull",
       "manualSteps": {"smartCodec": ["ignored: first match wins"], "audio": ["Enable audio"]}},
      {"vendor": "Reolink", "modelPattern": "doorbell", "preferredConfigMethod": "reolinkAPI"}
    ]}
    """

    @Test func decodesVersionAsNumberOrString() throws {
        #expect(try feed(sample).version == "3")
        #expect(try feed(#"{"version": "2026.10", "profiles": []}"#).version == "2026.10")
    }

    @Test func matchesVendorModelAndFirmware() throws {
        let feed = try feed(sample)
        let match = feed.match(vendor: .onvif, manufacturer: "HIKVISION", model: "DS-2CD2143G2-I", firmware: "V5.7.15 build 1")
        #expect(match.preferredConfigMethod == .hikvisionISAPI)
        #expect(match.notes == "ISAPI first")
    }

    @Test func firmwareMismatchFallsToTheNextProfile() throws {
        let match = try feed(sample).match(vendor: .hikvision, manufacturer: nil, model: "DS-2CD2143G2-I", firmware: "V5.5.0")
        #expect(match.preferredConfigMethod == .onvifFull)
    }

    @Test func aProfileWithFirmwarePatternNeedsAFirmware() throws {
        let match = try feed(sample).match(vendor: .hikvision, manufacturer: nil, model: "DS-2CD2143G2-I", firmware: nil)
        #expect(match.preferredConfigMethod == .onvifFull)
    }

    @Test func manualStepsMergeWithFirstMatchWinningPerCheck() throws {
        let match = try feed(sample).match(vendor: .hikvision, manufacturer: "Hikvision", model: "DS-2CD2143G2-I", firmware: "V5.7.1")
        #expect(match.manualSteps["smartCodec"] == ["Turn off H.264+"])
        #expect(match.manualSteps["audio"] == ["Enable audio"])
    }

    @Test func vendorMustMatch() throws {
        let match = try feed(sample).match(vendor: .reolink, manufacturer: "Reolink", model: "DS-2CD2143G2-I", firmware: "V5.7.1")
        #expect(match.preferredConfigMethod == nil)
        #expect(match.manualSteps.isEmpty)
    }

    @Test func matchingIsCaseInsensitive() throws {
        let match = try feed(sample).match(vendor: .reolink, manufacturer: "REOLINK", model: "Reolink Video Doorbell PoE", firmware: nil)
        #expect(match.preferredConfigMethod == .reolinkAPI)
    }

    @Test func unknownMethodNameIsNoPreferenceAndABadProfileIsDropped() throws {
        let feed = try feed("""
        {"version": 1, "profiles": [
          {"vendor": "Acme", "modelPattern": "X", "preferredConfigMethod": "quantum"},
          {"modelPattern": "missing vendor"},
          {"vendor": "Acme", "modelPattern": "Y", "preferredConfigMethod": "onvifMinimal"}]}
        """)
        #expect(feed.profiles.count == 2)
        #expect(feed.match(vendor: nil, manufacturer: "Acme", model: "X1", firmware: nil).preferredConfigMethod == nil)
        #expect(feed.match(vendor: nil, manufacturer: "Acme", model: "Y1", firmware: nil).preferredConfigMethod == .onvifMinimal)
    }

    @Test func invalidRegexMatchesNothing() throws {
        let feed = try feed(#"{"version": 1, "profiles": [{"vendor": "Acme", "modelPattern": "(", "preferredConfigMethod": "onvifFull"}]}"#)
        #expect(feed.match(vendor: nil, manufacturer: "Acme", model: "(", firmware: nil) == .empty)
    }

    @Test func garbageIsNotAFeed() {
        #expect(CameraProfileFeed.decode(Data("<html>".utf8)) == nil)
        #expect(CameraProfileFeed.decode(Data(#"{"version": 1}"#.utf8)) == nil)
    }

    @Test func refreshIsDueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CameraProfileRefreshPolicy.isDue(lastCheck: nil, now: now))
        #expect(!CameraProfileRefreshPolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(!CameraProfileRefreshPolicy.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        #expect(CameraProfileRefreshPolicy.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(CameraProfileRefreshPolicy.isDue(lastCheck: now.addingTimeInterval(600), now: now))   // clock went backwards
    }

    @Test func manualStepOverridesReplaceBuiltInStepsOnlyWhereTheCheckNeedsThePerson() {
        let snapshot = CameraSettingsSnapshot(supportsONVIF: true)
        let plain = HomeKitReadinessAdvisor.evaluate(vendor: .hikvision, deviceInfo: nil, snapshot: snapshot)
        let overridden = HomeKitReadinessAdvisor.evaluate(vendor: .hikvision, deviceInfo: nil, snapshot: snapshot,
                                                          manualStepOverrides: ["timeSync": ["Use the profile's steps"], "codec": ["never"]])
        let time = overridden.checks.first { $0.id == "timeSync" }
        #expect(time?.status != .ok)
        #expect(time?.fixMethod == .manual(["Use the profile's steps"]))
        // A check that is fine, or that CameraBridge fixes automatically, keeps what it had, whatever the feed says.
        for (before, after) in zip(plain.checks, overridden.checks) where before.status == .ok || before.fixMethod == .automatic {
            #expect(before == after)
        }
    }
}
