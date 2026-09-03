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

    var body: some View {
        List {
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
                rowView(row)
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
        .overlay { overlay }
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
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if row.configured == false {
                    Text("Needs keys")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if !row.tools.isEmpty {
                    Text(row.tools.prefix(4).joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                }
            }
        }
        .padding(.vertical, 4)
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
