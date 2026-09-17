import SwiftUI

/// How the reply was arrived at: a trace that runs while the agent works and
/// settles above the answer, still openable.
///
/// What came before showed one line — the step running right now — and threw it
/// away when the reply landed. That kept the chat clean and told the reader
/// nothing afterwards: a reply that searched three sites and read a file looked
/// exactly like one the model wrote from memory. This keeps the steps, under a
/// header that is a single quiet line when closed.
///
/// It opens itself while the agent is working, because that is when the steps
/// answer "what is it doing", and closes when the reply arrives, because by
/// then the reply answers it. Once the reader opens or closes it by hand their
/// choice stands: `manual` is only ever set by a tap.
///
/// A reply with no steps leaves nothing behind. "Thought for 2 seconds" over
/// every answer in the chat is a label on a thing nobody asked about.
struct ThinkingTrace: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// This reply's tool calls, oldest first.
    let steps: [Message.ToolCall]
    /// Whether the reply is still being written.
    let pending: Bool
    /// What the reply is waiting on when it is not the agent thinking: a busy
    /// bot, or a connection being re-made.
    var note: String? = nil
    /// How long the agent worked, once it has stopped.
    var thoughtSeconds: Int? = nil

    @State private var manual: Bool?

    /// The steps worth drawing.
    ///
    /// Clarify is a question for the reader, drawn as buttons further down the
    /// chat. Listing it would leave "Asking a question" sitting in the trace
    /// under an answer the reader has already given.
    private var rows: [Message.ToolCall] {
        steps.filter { !$0.name.lowercased().contains("clarify") }
    }

    private var expanded: Bool { manual ?? pending }

    private var headline: String {
        if pending { return note ?? "Thinking" }
        guard let thoughtSeconds, thoughtSeconds >= 1 else { return "Thought for a moment" }
        return "Thought for \(thoughtSeconds) second\(thoughtSeconds == 1 ? "" : "s")"
    }

    var body: some View {
        if pending || !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded, !rows.isEmpty {
                    trace.transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.3), value: expanded)
            .animation(.snappy(duration: 0.3), value: rows.count)
            .animation(.easeInOut(duration: 0.25), value: pending)
        }
    }

    // ── header ───────────────────────────────────────────────────────────────

    @ViewBuilder private var header: some View {
        if rows.isEmpty {
            headerLine.accessibilityLabel(headline)
        } else {
            Button { manual = !expanded } label: { headerLine }
                .buttonStyle(.plain)
                .accessibilityLabel(headline)
                .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")
        }
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    pending
                        ? AnyShapeStyle(store.accent.primary(scheme))
                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                )
            headlineText
            if !rows.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        }
        // A hairline of text and two small glyphs: without a shape of its own
        // only the ink itself would be tappable.
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    /// The headline, with a band of light crossing it while the agent works.
    ///
    /// Driven by `TimelineView`, not by a repeating animation: a repeating
    /// animation attached to this row is inherited by everything laid out
    /// beside it, which is how the old thinking dot ended up drifting across
    /// the line whenever the row moved. A timeline redraws and animates
    /// nothing, so nothing can inherit it, and it stops dead when the reply
    /// lands.
    @ViewBuilder private var headlineText: some View {
        let label = Text(headline)
            .font(.footnote.weight(.medium))
            .lineLimit(1)

        if pending, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.7) / 1.7
                label
                    .foregroundStyle(.secondary)
                    .overlay {
                        GeometryReader { box in
                            let band = box.size.width * 0.55
                            LinearGradient(
                                colors: [.clear, .primary, .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            // From fully off the left edge to fully past the
                            // right one, so the sweep has no visible start.
                            .offset(x: phase * (box.size.width + band) - band)
                        }
                        .mask(label)
                        .allowsHitTesting(false)
                    }
            }
            .fixedSize()
        } else {
            label.foregroundStyle(pending ? .secondary : .tertiary)
        }
    }

    // ── steps ────────────────────────────────────────────────────────────────

    private var trace: some View {
        HStack(alignment: .top, spacing: 9) {
            // The rule the steps hang from, drawn behind the whole run of them.
            Capsule()
                .fill(Palette.border(scheme))
                .frame(width: 1)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    step(row).transition(.opacity)
                }
            }
        }
        .padding(.leading, 5)
        .padding(.top, 5)
        .padding(.bottom, 2)
    }

    private func step(_ row: Message.ToolCall) -> some View {
        let running = pending && row.status != .done && row.id == rows.last?.id
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if running {
                    StepSpinner(tint: store.accent.primary(scheme))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 11)
            Text(ToolCaption.phrase(for: row, running: running))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The ring that turns beside the step being run.
///
/// A timeline again, and for the same reason as the shimmer: this sits in a row
/// that moves as steps arrive, and an implicit rotation would be inherited by
/// that movement.
private struct StepSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color

    var body: some View {
        if reduceMotion {
            Circle().fill(tint).frame(width: 5, height: 5)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let turn = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.9) / 0.9
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(tint, style: .init(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: 9, height: 9)
        }
    }
}
