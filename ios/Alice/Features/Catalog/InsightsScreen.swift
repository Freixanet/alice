import SwiftUI

/// What the agent has actually been doing, totalled.
///
/// Hermes serves no analytics endpoint on a gateway-only install, but every
/// session it records carries its own token counts — so this is added up from
/// the session log rather than reported by the server. That is worth saying
/// on the screen, because a total the client computed can only be as complete
/// as the log it read.
struct InsightsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [SessionRow] = []
    @State private var complete = true
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        Group {
            if loading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    "Insights unavailable",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(failure)
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to total yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("The agent has not recorded a run.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        List {
            Section {
                total("Sessions", "\(rows.count)")
                total("Messages", Insights.compact(rows.reduce(0) { $0 + $1.messageCount }))
                total("Tool calls", Insights.compact(rows.reduce(0) { $0 + $1.toolCallCount }))
                total("Tokens", Insights.compact(rows.reduce(0) { $0 + $1.tokens }))
                if let spend = money {
                    total("Cost", spend)
                }
            } footer: {
                Text(complete
                    ? "Added up from the agent's session log."
                    : "Added up from the most recent sessions; older ones are not counted.")
            }

            Section("By model") {
                ForEach(byModel, id: \.name) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Insights.compact(entry.tokens))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        // The bar is the point: which model is doing the work
                        // is a proportion, and a column of numbers hides it.
                        GeometryReader { proxy in
                            Capsule()
                                .fill(store.accent.primary(scheme).opacity(0.75))
                                .frame(width: proxy.size.width * entry.share)
                        }
                        .frame(height: 4)
                        Text(entry.sessions == 1 ? "1 session" : "\(entry.sessions) sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    private func total(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .listRowBackground(Palette.card(scheme))
    }

    private var money: String? {
        let spend = rows.compactMap(\.cost).reduce(0, +)
        // Subscription providers report nothing, and "$0.00" would read as a
        // measurement rather than an absence.
        guard spend > 0 else { return nil }
        return spend.formatted(.currency(code: "USD"))
    }

    private struct ModelUse {
        let name: String
        let sessions: Int
        let tokens: Int
        var share: Double = 0
    }

    private var byModel: [ModelUse] {
        var counts: [String: (sessions: Int, tokens: Int)] = [:]
        for row in rows {
            let name = row.model ?? "unknown"
            let current = counts[name] ?? (0, 0)
            counts[name] = (current.sessions + 1, current.tokens + row.tokens)
        }
        var top: [ModelUse] = []
        for (name, use) in counts {
            top.append(ModelUse(name: name, sessions: use.sessions, tokens: use.tokens))
        }
        top.sort { left, right in
            if left.tokens != right.tokens { return left.tokens > right.tokens }
            return left.sessions > right.sessions
        }
        let most = Double(top.first?.tokens ?? 0)
        guard most > 0 else { return top }
        return top.map {
            var entry = $0
            entry.share = Double($0.tokens) / most
            return entry
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await store.sessions()
            rows = result.rows
            complete = result.complete
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Hermes did not answer."
        }
    }
}

enum Insights {
    /// 18,933,023 is not a number anybody reads. 18.9M is.
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
