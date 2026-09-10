import SwiftUI

struct MessageRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let message: Message

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            switch message.role {
            case .user:
                if !message.attachments.isEmpty {
                    SentAttachments(attachments: message.attachments)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    if let bot = message.botName, !bot.isEmpty {
                        HStack(spacing: 6) {
                            // The one moment a thinking face means something:
                            // while this reply is still being written.
                            BotMarkView(
                                mark: store.mark(for: bot),
                                size: 16,
                                animated: message.pending,
                                mood: .thinking,
                                // Sitting on a line with the name: it thinks,
                                // it does not levitate away from it.
                                floats: false
                            )
                            Text(store.botCurrentName(for: bot).uppercased())
                                .font(.caption2.weight(.medium))
                                .tracking(1.4)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("ALICE")
                            .font(.caption2.weight(.medium))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                    }

                    if !message.content.isEmpty {
                        // Markdown, the way every other model surface shows a
                        // reply. `.full` keeps block structure — lists, quotes
                        // and code — instead of collapsing to one line.
                        // No foregroundStyle here. Applied to the Text it
                        // wins over every colour set inside the attributed
                        // string, which repainted the links in the body
                        // colour: tappable, underlined, and indistinguishable
                        // from the prose around them. The colours are set on
                        // the runs instead, body and links alike.
                        Text(attributed)
                            .textSelection(.enabled)
                            // Links are painted from the environment's tint,
                            // not from the colour set on their run — which is
                            // why setting the run's colour changed nothing and
                            // the links kept coming out in the app's accent.
                            // The accent here is Stone: #ECECEA in the dark,
                            // the same near-white as the body.
                            .tint(Palette.link(scheme))
                    }

                    if message.pending || !message.tools.isEmpty {
                        ToolList(
                            tools: message.tools,
                            pending: message.pending && message.approval == nil,
                            hasContent: !message.content.isEmpty
                        )
                    }
                    if let approval = message.approval {
                        RunApprovalCard(messageID: message.id, approval: approval)
                    }
                    if let limit = message.errorLimit {
                        ModelLimitNote(limit: limit)
                    } else if AppStore.agentFailure(in: message.error ?? "") != nil {
                        Text("This is what the last provider Hermes tried said — it may not be the model you picked. Its own fallbacks are tried in order, and only the final failure comes back.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Only once the reply has finished: acting on half an
                    // answer copies or shares something that is still changing.
                    if !message.pending && !message.content.isEmpty {
                        MessageActions(message: message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The reply, with its emphasis but also its shape.
    ///
    /// `.full` parses block structure that `AttributedString` has nowhere to
    /// put: a numbered list came back as one run with the items welded
    /// together — "…en renovación.Amazon: Cupón directo…" — because the
    /// paragraph breaks were understood and then discarded. Inline-only keeps
    /// bold, italics and code while leaving every newline exactly where the
    /// model put it, which is the half of Markdown that survives here.
    private var attributed: AttributedString {
        Self.linkified(
            parsed,
            body: message.error == nil ? Color.primary : Color.red,
            link: Palette.link(scheme)
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
    private static func linkified(
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
            output[range].underlineStyle = .single
        }
        return output
    }

    private var parsed: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(message.content)
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
    let message: Message
    @State private var copied = false

    var body: some View {
        // Every slot carries its own half of the gap, so spacing here is 0
        // and the leading inset pulls the first glyph's ink back onto the
        // paragraph's left edge rather than onto its slot's edge.
        HStack(spacing: 0) {
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

            Button {
                store.retry(message.id)
            } label: {
                ActionIcon("arrow.triangle.2.circlepath", slot: 19.33)
            }
            .disabled(store.isSending)
            .accessibilityLabel("Try again")
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

/// What went out with a message, shown so the conversation is a record of
/// what was actually sent rather than only of what was typed.
private struct SentAttachments: View {
    @Environment(\.colorScheme) private var scheme
    let attachments: [Attachment]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(.rect(cornerRadius: 14))
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

/// What the agent is doing, while it is doing it.
///
/// Every tool call used to be listed and kept, so a reply that searched, read
/// a page and ran a command left a tower of `web_search`, `web_extract`,
/// `terminal` standing under it for ever — a build log where a sentence was
/// wanted. Only the step still running is shown, it is replaced by the next,
/// and when the reply is finished nothing is left behind.
private struct ToolList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let tools: [Message.ToolCall]
    @State private var breathing = false

    /// Whether the reply is still being written.
    let pending: Bool
    /// Whether any of it has arrived. Once the words are appearing the reader
    /// can see for themselves that it is not thinking any more.
    let hasContent: Bool

    /// The last one still going. Hermes reports a tool twice — start, then
    /// done — so anything with a later `done` is behind us.
    private var running: Message.ToolCall? {
        tools.last { $0.status != .done }
    }

    /// What to say. Between two tool calls there is often a real pause while
    /// the model decides what to do next, and showing the finished step would
    /// claim it was still running. Saying it is thinking is both true and
    /// what the gap actually is; the line only disappears when the reply does.
    private var caption: String? {
        if let running { return Self.phrase(for: running) }
        return pending && !hasContent ? "Thinking…" : nil
    }

    var body: some View {
        if let caption {
            HStack(spacing: 8) {
                // Slow enough to read as breathing rather than as blinking:
                // this marks that something is happening, and a fast pulse
                // beside a line of quiet text reads as an alarm.
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(store.accent.primary(scheme))
                    .opacity(breathing ? 0.28 : 1)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: breathing
                    )
                    .onAppear { breathing = true }
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: caption)
        }
    }

    /// A tool's name said as an action.
    ///
    /// `web_extract` tells a reader nothing they wanted to know, and a reader
    /// who does not write software it actively puts off. The names come from
    /// Hermes and change between builds, so an unknown one falls back to its
    /// own words tidied up rather than to a shrug.
    static func phrase(for tool: Message.ToolCall) -> String {
        let name = tool.name.lowercased()
        switch true {
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
        case name.contains("cron"),
             name.contains("job"):          return "Checking its routines…"
        default:
            let words = name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst() + "…"
        }
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
                    .foregroundStyle(Color.red)
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
            Button(label(for: choice)) {
                Task { await store.resolveApproval(messageID: messageID, choice: choice) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(approval.resolving == true)
            .tint(choice == .deny ? .secondary : .primary)
        }
    }

    private func label(for choice: Message.ApprovalChoice) -> String {
        ApprovalExplainer.label(choice)
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

