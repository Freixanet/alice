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
    @State private var manualExpanded = false
    @State private var dashboardExpanded = false
    @State private var technicalExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                if store.isConnected {
                    connectionSummary
                    pairing
                    extraServices
                    technicalDetails
                    disconnect
                } else {
                    pairing
                    manualSetup
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

    /// The normal path. Keep it available even when Alice is already connected:
    /// a QR is also the clean way to re-pair or switch Hermes without first
    /// destroying a working connection. The pairing confirmation owns the
    /// replacement decision; merely opening the scanner changes nothing.
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

    /// The old form remains available for unusual deployments, but it no
    /// longer makes every new reader understand a gateway before they can use
    /// the one-tap path above.
    private var manualSetup: some View {
        Section {
            DisclosureGroup("Set up manually", isExpanded: $manualExpanded) {
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
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Manual setup is for Hermes installations that cannot use the pairing QR.")
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

    /// Dashboard is an implementation detail behind the user-facing idea of
    /// extra Hermes services. Pairing fills this in automatically when the
    /// Mac has credentials; the form is only a recovery/advanced path.
    @ViewBuilder
    private var extraServices: some View {
        Section {
            if store.dashboardReady {
                LabeledContent("Extra services") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Connected")
                    }
                    .foregroundStyle(.green)
                }
                Text("Projects, Memory and Usage are available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Disconnect extra services", role: .destructive) {
                    Task { await store.forgetDashboard() }
                }
            } else {
                DisclosureGroup(
                    "Set up extra services manually",
                    isExpanded: $dashboardExpanded
                ) {
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
                        if panelBusy { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(
                        panelAddress.isEmpty || panelUser.isEmpty
                            || panelPassword.isEmpty || panelBusy
                    )
                    if let panelError {
                        Text(panelError).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Extra services")
        } footer: {
            if !store.dashboardReady {
                Text("Optional. Pairing configures this automatically when Hermes exposes Projects, Memory and Usage.")
            }
        }
    }

    /// Addresses and raw capability names are useful when debugging, not when
    /// deciding whether Alice is connected. Keep them available without
    /// making the server's vocabulary part of the normal product surface.
    private var technicalDetails: some View {
        Section {
            DisclosureGroup("Technical details", isExpanded: $technicalExpanded) {
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
    }

    private var disconnect: some View {
        Section {
            Button("Disconnect and forget Hermes", role: .destructive) {
                Task { await store.disconnect() }
            }
        }
    }
}
