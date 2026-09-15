import ActivityKit
import Foundation

/// One Live Activity per agent chat at work (`AgentActivityAttributes`),
/// reconciled against what the store knows each time that changes.
///
/// An agent the person set to work gets an activity; while it works, the
/// activity says what it is doing; once it stops, the activity ends saying how
/// — done, failed or stopped — and stays on the Lock Screen for a while. What
/// iOS keeps across launches is the truth: a relaunch picks up the activities
/// already showing instead of starting duplicates.
@MainActor
final class AgentActivities {
    struct Work: Equatable, Sendable {
        let profile: String
        let name: String
        let mark: BotMark
        /// Display names of the agents it is waiting on.
        let waitingOn: [String]
    }

    enum Ending: Sendable {
        case finished, failed, stopped
    }

    /// How long an update is trusted before the activity shows it may be old.
    static let staleAfter: TimeInterval = 15 * 60
    /// How long a finished activity stays on the Lock Screen.
    static let lingers: TimeInterval = 15 * 60

    func sync(working: [Work], ending: (String) -> Ending, now: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Only what an activity says is read here; changing one is left to the
        // bridge below, which finds it again in its own context. ActivityKit's
        // handle is not safe to hand across isolation, and every decision here
        // needs nothing but its state.
        let showing = Activity<AgentActivityAttributes>.activities
            .filter { $0.activityState == .active && !$0.content.state.isDone }
            .reduce(into: [String: AgentActivityAttributes.ContentState]()) { found, activity in
                found[activity.attributes.profile] = activity.content.state
            }

        for work in working {
            let phase: AgentActivityAttributes.ContentState.Phase = work.waitingOn.isEmpty ? .working : .waiting
            let detail = AgentActivityText.waiting(for: work.waitingOn)
            guard let shown = showing[work.profile] else {
                let state = AgentActivityAttributes.ContentState(
                    phase: phase, detail: detail, startedAt: now, endedAt: nil, updatedAt: now
                )
                _ = try? Activity.request(
                    attributes: AgentActivityAttributes(
                        profile: work.profile, name: work.name,
                        colour: work.mark.colour, shape: work.mark.shape
                    ),
                    content: ActivityContent(state: state, staleDate: now + Self.staleAfter),
                    pushType: nil
                )
                continue
            }
            // Refreshed before it goes stale even when nothing changed, so the
            // activity does not start claiming it may be out of date.
            let refreshDue = now.timeIntervalSince(shown.updatedAt) > Self.staleAfter / 3
            guard shown.phase != phase || shown.detail != detail || refreshDue else { continue }
            let state = AgentActivityAttributes.ContentState(
                phase: phase, detail: detail, startedAt: shown.startedAt, endedAt: nil, updatedAt: now
            )
            let profile = work.profile
            let staleDate = now + Self.staleAfter
            Task { await AgentActivityBridge.update(profile: profile, to: state, staleDate: staleDate) }
        }

        let busy = Set(working.map(\.profile))
        for (profile, shown) in showing where !busy.contains(profile) {
            var state = shown
            state.phase = switch ending(profile) {
            case .finished: .finished
            case .failed: .failed
            case .stopped: .stopped
            }
            state.detail = AgentActivityText.ended(state.phase)
            state.endedAt = now
            state.updatedAt = now
            let finished = state
            let dismissAt = now + Self.lingers
            Task { await AgentActivityBridge.end(profile: profile, with: finished, at: dismissAt) }
        }
    }
}

/// Changes an activity where ActivityKit's own handle never has to cross
/// isolation: it is found and used in the same place.
private enum AgentActivityBridge {
    nonisolated static func update(
        profile: String, to state: AgentActivityAttributes.ContentState, staleDate: Date
    ) async {
        guard let activity = current(profile) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated static func end(
        profile: String, with state: AgentActivityAttributes.ContentState, at dismissAt: Date
    ) async {
        guard let activity = current(profile) else { return }
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(dismissAt)
        )
    }

    nonisolated private static func current(_ profile: String) -> Activity<AgentActivityAttributes>? {
        Activity<AgentActivityAttributes>.activities.first {
            $0.attributes.profile == profile && $0.activityState == .active && !$0.content.state.isDone
        }
    }
}
