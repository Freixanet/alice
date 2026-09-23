import SwiftUI

/// The agent's plan for a task, above its reply: every step and where it
/// stands, while the work goes; one quiet line once it is done.
struct TaskPlanCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let plan: TaskPlan
    /// The task is still going: the plan stays open.
    var working: Bool

    @State private var manual: Bool?

    private var expanded: Bool { manual ?? (working && !plan.isFinished) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { manual = !expanded }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.items) { item in
                        row(item)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .animation(.snappy(duration: 0.25), value: plan)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProgressRing(fraction: plan.total == 0 ? 0 : Double(plan.done) / Double(plan.total),
                         tint: store.accent.primary(scheme))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !expanded, let current = plan.current {
                    Text(current.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .frame(minHeight: 30)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if plan.isFinished { return String(localized: "Plan done · \(plan.total) steps") }
        return String(localized: "Plan · \(plan.done) of \(plan.total)")
    }

    private func row(_ item: TaskPlan.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(item.status)
                .font(.footnote)
                .frame(width: 16)
            Text(item.content)
                .font(.footnote)
                .foregroundStyle(item.status == .inProgress ? .primary : .secondary)
                .fontWeight(item.status == .inProgress ? .medium : .regular)
                .strikethrough(item.status == .cancelled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, item.parent == nil ? 0 : 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.content), \(statusLabel(item.status))")
    }

    @ViewBuilder
    private func icon(_ status: TaskPlan.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success(scheme))
        case .inProgress:
            Image(systemName: "circle.inset.filled")
                .foregroundStyle(store.accent.primary(scheme))
                .symbolEffect(.pulse, isActive: working && !reduceMotion)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.tertiary)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func statusLabel(_ status: TaskPlan.Status) -> String {
        switch status {
        case .completed: String(localized: "done")
        case .inProgress: String(localized: "in progress")
        case .cancelled: String(localized: "dropped")
        case .pending: String(localized: "to do")
        }
    }
}

/// A thin ring that fills with the plan.
private struct ProgressRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.snappy(duration: 0.35), value: fraction)
        .accessibilityHidden(true)
    }
}
