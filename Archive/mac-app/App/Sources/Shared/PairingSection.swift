import SwiftUI

/// "Apple Home" form section: the QR code and setup code while unpaired, the paired state and Reset Pairing after.
/// While the accessory isn't published (`blocker`: bridge paused or stopped, camera off) the code isn't offered — the
/// Home app couldn't find the accessory — and the section says why, with the fix when there is one.
struct PairingSection: View {
    let accessoryName: String
    let isPaired: Bool
    let setupCode: String
    let setupURI: String
    var blocker: PairingBlocker? = nil
    var resolve: (PairingBlocker.Action) -> Void = { _ in }
    let onReset: () -> Void
    @State private var confirmingReset = false

    var body: some View {
        Section {
            if isPaired {
                LabeledContent("Status") {
                    Label("Added to Apple Home", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("Pairing") {
                    Button("Reset Pairing…", role: .destructive) { confirmingReset = true }
                }
            } else if let blocker {
                PairingBlockedRow(blocker: blocker, resolve: resolve)
            } else if setupURI.isEmpty {
                LabeledContent("Status", value: String(localized: "Waiting for the bridge to publish this accessory…"))
            } else {
                HStack(alignment: .top, spacing: 20) {
                    QRCodeView(uri: setupURI)
                        .frame(width: 148, height: 148)
                        .padding(10)
                        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with the Home app")
                            .font(.headline)
                        SetupCodeText(code: setupCode)
                        Text("On iPhone or iPad, open the Home app, tap Add (+), then Add Accessory, and scan this code or enter it. When the Home app says the accessory isn’t certified, tap Add Anyway.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Apple Home")
        }
        .confirmationDialog("Reset pairing for “\(accessoryName)”?", isPresented: $confirmingReset) {
            Button("Reset Pairing", role: .destructive, action: onReset)
        } message: {
            Text("“\(accessoryName)” stops working in the Home app and gets a new setup code. Remove it from the Home app, then add it again.")
        }
    }
}

/// Why the code isn't offered, and the fix (Resume Bridge, Start Bridge) when there is one.
struct PairingBlockedRow: View {
    let blocker: PairingBlocker
    let resolve: (PairingBlocker.Action) -> Void

    var body: some View {
        LabeledContent {
            if let action = blocker.action {
                Button(action.title) { resolve(action) }
            }
        } label: {
            Label {
                Text(blocker.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "qrcode")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    Form {
        PairingSection(accessoryName: "Front Door", isPaired: false, setupCode: "631-58-204", setupURI: "X-HM://00GW95DQA7OSX", onReset: {})
        PairingSection(accessoryName: "Garage", isPaired: false, setupCode: "259-73-610", setupURI: "X-HM://0081YCYEP3QXO",
                       blocker: .bridgePaused, onReset: {})
        PairingSection(accessoryName: "Driveway", isPaired: true, setupCode: "482-17-935", setupURI: "X-HM://0081YCYEP3QXO", onReset: {})
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 520)
}
