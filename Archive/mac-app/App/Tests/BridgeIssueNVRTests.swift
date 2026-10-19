import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite struct BridgeIssueNVRTests {
    private func camera(_ state: ArchiveRecordingState) -> CameraStatus {
        CameraStatus(id: UUID(), name: "Gate", kind: .camera, vendor: .rtsp, nvr: CameraArchiveStatus(state: state))
    }

    @Test func recordingThatCannotContinueIsAnIssueOnlyWhileSomeCameraHasRecordOn() {
        let storage = ArchiveStorageStatus(pause: .folderMissing)
        #expect(BridgeIssue.nvrPause(storage: storage, cameras: [camera(.off), camera(.off)]) == nil, "nobody records: a missing drive is nobody's problem")
        #expect(BridgeIssue.nvrPause(storage: storage, cameras: []) == nil)
        #expect(BridgeIssue.nvrPause(storage: storage, cameras: [camera(.off), camera(.waiting("waiting for the camera"))]) == .folderMissing)
        #expect(BridgeIssue.nvrPause(storage: nil, cameras: [camera(.recording)]) == nil)
        #expect(BridgeIssue.nvrPause(storage: ArchiveStorageStatus(), cameras: [camera(.recording)]) == nil, "a drive without a pause is fine")
    }

    @Test func aCamerasOwnPauseCountsWhenTheDriveHasNone() {
        let stalled = camera(.paused(.notWritable("The drive isn’t answering.")))
        #expect(BridgeIssue.nvrPause(storage: ArchiveStorageStatus(), cameras: [camera(.recording), stalled]) == .notWritable("The drive isn’t answering."))
        #expect(BridgeIssue.nvrPause(storage: ArchiveStorageStatus(pause: .diskFull), cameras: [stalled]) == .diskFull, "the drive's pause comes first")
        #expect(BridgeIssue.nvrPause(storage: nil, cameras: [camera(.paused(.noFolder))]) == .noFolder, "Record on with no folder")
    }

    @Test func waitingForTheCameraIsNotAnIssue() {
        #expect(BridgeIssue.nvrPause(storage: ArchiveStorageStatus(), cameras: [camera(.waiting("waiting for the camera"))]) == nil)
    }

    @Test func theIssueHasTheLowestPrecedence() {
        let pause = ArchivePause.diskFull
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .granted, nvrPause: pause) == .nvrStorage(.diskFull))
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .granted, webhookProblem: "x", nvrPause: pause) == .webhookNotListening("x"))
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .denied, nvrPause: pause) == .localNetworkDenied)
        #expect(BridgeIssue.current(state: .failed("Port in use"), localNetworkAccess: .granted, nvrPause: pause) == .startFailed("Port in use"))
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .granted) == nil, "unchanged for every existing call")
    }

    @Test func theBannerSaysWhatToDo() {
        let none = BridgeIssue.nvrStorage(.noFolder), full = BridgeIssue.nvrStorage(.diskFull), missing = BridgeIssue.nvrStorage(.folderMissing)
        #expect(none.title == "Recording Can’t Continue" && full.title == "Recording Can’t Continue")
        #expect(none.detail == ArchivePause.noFolder.readable && missing.detail == ArchivePause.folderMissing.readable)
        #expect(none.actionTitle == "Choose Folder…")
        #expect(full.actionTitle == "Open Recording Settings" && missing.actionTitle == "Open Recording Settings")
        #expect(BridgeIssue.nvrStorage(.notWritable("The drive isn’t answering.")).detail == "The drive isn’t answering.")
        #expect(full.menuItemTitle == "Recording Can’t Continue — Show…")
        #expect(StatusText.menuBarSymbol(state: .running, issue: full) == "exclamationmark.triangle")
        #expect(StatusText.menuBarAccessibilityLabel(state: .running, issue: full) == "Camera Bridge, Recording Can’t Continue")
    }
}
