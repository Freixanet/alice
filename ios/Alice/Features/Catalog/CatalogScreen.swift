import SwiftUI

/// One screen shape for Skills, Tools and Add-ons.
///
/// They differ in where the rows come from and whether a row can be switched,
/// not in how they read, so they share a view rather than three near-copies —
/// the same reason the web client has one `CatalogPage`.
struct CatalogScreen: View {
    enum Source {
        case skills, toolsets, addons

        var title: String {
            switch self {
            case .skills: "Skills"
            case .toolsets: "Tools"
            case .addons: "Add-ons"
            }
        }

        var capability: String {
            switch self {
            case .skills: "skills"
            case .toolsets: "toolsets"
            case .addons: "mcp"
            }
        }

        var requirement: String {
            "This Hermes does not advertise \(title.lowercased())."
        }

        var emptyMessage: String {
            switch self {
            case .skills: "Hermes has no skills installed."
            case .toolsets: "Hermes has no visible toolsets."
            case .addons: "No MCP servers are configured."
            }
        }

        /// Only skills can be switched from here; the others are read-only
        /// until Alice can send the write Hermes expects for them.
        var togglable: Bool { self == .skills }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let source: Source

    @State private var rows: [CatalogRow] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var group: String?
    @State private var busy: Set<String> = []
    @State private var editing: SkillEditor.Subject?

    var body: some View {
        List {
            if source == .toolsets {
                Section {
                    Text("Tools are abilities Alice can use while working — for example browsing, handling files, running commands, or talking to connected services. You normally do not need to configure them yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }
            }

            if !groups.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(nil, label: "All")
                            ForEach(groups, id: \.self) { name in
                                filterChip(name, label: name)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }

            ForEach(filtered) { row in
                if source == .skills {
                    Button {
                        editing = .existing(row.name, label: row.label)
                    } label: {
                        rowView(row).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    rowView(row)
                }
            }
        }
        .listStyle(.plain)
        // A plain list rules off the top of the first row and the bottom of
        // the last. Between rows a line separates two things; there it
        // separates a row from nothing, and reads as an unfinished box.
        .listSectionSeparator(.hidden)
        .searchable(text: $query, prompt: "Search \(source.title.lowercased())")
        .navigationTitle(source.title)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            ScrollView {
                overlay.frame(maxWidth: .infinity, minHeight: 420)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .refreshable { await load() }
            .opacity(showsOverlay ? 1 : 0)
            .allowsHitTesting(showsOverlay)
        }
        // A skill is a Markdown file the agent reads. Hermes will hand it
        // over and take it back, so there is no reason to make somebody go
        // to a laptop to change a sentence in one.
        .toolbar {
            if source == .skills, store.dashboardReady {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = .new
                    } label: {
                        Label("New Skill", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editing) { subject in
            SkillEditor(subject: subject, onChange: { Task { await load() } })
        }
    }

    /// Whether one of the replacement states is showing.
    private var showsOverlay: Bool {
        !store.isConnected
            || !store.supports(source.capability)
            || (loading && rows.isEmpty)
            || error != nil
            || rows.isEmpty
            || filtered.isEmpty
    }

    private var groups: [String] {
        Array(Set(rows.compactMap(\.group))).sorted()
    }

    private var filtered: [CatalogRow] {
        rows.filter { row in
            if let group, row.group != group { return false }
            guard !query.isEmpty else { return true }
            let haystack = "\(row.label) \(row.name) \(row.detail)".lowercased()
            return haystack.contains(query.lowercased())
        }
    }

    /// The states that replace the list, wrapped so a pull still reaches
    /// `.refreshable`. An overlay laid over an empty List does not scroll, so
    /// a failure recorded while the agent was down could not be cleared by
    /// asking again — it simply stayed.
    @ViewBuilder
    private var overlay: some View {
        if !store.isConnected {
            ContentUnavailableView(
                "Connect your Hermes",
                systemImage: "link",
                description: Text("This list comes from your agent.")
            )
        } else if !store.supports(source.capability) {
            // The honest answer: not broken, not advertised.
            ContentUnavailableView(
                "Not available here",
                systemImage: "questionmark.circle",
                description: Text(source.requirement)
            )
        } else if loading && rows.isEmpty {
            ProgressView()
        } else if let error {
            ContentUnavailableView(
                "Couldn’t load",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if rows.isEmpty {
            ContentUnavailableView(
                source.title,
                systemImage: "tray",
                description: Text(source.emptyMessage)
            )
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func filterChip(_ value: String?, label: String) -> some View {
        Button {
            group = value
        } label: {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.glass)
        .tint(group == value ? store.accent.primary(scheme) : nil)
    }

    @ViewBuilder
    private func rowView(_ row: CatalogRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.body)
                let description = rowDescription(row)
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if row.configured == false {
                    Label("Setup required before Alice can use this", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if source == .toolsets, !row.tools.isEmpty {
                    Text(row.tools.count == 1 ? "Includes 1 action" : "Includes \(row.tools.count) actions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            // Only where the agent both reports the state and accepts a
            // change. This build serves neither for skills, and a switch that
            // invents an "off" and then 404s on the way back is worse than a
            // plain row.
            if source.togglable, let enabled = row.enabled {
                if busy.contains(row.id) {
                    ProgressView().frame(width: 51)
                } else {
                    Toggle(row.label, isOn: enabledBinding(row, enabled))
                        .labelsHidden()
                        .toggleStyle(CatalogContrastSwitchStyle(accent: store.accent.primary(scheme)))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func rowDescription(_ row: CatalogRow) -> String {
        guard source == .toolsets else { return row.detail }
        return Self.toolDescription(for: row)
    }

    nonisolated static func toolDescription(for row: CatalogRow) -> String {
        // The toolset name/label is its identity. Action names such as
        // `search_issues` are secondary evidence and must not turn a GitHub
        // toolset into a web-browser description.
        let identity = "\(row.name) \(row.label)".lowercased()
        let actions = row.tools.joined(separator: " ").lowercased()

        if contains(identity, any: ["github", "git"]) {
            return "Lets Alice work with code repositories, branches, commits, and related development tasks."
        }
        if contains(identity, any: ["file", "filesystem"]) {
            return "Lets Alice read, create, and manage files."
        }
        if contains(identity, any: ["terminal", "shell", "command"]) {
            return "Lets Alice run commands on the computer where Hermes is running."
        }
        if contains(identity, any: ["browser", "web"]) {
            return "Lets Alice find information online and work with web pages."
        }
        if contains(identity, any: ["memory"]) {
            return "Lets Alice save useful information and retrieve it later."
        }
        if contains(identity, any: ["cron", "schedule", "routine"]) {
            return "Lets Alice create and manage scheduled routines."
        }
        if contains(identity, any: ["mcp", "integration"]) {
            return "Lets Alice use actions provided by connected apps and services."
        }
        if contains(identity, any: ["message", "platform", "telegram", "discord", "slack", "whatsapp"]) {
            return "Lets Alice send or manage messages through connected services."
        }
        if contains(identity, any: ["image", "vision"]) {
            return "Lets Alice inspect and work with images."
        }
        if contains(identity, any: ["audio", "voice", "speech"]) {
            return "Lets Alice work with audio or voice features."
        }
        if contains(identity, any: ["agent", "delegate", "subagent"]) {
            return "Lets Alice hand parts of a task to other agents when that is useful."
        }

        // Unknown toolsets fall back to their actions, with specific local/code
        // capabilities taking precedence over broad words like `search`.
        if contains(actions, any: ["github", "git"]) {
            return "Lets Alice work with code repositories, branches, commits, and related development tasks."
        }
        if contains(actions, any: ["file", "filesystem"]) {
            return "Lets Alice read, create, and manage files."
        }
        if contains(actions, any: ["terminal", "shell", "command"]) {
            return "Lets Alice run commands on the computer where Hermes is running."
        }
        if contains(actions, any: ["browser", "web", "search"]) {
            return "Lets Alice find information online and work with web pages."
        }

        if !row.detail.isEmpty, !looksTechnical(row.detail) { return row.detail }
        return row.tools.isEmpty
            ? "Gives Alice an additional set of abilities for this type of work."
            : "Gives Alice \(row.tools.count) related actions for this type of work."
    }

    private nonisolated static func contains(_ text: String, any terms: [String]) -> Bool {
        let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return terms.contains { tokens.contains($0) }
    }

    private nonisolated static func looksTechnical(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("api") || lower.contains("schema") || lower.contains("endpoint")
            || lower.contains("json") || lower.contains("stdio") || lower.contains("http")
            || lower.contains("toolset") || lower.contains("_id") || lower.contains("argv")
    }

    /// Hermes owns the state, so the switch reflects `rows` and only moves once
    /// the agent has accepted the change.
    private func enabledBinding(_ row: CatalogRow, _ fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { rows.first { $0.id == row.id }?.enabled ?? fallback },
            set: { toggle(row, to: $0) }
        )
    }

    private func load() async {
        guard store.isConnected, store.supports(source.capability) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            rows = try await store.catalog(source)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ row: CatalogRow, to enabled: Bool) {
        guard source.togglable, !busy.contains(row.id) else { return }
        busy.insert(row.id)
        Task {
            defer { busy.remove(row.id) }
            do {
                try await store.setSkill(row.name, enabled: enabled)
                if let index = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[index].enabled = enabled
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct CatalogContrastSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                        ? accent
                        : Color.secondary.opacity(scheme == .dark ? 0.38 : 0.24))
                    .overlay {
                        Capsule().strokeBorder(
                            Color.primary.opacity(scheme == .dark ? 0.22 : 0.16),
                            lineWidth: 1
                        )
                    }

                Circle()
                    .fill(Color.white)
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.6) }
                    .shadow(color: Color.black.opacity(0.16), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 51, height: 31)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
