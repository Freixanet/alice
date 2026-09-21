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
           let agent = store.activeChat.id == conversationID
               ? store.activeChat.routedBotName
               : store.conversations.first(where: { $0.id == conversationID })?.routedBotName {
            let name = store.botCurrentName(for: agent)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(work.waitingOn) { delegation in
                    let asked = store.botCurrentName(for: delegation.handle)
                    row(
                        "Waiting for \(asked)",
                        detail: Text("\(name) asked it \(Text(delegation.sentAt, style: .relative)) ago. Its answer will appear here."),
                        stop: { store.stopWaiting(for: delegation.handle, in: conversationID) },
                        stopLabel: "Stop waiting for \(asked)"
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.backgroundWork")
        }
    }

    private func row(
        _ title: String, detail: Text, stop: (() -> Void)? = nil, stopLabel: String = ""
    ) -> some View {
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
            .accessibilityElement(children: .combine)
            if let stop {
                Spacer(minLength: 8)
                // An answer that will never come — refused out of sight, or
                // lost — must not hold the chat until the wait runs out.
                Button("Stop", action: stop)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.secondary)
                    .accessibilityLabel(stopLabel)
                    .accessibilityIdentifier("chat.backgroundWork.stop")
            }
        }
    }
}
