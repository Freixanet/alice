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
    @Environment(\.colorScheme) private var scheme
    @State private var flow: PairingFlow?

    var body: some View {
        Form {
            if let flow {
                switch flow.stage {
                case .confirming:
                    confirmation(flow)
                case .claiming, .connecting:
                    progress(flow)
                case let .connected(profile, dashboardWarning):
                    connected(
                        flow,
                        profile: profile,
                        dashboardWarning: dashboardWarning
                    )
                case let .failed(message, retryable):
                    failure(flow, message: message, retryable: retryable)
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

    // MARK: - Stages

    private func confirmation(_ flow: PairingFlow) -> some View {
        Section {
            if store.isConnected {
                Label("Alice is already connected to Hermes.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Confirming this pairing replaces the current Hermes connection. If the new gateway cannot be reached, Alice restores the current connection automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let profile = flow.payload?.profileName {
                LabeledContent("Profile", value: profile)
            }
            TextField("Device name", text: deviceNameBinding(flow))
                .textInputAutocapitalization(.words)
            Button {
                Task { await flow.run(store: store) }
            } label: {
                Text(store.isConnected ? "Replace connection" : "Connect")
            }
        } header: {
            Text(store.isConnected ? "Pair or change Hermes" : "Pair with your Hermes")
        } footer: {
            Text(
                store.isConnected
                    ? "Scanning alone changes nothing. The existing connection is kept until you confirm this pairing."
                    : "Your Hermes will hand over its address and key once you confirm. The name says which device paired."
            )
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

    private func connected(
        _ flow: PairingFlow,
        profile: String?,
        dashboardWarning: String?
    ) -> some View {
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
            LabeledContent("Device", value: flow.deviceName)

            if let dashboardWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hermes is connected, but its extra services did not finish connecting.")
                        .font(.subheadline.weight(.medium))
                    Text(dashboardWarning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try extra services again") {
                        Task { await flow.retryDashboard(store: store) }
                    }
                }
            }

            Button("Done") { onDone() }
        } footer: {
            Text(
                dashboardWarning == nil
                    ? "Connection secrets are held in the Keychain on this iPhone only."
                    : "Your main Hermes connection is ready. You can retry the remaining services now or later from Connect."
            )
        }
    }

    private func failure(
        _ flow: PairingFlow,
        message: String,
        retryable: Bool
    ) -> some View {
        Section {
            Text(message).foregroundStyle(.red)
            if retryable {
                Button("Try again") {
                    Task { await flow.run(store: store) }
                }
            }
            Button("Close") { onDone() }
        } footer: {
            Text(
                retryable
                    ? "Check the connection and try again."
                    : "This QR cannot be retried. Open the Hermes dashboard and generate a fresh code (Pairing → Connect Alice)."
            )
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
