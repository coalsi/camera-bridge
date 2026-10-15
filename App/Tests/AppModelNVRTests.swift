import BridgeEngine
import Foundation
import Testing

/// The NVR in the app model: the viewer and the NVR page as navigation, and the Record switches over a real engine in a temporary directory
/// (the folder chooser and the folder check are injected: no panel opens, and the check is tested with the archive store).
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppModelNVRTests {
    private func previewModel() -> (AppModel, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, previewLatency: .zero)
        return (model, scratch)
    }

    // MARK: Navigation

    @Test func anyNavigationClosesTheViewerEvenToThePageThatIsAlreadySelected() {
        let (model, scratch) = previewModel()
        _ = scratch
        let id = PreviewSample.firstCameraID(in: model.engine)
        model.selection = .overview
        model.expandCamera(id)
        #expect(model.expandedCameraID == id)
        model.selection = .overview   // a click on the Overview card while it is selected: the same value
        #expect(model.expandedCameraID == nil && model.selection == .overview)
        model.expandCamera(id, start: ViewerStart(time: Date(timeIntervalSinceReferenceDate: 800_000_000), playing: true))
        model.selection = .sensorsBridge
        #expect(model.expandedCameraID == nil && model.expandedStart == nil, "the start goes with the viewer")
    }

    @Test func theViewerOpensAtATimeAndKeepsItUntilItIsClosed() {
        let (model, scratch) = previewModel()
        _ = scratch
        let id = PreviewSample.firstCameraID(in: model.engine)
        let start = ViewerStart(time: Date(timeIntervalSinceReferenceDate: 800_000_000), playing: false)
        model.expandCamera(id, start: start)
        #expect(model.expandedCameraID == id && model.expandedStart == start)
        model.expandCamera(id)
        #expect(model.expandedStart == nil, "opened again without a time: live")
        model.expandCamera(id, start: start)
        model.closeExpandedCamera()
        #expect(model.expandedCameraID == nil && model.expandedStart == nil)
        model.expandCamera(id, start: start)
        model.openCameraPage(id)
        #expect(model.expandedStart == nil && model.selection == .camera(id))
    }

    // MARK: Record

    private func recordingFixture(cameras: Int = 1) async throws -> (LiveEngineFixture, [UUID]) {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        var ids: [UUID] = []
        for index in 0..<cameras {
            let camera = LiveEngineFixture.disabledCamera("Gate \(index)")
            try await fixture.engine.addCamera(camera, password: nil)
            ids.append(camera.id)
        }
        return (fixture, ids)
    }

    private func configurationBytes(_ fixture: LiveEngineFixture) throws -> Data {
        try Data(contentsOf: fixture.directory.appending(path: "config.json"))
    }

    @Test func theFirstRecordAsksWhereAndCancelChangesNothing() async throws {
        let (fixture, ids) = try await recordingFixture()
        let model = fixture.model, engine = fixture.engine
        let asked = Box(0)
        model.nvrFolderPicker = {
            asked.value += 1
            return nil   // Cancel
        }
        let before = try configurationBytes(fixture)
        await model.setNVRRecording(true, camera: ids[0])
        #expect(asked.value == 1)
        #expect(engine.configurations[0].nvrEnabled == false && engine.settings.nvrFolder == nil)
        #expect(try configurationBytes(fixture) == before, "Cancel persists nothing: config.json is byte-identical")
        #expect(!model.isRecording(ids[0]) && !model.isRecordChangePending(ids[0]) && model.message == nil)
        await fixture.tearDown()
    }

    @Test func aFolderThatCannotHoldRecordingsIsShownAndNothingChanges() async throws {
        let (fixture, ids) = try await recordingFixture()
        let model = fixture.model, engine = fixture.engine
        model.nvrFolderPicker = { URL(fileURLWithPath: "/Volumes/Recordings") }
        model.nvrFolderInspector = { _ in throw ArchiveFolderError.notFound }
        let before = try configurationBytes(fixture)
        await model.setNVRRecording(true, camera: ids[0])
        #expect(model.message?.title == "Can’t Record There")
        #expect(model.message?.detail.contains("doesn’t exist") == true, "the sentence of the folder check, not a case name")
        #expect(engine.configurations[0].nvrEnabled == false && engine.settings.nvrFolder == nil)
        #expect(try configurationBytes(fixture) == before)
        await fixture.tearDown()
    }

    @Test func anAcceptedFolderIsSavedRecordTurnsOnAndTheNextCameraDoesNotAskAgain() async throws {
        let (fixture, ids) = try await recordingFixture(cameras: 2)
        let model = fixture.model, engine = fixture.engine
        let folder = fixture.directory.appending(path: "Recordings", directoryHint: .isDirectory)
        let asked = Box(0), checked = Box<[URL]>([])
        model.nvrFolderPicker = {
            asked.value += 1
            return folder
        }
        model.nvrFolderInspector = { checked.value.append($0) }
        await model.setNVRRecording(true, camera: ids[0])
        #expect(asked.value == 1 && checked.value == [folder.standardizedFileURL])
        #expect(engine.settings.nvrFolder == folder.standardizedFileURL.path)
        #expect(engine.configurations[0].nvrEnabled && model.isRecording(ids[0]) && !engine.configurations[1].nvrEnabled)
        #expect(model.message == nil)

        await model.setNVRRecording(true, camera: ids[1])
        #expect(asked.value == 1, "the folder is known now")
        #expect(engine.configurations.allSatisfy { $0.nvrEnabled })

        await model.setNVRRecording(false, camera: ids[0])
        #expect(!engine.configurations[0].nvrEnabled && engine.configurations[1].nvrEnabled && asked.value == 1, "off needs no folder")
        await fixture.tearDown()
    }

    @Test func theSwitchShowsTheNewValueAtOnceWhileTheChangeIsOnItsWay() async throws {
        let (fixture, ids) = try await recordingFixture()
        let model = fixture.model
        let gate = Gate()
        model.nvrFolderPicker = {
            await gate.wait()
            return nil
        }
        let change = Task { @MainActor in await model.setNVRRecording(true, camera: ids[0]) }
        await eventually { model.isRecordChangePending(ids[0]) }
        #expect(model.isRecording(ids[0]) && model.pendingRecord[ids[0]] == true, "pending, shown on")
        gate.open()
        await change.value
        #expect(!model.isRecording(ids[0]) && !model.isRecordChangePending(ids[0]), "cancelled: back to the configuration's value")
        await fixture.tearDown()
    }

    @Test func recordSoundIsItsOwnSwitchAndOffByDefault() async throws {
        let (fixture, ids) = try await recordingFixture()
        let model = fixture.model, engine = fixture.engine
        #expect(!model.recordsSound(ids[0]) && !engine.configurations[0].nvrRecordSound)
        await model.setNVRRecordSound(true, camera: ids[0])
        #expect(engine.configurations[0].nvrRecordSound && model.recordsSound(ids[0]) && !engine.configurations[0].nvrEnabled)
        await model.setNVRRecordSound(false, camera: ids[0])
        #expect(!engine.configurations[0].nvrRecordSound)
        await fixture.tearDown()
    }

    @Test func previewModeSkipsRecordWithTheUsualNotice() async {
        let (model, scratch) = previewModel()
        _ = scratch
        let id = PreviewSample.firstCameraID(in: model.engine)
        let before = model.engine.configurations
        await model.setNVRRecording(true, camera: id)
        #expect(model.notice?.contains("Preview mode") == true && model.engine.configurations == before)
    }

    @Test func theChooseFlowIsSharedByTheBannerAndSettings() async throws {
        let (fixture, _) = try await recordingFixture()
        let model = fixture.model, engine = fixture.engine
        let folder = fixture.directory.appending(path: "Recordings", directoryHint: .isDirectory)
        model.nvrFolderPicker = { folder }
        model.nvrFolderInspector = { _ in }
        #expect(await model.chooseNVRFolder())
        #expect(engine.settings.nvrFolder == folder.standardizedFileURL.path)
        model.nvrFolderPicker = { nil }
        #expect(await model.chooseNVRFolder() == false && engine.settings.nvrFolder == folder.standardizedFileURL.path, "Cancel keeps the folder")
        await fixture.tearDown()
    }

    @Test func theFolderChooserStartsOnADriveOtherThanTheStartupVolumeWhenOneIsMounted() {
        let movies = URL(fileURLWithPath: "/Users/someone/Movies", isDirectory: true)
        let drive = URL(fileURLWithPath: "/Volumes/Recordings", isDirectory: true)
        #expect(AppModel.pickerStart(drives: [drive, URL(fileURLWithPath: "/Volumes/Other")], movies: movies) == drive)
        #expect(AppModel.pickerStart(drives: [], movies: movies) == movies, "no drive: Movies")
        #expect(AppModel.pickerStart(drives: [], movies: nil) == nil)
        #expect(AppModel.mountedDrives().allSatisfy { $0.path != "/" }, "never the startup volume")
    }

    @Test func aFolderBelowItsFloorIsRefusedWithTheSentenceAndNothingChanges() async throws {
        let (fixture, _) = try await recordingFixture()
        let model = fixture.model, engine = fixture.engine
        let before = engine.settings.nvrFolder
        model.nvrFolderPicker = { URL(fileURLWithPath: "/Volumes/Small", isDirectory: true) }
        model.nvrFolderInspector = { _ in throw ArchiveFolderError.belowFloor(freeBytes: 81_000_000_000, floorBytes: 99_400_000_000) }
        #expect(await model.chooseNVRFolder() == false)
        #expect(engine.settings.nvrFolder == before, "nothing was saved")
        #expect(model.message?.detail.contains("needs 99.4 GB free to record, and has 81.0 GB") == true, "the person reads the numbers: \(model.message?.detail ?? "no message")")
        await fixture.tearDown()
    }

    @Test func theBannersActionsOpenTheFolderChooserOrTheRecordingSettings() async throws {
        let (fixture, _) = try await recordingFixture()
        let model = fixture.model
        let asked = Box(0)
        model.nvrFolderPicker = {
            asked.value += 1
            return nil
        }
        await model.resolve(.nvrStorage(.noFolder))
        #expect(asked.value == 1, "Choose Folder…")
        await model.resolve(.nvrStorage(.diskFull))
        #expect(asked.value == 1 && fixture.settingsRequests == 1, "Open Recording Settings")
        #expect(fixture.scratch.defaults.string(forKey: SettingsTab.storageKey) == "recording", "on the Recording tab")
        model.show(.nvrStorage(.folderMissing))   // the menu bar's item
        #expect(fixture.settingsRequests == 2)
        await fixture.tearDown()
    }
}
