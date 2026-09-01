import SwiftUI

struct MessageRow: View {
    @Environment(\.colorScheme) private var scheme
    let message: Message

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            switch message.role {
            case .user:
                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    Text("ALICE")
                        .font(.caption2.weight(.medium))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)

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

private struct ToolList: View {
    let tools: [Message.ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tools) { tool in
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 5, height: 5)
                        .foregroundStyle(tool.status == .done ? .secondary : Color.accentColor)
                    Text(tool.name).font(.caption.monospaced())
                    if let detail = tool.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
