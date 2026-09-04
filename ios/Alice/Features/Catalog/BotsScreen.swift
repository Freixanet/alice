import SwiftUI

/// The agent's other selves.
///
/// A bot in Hermes is not a separate kind of thing: it is a profile with its
/// own standing instructions, model, skills and sessions. What the desktop
/// client shows under Bot Mode is that, and so is this.
struct BotsScreen: View {
    /// Closes the page — Done, or having opened a chat, which lands on the
    /// conversation the app is built around either way.
    var onClose: () -> Void = {}

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
    @State private var failure: String?
    /// True when the list on screen came from the cache because the agent did
    /// not answer.
    @State private var stale = false
    @State private var showHidden = false
    @State private var loading = false
    @State private var creatingBot = false
    @State private var creatingChannel = false
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
    @State private var showUnassigned = false
    @State private var showNewSectionAlert = false
    @State private var newSectionName = ""
    @State private var newSectionTargetBot: String?
    @State private var deletingSection: String?
    @State private var renamingSection: String?
    @State private var renameSectionName = ""
    @State private var showRenameSectionAlert = false

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
        .safeAreaInset(edge: .top, spacing: 0) {
            topControls
        }
        .sheet(isPresented: $creatingBot) {
            NewBotSheet { await load() }
        }
        .sheet(isPresented: $creatingChannel) {
            NewChannelSheet(bots: rows)
        }
        .sheet(item: $editingBot) { bot in
            // No Done here: the page has one of its own, and unlike this it
            // commits the name and description on the way out.
            NavigationStack {
                BotDetail(bot: bot, onChange: { Task { await load() } })
            }
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
                        try? await store.deleteBot(deletingBot.name)
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

    // MARK: - Sections & List

    private var filteredRows: [BotRow] {
        let visible = rows.filter { !store.hiddenBots.contains($0.name) }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visible }
        return visible.filter { bot in
            let dName = store.botCustomNames[bot.name] ?? bot.displayName
            let dDetail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
            return bot.name.lowercased().contains(query) ||
            dName.lowercased().contains(query) ||
            dDetail.lowercased().contains(query)
        }
    }

    /// Pinned bots keep the order the list has, not the order they were
    /// pinned in — the shelf is a shortcut to the same list, not a second one.
    private var pinnedRows: [BotRow] {
        filteredRows.filter { store.pinnedBots.contains($0.name) }
    }

    /// Everything the shelf above is not already showing. A pinned bot in
    /// both places is the same bot twice.
    private var unpinnedRows: [BotRow] {
        filteredRows.filter { !store.pinnedBots.contains($0.name) }
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
                    store.goHome()
                    store.botsExitLeading = false
                    onClose()
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
        .padding(.horizontal, 16)
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
                            pinnedTile(bot)
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
    private func botMenu(_ bot: BotRow) -> some View {
            Button {
                store.toggleBotUnread(bot.name)
            } label: {
                Label(store.unreadBots.contains(bot.name) ? "Mark Read" : "Mark Unread", systemImage: "bubble.left")
            }

            Button {
                store.toggleBotPin(bot.name)
            } label: {
                Label(store.pinnedBots.contains(bot.name) ? "Unpin" : "Pin", systemImage: "pin")
            }

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

            Button(role: .destructive) {
                store.hideBot(bot.name)
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
        return scheme == .dark
            ? 0.50 - 0.28 * lightness
            : 0.48 + 0.46 * lightness
    }

    private func pinnedTile(_ bot: BotRow) -> some View {
        Button {
            store.openBotConversation(for: bot)
            store.botsExitLeading = true
            onClose()
        } label: {
            VStack(spacing: 8) {
                // Glass, cut to the bot's own outline and tinted its own
                // colour, with the eyes sitting on top. A pinned bot is the
                // one thing on this page you reach for without reading, so
                // it is the one that can afford to be a surface rather than
                // a flat mark.
                // A tint alone cannot carry colour on a light ground: glass
                // over near-white is mostly the white, and the bots came out
                // washed. The colour goes underneath as well, at a strength
                // that depends on the colour: eleven of them, from a near-
                // white to a deep blue, and one opacity cannot serve both.
                // Pale marks need almost all of it on paper and very little
                // in the dark; deep ones the other way round.
                ZStack {
                    MarkShape(silhouette: mark(bot).silhouette)
                        .fill(mark(bot).color.opacity(Self.backing(mark(bot).color, scheme)))
                    BotFaceView(size: 76)
                }
                .frame(width: 76, height: 76)
                // Interactive, so it answers a press the way every other glass
                // control in the app does — the system's own recoil, not a
                // scale effect imitating one.
                // Not `.interactive()`. Its highlight is sized for a small
                // control and on a 76pt tile it reads as a flash, and while
                // the finger is held the effect morphs past the silhouette —
                // colour spilling out of the shape before the menu opens. The
                // press is given below instead, where it can be judged.
                .glassEffect(
                    .regular.tint(mark(bot).color.opacity(0.4)),
                    in: MarkShape(silhouette: mark(bot).silhouette)
                )
                // The menu lifts the bot's own outline rather than a square
                // drawn around it.
                .contentShape(
                    .contextMenuPreview,
                    MarkShape(silhouette: mark(bot).silhouette)
                )
                Text(store.botCurrentName(for: bot.name))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Fixed, so a row of three lines up and a row of one still knows
            // how wide it is to be centred in.
            .frame(width: 100)
            .contentShape(.rect)
        }
        .buttonStyle(GlassTile())
        .contextMenu { botMenu(bot) }
    }

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
        let hidden = rows.filter { store.hiddenBots.contains($0.name) }
        if !hidden.isEmpty {
            Button {
                showHidden.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Hidden")
                    Text("\(hidden.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: showHidden ? "chevron.down" : "chevron.right")
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

            if showHidden {
                ForEach(hidden) { bot in
                    HStack(spacing: 12) {
                        BotMarkView(mark: store.mark(for: bot.name), size: 34)
                        Text(store.botCurrentName(for: bot))
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Unhide") { store.unhideBot(bot.name) }
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

    @ViewBuilder
    private var normalBotSections: some View {
        if store.botCustomSections.isEmpty {
            ForEach(unpinnedRows) { bot in
                botRowView(bot)
            }
        } else {
            ForEach(store.sectionOrder, id: \.self) { sectionKey in
                if sectionKey == AppStore.unassignedSectionKey {
                    if !unassignedBots.isEmpty {
                        unassignedSectionHeader
                        if showUnassigned {
                            ForEach(unassignedBots) { bot in
                                botRowView(bot)
                            }
                        }
                    }
                } else {
                    let sectionBots = bots(in: sectionKey)
                    sectionHeader(sectionKey, count: sectionBots.count)

                    if !store.collapsedSections.contains(sectionKey) {
                        ForEach(sectionBots) { bot in
                            botRowView(bot)
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
                    q.isEmpty ? "No Routines" : "No Routines Found",
                    systemImage: "clock",
                    description: Text(q.isEmpty ? "No routines configured on bots." : "No routines matched “\(searchQuery)”.")
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
                Text(routine.prompt.isEmpty ? "Bot: \(store.botCustomNames[botName] ?? botName)" : routine.prompt)
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
                        Text(bots.joined(separator: ", "))
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
                showUnassigned.toggle()
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
                if !showUnassigned {
                    Text("\(unassignedBots.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showUnassigned ? 0 : -90))
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
    private func botRowView(_ bot: BotRow) -> some View {
        // Opens the bot's conversation on the app's own chat screen rather
        // than pushing a second one inside this sheet. A bot chat is a
        // conversation like any other; giving it its own screen inside a
        // sheet bought a duplicate transcript and a keyboard that a sheet
        // handles differently from a screen.
        Button {
            store.openBotConversation(for: bot)
            store.botsExitLeading = true
            onClose()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                BotMarkView(mark: store.mark(for: bot.name), size: 44)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(store.botCustomNames[bot.name] ?? bot.displayName)
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

                        if store.pinnedBots.contains(bot.name) {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(store.accent.primary(scheme))
                        }

                        if store.unreadBots.contains(bot.name) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { botMenu(bot) }
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
                try await store.createBot(name: newName, description: bot.detail)
                store.botMarks[newName] = store.mark(for: bot.name)
                if let model = store.botModel(for: bot.name) {
                    store.setBotModel(newName, model: model)
                }
                if let section = store.section(for: bot.name) {
                    store.setBotSection(newName, section: section)
                }
                let originalSoul = (try? await store.soul(bot.name))?.text
                if let originalSoul, !originalSoul.isEmpty {
                    try? await store.setSoul(newName, originalSoul)
                }
                await load()
            } catch {
                failure = describeBotError(error)
            }
        }
    }

    private func timestamp(for bot: BotRow) -> String {
        ""
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
        guard let reply = conversation.messages.last(where: {
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
        routinesByBot = (try? await store.allRoutines()) ?? routinesByBot
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
    @State private var selectedModel: String?
    @State private var selectedSection = ""
    @State private var notifications = false
    @State private var routines: [JobRow] = []
    @State private var addingRoutine = false
    @State private var editingSoul = false
    @State private var busy = false
    @State private var failure: String?
    @State private var exported: String?

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

            Section("Routines") {
                if routines.isEmpty {
                    Text("No routines yet")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                } else {
                    ForEach(routines) { routine in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(routine.enabled
                                          ? (routine.lastStatus == "error" ? .red : .green)
                                          : .secondary.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(routine.name).font(.subheadline).lineLimit(1)
                            }
                            if !routine.schedule.isEmpty {
                                Text(routine.schedule)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                Picker("Model", selection: $selectedModel) {
                    Text("Default (\(store.selectedModel ?? "Auto"))").tag(nil as String?)
                    ForEach(store.models) { model in
                        Text(model.label).tag(model.id as String?)
                    }
                }
                .listRowBackground(Palette.card(scheme))
                .onChange(of: selectedModel) { _, next in
                    store.setBotModel(bot.name, model: next)
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

                if let provider = bot.provider {
                    LabeledContent("Provider", value: provider)
                        .listRowBackground(Palette.card(scheme))
                }
                LabeledContent("Skills", value: "\(bot.skills)")
                    .listRowBackground(Palette.card(scheme))
            }

            Section {
                Toggle("Notifications", isOn: $notifications)
                    .listRowBackground(Palette.card(scheme))
                    .onChange(of: notifications) { _, next in
                        store.setBotNotifications(bot.name, enabled: next)
                    }
            } footer: {
                Text("Get notified when this Bot finishes or needs input")
            }

            Section {
                Button("Share as template", systemImage: "square.and.arrow.up") {
                    act { exported = try await store.exportBot(bot.name) }
                }
                .listRowBackground(Palette.card(scheme))

                if !bot.active {
                    Button("Make this the active bot") {
                        act { try await store.activateBot(bot.name) }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if let exported {
                    Text("Written to \(exported)").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(store.botCustomNames[bot.name] ?? bot.displayName)
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
                        Button("Share as template", systemImage: "square.and.arrow.up") {
                            act { exported = try await store.exportBot(bot.name) }
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
        .sheet(isPresented: $addingRoutine) {
            AddRoutineSheet { rName, rSchedule, rPrompt in
                Task {
                    try? await store.addRoutine(for: bot.name, name: rName, prompt: rPrompt, schedule: rSchedule)
                    routines = (try? await store.routines(for: bot.name)) ?? []
                }
            }
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
            name = store.botCustomNames[bot.name] ?? bot.displayName
            detail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
            selectedModel = store.botModel(for: bot.name)
            selectedSection = store.section(for: bot.name) ?? ""
            notifications = store.botNotificationsEnabled(for: bot.name)
            routines = (try? await store.routines(for: bot.name)) ?? []
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = store.botCustomNames[bot.name] ?? bot.displayName
        guard trimmed != current else { return }
        act {
            try await store.renameBot(bot.name, to: trimmed)
        }
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

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
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
                    } else {
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
                text = ((try? await store.soul(bot))?.text) ?? ""
                loaded = true
            }
        }
    }
}

// MARK: - AddRoutineSheet

private struct AddRoutineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let onSave: (String, String, String) -> Void

    @State private var name = ""
    @State private var schedule = "Every morning at 9:00 AM"
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine Details") {
                    TextField("Name (e.g. Daily Briefing)", text: $name)
                    TextField("Schedule (e.g. Every day at 9am)", text: $schedule)
                }
                .listRowBackground(Palette.card(scheme))

                Section("Instructions / Prompt") {
                    TextField("What should this routine do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }
                .listRowBackground(Palette.card(scheme))
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("New Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            onSave(trimmedName, schedule, prompt)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @State private var selectedModel: String?
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
                        Text("Default model").tag(nil as String?)
                        ForEach(store.models) { model in
                            Text(model.label).tag(model.id as String?)
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
                try await store.createBot(name: trimmed, description: detail)
                store.botMarks[trimmed] = mark
                if let model = selectedModel {
                    store.setBotModel(trimmed, model: model)
                }
                if !selectedSection.isEmpty {
                    store.setBotSection(trimmed, section: selectedSection)
                }
                await onCreated()
                dismiss()
            } catch {
                failure = describeBotError(error)
            }
        }
    }
}

// MARK: - NewChannelSheet

private struct NewChannelSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bots: [BotRow]

    @State private var channelName = ""
    @State private var topic = ""
    @State private var selectedBots: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name your channel (e.g. operations)", text: $channelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .listRowBackground(Palette.card(scheme))

                    TextField("Topic (optional)", text: $topic)
                        .listRowBackground(Palette.card(scheme))
                } header: {
                    Text("Channel Details")
                } footer: {
                    Text("Channels bring multiple bots together into a shared workspace.")
                }

                Section("Bots in this Channel") {
                    if bots.isEmpty {
                        Text("No bots available")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    } else {
                        ForEach(bots) { bot in
                            Button {
                                if selectedBots.contains(bot.name) {
                                    selectedBots.remove(bot.name)
                                } else {
                                    selectedBots.insert(bot.name)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    BotMarkView(mark: store.mark(for: bot.name), size: 30)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bot.displayName)
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

                                    if selectedBots.contains(bot.name) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(store.accent.primary(scheme))
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary.opacity(0.4))
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("New Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.createChannel(
                            name: trimmed,
                            bots: Array(selectedBots),
                            topic: topic.isEmpty ? nil : topic
                        )
                        dismiss()
                    }
                    .disabled(channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
