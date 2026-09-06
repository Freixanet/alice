import SwiftUI

/// The pairing confirmation: the device name to declare, the "connecting…"
/// wait, and the outcome. Lives inside a sheet that either the scanner or
/// the `alice://pair` deep link opened, and talks to the AppStore through
/// the same connect paths the manual form uses.
struct PairingForm: View {
    let link: String
    /// Called when the reader is finished looking at the result. The scanner
    /// sheet dismisses itself with it; the deep-link sheet closes the sheet.
    let onDone: () -> Void

    @Environment(AppStore.self) private var store
    @State private var flow: PairingFlow?

    var body: some View {
        Form {
            if let flow {
                switch flow.stage {
                case .confirming: confirmation(flow)
                case .claiming, .connecting: progress(flow)
                case let .connected(profile): connected(profile)
                case let .failed(message): failure(flow, message)
                }
            } else {
                Text("This pairing code is incomplete or damaged.")
                    .foregroundStyle(.red)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .onAppear {
            if flow == nil { flow = PairingFlow(link: link) }
        }
    }

    @Environment(\.colorScheme) private var scheme

    // MARK: - Stages

    private func confirmation(_ flow: PairingFlow) -> some View {
        Section {
            if let profile = flow.payload?.profileName {
                LabeledContent("Profile", value: profile)
            }
            TextField("Device name", text: deviceNameBinding(flow))
                .textInputAutocapitalization(.words)
            Button {
                Task { await flow.run(store: store) }
            } label: {
                Text("Connect")
            }
        } header: {
            Text("Pair with your Hermes")
        } footer: {
            Text("Your Hermes will hand over its address and key once you confirm. The name says which device paired.")
        }
    }

    private func progress(_ flow: PairingFlow) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(flow.stage == .claiming
                    ? "Contacting your Hermes…"
                    : "Connecting to your Hermes…")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func connected(_ profile: String?) -> some View {
        Section {
            LabeledContent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } label: {
                Text("Connected")
            }
            if let profile, !profile.isEmpty {
                LabeledContent("Profile", value: profile)
            }
            LabeledContent("Device", value: flow?.deviceName ?? "")
            Button("Done") { onDone() }
        } footer: {
            Text("The key and the dashboard login are held in the Keychain on this iPhone only.")
        }
    }

    private func failure(_ flow: PairingFlow, _ message: String) -> some View {
        Section {
            Text(message).foregroundStyle(.red)
            if flow.payload != nil {
                Button("Try again") {
                    Task { await flow.run(store: store) }
                }
            }
            Button("Close") { onDone() }
        } footer: {
            Text("A QR works once and for five minutes. If it will not take, run the pairing command on your Hermes again.")
        }
    }

    // MARK: - Plumbing

    private func deviceNameBinding(_ flow: PairingFlow) -> Binding<String> {
        Binding(
            get: { flow.deviceName },
            set: { flow.deviceName = $0 }
        )
    }
}

/// The deep-link presentation: iOS opens Alice with `alice://pair?…` and
/// this sheet appears over whatever the app was doing.
struct PairingSheet: View {
    let link: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            PairingForm(link: link, onDone: onDismiss)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
        }
    }
}
