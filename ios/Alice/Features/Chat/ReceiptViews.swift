import SwiftUI

extension Notification.Name {
    /// A receipt link was tapped in a reply's text (`SelectableReplyText`).
    static let aliceOpenReceipt = Notification.Name("alice.receipt.open")
}

/// Who said it, as the chat draws it: Alice's face for her own profile, the
/// agent's mark for the rest.
struct AgentFace: View {
    @Environment(AppStore.self) private var store
    let profile: String
    var size: CGFloat = 18

    var body: some View {
        if profile == AppStore.todayProfile {
            // Her portrait, as agents show theirs — not the web client's mark.
            Image("AliceAvatar")
                .resizable()
                .renderingMode(.original)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
                .accessibilityHidden(true)
        } else {
            BotMarkView(mark: store.mark(for: profile), size: size, floats: false)
        }
    }
}

/// The conversations a reply drew on, listed under it. Each opens the turns
/// around what was cited.
struct RichReceiptsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let receipts: [RichReceipt]
    var language: ChatLanguage = .english

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.pick("Sources", "Fuentes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(receipts) { receipt in
                Button {
                    store.openedReceipt = receipt
                } label: {
                    chip(receipt)
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: receipts) { await store.loadReceiptTitles(receipts) }
    }

    private func chip(_ receipt: RichReceipt) -> some View {
        let summary = store.receiptSummaries[receipt.session]
        let profile = summary?.profile ?? store.receiptProfile(receipt)
        return HStack(spacing: 8) {
            AgentFace(profile: profile, size: 18)
            Text(summary?.title ?? language.pick("Earlier conversation", "Conversación anterior"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let started = summary?.started {
                Text(started.formatted(.dateTime.day().month(.abbreviated).locale(language.locale)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Palette.card(scheme), in: .capsule)
        .overlay { Capsule().stroke(Palette.border(scheme), lineWidth: 0.5) }
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(language.pick("Opens what was said there", "Abre lo que se dijo allí"))
    }
}

/// The turns of a past conversation around what an agent cited, or around the
/// moment an action happened — the proof, one tap from the claim.
struct ReceiptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let receipt: RichReceipt
    /// For a sheet over another sheet (Activity): close that one too, so the
    /// opened chat is what is on screen.
    var onOpenedChat: () -> Void = {}

    @State private var found: ConversationReceipt?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let found {
                    content(found)
                } else if let failure {
                    ContentUnavailableView(
                        "Couldn’t open it",
                        systemImage: "text.bubble",
                        description: Text(failure)
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(found.map { $0.displayTitle(agent: store.botCurrentName(for: $0.profile)) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Palette.background(scheme))
        }
        .task { await load() }
    }

    private func content(_ found: ConversationReceipt) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(found)
                    if found.turns.isEmpty {
                        Text("Nothing was said there that can be shown.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(found.turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) { footer(found) }
            .onAppear {
                if let anchor = found.turns.first(where: \.anchor) {
                    reader.scrollTo(anchor.id, anchor: .center)
                }
            }
        }
    }

    private func header(_ found: ConversationReceipt) -> some View {
        HStack(spacing: 10) {
            AgentFace(profile: found.profile, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.botCurrentName(for: found.profile))
                    .font(.subheadline.weight(.semibold))
                Text(origin(found))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, 4)
    }

    private func origin(_ found: ConversationReceipt) -> String {
        let date = found.started.map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()) }
        let place = found.routineName != nil ? String(localized: "Routine") : String(localized: "Conversation")
        return [place, date].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func turnView(_ turn: ConversationReceipt.Turn) -> some View {
        let mine = turn.role == .user
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if turn.anchor {
                Label(
                    receipt.at == nil ? String(localized: "What was cited") : String(localized: "When it happened"),
                    systemImage: receipt.at == nil ? "quote.opening" : "clock"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(store.accent.primary(scheme))
            }
            Text(Self.inline(turn.text))
                .font(.subheadline)
                .foregroundStyle(turn.anchor ? .primary : .secondary)
                .textSelection(.enabled)
                .padding(.horizontal, mine || turn.anchor ? 12 : 0)
                .padding(.vertical, mine || turn.anchor ? 9 : 0)
                .background {
                    if turn.anchor {
                        RoundedRectangle(cornerRadius: 14).fill(store.accent.primary(scheme).opacity(0.12))
                    } else if mine {
                        RoundedRectangle(cornerRadius: 14).fill(Palette.card(scheme))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, mine ? 40 : 0)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func footer(_ found: ConversationReceipt) -> some View {
        if store.conversation(forSession: found.session) != nil {
            Button {
                let anchor = found.turns.first(where: \.anchor)?.id
                if store.openReceiptConversation(found, anchor: anchor) {
                    dismiss()
                    onOpenedChat()
                }
            } label: {
                Text("Open the conversation")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(store.accent.primary(scheme))
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    /// Bold, italics and links; blocks read as their text.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }

    private func load() async {
        guard store.dashboardReady else {
            failure = String(localized: "Alice needs the dashboard connection to read past conversations.")
            return
        }
        do {
            found = try await store.receipt(receipt)
        } catch {
            failure = String(localized: "That conversation is no longer on this Hermes, or the Alice plugin on your Mac needs updating.")
        }
    }
}
