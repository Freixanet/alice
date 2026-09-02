import SwiftUI

/// The named workspaces the agent divides its sessions between.
struct ProjectsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var rows: [ProjectRow] = []
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        DashboardList(
            title: "Projects",
            symbol: "folder",
            empty: "No projects yet.",
            loading: loading && rows.isEmpty,
            failure: failure,
            isEmpty: rows.isEmpty
        ) {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label).font(.subheadline.weight(.medium))
                    if let path = row.path {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(detail(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .listRowBackground(Palette.card(scheme))
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func detail(_ row: ProjectRow) -> String {
        var parts = [row.sessions == 1 ? "1 session" : "\(row.sessions) sessions"]
        if row.tokens > 0 { parts.append("\(Insights.compact(row.tokens)) tokens") }
        if let when = row.lastActive {
            parts.append(when.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { rows = try await store.projects(); failure = nil }
        catch { failure = message(error) }
    }
}

/// Where the agent keeps what it remembers, and which of those it is using.
struct MemoryScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var rows: [MemoryProvider] = []
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        DashboardList(
            title: "Memory",
            symbol: "brain",
            empty: "No memory providers.",
            loading: loading && rows.isEmpty,
            failure: failure,
            isEmpty: rows.isEmpty
        ) {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.name.capitalized)
                            .font(.subheadline.weight(.medium))
                        if row.active {
                            Text("In use")
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    store.accent.primary(scheme).opacity(0.18),
                                    in: .capsule
                                )
                        }
                        Spacer(minLength: 0)
                        Text(row.status)
                            .font(.caption2)
                            .foregroundStyle(row.available ? .secondary : Color.orange)
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .listRowBackground(Palette.card(scheme))
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { rows = try await store.memoryProviders(); failure = nil }
        catch { failure = message(error) }
    }
}

/// Usage as the dashboard totals it, which is not the same as the app adding
/// up sessions: this counts every call, including the small ones the agent
/// makes on its own to title a chat.
struct UsageScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var report: UsageReport?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        DashboardList(
            title: "Usage",
            symbol: "chart.bar",
            empty: "Nothing recorded yet.",
            loading: loading && report == nil,
            failure: failure,
            isEmpty: report == nil
        ) {
            if let report {
                List {
                    Section {
                        row("Sessions", "\(report.sessions)")
                        row("API calls", Insights.compact(report.calls))
                        row("Input tokens", Insights.compact(report.inputTokens))
                        row("Output tokens", Insights.compact(report.outputTokens))
                        if report.cost > 0 {
                            row("Cost", report.cost.formatted(.currency(code: "USD")))
                        }
                    } footer: {
                        Text("The agent's own figures, over the last \(report.days) days.")
                    }

                    if !report.models.isEmpty {
                        Section("Models") {
                            ForEach(report.models) { model in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(model.name).font(.subheadline).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(Insights.compact(model.tokens))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(model.sessions) sessions · \(model.calls) calls")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .listRowBackground(Palette.card(scheme))
                            }
                        }
                    }

                    if !report.tools.isEmpty {
                        Section("Tools") {
                            ForEach(report.tools) { tool in
                                HStack {
                                    Text(tool.name).font(.subheadline.monospaced())
                                    Spacer(minLength: 8)
                                    Text(tool.share.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .listRowBackground(Palette.card(scheme))
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .listRowBackground(Palette.card(scheme))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { report = try await store.usage(); failure = nil }
        catch { failure = message(error) }
    }
}

/// The three dashboard screens differ in their rows, not in how they behave
/// when there is nothing to show or nowhere to ask.
private struct DashboardList<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    let empty: String
    let loading: Bool
    let failure: String?
    let isEmpty: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    title, systemImage: symbol, description: Text(failure)
                )
            } else if isEmpty {
                ContentUnavailableView(
                    title, systemImage: symbol, description: Text(empty)
                )
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}

private func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "The dashboard did not answer."
}
