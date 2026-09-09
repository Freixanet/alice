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
    @State private var showScanner = false
    @State private var advancedExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                if store.isConnected {
                    connectionSummary
                }

                pairing

                if store.isConnected && !store.dashboardReady {
                    limitedFeatures
                }

                advancedConnection

                if store.isConnected {
                    disconnect
                }
            }
            .navigationTitle("Connect")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                PairingScanSheet()
                    .environment(store)
                    .preferredColorScheme(store.theme.colorScheme)
            }
        }
    }

    /// The pairing QR is the normal path. Alice configures every connection it
    /// can from one scan, so people don't need to learn the gateway/dashboard
    /// split just to get started.
    private var pairing: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text(store.isConnected ? "Pair or change Hermes" : "Connect to Hermes")
        } footer: {
            Text(
                store.isConnected
                    ? "Scan a pairing QR to re-pair or switch Hermes. Your current connection stays in place unless you confirm the new pairing."
                    : "Show the pairing QR on the Mac running Hermes, then scan it here. Alice configures the connection automatically."
            )
        }
    }

    private var connectionSummary: some View {
        Section {
            LabeledContent("Hermes") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Connected")
                }
                .foregroundStyle(.green)
            }
            if let version = store.manifest?.version {
                LabeledContent("Version", value: version)
            }
            if !store.models.isEmpty {
                LabeledContent("Models", value: "\(store.models.count)")
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("The connection key is stored in Keychain on this iPhone.")
        }
    }

    /// A partial dashboard connection is expressed as a feature problem, not
    /// as a second service the person is expected to understand. The repair
    /// controls themselves stay under Advanced.
    private var limitedFeatures: some View {
        Section {
            Label("Some features are unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Projects, Memory and Usage need the full Hermes connection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Repair connection") {
                advancedExpanded = true
            }
        }
    }

    /// One disclosure point for every uncommon connection detail. Apple
    /// recommends keeping the common path visible and advanced functionality
    /// hidden until it becomes relevant.
    private var advancedConnection: some View {
        Section {
            DisclosureGroup("Advanced connection settings", isExpanded: $advancedExpanded) {
                if !store.isConnected {
                    TextField("Address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Connection key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let error = store.connectionError {
                        Text(error).foregroundStyle(.red)
                    }

                    Button {
                        Task { await store.connect(urlText: address, key: key) }
                    } label: {
                        if store.isConnecting { ProgressView() } else { Text("Connect manually") }
                    }
                    .disabled(address.isEmpty || key.isEmpty || store.isConnecting)
                }

                if store.isConnected && !store.dashboardReady {
                    TextField("Dashboard address", text: $panelAddress)
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
                        if panelBusy { ProgressView() } else { Text("Repair full connection") }
                    }
                    .disabled(
                        panelAddress.isEmpty || panelUser.isEmpty
                            || panelPassword.isEmpty || panelBusy
                    )
                    if let panelError {
                        Text(panelError).foregroundStyle(.red)
                    }
                }

                if store.isConnected {
                    LabeledContent("Gateway", value: store.gatewayURL)
                    if store.dashboardReady {
                        LabeledContent("Dashboard", value: store.dashboardURL)
                        LabeledContent("Dashboard user", value: store.dashboardUser)
                    }

                    let advertised = store.manifest?.advertised.sorted() ?? []
                    if !advertised.isEmpty {
                        Text("Capabilities")
                            .font(.footnote.weight(.semibold))
                            .padding(.top, 4)
                        ForEach(advertised, id: \.self) { name in
                            Text(name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Manual addresses and technical details are only needed for unusual or troubleshooting setups.")
        }
    }

    private var disconnect: some View {
        Section {
            Button("Disconnect and forget Hermes", role: .destructive) {
                Task { await store.disconnect() }
            }
        }
    }
}
