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
    @State private var deletingConversation: Conversation?
    @State private var projects: [ProjectRow] = []
    @State private var going: Destination?

    /// Where the drawer can take you. The frequent ones sit above the
    /// conversations, where they are reached without scrolling; the rest are
    /// in Settings, which is where things you set once belong.
    private enum Destination: String, Identifiable {
        case jobs, projects, skills, tools, library, settings, connect
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            destinations

            // The conversations run underneath the footer rather than stopping
            // above it. Glass has to have something behind it to be glass: with
            // the list ending where the buttons begin, those two discs sat over
            // flat card colour and refracted nothing. Now a row slides beneath
            // them and, at the very bottom, fades out instead of being cut off.
            //
            // The same at the top, where the list passes under the fixed rows —
            // Bots, Jobs, Library — so a conversation scrolling up dissolves
            // rather than vanishing at a hard line.
            ZStack(alignment: .bottom) {
                list.mask(edgeFade)
                footer
            }
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card(scheme).ignoresSafeArea())
        .sheet(item: $going) { destination in
            switch destination {
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
            // Always listed, connected or not. A row that disappears when the
            // agent is unreachable teaches the reader that the app is broken
            // rather than that the connection is: the destination still knows
            // what it last saw, and says so when it cannot refresh.
            row("Bots", systemImage: "person.2", weight: .medium) {
                onDismiss()
                store.botsFromLeading = false
                store.showingBots = true
            }
            row("Jobs", systemImage: "clock", weight: .medium) { going = .jobs }
            row("Projects", systemImage: "folder", weight: .medium) { going = .projects }
            row("Skills", systemImage: "sparkles", weight: .medium) { going = .skills }
            row("Tools", systemImage: "wrench.adjustable", weight: .medium) { going = .tools }
            row("Library", systemImage: "photo.on.rectangle", weight: .medium) { going = .library }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 22)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The stack around it already carries 12, and the rows add 12
            // of their own — so 12 here lands on the same 24pt column as
            // everything else in the drawer.
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    /// Opaque through the middle, out at both ends.
    ///
    /// In points, not in fractions of the container. Expressed as fractions
    /// the ramp changed length with the height it happened to be given, and
    /// at this size that made the bottom one about a finger's width — short
    /// enough to read as a rule with a soft edge rather than as a row losing
    /// itself. A hundred and thirty points is most of the way from the last
    /// legible row to the buttons, which is the distance a row actually has
    /// to disappear over.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Color.black
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.86), location: 0.18),
                    .init(color: .black.opacity(0.62), location: 0.38),
                    .init(color: .black.opacity(0.34), location: 0.60),
                    .init(color: .black.opacity(0.12), location: 0.80),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)
        }
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
        .confirmationDialog(
            "Delete Chat",
            isPresented: .init(
                get: { deletingConversation != nil },
                set: { if !$0 { deletingConversation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletingConversation {
                    store.delete(deletingConversation.id)
                }
                deletingConversation = nil
            }
            Button("Cancel", role: .cancel) {
                deletingConversation = nil
            }
        } message: {
            Text("Are you sure you want to delete this chat? This cannot be undone.")
        }
    }

    private var pinned: [Conversation] { store.conversations.filter { $0.pinned && !$0.isBotChat } }
    private var recents: [Conversation] { store.conversations.filter { !$0.pinned && !$0.isBotChat } }

    @ViewBuilder
    private func chatRow(_ conversation: Conversation) -> some View {
        Button {
            store.activeID = conversation.id
            onDismiss()
        } label: {
            Text(conversation.title)
                .lineLimit(1)
                // A definite width, matching row and preview width exactly
                // so the long-press preview never shrinks or stretches.
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
        .contextMenu {
            menu(for: conversation)
        } preview: {
            Text(conversation.title)
                .lineLimit(1)
                .frame(width: width - 48, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    conversation.id == store.activeID
                        ? store.accent.primary(scheme).opacity(scheme == .dark ? 0.22 : 0.16)
                        : Palette.card(scheme),
                    in: .rect(cornerRadius: 10)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            deletingConversation = conversation
        }
    }

    private func loadProjects() async {
        guard store.dashboardReady else { return }
        projects = (try? await store.projects()) ?? []
    }

    /// The initial to show on the settings button, or nil when there is
    /// nothing to go on.
    ///
    /// `UIDevice.name` is generic on modern iOS without an entitlement, so
    /// the only real source is the dashboard login. A hardcoded fallback used
    /// to stand in for it — which showed one person's initial to everybody
    /// else.
    private var userInitial: String? {
        let name = store.dashboardUser.trimmingCharacters(in: .whitespaces)
        guard let first = name.first(where: { $0.isLetter }) else { return nil }
        return String(first).uppercased()
    }

    private var footer: some View {
        HStack {
            Button {
                going = .settings
            } label: {
                Group {
                    if let userInitial {
                        Text(userInitial)
                            .font(.system(size: 17, weight: .semibold))
                    } else {
                        Image(systemName: "person")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Settings")
            .contextMenu {
                Button {
                    going = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    going = .connect
                } label: {
                    Label(store.isConnected ? "Hermes Connected" : "Connect Hermes", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            Spacer()

            Button {
                store.newChat()
                onDismiss()
            } label: {
                // No nudge. The pencil hangs off the square's top-right, so
                // the obvious correction is to shove the glyph back down and
                // left — but measured against the 44pt frame the square's own
                // centre already lands within a third of a point of it, and a
                // 2.5pt "correction" moved it that far off. Apple has already
                // balanced this one.
                // Vertically only. The measurement said the square sat low
                // and left of the symbol's own box by the same amount, and
                // both corrections were applied — but SwiftUI centres the
                // glyph's layout box, not its ink, and horizontally those
                // already agree. Nudging x as well simply pushed it right.
                // ChatGPT's own compose mark, from OpenAI's MIT-licensed
                // Apps SDK icon set. Drawn on a 24-unit grid that is already
                // balanced, so it needs no nudge: unlike the SF Symbol, the
                // pencil is inside the square's own bounds.
                PencilSquareMark()
                    // Stated, like the bots' eyes: the disc's vibrancy
                    // lightens a shape fill far more than a symbol stroke,
                    // and inherited it came out grey against black glyphs.
                    .foregroundStyle(scheme == .dark ? Color.white : .black)
                    .frame(width: 21, height: 21)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        // No background: the discs are the only thing meant to be seen here,
        // and anything behind them is the point.
        .padding(.bottom, 12)
    }

    /// `Label` gives each symbol only the width its own glyph needs, so a
    /// clock and a wrench push their words to different places. The icon gets
    /// a column of its own instead, and every word starts on one line.
    private func row(
        _ title: String, systemImage: String, weight: Font.Weight = .regular, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: weight))
                    .frame(width: 22, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(weight))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
