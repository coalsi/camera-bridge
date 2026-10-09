import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

@Suite struct SetupReportTests {
    private func check(_ id: String, _ status: HomeKitReadinessCheck.Status, _ fix: HomeKitReadinessCheck.FixMethod = .none) -> HomeKitReadinessCheck {
        HomeKitReadinessCheck(id: id, title: id, status: status, explanation: "", fixMethod: fix)
    }

    private func result(failedReason: CameraConfigFailure = .rejected("InvalidArgVal")) -> HomeKitOptimizationResult {
        HomeKitOptimizationResult(
            before: HomeKitReadinessReport(checks: [check("codec", .warning, .automatic), check("keyframeInterval", .problem, .automatic)]),
            after: HomeKitReadinessReport(checks: [check("codec", .ok), check("keyframeInterval", .problem, .automatic),
                                                   check("smartCodec", .warning, .manual(["Open http://192.168.1.20/ and tick H.264+"])),
                                                   check("audio", .ok)]),
            appliedFixes: ["codec"],
            failedFixes: [HomeKitOptimizationFailure(checkID: "keyframeInterval", reason: "x", attempts: [
                CameraConfigAttempt(method: .onvifMinimal, failure: failedReason),
                CameraConfigAttempt(method: .onvifFull, failure: .didNotStick)])],
            fixMethods: ["codec": .hikvisionISAPI], canUndo: true)
    }

    private func report(_ result: HomeKitOptimizationResult) -> SetupReport {
        SetupReport(result: result, vendor: "HIKVISION", model: "DS-2CD2143G2-I", firmware: "V5.7.15", appVersion: "1.0 (1)", osVersion: "macOS 27.0")
    }

    @Test func buildsTheDocumentedShape() throws {
        let report = report(result())
        #expect(report.schema == 1)
        #expect(report.readiness.map(\.id) == ["codec", "keyframeInterval", "smartCodec", "audio"])
        #expect(report.readiness.map(\.status) == ["ok", "problem", "warning", "ok"])
        #expect(report.methods == [
            .init(fix: "codec", method: "hikvisionISAPI", result: "ok", reason: nil),
            .init(fix: "keyframeInterval", method: "onvifMinimal", result: "failed", reason: "InvalidArgVal"),
            .init(fix: "keyframeInterval", method: "onvifFull", result: "failed", reason: "didn't stick"),
        ])
        // Failed and manual-only fixes, each once.
        #expect(report.unresolved == ["keyframeInterval", "smartCodec"])
        #expect(report.hasUnresolvedFixes)

        let object = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "appVersion", "osVersion", "vendor", "model", "firmware", "readiness", "methods", "unresolved"])
    }

    @Test func aCleanRunHasNothingToReport() {
        let clean = HomeKitOptimizationResult(before: HomeKitReadinessReport(checks: [check("codec", .warning, .automatic)]),
                                              after: HomeKitReadinessReport(checks: [check("codec", .ok)]),
                                              appliedFixes: ["codec"], fixMethods: ["codec": .onvifMinimal], canUndo: true)
        #expect(!report(clean).hasUnresolvedFixes)
    }

    @Test func prettyJSONIsExactlyWhatIsSent() throws {
        let report = report(result())
        #expect(Data(report.prettyJSON.utf8) == (try report.encoded()))
        let decoded = try JSONDecoder().decode(SetupReport.self, from: report.encoded())
        #expect(decoded == report)
    }

    @Test func failureReasonsAreScrubbed() {
        let dirty = CameraConfigFailure.rejected("bob@example.com 192.168.1.20 cam-garage.local")
        let report = report(result(failedReason: dirty))
        let text = report.prettyJSON
        for leaked in ["192.168", "bob@", "example.com", "garage", ".local"] {
            #expect(!text.contains(leaked), "leaked \(leaked)")
        }
    }

    @Test func scrubberRemovesAddressesAndIdentifiers() {
        let cases: [(String, [String])] = [
            ("no answer from 10.0.0.5:8000", ["10.0.0.5"]),
            ("fe80::1c2b:3d4e:5f60:7182 refused", ["fe80", "7182"]),
            ("mac AA:BB:CC:DD:EE:FF", ["AA:BB"]),
            ("see https://example.com/x?token=abc", ["example", "token", "https"]),
            ("mail me@host.tld", ["me@"]),
            ("camera.lan answered", ["camera.lan"]),
            ("serial DS2CD2143G2I20200101AAWR123456789 bad", ["WR123456789"]),
        ]
        for (input, forbidden) in cases {
            let out = SetupReportScrubber.reason(input) ?? ""
            for item in forbidden { #expect(!out.contains(item), "\(input) -> \(out)") }
        }
    }

    @Test func scrubberKeepsUsefulShortReasons() {
        #expect(SetupReportScrubber.reason("InvalidArgVal") == "InvalidArgVal")
        #expect(SetupReportScrubber.reason("ONVIF minimal: InvalidArgVal") == "ONVIF minimal: InvalidArgVal")
        #expect(SetupReportScrubber.reason("   ") == nil)
    }

    @Test func fieldsKeepVersionsButLoseAddressesAndLength() {
        #expect(SetupReportScrubber.field("V5.7.15 build 190909") == "V5.7.15 build 190909")
        #expect(SetupReportScrubber.field("RLC-810A") == "RLC-810A")
        #expect(SetupReportScrubber.field(nil) == nil)
        #expect(SetupReportScrubber.field("  ") == nil)
        #expect(SetupReportScrubber.field("Cam 192.168.1.9\nline")?.contains("192") == false)
        #expect((SetupReportScrubber.field(String(repeating: "a", count: 500)) ?? "").count == SetupReportScrubber.maximumFieldLength)
    }

    @Test func theExampleReportIsValidJSONOfTheSameShape() throws {
        let object = try #require(JSONSerialization.jsonObject(with: SetupReport.example.encoded()) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["unresolved"] as? [String] == ["smartCodec"])
    }
}
