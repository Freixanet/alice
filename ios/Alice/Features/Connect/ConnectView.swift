import SwiftUI

struct ConnectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var panelAddress = ""
    @State private var panelUser = "alice"
    @State private var panelPassword = ""
    @State private var panelBusy = false
    @State private var panelError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isConnected {
                        LabeledContent("Status") {
                            // Not a `Label`: inside a `LabeledContent` one lays
                            // out as though it were the row's own title, and
                            // the row grew to about four times its height with
                            // a stray separator floating in the gap.
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Online")
                            }
                            .foregroundStyle(.green)
                        }
                        LabeledContent("Address", value: store.gatewayURL)
                        if let version = store.manifest?.version {
                            LabeledContent("Version", value: version)
                        }
                        LabeledContent("Models", value: "\(store.models.count)")
                    } else {
                        TextField("Address", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Connection key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Your Hermes")
                } footer: {
                    Text(store.isConnected
                        ? "The key is held in the Keychain on this device only. It is never backed up and never leaves the phone except to the address above."
                        : "Copy the address and connection key from your Hermes. Alice talks to it directly — nothing passes through a server of ours.")
                }

                if let error = store.connectionError {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    if store.isConnected {
                        Button("Disconnect and forget", role: .destructive) {
                            Task { await store.disconnect() }
                        }
                    } else {
                        Button {
                            Task { await store.connect(urlText: address, key: key) }
                        } label: {
                            if store.isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                            }
                        }
                        .disabled(address.isEmpty || key.isEmpty || store.isConnecting)
                    }
                }

                if store.isConnected { abilities }
                panel
            }
            .navigationTitle("Connect")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            // A sheet with nothing but a swipe to close it is a sheet the
            // reader has to guess at.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The dashboard is a second address with a second login.
    ///
    /// Hermes serves projects, memory and the usage figures only from here,
    /// and only over a login — it will not listen beyond its own machine
    /// without one. An install without a dashboard simply leaves this blank
    /// and loses those three screens, nothing else.
    @ViewBuilder
    private var panel: some View {
        Section {
            if store.dashboardReady {
                LabeledContent("Address", value: store.dashboardURL)
                LabeledContent("Signed in as", value: store.dashboardUser)
                Button("Disconnect the dashboard", role: .destructive) {
                    Task { await store.forgetDashboard() }
                }
            } else {
                TextField("Address", text: $panelAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Username", text: $panelUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $panelPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task {
                        panelBusy = true
                        panelError = await store.connectDashboard(
                            urlText: panelAddress,
                            username: panelUser,
                            password: panelPassword
                        )
                        if panelError == nil { panelPassword = "" }
                        panelBusy = false
                    }
                } label: {
                    if panelBusy { ProgressView() } else { Text("Sign in") }
                }
                .disabled(panelAddress.isEmpty || panelUser.isEmpty
                    || panelPassword.isEmpty || panelBusy)
                if let panelError {
                    Text(panelError).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Hermes dashboard")
        } footer: {
            Text(store.dashboardReady
                ? "The password is held in the Keychain on this device only, like the connection key."
                : "Optional. Adds Projects, Memory and Usage, which the agent serves only from its dashboard.")
        }
    }

    /// What the agent says it can do — and, when it says nothing, that it said
    /// nothing, which is the honest answer to why half the app is greyed out.
    @ViewBuilder
    private var abilities: some View {
        let advertised = store.manifest?.advertised.sorted() ?? []
        Section {
            if advertised.isEmpty {
                Text("This Hermes did not advertise a capability manifest, so screens that depend on one stay hidden.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(advertised, id: \.self) { name in
                    Text(name).font(.caption.monospaced())
                }
            }
        } header: {
            Text("What this Hermes can do")
        } footer: {
            if !advertised.isEmpty {
                Text("Named as your Hermes reports them. Screens that need something missing from this list stay hidden rather than failing when you open them.")
            }
        }
    }
}
