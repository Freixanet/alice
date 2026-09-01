import SwiftUI

struct ConnectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var address = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isConnected {
                        LabeledContent("Status") {
                            Label("Online", systemImage: "checkmark.circle.fill")
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

                if store.isConnected, let manifest = store.manifest {
                    Section("What this Hermes can do") {
                        // Screens are gated on what the agent advertises, so
                        // this is also the honest answer to "why is that empty".
                        ForEach(manifest.advertised.sorted(), id: \.self) { name in
                            Text(name).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Connect")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
        }
    }
}
