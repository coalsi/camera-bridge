import BridgeEngine
import SwiftUI

/// The "CameraBridge Sensors" bridge accessory: its QR code, and which camera signals it publishes.
struct SensorsBridgeView: View {
    let model: AppModel

    var body: some View {
        let engine = model.engine
        let unavailable = StatusText.sensorsBridgeUnavailable(state: engine.state, bridge: engine.sensorsBridge, hasCameras: !engine.configurations.isEmpty)
        ScrollViewReader { proxy in
        Form {
            if unavailable == nil, let bridge = engine.sensorsBridge {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "sensor.fill")
                            .font(.title)
                            .foregroundStyle(Brand.onAmber)
                            .frame(width: 52, height: 52)
                            .background(Brand.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Camera Bridge Sensors")
                                .font(.title2.weight(.semibold))
                            Text(bridge.accessoryCount == 1 ? String(localized: "1 sensor") : String(localized: "\(bridge.accessoryCount) sensors"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                PairingSection(accessoryName: String(localized: "Camera Bridge Sensors"), isPaired: bridge.isPaired, setupCode: bridge.setupCode,
                               setupURI: bridge.setupURI) {
                    Task { await model.resetSensorsBridgePairing() }
                }
            } else {
                Section {
                    ContentUnavailableView("Sensors Bridge Isn’t Running", systemImage: "sensor", description: Text(unavailable ?? ""))
                }
            }

            // The engine's own list (kept after a pause or stop: what the bridge published last).
            CamerasWithSensorsSection(model: model, configurations: engine.configurations, published: engine.sensorsBridge?.publishedSensors)
                .id(Self.camerasSectionID)

            Section {
                SignalRow(signal: String(localized: "Person, vehicle, animal or package"), accessory: String(localized: "Occupancy sensor, on for 60 seconds"))
                SignalRow(signal: String(localized: "Day and night"), accessory: String(localized: "Light sensor: 1 lux at night, 1000 lux by day"))
                SignalRow(signal: String(localized: "Tampering"), accessory: String(localized: "Tampered status on the camera’s sensors"))
                SignalRow(signal: String(localized: "Camera offline"), accessory: String(localized: "Fault status on the camera’s sensors"))
                SignalRow(signal: String(localized: "Alarm input"), accessory: String(localized: "Contact sensor"))
                SignalRow(signal: String(localized: "Temperature or humidity"), accessory: String(localized: "Temperature or humidity sensor"))
            } header: {
                Text("What Appears in the Home App")
            } footer: {
                Text("Sensors are created only for signals a camera provides and you turn on. They never start recordings; only motion and doorbell rings do.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .listRowBackground(BrandRowBackground())
        .frame(maxWidth: 1_000)
        .frame(maxWidth: .infinity)
        .navigationTitle("Sensors Bridge")
        // A sensor or camera in the sidebar's Sensors section: the page scrolls to that camera's sensors.
        .onChange(of: model.sensorsFocus, initial: true) { _, focus in
            guard focus != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.camerasSectionID, anchor: .top) }
            }
        }
        }
    }

    private static let camerasSectionID = "cameras-with-sensors"
}

private struct CamerasWithSensorsSection: View {
    let model: AppModel
    let configurations: [CameraConfiguration]
    /// The bridge's sensors per camera (`SensorsBridgeStatus.publishedSensors`); nil before it first ran.
    let published: [UUID: [BridgedSensor]]?

    var body: some View {
        let focus = model.sensorsFocus.flatMap { id in configurations.first { $0.id == id } }
        Section {
            if let published {
                // What the bridge publishes, not every option that is on: webhook detections after the motion source
                // changed, or an alarm input the camera hasn't reported yet, are not published.
                let rows = SensorKind.cameraRows(configurations, published: published)
                if rows.isEmpty {
                    Text("No camera has sensors turned on. Turn them on in a camera’s details.")
                        .foregroundStyle(.secondary)
                }
                if let focus, let group = model.sensorGroups().first(where: { $0.id == focus.id }) {
                    // One camera: each sensor with what it shows now.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let current = model.sensorGroups(now: context.date).first { $0.id == focus.id } ?? group
                        ForEach(current.sensors) { sensor in
                            LabeledContent {
                                HStack(spacing: 6) {
                                    Circle().fill(sensor.isActive ? Brand.warning : Brand.live).frame(width: 7, height: 7).accessibilityHidden(true)
                                    Text(sensor.stateText(now: context.date))
                                }
                            } label: {
                                Label(sensor.title, systemImage: sensor.symbol)
                            }
                        }
                    }
                } else {
                    ForEach(rows) { row in
                        LabeledContent(row.name, value: row.sensors.formatted(.list(type: .and)))
                    }
                }
            } else {
                Text("The cameras’ sensors are listed once the sensors bridge runs.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                if let focus {
                    Text("Sensors of \(focus.name)")
                } else {
                    Text("Cameras With Sensors")
                }
                Spacer()
                if focus != nil {
                    Button("Show All Cameras") { model.sensorsFocus = nil }
                        .buttonStyle(.link)
                        .textCase(nil)
                }
            }
        }
    }
}

private struct SignalRow: View {
    let signal: String
    let accessory: String

    var body: some View {
        LabeledContent(signal, value: accessory)
    }
}

#Preview {
    SensorsBridgeView(model: .preview())
        .frame(width: 700, height: 800)
}
