import SwiftUI
import TipKit
import UIKit

struct MessageRow: View {
    /// Only separators, spaces and punctuation: nothing a person could read.
    static func saysNothing(_ text: String) -> Bool {
        !text.contains { $0.isLetter || $0.isNumber }
    }

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
    /// Resolved once for the whole conversation, never independently per reply.
    var errandRefs: [ErrandRef] = []
    /// This reply was written by another model than the reply before it (`ModelChange`).
    var modelChange: ModelChange? = nil
    /// The lessons Alice kept after this reply (`LessonNotice`); tapped, they say what she learned.
    var learned: [AgentAction] = []
    @State private var showingLessons = false
    @AppStorage(HomeInterface.storageKey) private var homeInterface: HomeInterface = .current
    @State private var selectingText = false
    @State private var showingModelPicker = false
    /// The model chosen from this reply's «Choose a model», kept so the button does not come back.
    @AppStorage("alice.modelChoices") private var modelChoices: String = "{}"
    /// Copy, share, speak, retry and developer usage stay off until the reply is tapped.
    @State private var showingExtras = false
    @State private var purchaseSets: [String: PurchaseOptionSet] = [:]

    /// The agent this reply is from when it was asked by name in a chat that
    /// is not its own.
    private var invokedAgent: String? {
        if let profile = message.mentionProfile, !profile.isEmpty { return profile }
        // Alice's own words, kept in a session by `/new`, are hers: no name over them.
        guard let bot = message.botName, !bot.isEmpty, bot != AppStore.todayProfile,
              store.activeChat.routedBotName == nil,
              !store.activeChat.isChannel
        else { return nil }
        return bot
    }

    /// The experimental interface draws every reply's words in a bubble, in Alice's chat and the agents'.
    private var bubblesReplies: Bool { store.developerMode && homeInterface == .experimental }

    @ViewBuilder
    private func inBubble<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if bubblesReplies { ReplyBubble { content() } } else { content() }
    }

    @ViewBuilder
    private func routineReport(_ routine: String) -> some View {
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
        } else if Self.saysNothing(content) {
            // A run whose model answered only "---" (29-09): said, not a blank card.
            RoutineReportCard(name: routine) {
                Text("This run came back empty. The next one will try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            RoutineReportCard(name: routine) {
                replyBody(content)
            }
        }
    }

    /// While tokens arrive, finished blocks in their final layout and the
    /// paragraph being written as light Markdown (`StreamingReply`).
    @ViewBuilder
    private func replyBody(_ content: String, bubbled: Bool = false) -> some View {
        if message.pending {
            if bubbled {
                ReplyBubble { StreamingReply(content: content, onTap: revealReplyExtras) }
            } else {
                StreamingReply(content: content, onTap: revealReplyExtras)
            }
        } else {
            RichMessageView(content: content, failed: message.error != nil, onTap: revealReplyExtras,
                            bubbled: bubbled)
                // A hold is the menu, so the words are not selected in place; Select opens them.
                .environment(\.allowsRichTextSelection, false)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 22))
                .contextMenu {
                    if canShowActions { ReplyMenu(message: actionsMessage, selecting: $selectingText) }
                }
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
        // Words said just before or after a routine are drawn inside the routine's bubble.
        if absorbedIntoRoutine {
            EmptyView()
        } else if let eventID = AgentRoutineRunCard.eventID(message.id) {
            AgentRoutineRunCard(eventID: eventID)
        } else if let post = message.feedContext {
            FeedContextCard(post: post)
        } else {
            row
        }
    }

    /// A routine's opening or closing words: in a bubbled chat they are drawn inside the
    /// report's own bubble (`routineIntro` / `routineOutro` on the card), not as bubbles apart.
    private var absorbedIntoRoutine: Bool {
        bubblesReplies && message.routineGroup != nil
            && (message.routinePart == .opening || message.routinePart == .closing)
    }

    private var row: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            switch message.role {
            case .user:
                if !message.attachments.isEmpty {
                    SentAttachments(attachments: message.attachments)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let turn = ReactionTurn.parse(message.content) {
                    ReactionBubble(turn: turn)
                } else if AskPerson.isAnswersOnly(message.content) || PurchaseChoice.id(in: message.content) != nil {
                    // Answers to a question card, or an option tapped in the options card: both are
                    // shown in the card that asked («Elegida»), not as words the person typed.
                    EmptyView()
                } else if !message.content.isEmpty {
                    // An answer to one reply carries it on top, quoted (`ReplyQuote`).
                    if let quoted = ReplyQuote.split(message.content) {
                        QuotedReply(text: quoted.quote)
                    }
                    // Only a hold opens its actions, as in Messages; a tap does
                    // nothing. (A tap-opened SwiftUI `Menu` crashed on a double
                    // tap in build 60, and a row of buttons under every sent
                    // message on a tap was not wanted either.)
                    // Only the named agent is emphasized; the bubble keeps one text colour.
                    Text(store.mentionStyled(
                        PurchaseChoice.display(AskPerson.display(ReplyQuote.split(message.content)?.text ?? message.content)),
                        bareSlugs: message.mentionProfile.map { [$0] } ?? [],
                        selectedRanges: ReplyQuote.ranges(message.selectedMentionRanges, in: message.content)
                    ))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 18))
                        .contextMenu { SentMessageMenu(message: message, selecting: $selectingText) }
                        .accessibilityHint("Hold for actions.")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ForEach(errandRefs, id: \.self) { ref in
                    ErrandChatBlock(ref: ref).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .assistant:
                // Said where it happened: the model changed (chosen, or Hermes fell back because the
                // usual one failed), with nothing else in the chat to show it.
                if let modelChange {
                    Label(modelChange.said(in: ChatLanguage.of(message.content)), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                }
                // Ordinary turns are a conversation, not a log. A routine
                // delivery is dated because it arrived on its own, later.
                // Once, above the whole delivery: the agent's opening words,
                // its card and its closing words are one routine.
                // A routine's report always says when it ran, even when its opening words came first.
                if showsTime || message.routineName != nil, message.routineName != nil || message.routinePart != nil,
                   let when = MessageTime.routineCaption(message.createdAt) {
                    Text(when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Room from the agent's previous message and before the routine opens.
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                        .accessibilityLabel(Text("Sent \(String(when.characters))"))
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
                        || !ToolCaption.steps(in: message.tools).isEmpty
                        || shownReasoning != nil {
                        ThinkingTrace(
                            steps: message.tools,
                            pending: working && !writing && message.approval == nil
                                && !store.activeAwaitsAnswers,
                            note: message.deliveryNote,
                            thoughtSeconds: message.thoughtSeconds,
                            startedAt: message.createdAt,
                            seed: ToolCaption.seed(message.id),
                            status: message.lastStatus,
                            reasoning: shownReasoning
                        )
                    }

                    // What the agent set out to do, step by step (`TaskPlan`).
                    if let plan = message.plan, plan.total > 0 {
                        TaskPlanCard(plan: plan, working: working)
                    }

                    // The page it is on, live, while it browses — tap to take over.
                    // Gone once the task ends: left behind, it was a grey box with a spinner.
                    if BrowserActivity.used(message.tools), working {
                        LiveBrowserCard(working: working, browsing: BrowserActivity.running(message.tools),
                                        caption: BrowserActivity.caption(message.tools))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    // In the order they happened: the model shows the options (or asks) and then writes
                    // its words about them. Drawn under the words, the text arrived afterwards above a
                    // card already on screen, and the chat read out of order.
                    ForEach(message.tools.filter { PurchaseOptionSet.isTool($0.name) && $0.status == .done }) { call in
                        PurchaseOptionsCard(detail: call.detail, language: ChatLanguage.of(message.content),
                                            session: message.mentionSessionID ?? store.shownConversation?.hermesSessionID,
                                            replyProfile: message.mentionProfile,
                                            onLoaded: { purchaseSets[call.id] = $0 })
                    }
                    ForEach(message.tools.filter { AskPerson.isTool($0.name) }) { call in
                        if let ask = AskPerson.parse(call.detail),
                           !AskPerson.superseded(ask, callID: call.id,
                                                 in: store.shownConversation?.messages ?? []) {
                            AskPersonCard(ask: ask)
                        }
                    }

                    if let routine = message.routineName {
                        // One bubble with what Alice said around it, like every other reply's words.
                        inBubble {
                            VStack(alignment: .leading, spacing: 10) {
                                if bubblesReplies, let intro = message.routineIntro, !intro.isEmpty {
                                    RichMessageView(content: intro)
                                }
                                routineReport(routine)
                                if bubblesReplies, let outro = message.routineOutro, !outro.isEmpty {
                                    RichMessageView(content: outro)
                                }
                            }
                        }
                    } else if let agent = message.fromAgent {
                        AgentMessageCard(handle: agent) {
                            replyBody(message.content)
                        }
                    } else if store.pendingHomeModelConfirmation?.replyID == message.id {
                        ModelConfirmationCard()
                    } else if let set = message.tools.reversed().compactMap({ purchaseSets[$0.id] }).first,
                              let recommendation = set.recommendation(ChatLanguage.of(message.content)) {
                        replyBody(recommendation, bubbled: bubblesReplies)
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
                        replyBody(message.content, bubbled: bubblesReplies)
                    }
                    }
                    .accessibilityHint(
                        canShowActions ? "Hold for Reply, Copy, Select and Share." : ""
                    )

                    if message.role == .assistant, message.choosesModelInAPicker {
                        if let chosen = chosenModel {
                            // Done: the picker changed it (or it already was that one).
                            Label(ChatLanguage.of(message.content).pick("Model changed to \(chosen)", "Modelo cambiado a \(chosen)"),
                                  systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.success(scheme))
                        } else {
                            Button("Choose a model") { showingModelPicker = true }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.regular)
                        }
                    } else if message.role == .assistant, !message.slashChoices.isEmpty {
                        SlashChoiceButtons(choices: message.slashChoices)
                    }

                    // The errand this turn started, after everything the turn said.
                    if message.role == .assistant {
                        ForEach(errandRefs, id: \.self) { ref in
                            ErrandChatBlock(ref: ref)
                        }
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
                        if let payment = PaymentApproval(command: approval.command) {
                            // The card itself has no words of Alice's; the chat around it does.
                            let said = message.content.isEmpty
                                ? (store.shownConversation?.messages.last { $0.role == .assistant && !$0.content.isEmpty }?.content ?? "")
                                : message.content
                            PaymentApprovalCard(messageID: message.id, approval: approval, payment: payment,
                                                language: ChatLanguage.of(said))
                        } else {
                            RunApprovalCard(messageID: message.id, approval: approval)
                        }
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !learned.isEmpty {
                    Button { showingLessons = true } label: {
                        Label(LessonNotice.said(in: ChatLanguage.of(message.content)), systemImage: "graduationcap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                    .accessibilityHint("Shows what was learned.")
                    .sheet(isPresented: $showingLessons) { LessonSheet(lessons: learned, reply: message.content) }
                }
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPicker(onChanged: { label in rememberModelChoice(label) })
        }
        // The same rule for links SwiftUI opens (Markdown in Text): none of these from a reply.
        .environment(\.openURL, OpenURLAction { url in
            AgentLinks.refused(url) && message.role == .assistant ? .discarded : .systemAction
        })
        .sheet(isPresented: $selectingText) {
            SelectableTextSheet(text: message.role == .user ? PurchaseChoice.display(message.content) : message.content)
        }
    }

    /// The reasoning worth showing: not the reply over again, which is what
    /// earlier builds stored from Hermes' misnamed `reasoning.available`.
    private var shownReasoning: String? {
        guard let text = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let reply = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasPrefix(text) || text.hasPrefix(reply.prefix(200)) { return nil }
        return text
    }

    private var canShowActions: Bool {
        showsActions && !message.pending && !message.content.isEmpty
    }

    private var chosenModel: String? {
        (try? JSONDecoder().decode([String: String].self, from: Data(modelChoices.utf8)))?[message.id]
    }

    private func rememberModelChoice(_ label: String) {
        var all = (try? JSONDecoder().decode([String: String].self, from: Data(modelChoices.utf8))) ?? [:]
        all[message.id] = label
        if all.count > 50 { all = Dictionary(uniqueKeysWithValues: all.suffix(50).map { ($0.key, $0.value) }) }
        modelChoices = (try? String(data: JSONEncoder().encode(all), encoding: .utf8)) ?? "{}"
    }

    /// A tap shows only the developer line now; what to do with a reply is in its hold menu.
    private var canRevealExtras: Bool { developerLine != nil }

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

    // Inside the reply's own bubble now: a card of its own inside it was a box in a box. The
    // routine's name is not written over it (29-09): the time above says it arrived on its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .environment(\.separatesEntries, true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routine: \(name)")
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
                // The title is the link (29-09): no button under every deal.
                let detail = deal.detail.map { " — \($0)" } ?? ""
                Link(destination: deal.url) {
                    Text("\(Text(deal.title).bold().foregroundStyle(tint))\(Text(detail).foregroundStyle(.primary))")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the deal in the browser")
            }
        }
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

/// Keep the existing 16pt glyphs, with a full native touch target. The fixed
/// footprint also keeps the row stable when copy becomes a checkmark.
private struct ActionIcon: View {
    static let targetSize: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .offset(y: -Self.inkDropBelowCentre(symbol))
            .frame(width: slot)
            .frame(width: Self.targetSize, height: Self.targetSize)
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
/// A finished reply's hold menu: answer it, copy it, pick words out of it, or send it on.
private struct ReplyMenu: View {
    @Environment(AppStore.self) private var store
    let message: Message
    @Binding var selecting: Bool

    private var author: String {
        guard let bot = message.botName, !bot.isEmpty, bot != AppStore.todayProfile else { return "Alice" }
        return store.botCurrentName(for: bot)
    }

    var body: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") {
            store.replyingTo = ReplyQuote(messageID: message.id, author: author, content: message.content)
        }
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.content
            Haptic.success.play()
        }
        Button("Select", systemImage: "selection.pin.in.out") { selecting = true }
        ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

private struct SentMessageMenu: View {
    @Environment(AppStore.self) private var store
    let message: Message
    @Binding var selecting: Bool

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = PurchaseChoice.display(message.content)
            Haptic.success.play()
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
            item: PurchaseChoice.display(message.content),
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
        let images = attachments.compactMap { $0.kind == .image ? AttachmentImages.image($0) : nil }
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image, let image = AttachmentImages.image(attachment) {
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
        tools.filter { !$0.name.lowercased().contains("clarify") && !AskPerson.isTool($0.name) && !ErrandRef.isTool($0.name) && !PurchaseOptionSet.isTool($0.name) }
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
        guard let thoughtSeconds, thoughtSeconds >= 1 else { return String(localized: "Thought for a moment") }
        // "Thought for 53s", "Thought for 2m 5s".
        let span = thoughtSeconds < 60 ? "\(thoughtSeconds)s"
            : thoughtSeconds % 60 == 0 ? "\(thoughtSeconds / 60)m"
            : "\(thoughtSeconds / 60)m \(thoughtSeconds % 60)s"
        return String(localized: "Thought for \(span)")
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
                    .foregroundStyle(Palette.warning(scheme))
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

/// The one yes a purchase needs: Hermes asks before it writes a saved card
/// into the checkout. What is being bought and for how much is in Alice's
/// message just above; this says where and with which card.
struct PaymentApprovalCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let messageID: String
    let approval: Message.Approval
    let payment: PaymentApproval
    let language: ChatLanguage
    /// The Developer › Purchase walkthrough answers here instead of asking Hermes.
    var demoChoice: ((Message.ApprovalChoice) -> Void)? = nil
    @State private var unconfirmed = false
    @State private var approved = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.pick("Confirm the payment", "Confirmar el pago"), systemImage: "creditcard")
                .font(.subheadline.weight(.semibold))
            Text(language.pick("Alice will pay on \(payment.site) with your \(payment.card).",
                               "Alice pagará en \(payment.site) con tu \(payment.card)."))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ApprovalChoiceButton(title: language.pick("Pay", "Pagar"), deny: false,
                                     disabled: approval.resolving == true, tint: store.accent.control(scheme)) {
                    // Paying is the person's own decision: Face ID (or the passcode) first.
                    Task {
                        unconfirmed = false
                        guard await Biometrics.authenticate(
                            reason: language.pick("Confirm the payment on \(payment.site)",
                                                  "Confirma el pago en \(payment.site)")
                        ) else { unconfirmed = true; return }
                        approved += 1
                        if let demoChoice { demoChoice(.once) } else {
                            await store.resolveApproval(messageID: messageID, choice: .once)
                        }
                    }
                }
                ApprovalChoiceButton(title: language.pick("Cancel", "Cancelar"), deny: true,
                                     disabled: approval.resolving == true, tint: store.accent.control(scheme)) {
                    if let demoChoice { demoChoice(.deny) } else {
                        Task { await store.resolveApproval(messageID: messageID, choice: .deny) }
                    }
                }
            }
            Text(language.pick("The card numbers never go through the chat.",
                               "Los números de la tarjeta nunca pasan por el chat."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if approval.resolving == true {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(language.pick("Sending your answer…", "Enviando tu respuesta…"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if unconfirmed {
                Text(language.pick("Couldn't confirm it's you, so nothing was paid.",
                                   "No se ha podido confirmar que eres tú, así que no se ha pagado."))
                    .font(.caption).foregroundStyle(Palette.danger(scheme))
            }
            if let error = approval.error {
                Text(error).font(.caption).foregroundStyle(Palette.danger(scheme))
            }
        }
        .padding(12)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: approved)
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
            .buttonStyle(.borderedProminent).onAccentLabel()
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
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
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
            // The label on the accent fill: white on the dark theme's light accents was unreadable.
            control.buttonStyle(.borderedProminent).tint(tint).foregroundStyle(store.accent.onControl(scheme))
        }
    }

    private var control: some View {
        Button(title, action: action)
            .buttonBorderShape(.capsule)
            .controlSize(small ? .small : .regular)
            .disabled(disabled)
    }
}

/// Another agent's routine that just ran, as a card in Alice's own chat (`AppStore.agentRoutineRuns`):
/// that it ran, and when. A tap opens the routine — its schedule, runs and controls.
struct AgentRoutineRunCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let eventID: String

    @State private var opened: JobRow?
    @State private var opening = false
    @State private var notice: String?

    private static let prefix = "agentRun:"
    static func messageID(_ eventID: String) -> String { prefix + eventID }
    static func eventID(_ messageID: String) -> String? {
        messageID.hasPrefix(prefix) ? String(messageID.dropFirst(prefix.count)) : nil
    }

    private var event: AliceEvent? { store.activity.first { $0.id == eventID } }

    var body: some View {
        if let event, let profile = event.profile {
            let failed = event.kind == .automationFailed
            VStack(spacing: 6) {
                if let when = MessageTime.routineCaption(event.occurred) {
                    Text(when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)
                }
                Button { Task { await open(event) } } label: {
                    HStack(spacing: 12) {
                        BotMarkView(mark: store.mark(for: profile), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(failed
                                 ? "\(store.botCurrentName(for: profile))’s routine did not finish"
                                 : "\(store.botCurrentName(for: profile)) ran this routine")
                                .font(.caption)
                                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if opening {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
                    .contentShape(.rect(cornerRadius: 18))
                }
                .buttonStyle(PressableCardStyle())
                .disabled(opening)
                .accessibilityHint("Opens the routine")
            }
            .sheet(item: $opened) { routine in
                RoutineDetailSheet(routine: routine) {}
                    .preferredColorScheme(store.theme.colorScheme)
            }
            .alert("Couldn’t open routine", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private func open(_ event: AliceEvent) async {
        guard let key = event.reference.routineKey, let slash = key.lastIndex(of: "/") else { return }
        Haptic.tap.play()
        let profile = String(key[..<slash])
        let id = String(key[key.index(after: slash)...])
        opening = true
        defer { opening = false }
        do {
            if let routine = try await store.routines(for: profile).first(where: { $0.id == id }) {
                opened = routine
            } else {
                Haptic.error.play()
                notice = String(localized: "That routine no longer exists.")
            }
        } catch {
            Haptic.error.play()
            notice = PlainWords.describe(error, doing: "open the routine")
        }
    }
}


/// The feed post a conversation was opened about (`AppStore.discuss`): quoted, not said.
struct FeedContextCard: View {
    @Environment(\.colorScheme) private var scheme
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("From your feed", systemImage: "newspaper")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(post.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            FeedBodyText(post: post, collapsed: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From your feed: \(post.headline)")
    }
}


/// Decoded once per attachment: the transcript redraws about ten times a second while a reply
/// streams, and each redraw decoded every sent picture twice.
@MainActor
enum AttachmentImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func image(_ attachment: Attachment) -> UIImage? {
        let key = attachment.id as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: attachment.data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
