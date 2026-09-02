import SwiftUI

/// History, and the way into everything that is not the conversation.
struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    let onDismiss: () -> Void

    @State private var showSearch = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var projects: [ProjectRow] = []
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
        .padding(.bottom, 20)
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
            row("Library", systemImage: "photo.on.rectangle") { going = .library }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 22)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The stack around it already carries 12, and the rows add 12
            // of their own — so 12 here lands on the same 24pt column as
            // everything else in the drawer.
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                // Only when there is something in it: a heading over nothing
                // is worse than no heading.
                if !pinned.isEmpty {
                    sectionLabel("Pinned")
                    ForEach(pinned) { conversation in
                        chatRow(conversation)
                    }
                    Spacer(minLength: 14)
                }

                sectionLabel("Recents")
                ForEach(recents) { conversation in
                    chatRow(conversation)
                }
            }
            .padding(.horizontal, 12)
        }
        // Keyed on the connection: the drawer is built before the dashboard
        // has signed in, and a one-shot task would leave the project list
        // empty for the rest of the session.
        .task(id: store.dashboardReady) { await loadProjects() }
        .alert("Rename chat", isPresented: .constant(renaming != nil)) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { store.rename(renaming.id, to: newTitle) }
                renaming = nil
            }
        }
    }

    private var pinned: [Conversation] { store.conversations.filter(\.pinned) }
    private var recents: [Conversation] { store.conversations.filter { !$0.pinned } }

    @ViewBuilder
    private func chatRow(_ conversation: Conversation) -> some View {
        Button {
            store.activeID = conversation.id
            onDismiss()
        } label: {
            Text(conversation.title)
                .lineLimit(1)
                // A definite width, so the long-press preview takes its size
                // from the drawer rather than from the label. Less both
                // insets: the stack's 12 either side and the row's.
                .frame(width: width - 48, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    conversation.id == store.activeID
                        ? store.accent.primary(scheme).opacity(scheme == .dark ? 0.22 : 0.16)
                        : .clear,
                    in: .rect(cornerRadius: 10)
                )
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // An explicit preview rather than a lift of the row: the default
        // takes the row's bounds and enlarges them, which on a 300pt drawer
        // reaches past the edge.
        .contextMenu {
            menu(for: conversation)
        } preview: {
            Text(conversation.title)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(width: width - 72, alignment: .leading)
                .background(Palette.card(scheme))
        }
    }

    @ViewBuilder
    private func menu(for conversation: Conversation) -> some View {
        Button {
            store.togglePin(conversation.id)
        } label: {
            Label(conversation.pinned ? "Unpin" : "Pin", systemImage: "pin")
        }

        Button {
            newTitle = conversation.title
            renaming = conversation
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        // Only where there are projects to file it under. The grouping is
        // local: the agent's projects hold its own sessions, and a chat
        // started on this phone is not one of those.
        if !projects.isEmpty {
            Menu {
                ForEach(projects) { project in
                    Button(project.label) {
                        store.file(conversation.id, under: project.label)
                    }
                }
                if conversation.project != nil {
                    Divider()
                    Button("None") { store.file(conversation.id, under: nil) }
                }
            } label: {
                Label("Add to Project", systemImage: "folder")
            }
        }

        Button("Delete", systemImage: "trash", role: .destructive) {
            store.delete(conversation.id)
        }
    }

    private func loadProjects() async {
        guard store.dashboardReady else { return }
        projects = (try? await store.projects()) ?? []
    }

    private var footer: some View {
        VStack(spacing: 2) {
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

    /// `Label` gives each symbol only the width its own glyph needs, so a
    /// clock and a wrench push their words to different places. The icon gets
    /// a column of its own instead, and every word starts on one line.
    private func row(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .frame(width: 22, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
