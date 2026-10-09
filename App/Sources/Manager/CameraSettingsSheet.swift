import AppKit
import BridgeEngine
import CameraAdapters
import SwiftUI

/// "Camera Settings…": the camera's own ONVIF video encoder and imaging controls, bounded by the ranges the camera
/// itself reports. Load → edit → Save/Revert. A camera with no ONVIF service shows just its web page link (the
/// camera detail page's "Open Camera Web Page" button covers that; this sheet explains it and offers nothing else).
struct CameraSettingsSheet: View {
    let model: AppModel
    let cameraID: UUID
    let name: String
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: CameraSettingsSnapshot?
    @State private var mainDraft: CameraVideoEncoderSettings?
    @State private var subDraft: CameraVideoEncoderSettings?
    @State private var imagingDraft: CameraImagingSettings?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var statusMessage: StatusMessage?
    @State private var confirmingReboot = false
    @State private var isRebooting = false

    private struct StatusMessage {
        var text: String
        var isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera Settings for “\(name)”")
                .font(.headline)
            Group {
                if isLoading {
                    ProgressView("Loading settings…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let snapshot, snapshot.supportsONVIF {
                    Form {
                        if let mainDraft {
                            EncoderSection(title: "Main Stream", options: snapshot.mainProfile?.options ?? [],
                                           draft: Binding(get: { mainDraft }, set: { self.mainDraft = $0 }))
                        }
                        if let subDraft {
                            EncoderSection(title: "Sub Stream", options: snapshot.subProfile?.options ?? [],
                                           draft: Binding(get: { subDraft }, set: { self.subDraft = $0 }))
                        }
                        if let imagingDraft {
                            ImagingSection(options: snapshot.imagingOptions,
                                           draft: Binding(get: { imagingDraft }, set: { self.imagingDraft = $0 }))
                        }
                        if let device = snapshot.deviceInfo {
                            DeviceInfoSection(device: device)
                        }
                        Section {
                            Button("Restart Camera…", role: .destructive) { confirmingReboot = true }
                                .disabled(isRebooting)
                        } footer: {
                            Text("Restarts the camera itself (not just its stream to Camera Bridge). The live view and any recording in progress stop briefly.")
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No ONVIF Settings", systemImage: "network.slash",
                                           description: Text("This camera didn’t answer ONVIF, so Camera Bridge can’t show its settings here. Use “Open Camera Web Page” on the camera page instead."))
                        .frame(minHeight: 240)
                }
            }
            if let statusMessage {
                Label(statusMessage.text, systemImage: statusMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(statusMessage.isError ? .red : .secondary)
            }
            HStack {
                if snapshot?.supportsONVIF == true {
                    Button("Revert") { Task { await load() } }
                        .disabled(isLoading || isSaving)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if snapshot?.supportsONVIF == true {
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isLoading || isSaving)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
        .confirmationDialog("Restart “\(name)”?", isPresented: $confirmingReboot) {
            Button("Restart Camera", role: .destructive) { Task { await reboot() } }
        } message: {
            Text("The camera itself restarts; its live view and any recording in progress stop for a moment.")
        }
    }

    private func load() async {
        isLoading = true
        statusMessage = nil
        do {
            let snapshot = try await model.cameraSettings(cameraID: cameraID)
            self.snapshot = snapshot
            mainDraft = snapshot.mainProfile?.settings
            subDraft = snapshot.subProfile?.settings
            imagingDraft = snapshot.imaging
        } catch {
            statusMessage = StatusMessage(text: Self.describe(error), isError: true)
            snapshot = CameraSettingsSnapshot(supportsONVIF: false)
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        statusMessage = nil
        var change = CameraSettingsChange()
        if let mainDraft, mainDraft != snapshot?.mainProfile?.settings { change.mainEncoder = mainDraft }
        if let subDraft, subDraft != snapshot?.subProfile?.settings { change.subEncoder = subDraft }
        if let imagingDraft, imagingDraft != snapshot?.imaging { change.imaging = imagingDraft }
        do {
            try await model.applyCameraSettings(cameraID: cameraID, change)
            let resolutionChanged = change.mainEncoder?.resolution != nil && change.mainEncoder?.resolution != snapshot?.mainProfile?.settings.resolution
            statusMessage = StatusMessage(
                text: resolutionChanged
                    ? "Saved. If this camera records with HomeKit Secure Video, you may need to turn recording off and on again for it in the Home app."
                    : "Saved.",
                isError: false)
            await load()
        } catch {
            statusMessage = StatusMessage(text: Self.describe(error), isError: true)
        }
        isSaving = false
    }

    private func reboot() async {
        isRebooting = true
        do {
            try await model.rebootCamera(cameraID: cameraID)
            statusMessage = StatusMessage(text: "The camera is restarting.", isError: false)
        } catch {
            statusMessage = StatusMessage(text: Self.describe(error), isError: true)
        }
        isRebooting = false
    }

    private static func describe(_ error: any Error) -> String {
        if case CameraAdapterError.unauthorized = error { return String(localized: "The camera rejected the user name or password.") }
        if case CameraAdapterError.unsupported(let what) = error { return String(localized: "Not supported by this camera (\(what)).") }
        return ErrorText.describe(error)
    }
}

private struct EncoderSection: View {
    let title: String
    let options: [CameraVideoEncoderOptions]
    @Binding var draft: CameraVideoEncoderSettings

    private var currentOptions: CameraVideoEncoderOptions? {
        options.first { $0.encoding.caseInsensitiveCompare(draft.encoding) == .orderedSame }
    }

    var body: some View {
        Section {
            if options.count > 1 {
                Picker("Codec", selection: $draft.encoding) {
                    ForEach(options, id: \.encoding) { Text($0.encoding).tag($0.encoding) }
                }
            }
            if let currentOptions, !currentOptions.resolutions.isEmpty {
                Picker("Resolution", selection: Binding(get: { draft.resolution ?? currentOptions.resolutions[0] },
                                                         set: { draft.resolution = $0 })) {
                    ForEach(currentOptions.resolutions, id: \.self) { resolution in
                        Text("\(resolution.width)×\(resolution.height)").tag(resolution)
                    }
                }
            }
            if let range = currentOptions?.frameRateRange {
                Stepper(value: Binding(get: { draft.frameRate ?? range.lowerBound }, set: { draft.frameRate = $0 }),
                        in: range, step: 1) {
                    LabeledContent("Frame Rate", value: "\(Int(draft.frameRate ?? range.lowerBound)) fps")
                }
            }
            if let range = currentOptions?.bitrateRange {
                Stepper(value: Binding(get: { draft.bitrate ?? range.lowerBound }, set: { draft.bitrate = $0 }),
                        in: range, step: max(1, (range.upperBound - range.lowerBound) / 32)) {
                    LabeledContent("Bit Rate", value: "\(draft.bitrate ?? range.lowerBound) Kbit/s")
                }
            }
            if let range = currentOptions?.iFrameIntervalRange {
                Stepper(value: Binding(get: { draft.iFrameInterval ?? range.lowerBound }, set: { draft.iFrameInterval = $0 }),
                        in: range, step: 1) {
                    LabeledContent("I-Frame Interval", value: "\(draft.iFrameInterval ?? range.lowerBound) frames")
                }
            }
            if let profiles = currentOptions?.h264ProfilesSupported, !profiles.isEmpty, draft.encoding.uppercased() == "H264" {
                Picker("H.264 Profile", selection: Binding(get: { draft.h264Profile ?? profiles[0] }, set: { draft.h264Profile = $0 })) {
                    ForEach(profiles, id: \.self) { Text($0).tag($0) }
                }
            }
            if !draft.isRecommendedForHomeKit {
                Label("For HomeKit Secure Video recording, H.264 with an I-frame interval of about 4 seconds or less (roughly twice the frame rate) works best, with no smart/adaptive codec.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        }
    }
}

private struct ImagingSection: View {
    let options: CameraImagingOptions?
    @Binding var draft: CameraImagingSettings

    var body: some View {
        Section {
            if let range = options?.brightnessRange {
                slider("Brightness", value: Binding(get: { draft.brightness ?? range.lowerBound }, set: { draft.brightness = $0 }), range: range)
            }
            if let range = options?.contrastRange {
                slider("Contrast", value: Binding(get: { draft.contrast ?? range.lowerBound }, set: { draft.contrast = $0 }), range: range)
            }
            if let range = options?.saturationRange {
                slider("Saturation", value: Binding(get: { draft.saturation ?? range.lowerBound }, set: { draft.saturation = $0 }), range: range)
            }
            if let range = options?.sharpnessRange {
                slider("Sharpness", value: Binding(get: { draft.sharpness ?? range.lowerBound }, set: { draft.sharpness = $0 }), range: range)
            }
            if let modes = options?.irCutModesSupported, !modes.isEmpty {
                Picker("Night Vision (IR)", selection: Binding(get: { draft.irCutMode ?? modes[0] }, set: { draft.irCutMode = $0 })) {
                    ForEach(modes) { mode in Text(Self.title(mode)).tag(mode) }
                }
            }
            if options?.wideDynamicRangeSupported == true {
                Toggle("Wide Dynamic Range", isOn: Binding(get: { draft.wideDynamicRangeEnabled ?? false }, set: { draft.wideDynamicRangeEnabled = $0 }))
            }
            if options?.backlightCompensationSupported == true {
                Toggle("Backlight Compensation", isOn: Binding(get: { draft.backlightCompensationEnabled ?? false },
                                                                set: { draft.backlightCompensationEnabled = $0 }))
            }
        } header: {
            Text("Image")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
                .frame(width: 220)
        }
    }

    private static func title(_ mode: CameraIRCutMode) -> String {
        switch mode {
        case .on: String(localized: "On (Night)")
        case .off: String(localized: "Off (Day)")
        case .auto: String(localized: "Automatic")
        }
    }
}

private struct DeviceInfoSection: View {
    let device: CameraDeviceInfo

    var body: some View {
        Section {
            LabeledContent("Manufacturer", value: device.manufacturer)
            LabeledContent("Model", value: device.model)
            LabeledContent("Firmware", value: device.firmwareVersion)
            LabeledContent("Serial Number", value: device.serialNumber)
        } header: {
            Text("Device")
        }
    }
}

#Preview {
    let model = AppModel.preview()
    let id = model.engine.cameras[0].id
    return CameraSettingsSheet(model: model, cameraID: id, name: model.engine.cameras[0].name)
}
