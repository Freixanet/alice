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

                    if message.content.isEmpty && message.pending {
                        TypingIndicator()
                    } else {
                        // Markdown, the way every other model surface shows a
                        // reply. `.full` keeps block structure — lists, quotes
                        // and code — instead of collapsing to one line.
                        Text(attributed)
                            .textSelection(.enabled)
                            .foregroundStyle(message.error == nil ? .primary : Color.red)
                    }

                    if !message.tools.isEmpty { ToolList(tools: message.tools) }
                    if let limit = message.errorLimit { ModelLimitNote(limit: limit) }
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

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
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

private struct ToolList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let tools: [Message.ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tools) { tool in
                if tool.name == RunApprovalBroker.toolName {
                    // The completed event removes the decision surface. The
                    // transcript already records what Hermes did afterwards,
                    // so a permanent "approved" row would only add noise.
                    if tool.status != .done,
                       let approval = RunApprovalPayload.decode(tool.detail) {
                        RunApprovalCard(runID: tool.id, approval: approval)
                    }
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .frame(width: 5, height: 5)
                            .foregroundStyle(
                                tool.status == .done
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(store.accent.primary(scheme))
                            )
                        Text(tool.name).font(.caption.monospaced())
                        if let detail = tool.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// A run approval is an actual pause in Hermes, not prose asking the reader to
/// go somewhere else. Answering here resumes the same run and its existing
/// event stream; the key and endpoint stay inside HermesClient.
private struct RunApprovalCard: View {
    @Environment(\.colorScheme) private var scheme
    let runID: String
    let approval: RunApprovalPayload

    @State private var submitting: String?
    @State private var submitted: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))

            if let detail = approval.detail {
                Text(detail)
                    .font(.footnote)
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

            HStack(spacing: 8) {
                ForEach(approval.choices, id: \.self) { choice in
                    Button(label(for: choice)) {
                        submit(choice)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(submitting != nil || submitted != nil)
                    .tint(choice == "deny" ? .secondary : .primary)
                }
            }

            if let submitted {
                Text("Sent: \(label(for: submitted)). Waiting for Hermes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
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
    }

    private func submit(_ choice: String) {
        submitting = choice
        error = nil
        Task {
            do {
                try await RunApprovalBroker.shared.respond(runID: runID, choice: choice)
                submitted = choice
            } catch {
                self.error = error.localizedDescription
            }
            submitting = nil
        }
    }

    private func label(for choice: String) -> String {
        switch choice {
        case "once": "Once"
        case "session": "Session"
        case "always": "Always"
        case "deny": "Deny"
        default: choice.capitalized
        }
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
        var body = limit.kind == .quota
            ? "You’ve used up your allowance for this model. Waiting won’t help — switch model or top up the provider’s plan."
            : "This model is taking requests too fast right now. It should work again shortly."
        if let seconds = limit.retryAfterSeconds {
            let wait = seconds >= 90 ? "\(Int((Double(seconds) / 60).rounded())) min" : "\(max(1, seconds))s"
            body += " Try again in about \(wait)."
        }
        return body
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.secondary)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                phase += 0.28
            }
        }
        .accessibilityLabel("Alice is responding")
    }
}
