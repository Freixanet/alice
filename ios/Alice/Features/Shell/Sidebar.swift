import SwiftUI

/// Everyday navigation and conversation history. Configuration lives in Settings.
struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    let onDismiss: () -> Void

    @State private var showSearch = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var deletingConversation: Conversation?
    @State private var projects: [NamedProject] = []
    @State private var projectMoveFailure: String?
    @State private var going: Destination?

    /// Every surface Search can route to from the drawer. Only the everyday
    /// destinations are listed visibly; configuration is progressively disclosed
    /// through Settings while remaining searchable for expert users.
    private enum Destination: String, Identifiable {
        case activity, routines, projects, git, skills, tools, mcp, webhooks, channels, system, files, library, settings, connect
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
            // Bots, Routines, Library — so a conversation scrolling up dissolves
            // rather than vanishing at a hard line.
            ZStack(alignment: .bottom) {
                list.mask(edgeFade)
                footer
            }
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card(scheme).ignoresSafeArea())
        // An alert in Activity offering "Open messaging apps" asks through the
        // store; the drawer presents, so Activity is replaced by that screen.
        .onChange(of: store.requestedDestination) { _, target in
            guard let target else { return }
            store.requestedDestination = nil
            open(target)
        }
        .sheet(
            item: $going,
            onDismiss: { Task { await loadProjects() } }
        ) { destination in
            Group {
                switch destination {
                case .activity: closable { ActivityScreen() }
                case .routines: closable { RoutinesScreen() }
                case .projects: closable { ProjectsScreen() }
                case .git: closable { GitDevelopmentScreen() }
                case .skills: closable { CatalogScreen(source: .skills) }
                case .tools: closable { CatalogScreen(source: .toolsets) }
                case .mcp: closable { MCPScreen() }
                case .webhooks: closable { WebhooksScreen() }
                case .channels: closable { ChannelsScreen() }
                case .system: closable { SystemScreen() }
                case .files: closable { HermesFilesScreen() }
                case .library: closable { LibraryView() }
                // These two bring their own Done; a second would be one too many.
                case .settings: NavigationStack { SettingsView() }
                case .connect: ConnectView()
                }
            }
            // Said again here. The app sets its scheme once at the window, and
            // a sheet is presented outside that: changing from light to dark
            // repainted everything behind Settings and left Settings itself —
            // the screen the switch is on — in the colours it had opened in.
            .preferredColorScheme(store.theme.colorScheme)
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchScreen(
                onOpen: onDismiss,
                onOpenDestination: { open($0) }
            )
        }
        .alert(
            "Couldn’t move chat",
            isPresented: Binding(
                get: { projectMoveFailure != nil },
                set: { if !$0 { projectMoveFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { projectMoveFailure = nil }
        } message: {
            Text(projectMoveFailure ?? "Hermes did not move the session.")
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
                    // Same as the footer discs: measured at 20 x 20pt.
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("sidebar.search")
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

    /// The drawer is for places people use while working with Alice, not for
    /// configuring Hermes. Technical administration remains searchable and is
    /// grouped under Settings → Advanced instead of competing with recents.
    private var destinations: some View {
        VStack(spacing: 2) {
            row("Bots", systemImage: "person.2", weight: .medium) {
                onDismiss()
                store.botsFromLeading = false
                store.showingBots = true
            }
            row(
                "Activity", systemImage: "bell", weight: .medium,
                badge: store.unreadActivity
            ) { going = .activity }
            row("Routines", systemImage: "clock", weight: .medium) { going = .routines }
            row("Projects", systemImage: "folder", weight: .medium) { going = .projects }
            row("Library", systemImage: "photo.on.rectangle", weight: .medium) { going = .library }
        }
        .padding(.horizontal, 12)
        // Most of the gap to Pinned is the list's own top inset, which has to
        // clear the fade; this adds only a little on top of it.
        .padding(.bottom, 6)
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
    /// Shared by the mask and by the list's top inset, so the heading and the
    /// ramp cannot drift apart.
    /// 22, down from 30 with the destinations' bottom padding down from 22 to
    /// 6: the gap to Pinned was 52pt. The list still starts where the ramp
    /// ends, because both read this one value.
    static let topFadeHeight: CGFloat = 22

    private var edgeFade: some View {
        VStack(spacing: 0) {
            // Both ramps are long, and both hold near-opaque for their first
            // third. That is what makes a fade look like it starts late and
            // still takes its time: a row stays fully legible well into the
            // band and then loses itself over the rest of it. A short ramp
            // reads as a rule however many stops it has.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.18), location: 0.22),
                    .init(color: .black.opacity(0.55), location: 0.48),
                    .init(color: .black.opacity(0.85), location: 0.74),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.topFadeHeight)

            Color.black

            // Taller than the old 180, and it holds. The previous ramp was
            // already down to three-quarters opacity a third of the way in,
            // so a row went from legible to gone across about a finger —
            // which reads as a hard edge that happens to be soft. Eight stops
            // over 240pt keep a row readable well past halfway and then let
            // it lose itself slowly, so full transparency lands lower down
            // the drawer than it used to.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.99), location: 0.18),
                    .init(color: .black.opacity(0.95), location: 0.34),
                    .init(color: .black.opacity(0.85), location: 0.48),
                    .init(color: .black.opacity(0.68), location: 0.61),
                    .init(color: .black.opacity(0.46), location: 0.73),
                    .init(color: .black.opacity(0.24), location: 0.85),
                    .init(color: .black.opacity(0.08), location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
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
            // Clears the top fade. The band exists so a row scrolling up
            // dissolves rather than being cut off, but the first heading was
            // starting inside it — "Pinned" was half gone before anything had
            // moved. Content now begins below the ramp and only enters it on
            // the way out.
            .padding(.top, Self.topFadeHeight)
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

        // A Hermes Project owns workspace folders. Moving a chat therefore
        // moves the real Hermes session cwd to that Project's primary folder;
        // there is no iPhone-only filing layer and no fake "None" project.
        if !projects.isEmpty {
            Menu {
                ForEach(projects) { project in
                    Button(project.name) {
                        Task {
                            do {
                                try await store.moveConversation(conversation.id, to: project)
                            } catch {
                                projectMoveFailure = (error as? LocalizedError)?.errorDescription
                                    ?? "Hermes did not move the session."
                            }
                        }
                    }
                }
            } label: {
                Label("Move to Project", systemImage: "folder")
            }
        }

        Button("Delete", systemImage: "trash", role: .destructive) {
            deletingConversation = conversation
        }
    }

    private func loadProjects() async {
        guard store.dashboardReady else {
            projects = []
            return
        }
        projects = ((try? await store.namedProjects(profile: "default")) ?? [])
            .filter { !$0.archived && $0.primaryPath != nil }
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
                // The frame alone sizes the layout but leaves the button's hit
                // region and its accessibility frame on the glyph — measured at
                // 11.7 x 20.3pt, a quarter of the 44pt minimum, so the target
                // was the symbol rather than the disc drawn around it.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings")
            .contextMenu {
                Button {
                    going = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    going = .connect
                } label: {
                    Label(store.wellbeingSummary, systemImage: "antenna.radiowaves.left.and.right")
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
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
                    // Same as the settings disc: measured at 18 x 18pt.
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("sidebar.newChat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        // No background: the discs are the only thing meant to be seen here,
        // and anything behind them is the point.
        .padding(.bottom, 12)
    }

    /// `Label` gives each symbol only the width its own glyph needs, so a
    /// clock and a wrench push their words to different places. The icon gets
    /// Sends the drawer to one of its own destinations. Bots is a page rather
    /// than a sheet, and Memory and the rest live inside Settings, so a couple
    /// of these land on the nearest screen that contains the thing rather than
    /// on a sheet of their own.
    private func open(_ target: AliceDestination.Target) {
        switch target {
        case .bots:
            onDismiss()
            store.botsFromLeading = false
            store.showingBots = true
        case .activity: going = .activity
        case .routines: going = .routines
        case .projects: going = .projects
        case .files: going = .files
        case .library: going = .library
        case .channels: going = .channels
        case .mcp: going = .mcp
        case .skills: going = .skills
        case .tools: going = .tools
        case .webhooks: going = .webhooks
        case .git: going = .git
        case .system: going = .system
        case .connect: going = .connect
        // Reached inside Settings. Landing there is one tap short of the
        // destination and still far better than not finding it at all.
        case .settings, .memory, .models, .usage, .sessions, .insights,
             .configuration, .pairing, .plugins:
            going = .settings
        }
    }


    /// Each symbol gets a fixed column so every label starts on the same line.
    private func row(
        _ title: String, systemImage: String, weight: Font.Weight = .regular,
        badge: Int = 0, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: weight))
                    .frame(width: 22, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.card(scheme), in: .capsule)
                        .accessibilityLabel("\(badge) unread")
                }
            }
            .font(.subheadline.weight(weight))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.row.\(title)")
    }
}
