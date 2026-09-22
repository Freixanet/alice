import SwiftUI
import TipKit
import UIKit

struct MessageRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let message: Message
    /// Off for the last reply while its agent is still working behind the
    /// scenes: that reply is not the end of the task yet.
    var showsActions = true
    /// Off for replies after the first of a task (`ChatTasks`), and while the
    /// task is under way: one task has one time.
    var showsTime = true
    /// On for the first reply of a task, busy or not: who is answering is
    /// known from the start, so the name comes in with the words, not after.
    var showsAuthor = true
    /// What copying, sharing and reading aloud take: the whole task.
    var actionsContent: String? = nil
    @State private var selectingText = false
    @State private var showingModelPicker = false
    /// Copy, share, speak, retry and developer usage stay off until the reply is tapped.
    @State private var showingExtras = false

    /// The agent this reply is from when it was asked by name in a chat that
    /// is not its own.
    private var invokedAgent: String? {
        if let profile = message.mentionProfile, !profile.isEmpty { return profile }
        guard let bot = message.botName, !bot.isEmpty,
              store.activeChat.routedBotName == nil,
              !store.activeChat.isChannel
        else { return nil }
        return bot
    }

    /// While tokens arrive, finished blocks in their final layout and the
    /// paragraph being written as light Markdown (`StreamingReply`).
    @ViewBuilder
    private func replyBody(_ content: String) -> some View {
        if message.pending {
            StreamingReply(content: content, onTap: revealReplyExtras)
        } else {
            RichMessageView(content: content, failed: message.error != nil, onTap: revealReplyExtras)
        }
    }

    /// Out of this phone's sight after a lost connection, but Hermes says it
    /// is still being written.
    private var stillWorking: Bool {
        !message.pending && message.awaitingRemote && store.isStillWorking(message.id)
    }

    /// Being written, here or out of sight.
    private var working: Bool { message.pending || stillWorking }

    /// What is shown of a reply still arriving: plain, and cheap to make on
    /// every token. Blank lines at the start — models often open with them
    /// after a tool — left a gap under the trace that closed only when the
    /// reply settled; bold markers would show as asterisks; and a code or
    /// card block still being written would show its raw JSON, so the text
    /// stops where one opens and the finished block appears with the reply.
    nonisolated static func streamingText(_ content: String) -> String {
        var text = content
        if let fence = text.range(of: "```") {
            let after = text[fence.upperBound...]
            if after.range(of: "```") == nil { text = String(text[..<fence.lowerBound]) }
        }
        text = text.replacingOccurrences(of: "**", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words arriving and no tool running: the reply is being written, not
    /// thought about, so the trace above it stops saying "Thinking".
    private var writing: Bool {
        guard message.pending,
              !Self.streamingText(message.content).isEmpty
        else { return false }
        return ToolCaption.steps(in: message.tools).last.map { $0.status == .done } ?? true
    }

    private var actionsMessage: Message {
        var whole = message
        if let actionsContent, !actionsContent.isEmpty { whole.content = actionsContent }
        return whole
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            switch message.role {
            case .user:
                if !message.attachments.isEmpty {
                    SentAttachments(attachments: message.attachments)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let turn = ReactionTurn.parse(message.content) {
                    ReactionBubble(turn: turn)
                } else if !message.content.isEmpty {
                    // A tap opens the same actions as a long press: a menu
                    // only a long press reaches is one most people never find.
                    Menu {
                        SentMessageMenu(message: message, selecting: $selectingText)
                    } label: {
                        // An agent named with `@` shows in its own colour.
                        Text(store.mentionStyled(
                            message.content,
                            bareSlugs: message.mentionProfile.map { [$0] } ?? []
                        ))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
                            .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .menuStyle(.button)
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: 18))
                    .contextMenu { SentMessageMenu(message: message, selecting: $selectingText) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                        .sheet(isPresented: $selectingText) {
                            SelectableTextSheet(text: message.content)
                        }
                }
            case .assistant:
                // Ordinary turns are a conversation, not a log. A routine
                // delivery is dated because it arrived on its own, later.
                if showsTime, message.routineName != nil,
                   let when = MessageTime.caption(message.createdAt) {
                    Text(when)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Sent \(when)")
                }
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                    // Trying bot replies with nothing above them — no name, no
                    // mark. The conversation already says whose it is, and a
                    // reply still being written says "Thinking…" in its tool
                    // list. Alice's own replies need no label either: her face
                    // is already at the top of the chat.
                    if showsAuthor, let agent = invokedAgent {
                        // An agent named with `@` in Alice's chat answers under
                        // its own face and name, not hers.
                        HStack(spacing: 6) {
                            BotMarkView(mark: store.mark(for: agent), size: 18)
                            Text(store.botCurrentName(for: agent))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    // Above the answer, where the work happened: the steps run
                    // there while the reply is written and settle into one line
                    // over it. Questions waiting on the person end the turn as
                    // far as the chat shows — nothing is "Thinking" meanwhile.
                    if store.pendingHomeModelConfirmation?.replyID != message.id,
                       (working && !writing && !store.activeAwaitsAnswers)
                        || !ToolCaption.steps(in: message.tools).isEmpty {
                        ThinkingTrace(
                            steps: message.tools,
                            pending: working && !writing && message.approval == nil
                                && !store.activeAwaitsAnswers,
                            note: message.deliveryNote,
                            thoughtSeconds: message.thoughtSeconds,
                            startedAt: message.createdAt,
                            seed: ToolCaption.seed(message.id),
                            status: message.lastStatus
                        )
                    }

                    if let routine = message.routineName {
                        let content = message.botName == "chollometro"
                            && routine == "Chollos del dia"
                            ? ChollometroReport.normalizedMarkdown(message.content)
                            : message.content
                        if message.botName == "chollometro",
                           let deals = ChollometroReport.deals(in: content) {
                            RoutineReportCard(name: routine) {
                                ChollometroDeals(
                                    deals: deals,
                                    tint: store.mark(for: "chollometro").color
                                )
                            }
                        } else {
                            RoutineReportCard(name: routine) {
                                replyBody(content)
                            }
                        }
                    } else if let agent = message.fromAgent {
                        AgentMessageCard(handle: agent) {
                            replyBody(message.content)
                        }
                    } else if store.pendingHomeModelConfirmation?.replyID == message.id {
                        ModelConfirmationCard()
                    } else if !message.content.isEmpty {
                        // Markdown as blocks — headings, lists, tables, code,
                        // callouts, formulas and reply buttons — the way
                        // every other model surface shows a reply.
                        // No foregroundStyle here: applied to a Text it wins
                        // over the colours set inside the attributed string
                        // and repaints the links in the body colour. Links
                        // take the environment's tint, which `RichMessageView`
                        // sets on every block that can hold one.
                        // While the reply is still arriving it stays plain
                        // text: parsing the whole answer on every token is
                        // what made the phone stop taking taps.
                        replyBody(message.content)
                    }
                    }
                    .accessibilityHint(
                        canRevealExtras
                            ? "Shows actions. Hold to select text."
                            : (canSelectReplyText ? "Hold to select text." : "")
                    )

                    if message.role == .assistant, message.choosesModelInAPicker {
                        Button("Choose a model") { showingModelPicker = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.regular)
                    } else if message.role == .assistant, !message.slashChoices.isEmpty {
                        SlashChoiceButtons(choices: message.slashChoices)
                    }

                    if showingExtras, let line = developerLine {
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .accessibilityLabel("Developer details")
                    }

                    // A reply this device stopped watching. The bot may still
                    // be working, and saying so beats a spinner that never
                    // ends or a failure that did not happen.
                    if !message.pending, message.awaitingRemote, !stillWorking,
                       let note = message.deliveryNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let approval = message.approval {
                        RunApprovalCard(messageID: message.id, approval: approval)
                    }
                    if let limit = message.errorLimit {
                        ModelLimitNote(limit: limit)
                    } else if AppStore.agentFailure(in: message.error ?? "") != nil {
                        if AppStore.isNoReply(message.error ?? "") {
                            Text("Hermes stopped after every model it tried failed. Continue retries the same question; picking another model avoids this chain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Continue") { store.sendQuickReply("continue") }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Text("This is what the last provider Hermes tried said — it may not be the model you picked. Its own fallbacks are tried in order, and only the final failure comes back.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Only once the reply has finished: acting on half an
                    // answer copies or shares something that is still changing.
                    if showingExtras, canShowActions {
                        MessageActions(message: actionsMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showingModelPicker) { ModelPicker() }
    }

    private var canShowActions: Bool {
        showsActions && !message.pending && !message.content.isEmpty
    }

    private var canRevealExtras: Bool { canShowActions || developerLine != nil }

    private var canSelectReplyText: Bool {
        !message.pending && !actionsMessage.content.isEmpty
    }

    private func revealReplyExtras() {
        guard canRevealExtras else { return }
        showingExtras.toggle()
    }

    /// Developer-mode line under a finished reply, hidden until the message is tapped.
    private var developerLine: String? {
        guard store.developerMode, !message.pending, message.role == .assistant else { return nil }
        return MessageUsage.footer(
            usage: message.usage,
            tools: message.tools.count,
            seconds: message.usage?.seconds ?? message.thoughtSeconds
        )
    }

    /// Makes a bare URL tappable.
    ///
    /// Markdown only marks a link that was written as one, and a model listing
    /// deals writes the address plainly. Left as text it is something to copy
    /// out by hand, which for a list of offers is most of the work the list
    /// was meant to save.
    ///
    /// The addresses are found in the plain text and then located again in the
    /// attributed copy by searching for them. Converting string offsets across
    /// the two is the obvious route and the fragile one: markdown parsing does
    /// not preserve them, and every failed conversion silently dropped a link.
    static func linkified(
        _ input: AttributedString, body: Color, link: Color
    ) -> AttributedString {
        var output = input
        // The body colour first, so the links can then be picked out of it.
        output.foregroundColor = body
        let plain = String(output.characters)
        guard !plain.isEmpty,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.link.rawValue
              )
        else { return output }

        let found = detector
            .matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
            .compactMap { match -> (String, URL)? in
                guard let url = match.url,
                      let range = Range(match.range, in: plain)
                else { return nil }
                return (String(plain[range]), url)
            }

        for (text, url) in found {
            var searchFrom = output.startIndex
            while searchFrom < output.endIndex,
                  let range = output[searchFrom...].range(of: text) {
                if output[range].link == nil { output[range].link = url }
                searchFrom = range.upperBound
            }
        }

        // Colouring is a second pass, over ranges taken from the string
        // itself. Assigned through a range that came from a slice — which is
        // how the addresses are found — `link` takes and `foregroundColor`
        // silently does not: the run ends up a link in the body's colour,
        // which is exactly what it looked like. Verified against the real
        // AttributedString rather than reasoned about.
        let linked = output.runs.filter { $0.link != nil }.map(\.range)
        for range in linked {
            output[range].foregroundColor = link
            output[range].underlineStyle = nil
        }
        return output
    }

    /// Inline Markdown only — bold, italics, code, links — with every newline
    /// left where the model put it. The block structure is `RichMarkdown`'s:
    /// `.full` understood lists and paragraphs and then welded them together,
    /// "…en renovación.Amazon: Cupón directo…", with nowhere to put them.
    static func parsed(_ content: String) -> AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(content)
    }
}

/// A routine's report in a bot's chat (`RoutineDelivery`).
///
/// On a card, named, so what a routine found on its own reads apart from the
/// conversation with the bot.
private struct RoutineReportCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Routine: \(name)")
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Another agent's message in this chat — its answer to something this agent
/// asked, or a request it sent — marked as that agent's rather than drawn as
/// something the person wrote.
private struct AgentMessageCard<Content: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let handle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BotMarkView(mark: store.mark(for: handle), size: 18)
                Text("From \(store.botCurrentName(for: handle))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ChollometroDeals: View {
    let deals: [ChollometroReport.Deal]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(deals.enumerated()), id: \.offset) { _, deal in
                VStack(alignment: .leading, spacing: 8) {
                    let detail = deal.detail.map { " — \($0)" } ?? ""
                    Text("\(Text(deal.title).bold())\(Text(detail))")
                    .textSelection(.enabled)

                    Link(destination: deal.url) {
                        Text("Open deal")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(tint, in: .rect(cornerRadius: 7))
                            .contentShape(.rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the deal in the browser")
                }
            }
        }
    }
}

/// The row of things you can do with a finished reply.
///
/// Glyphs chosen to match what a reader coming from another model client
/// expects: overlapping squares for copy, the tray-and-arrow iOS share, a
/// speaker for reading aloud, and the two-arrow cycle for another attempt.
private struct MessageActions: View {
    @Environment(AppStore.self) private var store
    @Environment(ReadAloud.self) private var speech
    @Environment(\.colorScheme) private var scheme
    @Environment(\.givenReaction) private var given
    let message: Message
    @State private var copied = false

    var body: some View {
        // Every slot carries its own half of the gap, so spacing here is 0
        // and the leading inset pulls the first glyph's ink back onto the
        // paragraph's left edge rather than onto its slot's edge.
        HStack(spacing: 0) {
            // First, because they answer: a yes or a no to what the reply
            // proposed, sent as his turn. The one given stays filled.
            if store.canReact(to: message) {
                ForEach(Reaction.allCases, id: \.self) { reaction in
                    reactionButton(reaction)
                }
            }

            Button {
                UIPasteboard.general.string = message.content
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                ActionIcon(copied ? "checkmark" : "square.on.square", slot: 16.67)
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")

            ShareLink(item: message.content) {
                ActionIcon("square.and.arrow.up", slot: 14)
            }
            .accessibilityLabel("Share")

            Button {
                speech.toggle(message.content, id: message.id)
            } label: {
                ActionIcon(
                    speech.isSpeaking(message.id) ? "speaker.slash" : "speaker.wave.2",
                    slot: 17.33
                )
            }
            .accessibilityLabel(
                speech.isSpeaking(message.id) ? "Stop reading" : "Read aloud"
            )

            // A routine's report was not an answer to anything the person
            // said, so there is nothing to ask again.
            if message.routineName == nil {
                Button {
                    store.retry(message.id)
                } label: {
                    ActionIcon("arrow.triangle.2.circlepath", slot: 19.33)
                }
                .disabled(store.isSending)
                .accessibilityLabel("Try again")
            }
        }
        // Slots carry half a gap each, so the first glyph's ink would sit
        // half a gap in from the paragraph. Pull it back out, less the
        // 0.67pt of left side bearing the text above already carries, so the
        // copy square lines up with the letters instead of overhanging them.
        .padding(.leading, -ActionIcon.gap / 2 + 0.67)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

extension MessageActions {
    private func reactionButton(_ reaction: Reaction) -> some View {
        let chosen = given == reaction
        return Button {
            guard !chosen else { return }
            ReactionTip().invalidate(reason: .actionPerformed)
            Task { await store.react(reaction, to: message) }
        } label: {
            // 16.67: the thumb paints 17pt of ink at 16pt, as the copy
            // squares do (`scripts/measure-symbol-ink.swift`).
            ActionIcon(chosen ? reaction.symbol + ".fill" : reaction.symbol, slot: 16.67)
                .foregroundStyle(chosen ? AnyShapeStyle(store.accent.primary(scheme)) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: chosen)
        }
        .disabled(store.isSending && !chosen)
        .sensoryFeedback(.selection, trigger: chosen) { _, now in now }
        .accessibilityLabel(reaction == .yes ? Text("Answer yes") : Text("Answer no"))
        .accessibilityValue(chosen ? Text("Chosen") : Text(verbatim: ""))
        .accessibilityHint("Sends it to the agent as your answer")
    }
}

/// His answer with a thumb: the thumb itself, large, as a single emoji is in
/// Messages, under the start of the reply it answers when that was not the
/// latest, and over what the phone did about it.
private struct ReactionBubble: View {
    @Environment(\.colorScheme) private var scheme
    let turn: ReactionTurn

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let quote = turn.quote {
                Text("«\(quote)»")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border(scheme), lineWidth: 0.5) }
            }
            Text(turn.reaction.rawValue)
                .font(.system(size: 40))
            if let note = turn.note, let first = note.first {
                Label(first.uppercased() + note.dropFirst(), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let answer = turn.reaction == .yes ? String(localized: "You answered yes") : String(localized: "You answered no")
        var parts = [answer]
        if let quote = turn.quote { parts.append(quote) }
        if let note = turn.note { parts.append(note) }
        return parts.joined(separator: ". ")
    }
}

/// One action glyph, laid out by the pixels it actually paints.
///
/// SF Symbols share neither a layout box nor an ink size. At 16pt the share
/// tray paints 14x17.75pt inside an 18x21 box while the refresh cycle paints
/// 19.75x16 inside 20x18, so spacing them by their boxes — or on a fixed
/// pitch — leaves uneven whitespace: the gap before the refresh glyph
/// measured 2pt tighter than the others, which is what made the row read as
/// ragged.
///
/// Each glyph gets a slot as wide as its own ink plus one shared gap. Two
/// neighbours then contribute half a gap each, so the whitespace between any
/// two glyphs is exactly `gap` whatever their widths. `slot` is the widest
/// ink among the states one button can show, so the row does not reflow when
/// a glyph swaps.
///
/// Slot widths are the ink the device actually paints, which runs a little
/// under what `scripts/measure-symbol-ink.swift` reports — the renderer
/// drops the faintest antialiased edge, 1.4pt of it on the speaker's outer
/// wave. Take the script's numbers as the starting point and settle them
/// against a screenshot; re-derive both if the symbol set, weight or point
/// size changes.
private struct ActionIcon: View {
    static let gap: CGFloat = 12
    private static let pointSize: CGFloat = 16

    private let symbol: String
    private let slot: CGFloat

    init(_ symbol: String, slot: CGFloat) {
        self.symbol = symbol
        self.slot = slot
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Self.pointSize))
            .contentTransition(.symbolEffect(.replace))
            .offset(y: -Self.inkDropBelowCentre(symbol))
            .frame(width: slot + Self.gap, height: 30)
            .contentShape(.rect)
    }

    /// How far a symbol's ink centre sits below its layout centre. Only the
    /// share tray is off: its arrow overshoots the box upward, leaving the
    /// drawn shape 0.63pt low. Everything else is centred as drawn.
    private static func inkDropBelowCentre(_ symbol: String) -> CGFloat {
        symbol == "square.and.arrow.up" ? 0.63 : 0
    }
}

/// Holding a message you sent: copy it, rewrite it, pick out part of it, or
/// pass the prompt on.
private struct SentMessageMenu: View {
    @Environment(AppStore.self) private var store
    let message: Message
    @Binding var selecting: Bool

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.content
            MessageActionsTip().invalidate(reason: .actionPerformed)
        }
        // Only the latest message: Hermes can replace the last exchange and
        // nothing before it.
        if store.canEdit(message) {
            Button("Edit", systemImage: "pencil") {
                store.beginEditing(message)
                MessageActionsTip().invalidate(reason: .actionPerformed)
            }
        }
        Button("Select Text", systemImage: "selection.pin.in.out") {
            selecting = true
            MessageActionsTip().invalidate(reason: .actionPerformed)
        }
        ShareLink(
            item: message.content,
            preview: SharePreview("Prompt")
        ) {
            Label("Share Prompt", systemImage: "square.and.arrow.up")
        }
    }
}

/// The message in a read-only text view, so any part of it can be selected
/// with the system handles and its menu: Copy, Look Up, Translate, Share and
/// whatever else iOS offers for selected text.
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        view.dataDetectorTypes = [.link]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        guard !context.coordinator.didPrime, !text.isEmpty else { return }
        context.coordinator.didPrime = true
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            view.selectAll(nil)
        }
    }

    final class Coordinator {
        var didPrime = false
    }
}

/// What went out with a message, shown so the conversation is a record of
/// what was actually sent rather than only of what was typed.
private struct SentAttachments: View {
    @Environment(\.colorScheme) private var scheme
    let attachments: [Attachment]

    var body: some View {
        // Every image in the message, so the viewer can swipe between them.
        let images = attachments.compactMap { $0.kind == .image ? UIImage(data: $0.data) : nil }
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(.rect(cornerRadius: 14))
                        .opensImageViewer(
                            images,
                            at: attachments.filter { $0.kind == .image }
                                .firstIndex { $0.id == attachment.id } ?? 0
                        )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(attachment.name).lineLimit(1)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.card(scheme), in: .capsule)
                }
            }
        }
    }
}

/// What the agent is doing, said in words a reader wants.
///
/// The words of `ThinkingTrace`, kept out of the view so they can be tested
/// without one.
enum ToolCaption {
    /// The steps worth showing a reader.
    ///
    /// Clarify is a question for the person, drawn as buttons in the chat.
    /// Listing it as a step would leave "Asking a question" standing in the
    /// trace under an answer they have already given.
    static func steps(in tools: [Message.ToolCall]) -> [Message.ToolCall] {
        tools.filter { !$0.name.lowercased().contains("clarify") }
    }

    /// The line above the reply: what it is doing, or what it took.
    ///
    /// While a tool runs the line says what that tool does — "Downloading",
    /// "Searching the web" — because that is the honest answer to "what is it
    /// doing". Between tools the agent is thinking, and a wait that always
    /// says "Thinking" feels stuck; the word changes every few seconds, from
    /// a place chosen by `seed` so two replies on screen do not move in step.
    static func headline(
        pending: Bool, note: String?, thoughtSeconds: Int?,
        steps: [Message.ToolCall] = [], elapsed: TimeInterval? = nil, seed: Int = 0,
        status: String? = nil
    ) -> String {
        if pending {
            if let note, !note.isEmpty { return note }
            if let status, !status.isEmpty { return status }
            if let running = Self.steps(in: steps).last, running.status != .done {
                return phrase(for: running, running: false)
            }
            if !Self.steps(in: steps).isEmpty { return "Thinking" }
            guard let elapsed else { return "Thinking" }
            return musing(elapsed: elapsed, seed: seed)
        }
        guard let thoughtSeconds, thoughtSeconds >= 1 else { return "Thought for a moment" }
        return "Thought for \(thoughtSeconds) second\(thoughtSeconds == 1 ? "" : "s")"
    }

    /// Ways of saying "thinking" that a person waiting can smile at. Plain
    /// first, so a short wait reads plainly; the rest arrive with time.
    static let musings: [String] = [
        "Thinking", "Pondering", "Mulling it over", "Connecting the dots", "Cogitating",
        "Brewing", "Percolating", "Noodling", "Ruminating", "Weighing it up",
        "Puzzling", "Deliberating", "Musing", "Marinating", "Untangling",
        "Simmering", "Sharpening the pencil", "Consulting the oracle", "Chewing on it", "Warming up the neurons",
    ]

    /// How long one word stays before the next one.
    static let musingBeat: TimeInterval = 6

    /// The word for this moment of the wait. The first beat is always
    /// "Thinking": a reply that lands in two seconds never needs a joke.
    static func musing(elapsed: TimeInterval, seed: Int) -> String {
        let beats = Int(max(elapsed, 0) / musingBeat)
        guard beats > 0 else { return musings[0] }
        let others = musings.dropFirst()
        let index = (abs(seed) + beats - 1) % others.count
        return others[others.startIndex + index]
    }

    /// A stable number for a reply, so its wait keeps its own rhythm across
    /// redraws and no two replies say the same word at the same time.
    static func seed(_ id: String) -> Int {
        id.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
    }

    /// A step, named. Still running it keeps its "…"; done, it does not — by
    /// the time a reader opens a settled trace, nothing in it is happening.
    static func phrase(for tool: Message.ToolCall, running: Bool) -> String {
        let said = phrase(for: tool)
        return running ? said : said.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
    }

    /// A tool's name said as an action.
    ///
    /// `web_extract` tells a reader nothing they wanted to know, and a reader
    /// who does not write software it actively puts off. The names come from
    /// Hermes and change between builds, so an unknown one falls back to its
    /// own words tidied up rather than to a shrug.
    static func phrase(for tool: Message.ToolCall) -> String {
        if let concrete = concretePhrase(for: tool) { return concrete }
        let name = tool.name.lowercased()
        switch true {
        // Media first: `cobalt_download` must not fall into "Reading a file".
        case name.contains("cobalt"),
             name.contains("download"):     return "Downloading…"
        case name.contains("upload"):       return "Uploading…"
        case name.contains("message_agent"),
             name.contains("send_message"),
             name.contains("delegate"):     return "Asking a teammate…"
        case name.contains("search"):       return "Searching the web…"
        case name.contains("browser"),
             name.contains("playwright"):   return "Opening a page…"
        case name.contains("extract"),
             name.contains("fetch"),
             name.contains("scrape"):       return "Reading a page…"
        case name.contains("terminal"),
             name.contains("shell"),
             name.contains("bash"),
             name.contains("execute_code"): return "Running a command…"
        case name.contains("skill"):        return "Checking its notes…"
        case name.contains("memory"):       return "Remembering…"
        case name.contains("file"),
             name.contains("read"):         return "Reading a file…"
        case name.contains("write"),
             name.contains("edit"):         return "Writing…"
        case name.contains("mail"),
             name.contains("email"):        return "Looking at mail…"
        case name.contains("calendar"):     return "Checking the calendar…"
        case name.contains("image"),
             name.contains("vision"):       return "Looking at an image…"
        case name.contains("audio"),
             name.contains("video"),
             name.contains("transcri"):     return "Working on the media…"
        case name.contains("cron"),
             name.contains("job"),
             name.contains("schedule"):     return "Checking its routines…"
        case name.contains("http"),
             name.contains("request"):      return "Calling a service…"
        default:
            let words = name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst() + "…"
        }
    }

    /// A tool plus the file, query or command it is using, when Hermes sent one.
    static func concretePhrase(for tool: Message.ToolCall) -> String? {
        guard let raw = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let snippet = Self.snippet(raw)
        let name = tool.name.lowercased()
        if name.contains("read") || name.contains("file") {
            return "Reading \(snippet)"
        }
        if name.contains("search") {
            return "Searching: \(snippet)"
        }
        if name.contains("terminal") || name.contains("shell") || name.contains("bash")
            || name.contains("execute") {
            return "Running \(snippet)"
        }
        if name.contains("download") || name.contains("cobalt") {
            return "Downloading \(snippet)"
        }
        return nil
    }

    static func snippet(_ text: String) -> String {
        let leaf = (text as NSString).lastPathComponent
        let cut = leaf.isEmpty ? text : leaf
        if cut.count <= 48 { return cut }
        return String(cut.prefix(45)) + "…"
    }
}

/// Hermes pauses the run here until the reader makes an explicit choice.
/// AppStore owns the mutation, so this view never sees the gateway key or has
/// to know which endpoint answers the approval.
private struct RunApprovalCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let messageID: String
    let approval: Message.Approval

    var body: some View {
        let explanation = ApprovalExplainer.explain(
            description: approval.hermesDescription, command: approval.command
        )
        VStack(alignment: .leading, spacing: 10) {
            Label("Wants to \(explanation.action)", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))

            Text(explanation.risk)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if approval.smartDenied == true {
                Label(ApprovalExplainer.smartDeniedWarning, systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons }
                VStack(alignment: .leading, spacing: 8) { choiceButtons }
            }

            Text(ApprovalExplainer.choiceHint(approval.choices))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Hermes' own words and the command, for anyone who wants them, out
            // of the way of everyone else.
            if approval.command != nil || approval.hermesDescription != nil {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        if let said = approval.hermesDescription {
                            Text("Hermes says: \(said)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let command = approval.command {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Palette.background(scheme), in: .rect(cornerRadius: 10))
                        }
                    }
                } label: {
                    Text("Show exact command").font(.caption)
                }
            }

            if approval.resolving == true {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Sending decision…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = approval.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.danger(scheme))
            }
        }
        .padding(12)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var choiceButtons: some View {
        ForEach(approval.choices, id: \.self) { choice in
            ApprovalChoiceButton(
                title: label(for: choice),
                deny: choice == .deny,
                disabled: approval.resolving == true,
                tint: store.accent.control(scheme)
            ) {
                Task { await store.resolveApproval(messageID: messageID, choice: choice) }
            }
        }
    }

    private func label(for choice: Message.ApprovalChoice) -> String {
        ApprovalExplainer.label(choice)
    }
}

/// Hermes will not use this model until the person agrees. Not an answer.
private struct ModelConfirmationCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This model needs your OK", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(store.pendingHomeModelConfirmation?.message ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Alice has not sent your question yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This model needs confirmation before Alice sends your question")
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Use this model") { store.confirmHomeModel() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        Button("Not now", role: .cancel) { store.declineHomeModel() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// Says which kind of limit was hit, and whether waiting is worth it. Shown
/// only when the transport actually classified the failure — no guessed cause,
/// and no countdown the provider did not send.
private struct ModelLimitNote: View {
    let limit: ModelLimit

    var body: some View {
        if limit.kind != .auth {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        // "Waiting won’t help" and "try again in twenty minutes" were being
        // printed one after the other. A free tier that answers with a
        // Retry-After is telling you exactly when it comes back, which is the
        // opposite of what the first half said — so when the provider names a
        // time, that is the whole message.
        guard let seconds = limit.retryAfterSeconds else {
            return limit.kind == .quota
                ? "You’ve used up your allowance for this model. Waiting won’t help — switch model or top up the provider’s plan."
                : "This model is taking requests too fast right now. It should work again shortly."
        }
        let wait = seconds >= 90
            ? "\(Int((Double(seconds) / 60).rounded())) min"
            : "\(max(1, seconds))s"
        return limit.kind == .quota
            ? "This model’s allowance is spent. It comes back in about \(wait) — or switch model now."
            : "This model is taking requests too fast right now. Try again in about \(wait)."
    }
}

/// Allow is the filled button; refuse stays outlined. Mixed `ButtonStyle`
/// types cannot share a ternary, so the two looks are two branches.
/// Options parsed out of a slash command, so the person taps one instead of typing it.
private struct SlashChoiceButtons: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let choices: [SlashChoice]

    var body: some View {
        SlashChoiceFlow(spacing: 8) {
            ForEach(choices) { choice in
                Button {
                    store.sendQuickReply(choice.command)
                } label: {
                    Text(choice.label)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(choice.current ? store.accent.control(scheme) : Color.secondary)
                .disabled(store.isSending)
                .accessibilityLabel(choice.current ? "\(choice.label), current" : choice.label)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SlashChoiceFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = rows(of: subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                item.view.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Item {
        var view: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [Item]
        var height: CGFloat
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var items: [Item] = []
        var x: CGFloat = 0
        var height: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > width {
                rows.append(Row(items: items, height: height))
                items = []
                x = 0
                height = 0
            }
            items.append(Item(view: view, size: size))
            height = max(height, size.height)
            x += size.width + spacing
        }
        if !items.isEmpty { rows.append(Row(items: items, height: height)) }
        return rows
    }
}

struct ApprovalChoiceButton: View {
    let title: String
    var deny = false
    var disabled = false
    var tint: Color
    var small = false
    let action: () -> Void

    var body: some View {
        if deny {
            control.buttonStyle(.bordered).tint(.secondary)
        } else {
            control.buttonStyle(.borderedProminent).tint(tint)
        }
    }

    private var control: some View {
        Button(title, action: action)
            .buttonBorderShape(.capsule)
            .controlSize(small ? .small : .regular)
            .disabled(disabled)
    }
}
