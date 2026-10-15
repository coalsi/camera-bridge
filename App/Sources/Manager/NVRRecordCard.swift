import BridgeEngine
import SwiftUI

/// Record and Record sound for one camera, on its page: the switches, where it records to, why it is not recording, and the note about a long group
/// of pictures (a smart-codec camera) with the way to fix it. "Record" is the NVR; the camera page's Recording tab is the Home app's recording.
struct NVRRecordCard: View {
    let model: AppModel
    let cameraID: UUID
    let status: CameraStatus
    let configuration: CameraConfiguration
    let readiness: ReadinessState

    var body: some View {
        let isOn = model.isRecording(cameraID)
        SectionCard(title: "Record", systemImage: "circle.fill") {
            SettingToggleRow(title: "Record",
                             detail: "Saves this camera’s main stream, in full quality, to the recordings folder. Look back at it from the timeline.",
                             isOn: Binding(get: { isOn }, set: { on in Task { await model.setNVRRecording(on, camera: cameraID) } }))
                .disabled(model.isRecordChangePending(cameraID))
            if isOn || model.recordsSound(cameraID) {
                SettingDivider()
                SettingToggleRow(title: "Record sound",
                                 detail: configuration.audioEnabled ? "Also saves what the camera hears." : "Turn on this camera’s audio first: there is no sound to save.",
                                 isOn: Binding(get: { model.recordsSound(cameraID) }, set: { on in Task { await model.setNVRRecordSound(on, camera: cameraID) } }))
                    .disabled(!configuration.audioEnabled || model.isRecordChangePending(cameraID))
            }
            if isOn { stateLine }
            ForEach(status.nvr.notes) { note in
                SettingProblem(text: note.text) {
                    if note.id == .keyframe, configuration.hasCameraInterface {
                        Button("Optimize…") { readiness.showingOptimizeSheet = true }
                            .buttonStyle(.brand(.secondary))
                            .disabled(!readiness.canAct)
                    }
                }
                if note.id == .keyframe {
                    SettingNote("Optimize for HomeKit also limits the bit rate to 6 Mbps and may change H.265 to H.264, which lowers the quality of what is recorded afterwards. You can undo it from the same sheet.")
                }
            }
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch status.nvr.state {
        case .off:
            EmptyView()
        case .recording:
            let folder = model.engine.settings.nvrFolder.map { URL(fileURLWithPath: $0).lastPathComponent }
            Label(folder.map { String(localized: "Recording to “\($0)”") } ?? String(localized: "Recording"), systemImage: "record.circle.fill")
                .font(.callout).foregroundStyle(Brand.recording)
        case .waiting(let reason):
            Label(reason.prefix(1).uppercased() + reason.dropFirst(), systemImage: "hourglass").font(.callout).foregroundStyle(Brand.warning)
        case .paused(let pause):
            SettingProblem(text: pause.readable) {
                if case .noFolder = pause {
                    Button("Choose Folder…") { Task { await model.chooseNVRFolder() } }.buttonStyle(.brand(.secondary))
                } else {
                    Button("Open Recording Settings") { model.openRecordingSettings() }.buttonStyle(.brand(.secondary))
                }
            }
        }
    }
}
