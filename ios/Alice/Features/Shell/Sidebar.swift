import SwiftUI

/// History, and the way into everything that is not the conversation.
struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            Divider().opacity(0.4)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card(scheme).ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showConnect) {
            ConnectView()
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack { LibraryView() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Alice").font(.aliceTitle(.title2))
                Spacer()
                Button {
                    store.newChat()
                    onDismiss()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("New chat")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.muted(scheme), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var filtered: [Conversation] {
        guard !query.isEmpty else { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { conversation in
                    Button {
                        store.activeID = conversation.id
                        onDismiss()
                    } label: {
                        Text(conversation.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                conversation.id == store.activeID
                                    ? Palette.muted(scheme) : .clear,
                                in: .rect(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.delete(conversation.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            row("Library", systemImage: "square.grid.2x2") { showLibrary = true }
            row("Settings", systemImage: "gearshape") { showSettings = true }
            Button {
                showConnect = true
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.isConnected ? "Hermes connected" : "Connect your Hermes")
                            .font(.subheadline)
                        if store.isConnected, let host = URL(string: store.gatewayURL)?.host {
                            Text(host).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func row(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
