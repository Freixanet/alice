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
                    capabilityMatrix
                } else {
                    manualConnection
                }

                pairingShortcut

                if store.isConnected && !store.dashboardReady {
                    limitedFeatures
                }

                if store.isConnected {
                    advancedConnection
                    disconnect
                }
            }
            .navigationTitle("Connect")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                }
            }
            .sheet(isPresented: $showScanner) {
                PairingScanSheet()
                    .environment(store)
                    .preferredColorScheme(store.theme.colorScheme)
            }
            .onAppear {
                if address.isEmpty { address = store.gatewayURL }
                if panelAddress.isEmpty { panelAddress = store.dashboardURL }
            }
        }
    }

    /// Address and key first. A Linux, Windows or cloud Hermes has no pairing
    /// QR unless someone installed the Alice plugin; typing still works.
    private var manualConnection: some View {
        Section {
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
                if store.isConnecting { ProgressView() } else { Text("Connect") }
            }
            .disabled(address.isEmpty || key.isEmpty || store.isConnecting)
        } header: {
            Text("Connect to Hermes")
        } footer: {
            Text("The address and key come from whoever installed Hermes. Use HTTPS for a host that is not on your local network or tailnet.")
        }
    }

    /// A QR is faster when the plugin is on the dashboard. It is not required.
    private var pairingShortcut: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text(store.isConnected ? "Pair or change Hermes" : "Faster with a QR")
        } footer: {
            Text(
                store.isConnected
                    ? "Scan a pairing QR to re-pair or switch Hermes. Your current connection stays in place unless you confirm the new pairing."
                    : "If the Alice plugin is on your Hermes dashboard, show a pairing QR and scan it here. Chat still works from the address and key above."
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
        } header: {
            Text("Connection")
        } footer: {
            Text("The connection key is stored in Keychain on this iPhone.")
        }
    }

    private var capabilityMatrix: some View {
        Section {
            ForEach(ConnectionCapabilities.rows(
                dashboardReady: store.dashboardReady,
                modelCount: store.models.count
            )) { row in
                LabeledContent(row.title) {
                    Text(row.detail)
                        .foregroundStyle(row.available ? Color.secondary : Color.orange)
                }
            }
        } header: {
            Text("What this connection can do")
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

    private var advancedConnection: some View {
        Section {
            DisclosureGroup("Advanced connection settings", isExpanded: $advancedExpanded) {
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
        } header: {
            Text("Advanced")
        } footer: {
            Text("Technical addresses and the advertised capability list.")
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
