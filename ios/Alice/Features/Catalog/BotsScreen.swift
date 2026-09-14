import SwiftUI
import UniformTypeIdentifiers

/// The agent's other selves.
///
/// A bot in Hermes is not a separate kind of thing: it is a profile with its
/// own standing instructions, model, skills and sessions. What the desktop
/// client shows under Bot Mode is that, and so is this.
struct BotsScreen: View {
    /// RootView turns this off for the brief tail of a recognised page swipe,
    /// when SwiftUI may still deliver a row Button action on finger-up.
    var canOpenBot: () -> Bool = { true }
    /// Closes the page after opening a conversation from it.
    var onClose: () -> Void = {}
    /// Goes one level back from the Bots page. RootView owns this transition
    /// because it also owns the page layered underneath it.
    var onBack: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    /// Seeded from the cache, not empty. Starting at empty meant the page
    /// opened on "No bots" for the one frame before the cached list was
    /// read — an answer that was never true, shown and then taken back.
    @State private var rows: [BotRow] = []
    @State private var seeded = false
    /// The agent's routines, grouped by bot, so search has something real to
    /// look through. It used to search a local mirror that only ever held
    /// routines the server had rejected.
    @State private var routinesByBot: [String: [JobRow]] = [:]
    @State private var routinesUnavailable: String?
    @State private var failure: String?
    /// True when the list on screen came from the cache because the agent did
    /// not answer.
    @State private var stale = false
    @State private var loading = false
    @State private var creatingBot = false
    @State private var creatingChannel = false
    /// A bot to start a new channel with, from that bot's menu.
    @State private var channelSeedBot: String?
    @State private var editingChannel: BotChannel?
    @State private var deletingChannel: BotChannel?
    @State private var renamingChannel: BotChannel?
    @State private var channelNameDraft = ""
    @State private var creatingTeamIn: BotChannel?
    @State private var deletingTeam: Conversation?
    @State private var newChannelSection: ChannelSectionTarget?
    @State private var channelSectionName = ""
    @State private var importingBot = false
    @State private var importBusy = false
    @State private var editingBot: BotRow?
    @State private var deletingBot: BotRow?
    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case messages = "Messages"
        case bots = "Bots"
        case groups = "Groups"
        case files = "Files"
        case routines = "Routines"

        var id: String { rawValue }
    }

    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var selectedFilter: SearchFilter = .all
    @FocusState private var searchFocused: Bool
    @State private var showNewSectionAlert = false
    @State private var newSectionName = ""
    @State private var newSectionTargetBot: String?
    @State private var deletingSection: String?
    @State private var renamingSection: String?
    @State private var renameSectionName = ""
    @State private var showRenameSectionAlert = false
    /// The bot currently being reordered. Keeping the identity in view state lets
    /// DropDelegate advertise a real move operation instead of SwiftUI's default
    /// copy-style drop (the misleading “+” badge).
    @State private var draggedBotName: String?

    var body: some View {
        Group {
            // No spinner on the way in. The list is cached, so the page has
            // something to show immediately and a wheel over it only says
            // "wait" for work that has usually already finished by the time
            // the animation has drawn its first frame.
            if let failure, rows.isEmpty {
                ContentUnavailableView(
                    "Bots", systemImage: "person.2", description: Text(failure)
                )
            } else if rows.isEmpty, seeded {
                // Only once a load has actually finished. Seeding in `.task`
                // still leaves one frame drawn against an empty array, which
                // is long enough to flash "No bots" and take it back — an
                // answer that was never true.
                ContentUnavailableView(
                    "No bots", systemImage: "person.2",
                    description: Text("Every Hermes has at least a default profile.")
                )
            } else {
                botList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar(.hidden, for: .navigationBar)
        // A safe-area *bar*, not an inset or an overlay. With a scrolling list
        // under it, a phone delivered every press on Back to a container
        // above the controls and the button never fired — while the empty
        // page, with no list, worked. `safeAreaBar` is iOS 26's place for
        // custom controls over scrolling content, taking part in its edge
        // effect instead of sitting underneath it.
        .safeAreaBar(edge: .top, spacing: 0) {
            topControls
        }
        .sheet(isPresented: $creatingBot) {
            NewBotSheet { await load() }
        }
        .sheet(isPresented: $creatingChannel, onDismiss: { channelSeedBot = nil }) {
            ChannelSheet(bots: rows, seedBot: channelSeedBot)
        }
        .sheet(item: $editingChannel) { channel in
            ChannelSheet(bots: rows, editing: channel)
        }
        .sheet(item: $creatingTeamIn) { channel in
            TeamSheet(channel: channel, bots: rows.filter { channel.bots.contains($0.name) }) { team in
                store.activeID = team.id
                onClose()
            }
        }
        .alert(
            "Rename Channel",
            isPresented: Binding(
                get: { renamingChannel != nil },
                set: { if !$0 { renamingChannel = nil } }
            )
        ) {
            TextField("Channel Name", text: $channelNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let channel = renamingChannel {
                    store.renameChannel(channel.id, to: channelNameDraft)
                }
            }
        }
        .alert(
            "New Section",
            isPresented: Binding(
                get: { newChannelSection != nil },
                set: { if !$0 { newChannelSection = nil } }
            )
        ) {
            TextField("Section Name", text: $channelSectionName)
            Button("Cancel", role: .cancel) { channelSectionName = "" }
            Button("Create") {
                if let target = newChannelSection {
                    store.addChannelSection(target.channelID, name: channelSectionName, bot: target.bot)
                }
                channelSectionName = ""
            }
        }
        .alert(
            "Delete Channel",
            isPresented: Binding(
                get: { deletingChannel != nil },
                set: { if !$0 { deletingChannel = nil } }
            ),
            presenting: deletingChannel
        ) { channel in
            Button("Delete", role: .destructive) { store.deleteChannel(channel.id) }
            Button("Cancel", role: .cancel) {}
        } message: { channel in
            Text(store.teams(in: channel.id).isEmpty
                 ? "“\(channel.name)” will be removed. The bots are not deleted; those in no other channel go back to the list."
                 : "“\(channel.name)” and its teams’ chats will be removed from this iPhone. The bots are not deleted; those in no other channel go back to the list.")
        }
        .alert(
            "Delete Team",
            isPresented: Binding(
                get: { deletingTeam != nil },
                set: { if !$0 { deletingTeam = nil } }
            ),
            presenting: deletingTeam
        ) { team in
            Button("Delete", role: .destructive) { store.delete(team.id) }
            Button("Cancel", role: .cancel) {}
        } message: { team in
            Text("“\(team.title)” and its messages will be removed from this iPhone. The bots are not affected.")
        }
        .fileImporter(isPresented: $importingBot, allowedContentTypes: [.archive, .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await importBotArchive(url) }
        }
        .sheet(item: $editingBot) { bot in
            // No Done here: the page has one of its own, and unlike this it
            // commits the name and description on the way out.
            NavigationStack {
                BotDetail(bot: bot, onChange: { Task { await load() } })
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .alert("New Section", isPresented: $showNewSectionAlert) {
            TextField("Section Name", text: $newSectionName)
            Button("Cancel", role: .cancel) {
                newSectionName = ""
                newSectionTargetBot = nil
            }
            Button("Create") {
                let trimmed = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.addSection(trimmed)
                    if let target = newSectionTargetBot {
                        store.setBotSection(target, section: trimmed)
                    }
                }
                newSectionName = ""
                newSectionTargetBot = nil
            }
        } message: {
            Text("Enter a name for the new bot section.")
        }
        .alert("Rename Section", isPresented: $showRenameSectionAlert) {
            TextField("Section Name", text: $renameSectionName)
            Button("Cancel", role: .cancel) {
                renamingSection = nil
                renameSectionName = ""
            }
            Button("Save") {
                if let renamingSection {
                    store.renameSection(from: renamingSection, to: renameSectionName)
                }
                renamingSection = nil
                renameSectionName = ""
            }
        } message: {
            Text("Enter a new name for this section.")
        }
        .confirmationDialog(
            "Delete Section",
            isPresented: .init(
                get: { deletingSection != nil },
                set: { if !$0 { deletingSection = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletingSection {
                    store.deleteSection(deletingSection)
                }
                deletingSection = nil
            }
            Button("Cancel", role: .cancel) {
                deletingSection = nil
            }
        } message: {
            if let deletingSection {
                Text("Are you sure you want to delete '\(deletingSection)'? The bots inside will become Unassigned.")
            }
        }
        .confirmationDialog(
            "Delete Bot",
            isPresented: .init(
                get: { deletingBot != nil },
                set: { if !$0 { deletingBot = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletingBot {
                    Task {
                        do {
                            try await store.deleteBot(deletingBot.name)
                        } catch {
                            failure = describeBotError(error)
                        }
                        await load()
                    }
                }
                deletingBot = nil
            }
            Button("Cancel", role: .cancel) {
                deletingBot = nil
            }
        } message: {
            if let deletingBot {
                Text("Are you sure you want to delete '\(deletingBot.displayName)'? This cannot be undone.")
            }
        }
        .task {
            if rows.isEmpty { rows = store.cachedBots }
            await load()
            seeded = true
        }
        .refreshable { await load() }
    }

    private func importBotArchive(_ url: URL) async {
        importBusy = true
        defer { importBusy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var stagedPath: String?
        do {
            let listing = try await store.hermesFiles()
            let safeBase = URL(fileURLWithPath: url.lastPathComponent).lastPathComponent
                .replacingOccurrences(of: "/", with: "_")
            let stagedName = "alice-profile-import-\(UUID().uuidString)-\(safeBase)"
            let remote = RemoteFilePath.join(listing.path, stagedName)
            stagedPath = remote
            try await store.uploadHermesFileStream(path: remote, fileURL: url)
            _ = try await store.importProfileArchive(path: remote)
            try? await store.deleteHermesFile(path: remote)
            stagedPath = nil
            await load()
            failure = nil
        } catch {
            if let stagedPath { try? await store.deleteHermesFile(path: stagedPath) }
            failure = describeBotError(error)
        }
    }

    // MARK: - Sections & List

    private var filteredRows: [BotRow] {
        let visible = store.orderedBots(rows.filter { !store.isBotHidden($0) })
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visible }
        return visible.filter { bot in
            let dName = store.botCurrentName(for: bot)
            let dDetail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
            return bot.name.lowercased().contains(query) ||
            dName.lowercased().contains(query) ||
            dDetail.lowercased().contains(query)
        }
    }

    /// Pinned bots keep the order the list has, not the order they were
    /// pinned in — the shelf is a shortcut to the same list, not a second one.
    private var pinnedRows: [BotRow] {
        generalRows.filter { store.isBotPinned($0) }
    }

    /// The page outside channels. A bot put into a channel shows only there.
    private var generalRows: [BotRow] {
        filteredRows.filter { !store.isInAnyChannel($0.name) }
    }

    /// Everything the shelf above is not already showing. A pinned bot in
    /// both places is the same bot twice.
    private var unpinnedRows: [BotRow] {
        generalRows.filter { !store.isBotPinned($0) }
    }

    private func bots(in section: String) -> [BotRow] {
        unpinnedRows.filter { store.section(for: $0.name) == section }
    }

    private var unassignedBots: [BotRow] {
        unpinnedRows.filter { store.section(for: $0.name) == nil }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            if showSearch {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showSearch = false
                        searchQuery = ""
                        searchFocused = false
                        selectedFilter = .all
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close search")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search…", text: $searchQuery)
                        .font(.body)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)

                Menu {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(SearchFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Filter: \(selectedFilter.rawValue)")
            } else {
                // Now that this is a page rather than a sheet, Done was the
                // wrong word for it: nothing here is being confirmed, and
                // there was no way back to the conversation. The same disc
                // and the same chevron a bot's chat uses to get here.
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .imageScale(.large)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("bots.back")

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            showSearch = true
                        }
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search bots")

                    Menu {
                        Button {
                            creatingBot = true
                        } label: {
                            Label("New Bot", systemImage: "person.fill")
                        }
                        Button {
                            creatingChannel = true
                        } label: {
                            Label("New Channel", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button {
                            importingBot = true
                        } label: {
                            Label("Import Bot Template", systemImage: "square.and.arrow.down")
                        }
                        .disabled(importBusy)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add")
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
            }
        }
        // 20, the same as the conversation's top controls on every screen.
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var botList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if showSearch {
                    searchResultsView
                } else {
                    if stale { staleNotice }
                    pinnedShelf
                    channelsSection
                    normalBotSections
                    hiddenSection
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
    }

    /// The bots worth reaching without reading.
    ///
    /// A pinned bot is one you go to often, and a row of text is the wrong
    /// shape for that: you pick it out by its face long before you have read
    /// its name. So it gets the face at a size you can aim a thumb at, the
    /// name underneath, and nothing else — the description, the last message
    /// and the rest of what a row carries are for bots you are still deciding
    /// about.
    @ViewBuilder
    private var pinnedShelf: some View {
        let pinned = pinnedRows
        if !pinned.isEmpty {
            // Rows of three, each centred on its own. A grid would have held
            // three columns open whatever was in them, so a single pinned bot
            // sat in the left one with two empty columns beside it, looking
            // less like the one thing worth reaching first than like the first
            // of three you had failed to pin.
            // Generous gaps. The menu lifts a bot out of the row and grows
            // it, and at twelve points apart it had nowhere to grow into —
            // the lifted tile arrived overlapping its neighbours.
            VStack(spacing: 26) {
                ForEach(Array(stride(from: 0, to: pinned.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 22) {
                        ForEach(pinned[start..<min(start + 3, pinned.count)]) { bot in
                            pinnedTile(bot, reorderPeers: pinned)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// Everything you can do to a bot, wherever the bot is shown.
    ///
    /// The pinned shelf used to offer only Unpin. A bot does not become a
    /// different bot for being pinned, and a long press that answers with one
    /// item where it answers with six everywhere else reads as the shelf
    /// being a lesser copy of the list.
    @ViewBuilder
    private func botMenu(_ bot: BotRow, channel: BotChannel? = nil) -> some View {
            Button {
                store.toggleBotUnread(bot.name)
            } label: {
                Label(store.isBotUnread(bot.name) ? "Mark Read" : "Mark Unread", systemImage: "bubble.left")
            }

            // Pinning puts a bot on the shelf above the general list, which a
            // bot in a channel is no longer part of.
            if !store.isInAnyChannel(bot.name) {
                Button {
                    let next = !store.isBotPinned(bot)
                    Task {
                        do {
                            try await store.setBotPinned(bot, pinned: next)
                            await load()
                        } catch {
                            failure = describeBotError(error)
                        }
                    }
                } label: {
                    Label(store.isBotPinned(bot) ? "Unpin" : "Pin", systemImage: "pin")
                }
            }

            if let channel {
                // Inside a channel, sections are that channel's own.
                Menu {
                    ForEach(channel.sections, id: \.self) { sec in
                        Button {
                            store.setChannelSection(channel.id, bot: bot.name, section: sec)
                        } label: {
                            if channel.section(for: bot.name) == sec {
                                Label(sec, systemImage: "checkmark")
                            } else {
                                Text(sec)
                            }
                        }
                    }
                    if channel.section(for: bot.name) != nil {
                        Button("No Section") {
                            store.setChannelSection(channel.id, bot: bot.name, section: nil)
                        }
                    }
                    if !channel.sections.isEmpty { Divider() }
                    Button {
                        newChannelSection = ChannelSectionTarget(channelID: channel.id, bot: bot.name)
                    } label: {
                        Label("New Section", systemImage: "plus")
                    }
                } label: {
                    Label("Move to", systemImage: "folder")
                }

                Button {
                    store.removeBot(bot.name, fromChannel: channel.id)
                } label: {
                    Label("Remove from \(channel.name)", systemImage: "folder.badge.minus")
                }
            } else {
                Menu {
                    if !store.botCustomSections.isEmpty {
                        ForEach(store.botCustomSections, id: \.self) { sec in
                            Button {
                                store.setBotSection(bot.name, section: sec)
                            } label: {
                                if store.section(for: bot.name) == sec {
                                    Label(sec, systemImage: "checkmark")
                                } else {
                                    Text(sec)
                                }
                            }
                        }
                        if store.section(for: bot.name) != nil {
                            Button("Unassigned") {
                                store.setBotSection(bot.name, section: nil)
                            }
                        }
                        Divider()
                    }
                    Button {
                        newSectionTargetBot = bot.name
                        showNewSectionAlert = true
                    } label: {
                        Label("New Section", systemImage: "plus")
                    }
                } label: {
                    Label("Move to", systemImage: "folder")
                }
            }

            // A bot can be in several channels: each tick is one of them.
            Menu {
                ForEach(store.botChannels) { other in
                    Button {
                        if other.bots.contains(bot.name) {
                            store.removeBot(bot.name, fromChannel: other.id)
                        } else {
                            store.addBot(bot.name, toChannel: other.id)
                        }
                    } label: {
                        if other.bots.contains(bot.name) {
                            Label(other.name, systemImage: "checkmark")
                        } else {
                            Text(other.name)
                        }
                    }
                }
                if !store.botChannels.isEmpty { Divider() }
                Button {
                    channelSeedBot = bot.name
                    creatingChannel = true
                } label: {
                    Label("New Channel", systemImage: "plus")
                }
            } label: {
                Label("Channels", systemImage: "folder.badge.person.crop")
            }

            Button(role: .destructive) {
                Task {
                    do {
                        try await store.setBotHidden(bot, hidden: true)
                        await load()
                    } catch {
                        failure = describeBotError(error)
                    }
                }
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }

            Menu {
                Button {
                    UIPasteboard.general.string = bot.name
                } label: {
                    Label("Copy ID", systemImage: "doc.on.doc")
                }

                Button {
                    duplicateBot(bot)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Button(role: .destructive) {
                    deletingBot = bot
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }

            // No "Ask Siri" here: iOS exposes no way to open Siri from a
            // context menu, and an item that swallows the tap is worse than
            // one that is absent. Reaching a bot by voice needs an App
            // Intent, which lives outside this menu.
            }

    private func mark(_ bot: BotRow) -> BotMark { store.mark(for: bot.name) }

    /// How much of the colour to lay under the glass.
    ///
    /// Measured off the colour's own lightness rather than fixed. On paper a
    /// pale mark has almost nothing to say against a pale page and needs
    /// nearly all of itself; a deep one at the same strength would read as a
    /// sticker rather than as glass. In the dark it is the other way round.
    static func backing(_ colour: Color, _ scheme: ColorScheme) -> Double {
        var white: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getWhite(&white, alpha: &alpha)
        let lightness = Double(white)
        // Raised in both, and most in the dark. Interactive glass sits darker
        // than the plain kind — it has a shadow and a deeper surface — so the
        // colour underneath has to come up to meet it or every bot reads as a
        // muddy version of itself.
        return scheme == .dark
            ? 0.72 - 0.26 * lightness
            : 0.60 + 0.38 * lightness
    }

    @ViewBuilder
    private func pinnedTile(_ bot: BotRow, reorderPeers: [BotRow]? = nil) -> some View {
        if let reorderPeers {
            pinnedTileBase(bot)
                .onDrag {
                    draggedBotName = bot.name
                    return NSItemProvider(object: bot.name as NSString)
                } preview: {
                    pinnedTilePreview(bot)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: BotReorderDropDelegate(
                        target: bot.name,
                        peers: reorderPeers.map(\.name),
                        draggedName: $draggedBotName,
                        move: moveBot
                    )
                )
        } else {
            pinnedTileBase(bot)
        }
    }

    private func pinnedTileBase(_ bot: BotRow) -> some View {
        Button {
            guard canOpenBot() else { return }
            store.openBotConversation(for: bot)
            store.botsExitLeading = true
            onClose()
        } label: {
            VStack(spacing: 8) {
                glassMark(bot, size: 76)

                HStack(spacing: 5) {
                    Text(store.botCurrentName(for: bot.name))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if store.isBotUnread(bot.name) {
                        unreadDot(size: Self.unreadDotSize)
                            .offset(y: 1)
                    }
                }
                .frame(maxWidth: 100)
            }
            .frame(width: 100)
            .contentShape(.interaction, .rect)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bots.row.\(bot.name)")
        .contextMenu {
            botMenu(bot)
        } preview: {
            pinnedTilePreview(bot)
        }
    }

    private func pinnedTilePreview(_ bot: BotRow) -> some View {
        VStack(spacing: 8) {
            BotMarkView(mark: mark(bot), size: 76)
            Text(store.botCurrentName(for: bot.name))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 112)
        .padding(.vertical, 10)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
    }

    /// The bot's mark as a glass surface.
    @ViewBuilder
    private func glassMark(_ bot: BotRow, size: CGFloat, showsUnread: Bool = false) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                MarkShape(silhouette: mark(bot).silhouette)
                    .fill(mark(bot).color.opacity(Self.backing(mark(bot).color, scheme)))
                BotFaceView(size: size)
            }
            .frame(width: size, height: size)
            // Interactive, which is what makes it stretch under a finger the
            // way the discs in the conversation do.
            .glassEffect(
                .regular.interactive().tint(mark(bot).color.opacity(0.42)),
                in: MarkShape(silhouette: mark(bot).silhouette)
            )

            if showsUnread && store.isBotUnread(bot.name) {
                unreadDot(size: Self.unreadDotSize)
                    // The visible edge of a round mark crosses this badge near
                    // its centre. A rectangular bottom-trailing alignment sits
                    // beyond that curved edge, so pull it back into the face.
                    .offset(
                        x: -Self.unreadDotSize * 0.15,
                        y: -Self.unreadDotSize * 0.15
                    )
            }
        }
        // Slack outside the glass, not inside it: the shape is cut to the
        // mark first and the room comes after. The stretch draws beyond the
        // mark's own bounds, and with nothing around it the top of the bulge
        // was cut off against the edge of the layer.
        .padding(size * 0.16)
    }

    private func unreadDot(size: CGFloat) -> some View {
        Circle()
            .fill(Color.blue)
            .frame(width: size, height: size)
            .overlay {
                Circle().stroke(Palette.background(scheme), lineWidth: 2)
            }
            .accessibilityLabel("Unread")
    }

    private static let unreadDotSize: CGFloat = 10

    /// Said out loud rather than left to be assumed: this list came from the
    /// cache because the agent did not answer.
    private var staleNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text("Showing the last known list — the dashboard did not answer.")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    /// The way back from Hide.
    ///
    /// Hiding used to be one-way: `unhideBot` had no caller, so a hidden bot
    /// left the screen for good and the only recovery was wiping the app's
    /// data.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = rows.filter { store.isBotHidden($0) }
        if !hidden.isEmpty {
            Button {
                store.hiddenExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Hidden")
                    Text("\(hidden.count)")
                        .foregroundStyle(.secondary)
                    if store.hasUnread(hidden.map(\.name)) { unreadDot }
                    Image(systemName: store.hiddenExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if store.hiddenExpanded {
                ForEach(hidden) { bot in
                    HStack(spacing: 12) {
                        BotMarkView(mark: store.mark(for: bot.name), size: 34)
                        Text(store.botCurrentName(for: bot))
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Unhide") {
                            Task {
                                do {
                                    try await store.setBotHidden(bot, hidden: false)
                                    await load()
                                } catch {
                                    failure = describeBotError(error)
                                }
                            }
                        }
                            .font(.subheadline)
                            .buttonStyle(.plain)
                            .foregroundStyle(store.accent.primary(scheme))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// Channels: folders of bots and teams, above the general list.
    ///
    /// A channel is never a chat. Tapping it opens or shuts it, and it stays as
    /// it was left. Inside are its bots — loose, or in the channel's own
    /// sections — and its teams; an empty one says so and offers nothing to
    /// type into.
    @ViewBuilder
    private var channelsSection: some View {
        ForEach(store.botChannels) { channel in
            channelFolder(channel)
        }
    }

    @ViewBuilder
    private func channelFolder(_ channel: BotChannel) -> some View {
        let members = channelRows(channel)
        let teams = store.teams(in: channel.id)
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.toggleChannelCollapsed(channel.id)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(store.accent.primary(scheme))
                Text(channel.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if channel.collapsed {
                    Text("\(members.count + teams.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                if store.hasUnread(members.map(\.name)) { unreadDot }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(channel.collapsed ? -90 : 0))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bots.channel.\(channel.name)")
        .contextMenu {
            channelMenu(channel, hasBots: !members.isEmpty)
        }

        if !channel.collapsed {
            Group {
                if members.isEmpty && teams.isEmpty {
                    Text("This channel is empty")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                ForEach(teams, id: \.id) { team in
                    groupRowView(team)
                        .contextMenu {
                            Button(role: .destructive) {
                                deletingTeam = team
                            } label: {
                                Label("Delete Team", systemImage: "trash")
                            }
                        }
                }
                ForEach(channel.sections, id: \.self) { section in
                    let sectionBots = members.filter { channel.section(for: $0.name) == section }
                    channelSectionHeader(channel, section: section, bots: sectionBots)
                    if !channel.collapsedSections.contains(section) {
                        ForEach(sectionBots) { bot in
                            botRowView(bot, channel: channel)
                        }
                    }
                }
                ForEach(members.filter { channel.section(for: $0.name) == nil }) { bot in
                    botRowView(bot, channel: channel)
                }
            }
            .padding(.leading, 12)
        }
    }

    /// The bots shown in a channel, in the page's order; hidden ones stay in
    /// Hidden.
    private func channelRows(_ channel: BotChannel) -> [BotRow] {
        let members = Set(channel.bots)
        return filteredRows.filter { members.contains($0.name) }
    }

    private func channelSectionHeader(_ channel: BotChannel, section: String, bots: [BotRow]) -> some View {
        let collapsed = channel.collapsedSections.contains(section)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.toggleChannelSectionCollapsed(channel.id, section: section)
            }
        } label: {
            HStack(spacing: 6) {
                Text(section)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if store.hasUnread(bots.map(\.name)) { unreadDot }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.deleteChannelSection(channel.id, name: section)
            } label: {
                Label("Delete Section", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func channelMenu(_ channel: BotChannel, hasBots: Bool) -> some View {
        Button {
            channelNameDraft = channel.name
            renamingChannel = channel
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            editingChannel = channel
        } label: {
            Label("Choose Bots", systemImage: "person.2")
        }
        // A team is made from the channel's bots, so it needs some.
        Button {
            creatingTeamIn = channel
        } label: {
            Label("New Team", systemImage: "bubble.left.and.bubble.right")
        }
        .disabled(!hasBots)
        Button {
            newChannelSection = ChannelSectionTarget(channelID: channel.id, bot: nil)
        } label: {
            Label("New Section", systemImage: "plus")
        }
        Button(role: .destructive) {
            deletingChannel = channel
        } label: {
            Label("Delete Channel", systemImage: "trash")
        }
    }

    /// Between a section's name and its arrow: some bot inside has something
    /// unread, which a shut section would otherwise keep out of sight.
    private var unreadDot: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread")
    }

    @ViewBuilder
    private var normalBotSections: some View {
        if store.botCustomSections.isEmpty {
            ForEach(unpinnedRows) { bot in
                botRowView(bot, reorderPeers: unpinnedRows)
            }
        } else {
            ForEach(store.sectionOrder, id: \.self) { sectionKey in
                if sectionKey == AppStore.unassignedSectionKey {
                    if !unassignedBots.isEmpty {
                        unassignedSectionHeader
                        if store.unassignedExpanded {
                            ForEach(unassignedBots) { bot in
                                botRowView(bot, reorderPeers: unassignedBots)
                            }
                        }
                    }
                } else {
                    let sectionBots = bots(in: sectionKey)
                    sectionHeader(sectionKey, count: sectionBots.count)

                    if !store.collapsedSections.contains(sectionKey) {
                        ForEach(sectionBots) { bot in
                            botRowView(bot, reorderPeers: sectionBots)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch selectedFilter {
        case .bots:
            let matches = filteredRows
            if matches.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .padding(.top, 40)
            } else {
                ForEach(matches) { bot in
                    botRowView(bot)
                }
            }
        case .messages:
            let matches = allMessagesMatching(query: q)
            if matches.isEmpty {
                ContentUnavailableView(
                    q.isEmpty ? "Search Messages" : "No Messages Found",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(q.isEmpty ? "Type to find messages across chats." : "No messages matched “\(searchQuery)”.")
                )
                .padding(.top, 40)
            } else {
                ForEach(matches) { match in
                    messageRowMatchView(match)
                }
            }
        case .groups:
            let matches = allGroupsMatching(query: q)
            if matches.isEmpty {
                ContentUnavailableView(
                    q.isEmpty ? "No Channels" : "No Channels Found",
                    systemImage: "person.3",
                    description: Text(q.isEmpty ? "No group channels found." : "No channels matched “\(searchQuery)”.")
                )
                .padding(.top, 40)
            } else {
                ForEach(matches) { group in
                    groupRowView(group)
                }
            }
        case .files:
            let matches = allFilesMatching(query: q)
            if matches.isEmpty {
                ContentUnavailableView(
                    q.isEmpty ? "No Files" : "No Files Found",
                    systemImage: "doc",
                    description: Text(q.isEmpty ? "No files shared in chats yet." : "No files matched “\(searchQuery)”.")
                )
                .padding(.top, 40)
            } else {
                ForEach(matches) { file in
                    fileRowView(file)
                }
            }
        case .routines:
            let matches = allRoutinesMatching(query: q)
            if matches.isEmpty {
                ContentUnavailableView(
                    routinesUnavailable != nil ? "Routines Unavailable"
                        : (q.isEmpty ? "No Routines" : "No Routines Found"),
                    systemImage: routinesUnavailable != nil
                        ? "clock.badge.exclamationmark" : "clock",
                    description: Text(
                        routinesUnavailable
                            ?? (q.isEmpty ? "No routines configured on bots."
                                : "No routines matched “\(searchQuery)”.")
                    )
                )
                .padding(.top, 40)
            } else {
                ForEach(matches, id: \.routine.id) { item in
                    routineRowView(item.routine, botName: item.botName)
                }
            }
        case .all:
            if q.isEmpty {
                normalBotSections
            } else {
                allSearchResults(query: q)
            }
        }
    }

    @ViewBuilder
    private func allSearchResults(query: String) -> some View {
        let matchingBots = filteredRows
        let matchingRoutines = allRoutinesMatching(query: query)
        let matchingMessages = allMessagesMatching(query: query)
        let matchingGroups = allGroupsMatching(query: query)
        let matchingFiles = allFilesMatching(query: query)

        let hasAny = !matchingBots.isEmpty || !matchingRoutines.isEmpty || !matchingMessages.isEmpty || !matchingGroups.isEmpty || !matchingFiles.isEmpty

        if !hasAny {
            ContentUnavailableView.search(text: searchQuery)
                .padding(.top, 40)
        } else {
            if !matchingBots.isEmpty {
                searchCategoryHeader("Bots", count: matchingBots.count)
                ForEach(matchingBots) { bot in
                    botRowView(bot)
                }
            }

            if !matchingRoutines.isEmpty {
                searchCategoryHeader("Routines", count: matchingRoutines.count)
                ForEach(matchingRoutines, id: \.routine.id) { item in
                    routineRowView(item.routine, botName: item.botName)
                }
            }

            if !matchingGroups.isEmpty {
                searchCategoryHeader("Groups", count: matchingGroups.count)
                ForEach(matchingGroups) { group in
                    groupRowView(group)
                }
            }

            if !matchingMessages.isEmpty {
                searchCategoryHeader("Messages", count: matchingMessages.count)
                ForEach(matchingMessages) { match in
                    messageRowMatchView(match)
                }
            }

            if !matchingFiles.isEmpty {
                searchCategoryHeader("Files", count: matchingFiles.count)
                ForEach(matchingFiles) { file in
                    fileRowView(file)
                }
            }
        }
    }

    private func searchCategoryHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func routineRowView(_ routine: JobRow, botName: String) -> some View {
        HStack(spacing: 12) {
            BotMarkView(mark: store.mark(for: botName), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(routine.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !routine.schedule.isEmpty {
                        Text(routine.schedule)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: .rect(cornerRadius: 5))
                    }
                }
                Text(routine.prompt.isEmpty ? "Bot: \(store.botCurrentName(for: botName))" : routine.prompt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func groupRowView(_ group: Conversation) -> some View {
        Button {
            store.activeID = group.id
            onClose()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let bots = group.channelBots, !bots.isEmpty {
                        Text(bots.map { store.botCurrentName(for: $0) }.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func messageRowMatchView(_ match: MessageMatch) -> some View {
        Button {
            store.activeID = match.conversation.id
            onClose()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(match.conversation.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.accent.primary(scheme))
                    Spacer()
                    Text(match.message.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(match.message.content)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func fileRowView(_ match: FileMatch) -> some View {
        Button {
            store.activeID = match.conversation.id
            onClose()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: match.attachment.mime.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(match.attachment.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("In: \(match.conversation.title)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    struct MessageMatch: Identifiable {
        var id: String { message.id }
        let message: Message
        let conversation: Conversation
    }

    struct FileMatch: Identifiable {
        var id: String { "\(conversation.id)-\(attachment.name)" }
        let attachment: Attachment
        let conversation: Conversation
    }

    private func allRoutinesMatching(query: String) -> [(routine: JobRow, botName: String)] {
        var results: [(JobRow, String)] = []
        for (bName, routinesList) in routinesByBot {
            for r in routinesList {
                if query.isEmpty ||
                    r.name.localizedCaseInsensitiveContains(query) ||
                    r.prompt.localizedCaseInsensitiveContains(query) ||
                    r.schedule.localizedCaseInsensitiveContains(query) ||
                    bName.localizedCaseInsensitiveContains(query) {
                    results.append((r, bName))
                }
            }
        }
        return results
    }

    private func allGroupsMatching(query: String) -> [Conversation] {
        store.conversations.filter { conv in
            guard conv.isChannel == true else { return false }
            if query.isEmpty { return true }
            return conv.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func allMessagesMatching(query: String) -> [MessageMatch] {
        guard !query.isEmpty else { return [] }
        var results: [MessageMatch] = []
        for conv in store.conversations {
            for msg in conv.messages {
                if msg.content.localizedCaseInsensitiveContains(query) {
                    results.append(MessageMatch(message: msg, conversation: conv))
                }
            }
        }
        return results
    }

    private func allFilesMatching(query: String) -> [FileMatch] {
        var results: [FileMatch] = []
        for conv in store.conversations {
            for msg in conv.messages {
                for att in msg.attachments {
                    if query.isEmpty || att.name.localizedCaseInsensitiveContains(query) {
                        results.append(FileMatch(attachment: att, conversation: conv))
                    }
                }
            }
        }
        return results
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.toggleSectionCollapsed(title)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if store.hasUnread(bots(in: title).map(\.name)) { unreadDot }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.collapsedSections.contains(title) ? -90 : 0))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            let order = store.sectionOrder
            let isFirst = order.first == title
            let isLast = order.last == title

            Button {
                renamingSection = title
                renameSectionName = title
                showRenameSectionAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                store.moveSectionUp(title)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(isFirst)

            Button {
                store.moveSectionDown(title)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(isLast)

            Button(role: .destructive) {
                deletingSection = title
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var unassignedSectionHeader: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                store.unassignedExpanded.toggle()
            }
        } label: {
            // Laid out like the named sections: the title, then the mark that
            // opens it, then whatever space is left. Pushed to the far edge by
            // a Spacer, the chevron sat a phone's width from the word it acts
            // on and read as a separate control.
            //
            // The count goes with it, and only while the section is shut: open,
            // the bots are right there to be counted, and the number is one
            // more thing to read that says nothing new.
            HStack(spacing: 6) {
                Text("Unassigned")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !store.unassignedExpanded {
                    Text("\(unassignedBots.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                if store.hasUnread(unassignedBots.map(\.name)) { unreadDot }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.unassignedExpanded ? 0 : -90))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            let order = store.sectionOrder
            let isFirst = order.first == AppStore.unassignedSectionKey
            let isLast = order.last == AppStore.unassignedSectionKey

            Button {
                store.moveSectionUp(AppStore.unassignedSectionKey)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(isFirst)

            Button {
                store.moveSectionDown(AppStore.unassignedSectionKey)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(isLast)
        }
    }

    @ViewBuilder
    private func botRowView(
        _ bot: BotRow, reorderPeers: [BotRow]? = nil, channel: BotChannel? = nil
    ) -> some View {
        if let reorderPeers {
            botRowBase(bot, channel: channel)
                .onDrag {
                    draggedBotName = bot.name
                    return NSItemProvider(object: bot.name as NSString)
                } preview: {
                    botRowPreview(bot)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: BotReorderDropDelegate(
                        target: bot.name,
                        peers: reorderPeers.map(\.name),
                        draggedName: $draggedBotName,
                        move: moveBot
                    )
                )
        } else {
            botRowBase(bot, channel: channel)
        }
    }

    private func botRowBase(_ bot: BotRow, channel: BotChannel? = nil) -> some View {
        Button {
            guard canOpenBot() else { return }
            store.openBotConversation(for: bot)
            store.botsExitLeading = true
            onClose()
        } label: {
            botRowContents(bot)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(.interaction, .rect)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bots.row.\(bot.name)")
        .contextMenu {
            botMenu(bot, channel: channel)
        } preview: {
            botRowPreview(bot)
        }
    }

    private func botRowContents(_ bot: BotRow, glassFace: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if glassFace { glassMark(bot, size: 44, showsUnread: true) }
                else { BotMarkView(mark: mark(bot), size: 44) }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 6) {
                    Text(store.botCurrentName(for: bot))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    let liveDetail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
                    if !liveDetail.isEmpty {
                        Text(liveDetail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.secondary.opacity(0.16), in: .rect(cornerRadius: 5))
                    }

                    if store.isBotPinned(bot) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(store.accent.primary(scheme))
                    }

                    Spacer(minLength: 4)

                    Text(timestamp(for: bot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(snippet(for: bot))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func botRowPreview(_ bot: BotRow) -> some View {
        botRowContents(bot, glassFace: false)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 340)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
    }

    private func moveBot(_ source: String, _ target: String, _ peers: [String]) {
        guard source != target, peers.contains(source), peers.contains(target) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            store.reorderBot(source, relativeTo: target, within: peers)
        }
    }

    private func duplicateBot(_ bot: BotRow) {
        let baseName = bot.name
        var newName = baseName + "-copy"
        var counter = 2
        while rows.contains(where: { $0.name == newName }) {
            newName = "\(baseName)-copy-\(counter)"
            counter += 1
        }
        Task {
            do {
                try await store.duplicateBot(bot, as: newName)
                store.botMarks[newName] = store.mark(for: bot.name)
                if let section = store.section(for: bot.name) {
                    store.setBotSection(newName, section: section)
                }
                await load()
            } catch {
                failure = describeBotError(error)
            }
        }
    }

    /// When the bot last replied, at the end of its row — the way a messaging
    /// app dates a thread. The same reply the snippet under the name quotes.
    /// Empty for a bot that has not replied, or whose replies came without a
    /// time.
    private func timestamp(for bot: BotRow) -> String {
        guard let conversation = store.conversations.first(where: { $0.botName == bot.name }),
              let reply = RoutineDelivery.present(conversation.messages, botName: bot.name, quietRuns: store.quietRoutineRuns[bot.name] ?? []).last(where: {
                  $0.role == .assistant && !$0.pending && MessageTime.isKnown($0.createdAt)
              })
        else { return "" }
        return MessageTime.short(reply.createdAt) ?? ""
    }

    /// What the bot last said, which is what a list of conversations is
    /// supposed to show. Its description is already on the line above, on the
    /// badge beside the name — printing it twice told you nothing new.
    private func snippet(for bot: BotRow) -> String {
        if let line = lastReply(from: bot) { return line }
        let detail = store.cachedBots.first(where: { $0.name == bot.name })?.detail
            ?? bot.detail
        return detail.isEmpty ? "Ready for messages" : detail
    }

    /// The opening of the bot's most recent reply, flattened onto one line.
    ///
    /// A reply often starts with a heading or a list, so the raw first line
    /// can be a lone "#" or a bullet. Newlines collapse to spaces and the
    /// markdown that only makes sense in a rendered block is dropped.
    private func lastReply(from bot: BotRow) -> String? {
        guard let conversation = store.conversations.first(
            where: { $0.botName == bot.name }
        ) else { return nil }
        guard let reply = RoutineDelivery.present(conversation.messages, botName: bot.name, quietRuns: store.quietRoutineRuns[bot.name] ?? []).last(where: {
            $0.role == .assistant && !$0.pending
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }

        var line = reply.content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: "^[#>*\\-\\s]+", with: "", options: .regularExpression
            )
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // Well past what one line shows; the label truncates the rest.
        return String(line.prefix(160))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            rows = try await store.bots()
            failure = nil
            stale = false
        } catch {
            // Falling back to the cache is fine; pretending it is live is not.
            // The list still appears, and the header says how old it might be.
            if rows.isEmpty && !store.cachedBots.isEmpty {
                rows = store.cachedBots
            }
            stale = !rows.isEmpty
            failure = rows.isEmpty ? describeBotError(error) : nil
        }
        do {
            routinesByBot = try await store.allRoutines()
            routinesUnavailable = nil
        } catch {
            // Keep whatever was already listed — it is still true of the last
            // successful read — but do not let a failed refresh pass for an
            // agent that has no routines.
            routinesUnavailable = describeBotError(error)
        }
    }
}

/// The mark color picker, shared by the detail screen and the create sheet.
struct MarkPicker: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var mark: BotMark

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(BotMark.colours.indices, id: \.self) { index in
                Button { mark.colour = index } label: {
                    Circle()
                        .fill(BotMark.colours[index])
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle().strokeBorder(
                                Color.primary,
                                lineWidth: mark.colour == index ? 2 : 0
                            )
                            .padding(-3)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - BotDetail (Fully Editable)

/// One bot: fully editable properties including model, section, instructions, notifications, etc.
/// A bot's whole settings page — mark, name, description, model, section,
/// notifications, soul and routines. Reached from the list and from the top
/// of its own conversation.
struct BotDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bot: BotRow
    let onChange: () -> Void

    @State private var mark = BotMark(colour: 0, shape: 0)
    @State private var name = ""
    @State private var detail = ""
    @State private var choosingModel = false
    @State private var selectedSection = ""
    @State private var notifications = false
    @Environment(Notifier.self) private var notifier
    @State private var routines: RoutineState = .loading
    @State private var addingRoutine = false
    @State private var selectedRoutine: JobRow?
    @State private var editingSoul = false
    @State private var busy = false
    @State private var failure: String?
    @State private var exported: String?
    @State private var exportedURL: URL?
    @State private var setupCommand: String?
    @State private var autoDescribing = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    BotMarkView(mark: mark, size: 84, animated: true)
                    TextField("Name", text: $name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .onSubmit { commitName() }
                    Divider()
                    TextField("Title (optional)", text: $detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .onSubmit { commitDetail() }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .listRowBackground(Palette.card(scheme))
            }

            Section {
                MarkPicker(mark: $mark)
                    .listRowBackground(Palette.card(scheme))
                Button("Reset to default") {
                    mark = BotMark.derived(from: bot.name)
                }
                .listRowBackground(Palette.card(scheme))
            } header: {
                Text("Character")
            } footer: {
                Text("How this Bot's mark looks everywhere.")
            }

            Section {
                Button { editingSoul = true } label: {
                    HStack {
                        Label("Instructions", systemImage: "doc.text")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.card(scheme))
            }
            Section("Profile tools") {
                Button {
                    autoDescribe()
                } label: {
                    Label(autoDescribing ? "Generating description…" : "Generate description automatically", systemImage: "wand.and.stars")
                }
                .disabled(autoDescribing || busy)
                .listRowBackground(Palette.card(scheme))

                if let setupCommand {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CLI setup command").font(.caption).foregroundStyle(.secondary)
                            Text(setupCommand).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Spacer()
                        Button { UIPasteboard.general.string = setupCommand } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("Copy setup command")
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }

            let recovered = store.recoveredHistory(for: bot.name)
            if !recovered.isEmpty {
                Section("Historial anterior") {
                    ForEach(recovered) { chat in
                        Button {
                            store.openConversation(chat.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.title).lineLimit(1)
                                Text("\(chat.messages.count) mensajes · sólo lectura")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Palette.card(scheme))
                    }
                }
            }

            Section("Routines") {
                switch routines {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading routines…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Routines unavailable")
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                case .loaded(let rows) where rows.isEmpty:
                    Text("No routines yet")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                case let .loaded(rows):
                    ForEach(rows) { routine in
                        Button { selectedRoutine = routine } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(RoutinePresentation.colour(routine))
                                        .frame(width: 6, height: 6)
                                    Text(routine.name).font(.subheadline).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                if !routine.schedule.isEmpty {
                                    Text(routine.schedule)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let next = routine.nextRun, routine.enabled {
                                    Text("Next \(next.formatted(.relative(presentation: .named)))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Palette.card(scheme))
                    }
                }

                Button {
                    addingRoutine = true
                } label: {
                    Label("Add routine", systemImage: "plus")
                }
                .listRowBackground(Palette.card(scheme))
            }

            Section("Configuration") {
                Button { choosingModel = true } label: {
                    HStack {
                        Text("Model").foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text(
                            store.botModelOption(for: liveBot)?.label
                                ?? liveBot.model.map(HermesClient.prettify)
                                ?? "Not configured"
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.card(scheme))

                if store.botModelSyncPending(bot.name) {
                    Button("Retry model sync", systemImage: "arrow.clockwise") {
                        choosingModel = true
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                Picker("Section", selection: $selectedSection) {
                    Text("Unassigned").tag("")
                    ForEach(store.botCustomSections, id: \.self) { sec in
                        Text(sec).tag(sec)
                    }
                }
                .listRowBackground(Palette.card(scheme))
                .onChange(of: selectedSection) { _, next in
                    store.setBotSection(bot.name, section: next.isEmpty ? nil : next)
                }

                LabeledContent("Profile", value: "@\(bot.name)")
                    .listRowBackground(Palette.card(scheme))
                if let provider = bot.provider {
                    LabeledContent("Provider", value: provider)
                        .listRowBackground(Palette.card(scheme))
                }
                LabeledContent("Skills", value: "\(bot.skills)")
                    .listRowBackground(Palette.card(scheme))
                LabeledContent(
                    "Gateway", value: bot.gatewayRunning ? "Running" : "Shared / idle"
                )
                .listRowBackground(Palette.card(scheme))
            }

            Section {
                Toggle("Notify me about this assistant", isOn: $notifications)
                    .listRowBackground(Palette.card(scheme))
                    .disabled(notifier.permission == .refused)
                    .onChange(of: notifications) { _, next in
                        Task { await setNotifications(next) }
                    }

                if notifier.permission == .refused {
                    // The switch cannot be honoured, and iOS only presents its
                    // prompt once — so the way back is Settings, and saying so
                    // is more use than a switch that flips and does nothing.
                    Button("Open iOS Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notificationExplanation)
                    if notifier.permission != .refused {
                        Text(
                            "Alice tells you while it is open, and when iOS next "
                            + "wakes it in the background. It cannot be reached "
                            + "while it is closed, so for alerts that always "
                            + "arrive, have an automation deliver to a channel."
                        )
                        .font(.caption2)
                    }
                }
            }

            Section {
                Button("Export template", systemImage: "square.and.arrow.up") {
                    exportTemplate()
                }
                .listRowBackground(Palette.card(scheme))

                if let exportedURL {
                    ShareLink("Share exported template", item: exportedURL)
                }
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if exportedURL != nil {
                    Text("The template was downloaded from Hermes and is ready to share from this iPhone.").foregroundStyle(.secondary)
                } else if let exported {
                    Text("Hermes wrote the archive to \(exported)").foregroundStyle(.secondary)
                }
            }
        }
         .navigationTitle(store.botCurrentName(for: bot))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    commitName()
                    commitDetail()
                    dismiss()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if busy {
                    ProgressView()
                } else {
                    Menu {
                        Button("Export template", systemImage: "square.and.arrow.up") {
                            exportTemplate()
                        }
                        Button("Copy name", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = bot.name
                        }
                        if !bot.isDefault {
                            Divider()
                            Button("Delete Bot", systemImage: "trash", role: .destructive) {
                                act { try await store.deleteBot(bot.name) } then: { dismiss() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $editingSoul) {
            SoulEditor(bot: bot.name)
        }
        .sheet(isPresented: $choosingModel) {
            ModelPicker(bot: liveBot)
                .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(isPresented: $addingRoutine) {
            RoutineEditorSheet(
                profiles: [(bot.name, store.botCurrentName(for: bot))]
            ) { _, rName, rPrompt, rSchedule, deliver in
                try await store.addRoutine(
                    for: bot.name, name: rName, prompt: rPrompt,
                    schedule: rSchedule, deliver: deliver
                )
                failure = nil
                routines = await .resolving(
                    { try await store.routines(for: bot.name) },
                    describe: describeBotError
                )
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(item: $selectedRoutine) { routine in
            RoutineDetailSheet(routine: routine) {
                routines = await .resolving(
                    { try await store.routines(for: bot.name) },
                    describe: describeBotError
                )
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .onChange(of: mark) {
            guard mark != store.mark(for: bot.name) else { return }
            store.botMarks[bot.name] = mark
        }
        .onDisappear {
            commitName()
            commitDetail()
        }
        .task {
            mark = store.mark(for: bot.name)
            name = store.botCurrentName(for: bot)
            detail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
            selectedSection = store.section(for: bot.name) ?? ""
            notifications = store.botNotificationsEnabled(for: bot.name)
            await notifier.refreshPermission()
            // A permission revoked in iOS Settings must switch the row off
            // rather than leave it looking armed.
            if !notifier.permission.canDeliver, notifications, notifier.permission == .refused {
                notifications = false
                store.setBotNotifications(bot.name, enabled: false)
            }
            setupCommand = try? await store.profileSetupCommand(bot.name)
            routines = await .resolving(
                { try await store.routines(for: bot.name) },
                describe: describeBotError
            )
        }
    }

    private func autoDescribe() {
        guard !autoDescribing else { return }
        autoDescribing = true
        Task {
            defer { autoDescribing = false }
            do {
                let result = try await store.describeProfileAutomatically(bot.name, overwrite: true)
                if result.ok {
                    detail = result.description
                    failure = nil
                    onChange()
                } else {
                    failure = result.reason ?? "Hermes could not generate a profile description."
                }
            } catch { failure = describeBotError(error) }
        }
    }

    private var notificationExplanation: String {
        switch notifier.permission {
        case .refused:
            "iOS is not allowing Alice to send notifications, so this cannot be turned on."
        case .allowedQuietly:
            "Notifications are allowed but set to deliver quietly, so they will not appear as banners."
        case .notAsked, .allowed:
            "Tells you when one of this assistant’s automations finishes or fails."
        }
    }

    /// Asks for permission at the moment the person opts in — not at first
    /// launch, where there is nothing yet to explain.
    private func setNotifications(_ enabled: Bool) async {
        guard enabled else {
            store.setBotNotifications(bot.name, enabled: false)
            return
        }
        let granted = await notifier.requestPermission()
        guard granted else {
            notifications = false
            store.setBotNotifications(bot.name, enabled: false)
            return
        }
        store.setBotNotifications(bot.name, enabled: true)
    }

    private func exportTemplate() {
        guard !busy else { return }
        busy = true
        exportedURL = nil
        Task {
            defer { busy = false }
            do {
                guard let remote = try await store.exportBot(bot.name), !remote.isEmpty else {
                    throw DashboardClient.Failure.unreadable
                }
                exported = remote
                let downloaded = try await store.downloadHermesFilesystemFile(path: remote)
                exportedURL = downloaded.url
                // Profile exports are staging archives. Keeping the iPhone copy is enough;
                // clean the server-side staging artifact when its path is managed/readable.
                try? await store.deleteHermesFile(path: remote)
                failure = nil
            } catch { failure = describeBotError(error) }
        }
    }

    /// The bot as Hermes last reported it. `bot` is the row this page was
    /// opened with, and goes stale the moment a model is saved.
    private var liveBot: BotRow {
        store.cachedBots.first { $0.name == bot.name } ?? bot
    }

    /// Whether a model picked for a bot changes what Hermes has pinned.
    enum BotModelChoice {
        static func isChange(
            _ option: HermesClient.ModelOption, from model: String?, provider: String?
        ) -> Bool {
            guard option.id == model else { return true }
            guard let provider, !provider.isEmpty,
                  let chosen = option.provider, !chosen.isEmpty
            else { return false }
            return chosen != provider
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = store.botCurrentName(for: bot)
        guard trimmed != current else { return }
        // A visible bot name is Bot Mode metadata. The canonical profile id is
        // stable routing identity and must not change just because somebody
        // edits the label shown in the app.
        act { try await store.setBotTitle(bot, title: trimmed) }
    }

    private func commitDetail() {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
        guard trimmed != current else { return }
        act {
            try await store.setBotDescription(bot.name, trimmed)
        }
    }

    private func act(
        _ work: @escaping () async throws -> Void,
        then finish: @escaping () -> Void = {}
    ) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                failure = nil
                onChange()
                finish()
            } catch {
                failure = describeBotError(error)
            }
        }
    }
}

// MARK: - SoulEditor

private struct SoulEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bot: String

    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?
    @State private var unreadable: String?

    var body: some View {
        NavigationStack {
            Group {
                if let unreadable {
                    ContentUnavailableView(
                        "Instructions unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(unreadable)
                    )
                } else if loaded {
                    TextEditor(text: $text)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .scrollContentBackground(.hidden)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.background(scheme))
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else if loaded {
                        Button("Save") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    try await store.setSoul(bot, text)
                                    dismiss()
                                } catch {
                                    failure = describeBotError(error)
                                }
                            }
                        }
                    }
                }
            }
            .alert("Could not save", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .task {
                do {
                    text = try await store.soul(bot).text
                    loaded = true
                } catch {
                    // Never fall through to an empty editor. `loaded` stays
                    // false, so Save cannot replace a perfectly good SOUL with
                    // the blank left by a read that failed.
                    unreadable = describeBotError(error)
                }
            }
        }
    }
}

// MARK: - NewBotSheet

private struct NewBotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let onCreated: () async -> Void

    @State private var name = ""
    @State private var detail = ""
    @State private var selectedModel: HermesClient.ModelOption?
    @State private var selectedSection = ""
    @State private var mark = BotMark(colour: 0, shape: 0)
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        BotMarkView(mark: mark, size: 96)
                        TextField("Name your Bot", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Palette.card(scheme))
                }

                Section {
                    TextField("What it is for", text: $detail, axis: .vertical)
                        .lineLimit(2...4)
                        .listRowBackground(Palette.card(scheme))
                } footer: {
                    Text("A new profile with its own memory, sessions and standing instructions.")
                }

                Section("Character") {
                    MarkPicker(mark: $mark)
                        .listRowBackground(Palette.card(scheme))
                }

                Section("Options") {
                    Picker("Model", selection: $selectedModel) {
                        Text("Inherit Alice's model")
                            .tag(nil as HermesClient.ModelOption?)
                        ForEach(store.models) { model in
                            Text(model.label).tag(model as HermesClient.ModelOption?)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))

                    Picker("Section", selection: $selectedSection) {
                        Text("Unassigned").tag("")
                        ForEach(store.botCustomSections, id: \.self) { sec in
                            Text(sec).tag(sec)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        create()
                    } label: {
                        Text(busy ? "Creating…" : "Create")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(.white)
                            .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.4) : store.accent.primary(scheme), in: .capsule)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Create New Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let slug = try await store.createBot(
                    displayName: trimmed, description: detail, model: selectedModel
                )
                store.botMarks[slug] = mark
                if !selectedSection.isEmpty {
                    store.setBotSection(slug, section: selectedSection)
                }
                await onCreated()
                dismiss()
            } catch {
                failure = describeBotError(error)
            }
        }
    }
}

// MARK: - Channels

/// Where a new section inside a channel goes, and the bot to put in it.
private struct ChannelSectionTarget: Identifiable {
    let id = UUID()
    let channelID: String
    let bot: String?
}

/// Ticks bots on and off, for a channel or a team.
private struct BotChecklist: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let bots: [BotRow]
    @Binding var selected: Set<String>

    var body: some View {
        if bots.isEmpty {
            Text("No bots available")
                .foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        } else {
            ForEach(bots) { bot in
                Button {
                    if selected.contains(bot.name) {
                        selected.remove(bot.name)
                    } else {
                        selected.insert(bot.name)
                    }
                } label: {
                    HStack(spacing: 12) {
                        BotMarkView(mark: store.mark(for: bot.name), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.botCurrentName(for: bot))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if !bot.detail.isEmpty {
                                Text(bot.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: selected.contains(bot.name) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                selected.contains(bot.name)
                                    ? AnyShapeStyle(store.accent.primary(scheme))
                                    : AnyShapeStyle(.secondary.opacity(0.4))
                            )
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    /// In the list's order, not the order they were ticked.
    static func ordered(_ selected: Set<String>, in bots: [BotRow]) -> [String] {
        bots.map(\.name).filter { selected.contains($0) }
            + selected.filter { name in !bots.contains { $0.name == name } }.sorted()
    }
}

/// Makes a channel, or chooses the bots in one.
private struct ChannelSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bots: [BotRow]
    /// The channel whose bots are being chosen; nil makes a new one.
    var editing: BotChannel? = nil
    /// Ticked from the start, when the sheet was opened from a bot's menu.
    var seedBot: String? = nil

    @State private var channelName = ""
    @State private var selectedBots: Set<String> = []
    @State private var seeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name your channel (e.g. operations)", text: $channelName)
                        .autocorrectionDisabled()
                        .listRowBackground(Palette.card(scheme))
                } header: {
                    Text("Channel")
                } footer: {
                    Text("A channel is a folder for bots and teams. Bots you put in it leave the main list and show only inside; a bot can be in several channels. It can stay empty until you add some.")
                }

                Section("Bots in this Channel") {
                    BotChecklist(bots: bots, selected: $selectedBots)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle(editing == nil ? "New Channel" : "Choose Bots")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if let editing {
                    channelName = editing.name
                    selectedBots = Set(editing.bots)
                } else if let seedBot {
                    selectedBots = [seedBot]
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") {
                        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let members = BotChecklist.ordered(selectedBots, in: bots)
                        if let editing {
                            if trimmed != editing.name { store.renameChannel(editing.id, to: trimmed) }
                            store.setChannelBots(editing.id, bots: members)
                        } else {
                            store.createChannel(name: trimmed, bots: members)
                        }
                        dismiss()
                    }
                    .disabled(channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Makes a team: a shared chat with several of a channel's bots.
private struct TeamSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let channel: BotChannel
    /// The channel's bots, the only ones a team can have.
    let bots: [BotRow]
    let onCreated: (Conversation) -> Void

    @State private var teamName = ""
    @State private var selectedBots: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name your team", text: $teamName)
                        .autocorrectionDisabled()
                        .listRowBackground(Palette.card(scheme))
                } header: {
                    Text("Team in \(channel.name)")
                } footer: {
                    Text("A team is a shared chat with several of this channel’s bots. A message goes to the bot you @mention, or to the first one.")
                }

                Section("Bots in this Team") {
                    BotChecklist(bots: bots, selected: $selectedBots)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("New Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let team = store.createTeam(
                            inChannel: channel.id, name: teamName,
                            bots: BotChecklist.ordered(selectedBots, in: bots)
                        ) else { return }
                        dismiss()
                        onCreated(team)
                    }
                    .disabled(
                        teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || selectedBots.isEmpty
                    )
                }
            }
        }
    }
}

private func describeBotError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "The dashboard did not answer."
}


/// The press, given as movement rather than as light.
///
/// The system's interactive glass answers with a highlight, which at this
/// size is a flash — and held, it morphs the effect out past the silhouette.
/// A tile this large only needs to give a little under the finger to read as
/// pressed.
private struct GlassTile: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Enough to see. At 0.955 the tile moved two points and the press
            // read as nothing happening at all; the give has to be visible
            // from a hand's distance to stand in for the light that was
            // taken away.
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.snappy(duration: 0.18, extraBounce: 0.1),
                       value: configuration.isPressed)
    }
}


/// Native in-place reordering for bot rows and pinned tiles. Reordering happens
/// as the dragged item crosses a peer, while the proposal explicitly advertises
/// `.move`; this gives the same displacement behavior as system lists and avoids
/// the copy-style plus badge produced by a generic drop destination.
private struct BotReorderDropDelegate: DropDelegate {
    let target: String
    let peers: [String]
    @Binding var draggedName: String?
    let move: (String, String, [String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = draggedName, source != target else { return }
        move(source, target, peers)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedName = nil
        return true
    }
}
