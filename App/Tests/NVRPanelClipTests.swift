import BridgeEngine
import Foundation
import Testing

/// Choosing a clip on the shared panel: Save Clip sets the start, the playhead is the end, the cameras are kept, and letting go of the playhead does not
/// start playing.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NVRPanelClipTests {
    private func panel(_ harness: SessionHarness, scratch: ScratchDefaults, withExport: Bool = true) -> NVRPanelModel {
        let export = ClipExportModel(exporter: FakeClipExporter(), cameraNames: { [:] }, destinations: FakeClipDestinations(), freeSpace: { _ in nil },
                                     defaults: scratch.defaults, now: harness.wallClosure)
        let panel = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults, clipExport: withExport ? export : nil,
                                  wall: harness.wallClosure)
        harness.session.setCameras(harness.cameras)
        panel.setCameras(harness.cameras)
        panel.setClipCameras(harness.cameras)
        panel.setWidth(1_000)
        return panel
    }

    @Test func saveClipStartsAtThePlayheadAndTheEndIsWhereThePlayheadGoes() {
        let harness = SessionHarness(cameraCount: 2, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        harness.session.beginScrub()
        harness.session.scrub(to: harness.date(10))
        harness.session.finishPausedScrub()
        #expect(panel.saveClipUnavailableReason == nil && !panel.isChoosingClip)
        panel.beginClip()
        #expect(panel.isChoosingClip && panel.clipStart == harness.date(10) && panel.clipCameras == harness.cameras)
        harness.session.beginScrub()
        harness.session.scrub(to: harness.date(25))
        panel.endScrub()
        #expect(panel.clipSelection?.start == harness.date(10) && panel.clipSelection?.end == harness.date(25))
        #expect(!harness.session.clock.isPlaying && !harness.session.clock.isLive, "letting go while choosing stays paused")
        panel.beginClip()
        #expect(panel.clipStart == harness.date(25), "pressed again, the clip starts at the playhead instead")
        panel.cancelClip()
        #expect(!panel.isChoosingClip && panel.clipSelection == nil && panel.clipPreview == nil)
        harness.session.stopAll()
    }

    @Test func theChosenCamerasKeepAtLeastOneAndAllTakesThemBack() {
        let harness = SessionHarness(cameraCount: 3, withLive: false)
        let scratch = ScratchDefaults()
        let panel = panel(harness, scratch: scratch)
        harness.session.beginScrub()
        harness.session.scrub(to: harness.date(5))
        harness.session.finishPausedScrub()
        panel.beginClip()
        let ids = harness.cameras
        panel.toggleClipCamera(ids[1])
        #expect(panel.clipCameras == [ids[0], ids[2]] && !panel.includesInClip(ids[1]))
        panel.toggleClipCamera(ids[0])
        panel.toggleClipCamera(ids[2])
        #expect(panel.clipCameras == [ids[2]], "the last one stays")
        panel.toggleClipCamera(ids[0])
        #expect(panel.clipCameras == [ids[0], ids[2]], "back in the order of the page")
        panel.setAllClipCameras()
        #expect(panel.clipCameras == ids)
        panel.setClipCameras([ids[0], UUID()])
        #expect(panel.clipCameras == [ids[0]], "a camera that went away leaves the choice")
        harness.session.stopAll()
    }

    @Test func withoutRecordingsOrAnExporterSaveClipSaysWhyAndDoesNothing() {
        let harness = SessionHarness(cameraCount: 1, withLive: false)
        let scratch = ScratchDefaults()
        let without = panel(harness, scratch: scratch, withExport: false)
        #expect(without.saveClipUnavailableReason != nil)
        without.beginClip()
        #expect(!without.isChoosingClip)
        let empty = NVRPanelModel(archive: harness.archive, session: harness.session, defaults: scratch.defaults,
                                  clipExport: ClipExportModel(exporter: FakeClipExporter(), cameraNames: { [:] }, destinations: FakeClipDestinations(), freeSpace: { _ in nil },
                                                              defaults: scratch.defaults, now: harness.wallClosure),
                                  wall: harness.wallClosure)
        empty.setCameras([UUID()])
        #expect(empty.saveClipUnavailableReason != nil)
        empty.beginClip()
        #expect(!empty.isChoosingClip)
        harness.session.stopAll()
    }
}
