import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AliceActivitiesBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

/// An agent at work, where the person looks while Alice is not open: the Lock
/// Screen, the Dynamic Island and the top of the screen over other apps.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenAgentView(context: context)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentAvatar(attributes: context.attributes, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: context.state, isStale: context.isStale)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatusLine(state: context.state, isStale: context.isStale)
                        .font(.subheadline)
                }
            } compactLeading: {
                AgentAvatar(attributes: context.attributes, size: 22)
            } compactTrailing: {
                if context.state.isDone {
                    PhaseSymbol(phase: context.state.phase)
                } else {
                    ElapsedTime(state: context.state, isStale: context.isStale)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 44)
                }
            } minimal: {
                AgentAvatar(attributes: context.attributes, size: 20)
            }
        }
    }
}

private struct LockScreenAgentView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            AgentAvatar(attributes: context.attributes, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.name)
                    .font(.headline)
                    .lineLimit(1)
                StatusLine(state: context.state, isStale: context.isStale)
                    .font(.subheadline)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ElapsedTime(state: context.state, isStale: context.isStale)
                    .font(.title2.monospacedDigit().weight(.semibold))
                PhaseSymbol(phase: context.state.phase)
            }
        }
        .padding(16)
    }
}

private struct AgentAvatar: View {
    let attributes: AgentActivityAttributes
    let size: CGFloat

    var body: some View {
        BotMarkView(mark: BotMark(colour: attributes.colour, shape: attributes.shape), size: size)
            .accessibilityHidden(true)
    }
}

/// How long the agent has been at it, counting on its own; once done, how
/// long it took.
private struct ElapsedTime: View {
    let state: AgentActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        // Without news from Alice the clock stops at the last update: counting
        // on said work was going on when nobody knew.
        if let ended = state.endedAt ?? (isStale ? state.updatedAt : nil) {
            Text(Duration.seconds(max(0, ended.timeIntervalSince(state.startedAt))),
                 format: .time(pattern: .minuteSecond))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct StatusLine: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale && !state.isDone {
            // Alice could not check for a while: say so, rather than showing
            // an old status as if it were current.
            Text("No update since \(Text(state.updatedAt, style: .time)) · open Alice")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(state.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct PhaseSymbol: View {
    let phase: AgentActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .working, .waiting:
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.green)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}
