import BridgeEngine
import SwiftUI

/// The sidebar's Sensors section: the sensors the Sensors Bridge publishes, listed under the camera that provides them (a
/// source row with the camera's thumbnail, then its sensors with a state dot). A source or sensor row opens the Sensors page on
/// that camera; the chevron folds a camera's list (long lists start folded; the choice is remembered). "Sensors Settings" opens
/// the whole page, with pairing and the QR code.
struct SensorsSidebarSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let groups = model.sensorGroups()
        let total = groups.reduce(0) { $0 + $1.sensors.count }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Sensors")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                if total > 0 {
                    Text("\(total)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)

            if groups.isEmpty {
                Button { model.showSensors(for: nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sensor")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("No sensors yet — set them up")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brandSurface(radius: 14, highlighted: model.selection == .sensorsBridge)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("No sensors yet. Set them up."))
                .accessibilityAddTraits(.isButton)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.sensorGroups(now: context.date)) { group in
                            SensorGroupCard(model: model, group: group, now: context.date)
                        }
                    }
                }
            }

            Button { model.showSensors(for: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sensor.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.amber)
                        .accessibilityHidden(true)
                    Text("Sensors Settings")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandSurface(radius: 12, highlighted: model.selection == .sensorsBridge && model.sensorsFocus == nil)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Pairing, the QR code and everything the sensors bridge publishes")
            .accessibilityLabel(Text("Sensors Settings"))
            .accessibilityAddTraits(model.selection == .sensorsBridge && model.sensorsFocus == nil ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// One camera's sensors: its source row, and the sensors below it while it is open.
private struct SensorGroupCard: View {
    let model: AppModel
    let group: SidebarSensorGroup
    let now: Date

    var body: some View {
        let isExpanded = model.isSensorGroupExpanded(group)
        let isFocused = model.selection == .sensorsBridge && model.sensorsFocus == group.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { model.showSensors(for: group.id) } label: {
                    HStack(spacing: 9) {
                        CameraThumbnail(model: model, cameraID: group.id, kind: group.kind)
                            .frame(width: 44, height: 25)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(SensorsSidebar.countText(group.sensors.count))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(group.name)’s sensors")
                .accessibilityLabel(Text("\(group.name), \(SensorsSidebar.countText(group.sensors.count))"))
                .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)

                Button {
                    withAnimation(.snappy(duration: 0.18)) { model.setSensorGroup(group, expanded: !isExpanded) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide the sensors" : "Show the sensors")
                .accessibilityLabel(Text(isExpanded ? "Collapse \(group.name)’s sensors" : "Expand \(group.name)’s sensors"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.sensors) { sensor in
                        SensorRow(sensor: sensor, now: now) { model.showSensors(for: group.id) }
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .brandSurface(radius: 14, highlighted: isFocused)
    }
}

private struct SensorRow: View {
    let sensor: SidebarSensor
    let now: Date
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: sensor.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(sensor.isActive ? Brand.warning : Color.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(sensor.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(sensor.stateText(now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(sensor.title), \(sensor.stateText(now: now))"))
        .accessibilityAddTraits(.isButton)
    }

    private var color: Color {
        switch sensor.state {
        case .detected: Brand.warning
        case .clear: Brand.live
        case .published: Brand.neutral
        }
    }
}
