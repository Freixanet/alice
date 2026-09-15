import SwiftUI

/// What the agent in this chat is doing out of sight: another agent it asked
/// and is waiting on, or a turn Hermes is running that this phone is not
/// following. Without it the chat looked finished while the work went on, and
/// nobody could tell a real delegation from a claimed one.
struct BackgroundWorkCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let conversationID: String

    var body: some View {
        let work = store.backgroundWork(for: conversationID)
        if !work.isEmpty,
           let agent = store.conversations.first(where: { $0.id == conversationID })?.routedBotName {
            let name = store.botCurrentName(for: agent)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(work.waitingOn) { delegation in
                    row(
                        "Waiting for \(store.botCurrentName(for: delegation.handle))",
                        detail: Text("\(name) asked it \(Text(delegation.sentAt, style: .relative)) ago. Its answer will appear here.")
                    )
                }
                if work.running {
                    row("\(name) is working on it", detail: Text("Its reply will appear here."))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Palette.border(scheme), lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.backgroundWork")
        }
    }

    private func row(_ title: String, detail: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
