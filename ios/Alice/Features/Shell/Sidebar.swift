import SwiftUI

/// History, and the way into everything that is not the conversation.
struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    let onDismiss: () -> Void

    @State private var showSearch = false
    @State private var going: Destination?

    /// Where the drawer can take you. The frequent ones sit above the
    /// conversations, where they are reached without scrolling; the rest are
    /// in Settings, which is where things you set once belong.
    private enum Destination: String, Identifiable {
        case bots, jobs, projects, skills, tools, library, settings, connect
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            destinations
            sectionLabel("Recents")
            list
            Divider().opacity(0.4)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card(scheme).ignoresSafeArea())
        .sheet(item: $going) { destination in
            switch destination {
            case .bots: closable { BotsScreen() }
            case .jobs: closable { JobsScreen() }
            case .projects: closable { ProjectsScreen() }
            case .skills: closable { CatalogScreen(source: .skills) }
            case .tools: closable { CatalogScreen(source: .toolsets) }
            case .library: closable { LibraryView() }
            // These two bring their own Done; a second would be one too many.
            case .settings: NavigationStack { SettingsView() }
            case .connect: ConnectView()
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchScreen(onOpen: onDismiss)
        }
    }

    private var header: some View {
        HStack {
            // Aligned with the rows below rather than with the drawer's edge:
            // a title that starts 8pt left of everything under it reads as a
            // mistake, not as a heading.
            Text("Alice").font(.aliceTitle(.title))
            Spacer()
            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Search")
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        // The same 11pt the conversation's controls take, so the search button
        // and the drawer button line up while both are on screen.
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    /// Every destination gets a way out. A sheet whose only exit is a swipe
    /// is a sheet the reader has to guess at, and these are opened often
    /// enough that guessing gets old.
    private func closable<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { going = nil }
                    }
                }
        }
    }

    /// The handful worth reaching in one tap. Bots and Projects come from the
    /// dashboard, so they appear only once there is one to ask.
    private var destinations: some View {
        VStack(spacing: 2) {
            if store.dashboardReady {
                row("Bots", systemImage: "person.2") { going = .bots }
            }
            row("Jobs", systemImage: "clock") { going = .jobs }
            if store.dashboardReady {
                row("Projects", systemImage: "folder") { going = .projects }
            }
            row("Skills", systemImage: "sparkles") { going = .skills }
            row("Tools", systemImage: "wrench.adjustable") { going = .tools }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The 24pt column the wordmark and the rows below both sit on.
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.conversations) { conversation in
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
                                    ? store.accent.primary(scheme).opacity(scheme == .dark ? 0.22 : 0.16)
                                    : .clear,
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
            row("Library", systemImage: "photo.on.rectangle") { going = .library }
            row("Settings", systemImage: "gearshape") { going = .settings }
            Button {
                going = .connect
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
