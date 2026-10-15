import Foundation
import Testing

/// What a notarized, hardened, unsandboxed Developer ID app must keep saying about itself once it records to a drive the person chose
/// (docs/distribution.md): the two network entitlements and nothing else, and readable prompts for the places macOS protects.
@Suite struct DistributionGuardTests {
    private let appDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appDirectory.appending(path: name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theEntitlementsAreStillTheTwoNetworkOnes() throws {
        let entitlements = try plist("CameraBridge.entitlements")
        #expect(Set(entitlements.keys) == ["com.apple.security.network.client", "com.apple.security.network.server"],
                "recording to a folder needs no entitlement outside the sandbox; docs/distribution.md lists exactly these two")
        #expect(entitlements.values.allSatisfy { ($0 as? Bool) == true })
    }

    @Test func recordingDrivesGetReadablePermissionPrompts() throws {
        let info = try plist("Info.plist")
        // The places macOS asks about when a program that is not sandboxed first reads a folder there: the text of the prompt is ours or a generic one.
        let places = ["NSRemovableVolumesUsageDescription": "drive", "NSNetworkVolumesUsageDescription": "network drive",
                      "NSDocumentsFolderUsageDescription": "Documents", "NSDesktopFolderUsageDescription": "Desktop", "NSDownloadsFolderUsageDescription": "Downloads"]
        for (key, word) in places {
            let text = try #require(info[key] as? String, "\(key) is missing from Info.plist (add it to project.yml, info.properties)")
            #expect(text.hasPrefix("Camera Bridge ") && text.contains(word) && text.contains("record") && text.count < 200, "\(key): \(text)")
            #expect(!text.contains("HomeKit"), "product copy says Apple Home, never HomeKit as a name")
        }
    }

    @Test func theOtherInfoKeysAreUnchanged() throws {
        let info = try plist("Info.plist")
        #expect(info["NSBonjourServices"] as? [String] == ["_hap._tcp"])
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.hasPrefix("Camera Bridge connects to the security cameras") == true)
        #expect((info["NSAppTransportSecurity"] as? [String: Bool])?["NSAllowsLocalNetworking"] == true)
        #expect(info["SUFeedURL"] as? String == "https://www.camera-bridge.app/appcast.xml")
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
    }
}
