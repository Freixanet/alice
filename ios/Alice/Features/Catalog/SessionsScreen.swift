import SwiftUI

/// Every run the agent has had, not just the ones started on this phone.
///
/// The drawer lists conversations this device created; this is the server's
/// own record, which also holds the web client's chats, the messaging
/// channels and every scheduled job that fired.
struct SessionsScreen: View {
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
        .refreshable { await load() }
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
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
                .listRowBackground(Palette.card(scheme))
            }

            if !complete {
                Text("Older sessions are not shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private func subtitle(_ row: SessionRow) -> String {
        var parts: [String] = []
        if let model = row.model { parts.append(model) }
        if let source = row.source { parts.append(source) }
        parts.append(row.messageCount == 1 ? "1 message" : "\(row.messageCount) messages")
        if row.tokens > 0 {
            parts.append("\(Insights.compact(row.tokens)) tokens")
        }
        return parts.joined(separator: " · ")
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
