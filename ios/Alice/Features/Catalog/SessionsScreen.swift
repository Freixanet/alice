import SwiftUI

/// Every run the agent has had, not just the ones started on this phone.
///
/// The drawer lists conversations this device created; this is the server's
/// own record, which also holds the web client's chats, the messaging
/// channels and every scheduled job that fired. A conversation started in
/// Hermes Desktop, the terminal or the web client can be taken up here
/// (`AppStore.continueSession`); the rest are a record only.
struct SessionsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var onOpenedChat: () -> Void = {}
    @State private var opening: String?
    @State private var openFailure: String?

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
                    "Sessions unavailable",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(failure)
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("The agent has not recorded a run.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await load() }
        .refreshableWithFeedback { await load() }
        .alert("Couldn’t open the conversation", isPresented: Binding(
            get: { openFailure != nil }, set: { if !$0 { openFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openFailure ?? "")
        }
    }

    private func open(_ row: SessionRow) {
        guard opening == nil else { return }
        opening = row.id
        Task {
            defer { opening = nil }
            do {
                try await store.continueSession(row)
                onOpenedChat()
            } catch {
                openFailure = PlainWords.describe(error, doing: "open the conversation")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
                if AppStore.canContinue(row) {
                    Button { open(row) } label: {
                        HStack(spacing: 10) {
                            rowContent(row)
                            if opening == row.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(opening != nil)
                    .listRowBackground(Palette.card(scheme))
                    .accessibilityHint("Continues this conversation on this iPhone")
                } else {
                    rowContent(row)
                        .listRowBackground(Palette.card(scheme))
                }
            }

            if !complete {
                Text("Older sessions are not shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private func rowContent(_ row: SessionRow) -> some View {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let when = row.lastActive {
                            Text(when.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !row.preview.isEmpty {
                        Text(row.preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(subtitle(row))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
    }

    private func subtitle(_ row: SessionRow) -> String {
        var parts: [String] = []
        if let model = row.model { parts.append(model) }
        if let source = row.source { parts.append(Self.sourceName(source)) }
        parts.append(row.messageCount == 1 ? "1 message" : "\(row.messageCount) messages")
        if row.tokens > 0 {
            parts.append("\(Insights.compact(row.tokens)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// Where it was started, in words.
    nonisolated static func sourceName(_ source: String) -> String {
        switch source.lowercased() {
        case "desktop": String(localized: "Hermes Desktop")
        case "cli", "tui": String(localized: "Terminal")
        case "webui": String(localized: "Web")
        case "cron": String(localized: "Routine")
        case "api_server": String(localized: "Background task")
        case "subagent": String(localized: "Subagent")
        default: source.capitalized
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
