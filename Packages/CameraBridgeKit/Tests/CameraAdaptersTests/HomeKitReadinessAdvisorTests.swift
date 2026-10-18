import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

@Suite struct HomeKitReadinessAdvisorTests {
    private func snapshot(main: CameraVideoEncoderSettings?, sub: CameraVideoEncoderSettings? = nil, supportsONVIF: Bool = true) -> CameraSettingsSnapshot {
        CameraSettingsSnapshot(supportsONVIF: supportsONVIF,
                               mainProfile: main.map { CameraVideoProfile(id: "main", name: "Main", settings: $0, options: []) },
                               subProfile: sub.map { CameraVideoProfile(id: "sub", name: "Sub", settings: $0, options: []) })
    }

    // MARK: Table-driven: each row is one check's ok/warning/problem boundary.

    private struct Row {
        let name: String
        let main: CameraVideoEncoderSettings
        let checkID: String
        let expectedStatus: HomeKitReadinessCheck.Status
    }

    private static let rows: [Row] = [
        Row(name: "H.264 main stream is ok", main: .h264(), checkID: "codec", expectedStatus: .ok),
        Row(name: "HEVC main stream warns", main: .h264(encoding: "H265"), checkID: "codec", expectedStatus: .warning),
        Row(name: "4 s keyframe interval is ok", main: .h264(fps: 20, gov: 80), checkID: "keyframeInterval", expectedStatus: .ok),
        Row(name: "20 s keyframe interval is a problem", main: .h264(fps: 20, gov: 400), checkID: "keyframeInterval", expectedStatus: .problem),
        Row(name: "15-25 fps is ok", main: .h264(fps: 20), checkID: "frameRate", expectedStatus: .ok),
        Row(name: "5 fps is a problem", main: .h264(fps: 5, gov: 10), checkID: "frameRate", expectedStatus: .problem),
        Row(name: "30 fps warns (wastes bitrate)", main: .h264(fps: 30, gov: 60), checkID: "frameRate", expectedStatus: .warning),
        Row(name: "4 Mbps bitrate is ok", main: .h264(bitrate: 4000), checkID: "bitrate", expectedStatus: .ok),
        Row(name: "500 Kbps bitrate warns", main: .h264(bitrate: 500), checkID: "bitrate", expectedStatus: .warning),
        Row(name: "10 Mbps bitrate warns", main: .h264(bitrate: 10000), checkID: "bitrate", expectedStatus: .warning),
        Row(name: "1080p resolution is ok", main: .h264(width: 1920, height: 1080), checkID: "resolution", expectedStatus: .ok),
        Row(name: "4K resolution warns", main: .h264(width: 3840, height: 2160), checkID: "resolution", expectedStatus: .warning),
    ]

    @Test("Advisor grades each rule's boundary correctly", arguments: rows.indices)
    func gradesBoundary(_ index: Int) {
        let row = Self.rows[index]
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .hikvision, deviceInfo: nil, snapshot: snapshot(main: row.main))
        let check = report.checks.first { $0.id == row.checkID }
        #expect(check?.status == row.expectedStatus, "\(row.name): expected \(row.expectedStatus), got \(String(describing: check?.status))")
    }

    @Test func bFramesAreAlwaysAProblemWhenDetected() {
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot(main: .h264()),
                                                       mainStreamFacts: MeasuredStreamFacts(hasBFrames: true))
        #expect(report.checks.first { $0.id == "bFrames" }?.status == .problem)
    }

    @Test func noBFramesIsOK() {
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot(main: .h264()),
                                                       mainStreamFacts: MeasuredStreamFacts(hasBFrames: false))
        #expect(report.checks.first { $0.id == "bFrames" }?.status == .ok)
    }

    @Test func goodSubStreamIsOK() {
        let sub = CameraVideoEncoderSettings(token: "001", name: "sub", encoding: "H264", resolution: CameraResolution(width: 640, height: 360),
                                             frameRate: 15, bitrate: 512, iFrameInterval: 30)
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot(main: .h264(), sub: sub))
        #expect(report.checks.first { $0.id == "subStream" }?.status == .ok)
    }

    @Test func missingSubStreamWarnsWithManualSteps() {
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .hikvision, deviceInfo: nil, snapshot: snapshot(main: .h264(), sub: nil))
        let check = report.checks.first { $0.id == "subStream" }
        #expect(check?.status == .warning)
        if case .manual(let steps) = check?.fixMethod { #expect(!steps.isEmpty) } else { Issue.record("expected manual steps") }
    }

    @Test func smartCodecCheckGivesVendorSpecificSteps() {
        // Hikvision's SmartCodec is switched off by the optimizer over ISAPI, so it's an automatic fix.
        let hikvision = HomeKitReadinessAdvisor.evaluate(vendor: .hikvision, deviceInfo: nil, snapshot: snapshot(main: .h264()))
        if case .automatic = hikvision.checks.first(where: { $0.id == "smartCodec" })?.fixMethod {} else {
            Issue.record("expected an automatic smart-codec fix for .hikvision")
        }
        for vendor: CameraVendor in [.reolink, .onvif] {
            let report = HomeKitReadinessAdvisor.evaluate(vendor: vendor, deviceInfo: nil, snapshot: snapshot(main: .h264()))
            let check = report.checks.first { $0.id == "smartCodec" }
            guard case .manual(let steps) = check?.fixMethod else { Issue.record("expected manual steps for \(vendor)"); continue }
            #expect(!steps.isEmpty)
        }
    }

    @Test func noONVIFFallsBackToBuiltInMotionDetection() {
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .rtsp, deviceInfo: nil, snapshot: snapshot(main: nil, supportsONVIF: false))
        #expect(report.checks.first { $0.id == "motionEvents" }?.status == .warning)
    }

    @Test func perfectCameraScoresHigh() {
        let sub = CameraVideoEncoderSettings(token: "001", name: "sub", encoding: "H264", resolution: CameraResolution(width: 640, height: 360),
                                             frameRate: 15, bitrate: 512, iFrameInterval: 30)
        let report = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot(main: .h264(), sub: sub),
                                                       mainStreamFacts: MeasuredStreamFacts(codec: "H264", hasBFrames: false, audioCodec: "AAC"))
        #expect(report.score >= 80)
        #expect(report.problemCount == 0)
    }

    @Test func worseningEveryRuleLowersTheScore() {
        let good = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot(main: .h264()))
        let bad = HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil,
                                                   snapshot: snapshot(main: .h264(encoding: "H265", fps: 5, gov: 1000, bitrate: 200)))
        #expect(bad.score < good.score)
    }

    /// The ONVIF check while logins are paused says whose pause it is (the camera's lock, or Camera Bridge's own after a refused login), with
    /// its end in the bridge's time zone (`BridgeTime`), not the process's (UTC on the box). Checked in two zones, Phoenix and UTC, each with
    /// its own clock: with one zone the test could not tell the bridge's from the process's on a machine that runs in it.
    @Test func aLoginPauseSaysWhoseItIsAndEndsInTheBridgesTimeZone() throws {
        let until = try Date("2026-10-18T16:19:37Z", strategy: .iso8601)
        let phoenix = try #require(TimeZone(identifier: "America/Phoenix")), utc = try #require(TimeZone(identifier: "UTC"))
        #expect(BridgeTime.clock(until, in: phoenix) != BridgeTime.clock(until, in: utc))
        for (zone, other) in [(phoenix, utc), (utc, phoenix)] {
            var paused = snapshot(main: nil, supportsONVIF: false)
            paused.onvifLoginRejected = true
            paused.onvifLoginPausedUntil = until
            func onvifCheck(_ snapshot: CameraSettingsSnapshot) throws -> HomeKitReadinessCheck {
                let report = BridgeTime.$taskZone.withValue(zone) { HomeKitReadinessAdvisor.evaluate(vendor: .onvif, deviceInfo: nil, snapshot: snapshot) }
                return try #require(report.checks.first { $0.id == "onvif" })
            }
            let clock = BridgeTime.clock(until, in: zone)

            let refused = try onvifCheck(paused)
            #expect(refused.status == .problem)
            #expect(refused.explanation.contains("The camera refused the username or password Camera Bridge has, so Camera Bridge waits until \(clock) "
                                                 + "before it logs in again, so the camera doesn't lock the account."), "\(zone.identifier): \(refused.explanation)")
            #expect(refused.explanation.contains("Check the camera's username and password in Camera Bridge"))
            #expect(!refused.explanation.contains("locked") && !refused.explanation.contains(BridgeTime.clock(until, in: other)), "\(zone.identifier)")

            paused.onvifLoginLockedByCamera = true
            let locked = try onvifCheck(paused)
            #expect(locked.explanation.hasPrefix("The camera locked its logins after too many wrong passwords. Camera Bridge waits until \(clock) "
                                                 + "before it tries again"), "\(zone.identifier): \(locked.explanation)")
            #expect(locked.recommendedValue == "Wait until \(clock)", "\(zone.identifier)")
        }
    }

    @Test func manualStepsAreEmptyForUnmappedChecks() {
        #expect(HomeKitReadinessAdvisor.manualSteps(vendor: .demo, checkID: "smartCodec").isEmpty)
        #expect(HomeKitReadinessAdvisor.manualSteps(vendor: .hikvision, checkID: "notARealCheck").isEmpty)
    }
}

private extension CameraVideoEncoderSettings {
    static func h264(encoding: String = "H264", fps: Double = 20, gov: Int = 40, bitrate: Int = 3000, width: Int = 1920,
                     height: Int = 1080) -> CameraVideoEncoderSettings {
        CameraVideoEncoderSettings(token: "000", name: "main", encoding: encoding, resolution: CameraResolution(width: width, height: height),
                                   frameRate: fps, bitrate: bitrate, iFrameInterval: gov)
    }
}
