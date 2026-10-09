import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing

/// Settings › Diagnostics › "Compare built-in motion detection with camera events (test)": off by default, saved by the
/// engine, and the table the Diagnostics page shows while it is on.
@Suite struct MotionShadowSettingsTests {
    @Test func theTestIsOffUntilTheOwnerTurnsItOnAndTheEngineSavesIt() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        #expect(!fixture.model.motionShadowTest, "off by default")
        await fixture.model.setMotionShadowTest(true)
        #expect(fixture.model.motionShadowTest && fixture.model.message == nil)
        #expect(fixture.engine.settings.motionShadowTest)
        #expect(BridgeEngine(environment: .testing(directory: fixture.directory)).settings.motionShadowTest, "persisted in config.json")
        await fixture.model.setMotionShadowTest(false)
        #expect(!fixture.model.motionShadowTest)
        #expect(!BridgeEngine(environment: .testing(directory: fixture.directory)).settings.motionShadowTest)
        await fixture.tearDown()
    }

    @Test func changingTheTestLeavesTheOtherSettingsAlone() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        await fixture.model.setKeepMacAwake(true)
        await fixture.model.setMotionShadowTest(true)
        #expect(fixture.model.keepMacAwake && fixture.model.motionShadowTest)
        await fixture.model.setKeepMacAwake(false)
        #expect(fixture.model.motionShadowTest, "turning keep-awake off does not turn the test off")
        await fixture.tearDown()
    }

    private func status(_ name: String, shadow: MotionShadowStatus?) -> CameraStatus {
        CameraStatus(id: UUID(), name: name, kind: .camera, vendor: .onvif, motionShadow: shadow)
    }

    @Test func theTableListsOnlyCamerasTheTestAppliesTo() {
        let compared = MotionShadowStatus(state: .comparing, sensitivity: 0.7, enabledSince: Date(),
                                          last24Hours: MotionShadowTotals(both: 5, cameraOnly: 1, builtInOnly: 2, medianDelaySeconds: 0.9),
                                          sinceEnabled: MotionShadowTotals(both: 8, cameraOnly: 2, builtInOnly: 3, medianDelaySeconds: -1.2), eventInProgress: true)
        let skipped = MotionShadowStatus(state: .paused("The camera has no sub stream"), sensitivity: 0.5, enabledSince: Date())
        let cameras = [status("Patio", shadow: compared), status("Hall", shadow: nil), status("Gate", shadow: skipped)]

        let day = MotionShadowTable.rows(cameras, span: .last24Hours)
        #expect(day.map(\.name) == ["Patio", "Gate"], "a camera without the test (a webhook camera, the test off) has no row")
        #expect(day[0].both == 5 && day[0].cameraOnly == 1 && day[0].builtInOnly == 2)
        #expect(day[0].medianDelay.hasPrefix("0.9") && day[0].medianDelay.hasSuffix("later"))
        #expect(day[0].sensitivity.contains("70"))
        #expect(day[0].eventInProgress && day[0].pauseReason == nil)
        #expect(day[1].pauseReason == "The camera has no sub stream" && day[1].both == 0)
        #expect(day[1].medianDelay == "—")

        let since = MotionShadowTable.rows(cameras, span: .sinceEnabled)
        #expect(since[0].both == 8 && since[0].cameraOnly == 2 && since[0].builtInOnly == 3)
        #expect(since[0].medianDelay.hasPrefix("1.2") && since[0].medianDelay.hasSuffix("earlier"), "built-in came first")
    }

    @Test func theDelayIsWrittenInWords() {
        #expect(MotionShadowTable.delayText(nil) == "—")
        #expect(MotionShadowTable.delayText(0.01) == "Same time")
        #expect(MotionShadowTable.delayText(2.04).hasPrefix("2.0") && MotionShadowTable.delayText(2.04).hasSuffix("later"))
        #expect(MotionShadowTable.delayText(-0.5).hasSuffix("earlier"))
        #expect(MotionShadowTable.sensitivityText(1.4).contains("100"), "clamped")
    }
}
