import ActivityKit
import Foundation
import OSLog

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
        let conversationID: String
        let profile: String
        let name: String
        let mark: BotMark
        /// Display names of the agents it is waiting on.
        let waitingOn: [String]
        /// Same line the chat shows (`ToolCaption.headline`).
        let headline: String
    }

    /// One work item per conversation. A later item for the same chat replaces
    /// the earlier one; two chats never share a slot.
    nonisolated static func uniqueWorks(_ works: [Work]) -> [String: Work] {
        Dictionary(works.map { ($0.conversationID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Removes that conversation from a map. Safe when it is already gone.
    nonisolated static func removing(_ works: [String: Work], conversationID: String) -> [String: Work] {
        var next = works
        next.removeValue(forKey: conversationID)
        return next
    }

    enum Ending: Sendable {
        case finished, failed, stopped
    }

    /// How long an update is trusted before the activity shows it may be old.
    static let staleAfter: TimeInterval = 10 * 60
    /// How long a finished activity stays on the Lock Screen.
    static let lingers: TimeInterval = 15 * 60

    /// Why the last activity could not start, if it could not. Cleared by the
    /// next one that does.
    private(set) var lastStartFailure: String?
    private let log = Logger(subsystem: "com.freixanet.alice", category: "live-activity")

    func sync(working: [Work], ending: (String) -> Ending, now: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Only what an activity says is read here; changing one is left to the
        // bridge below, which finds it again in its own context. ActivityKit's
        // handle is not safe to hand across isolation, and every decision here
        // needs nothing but its state.
        let requested = Self.uniqueWorks(working)
        let showing = Activity<AgentActivityAttributes>.activities
            .filter { $0.activityState == .active && !$0.content.state.isDone }
            .reduce(into: [String: AgentActivityAttributes.ContentState]()) { found, activity in
                found[Self.key(activity.attributes)] = activity.content.state
            }

        for work in requested.values {
            let phase: AgentActivityAttributes.ContentState.Phase = work.waitingOn.isEmpty ? .working : .waiting
            let detail = work.headline
            guard let shown = showing[work.conversationID] else {
                let state = AgentActivityAttributes.ContentState(
                    phase: phase, detail: detail, startedAt: now, endedAt: nil, updatedAt: now
                )
                do {
                    _ = try Activity.request(
                        attributes: AgentActivityAttributes(
                            profile: work.profile, name: work.name,
                            colour: work.mark.colour, shape: work.mark.shape,
                            conversationID: work.conversationID
                        ),
                        content: ActivityContent(state: state, staleDate: now + Self.staleAfter),
                        pushType: nil
                    )
                    lastStartFailure = nil
                } catch {
                    // iOS refuses for reasons worth knowing — the person turned
                    // Live Activities off, or the system is at its limit. Kept
                    // and logged; the chat itself is unaffected.
                    lastStartFailure = HermesErrors.describe(error, fallback: "\(type(of: error))")
                    log.error("Live Activity for \(work.profile, privacy: .public) could not start: \(self.lastStartFailure ?? "", privacy: .public)")
                }
                continue
            }
            // Refreshed before it goes stale even when nothing changed, so the
            // activity does not start claiming it may be out of date.
            let refreshDue = now.timeIntervalSince(shown.updatedAt) > Self.staleAfter / 3
            guard shown.phase != phase || shown.detail != detail || refreshDue else { continue }
            let state = AgentActivityAttributes.ContentState(
                phase: phase, detail: detail, startedAt: shown.startedAt, endedAt: nil, updatedAt: now
            )
            let conversationID = work.conversationID
            let staleDate = now + Self.staleAfter
            Task { await AgentActivityBridge.update(conversationID: conversationID, to: state, staleDate: staleDate) }
        }

        let busy = Set(requested.keys)
        for (conversationID, shown) in showing where !busy.contains(conversationID) {
            end(conversationID: conversationID, as: ending(conversationID), shown: shown, now: now)
        }
    }

    /// The single close path: success, error, cancel, timeout, or the app
    /// going to the background after the reply has already settled.
    func end(conversationID: String, as ending: Ending = .finished, now: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let shown = Activity<AgentActivityAttributes>.activities.first {
            Self.key($0.attributes) == conversationID
                && $0.activityState == .active && !$0.content.state.isDone
        }?.content.state
        end(conversationID: conversationID, as: ending, shown: shown, now: now)
    }

    private func end(
        conversationID: String, as ending: Ending,
        shown: AgentActivityAttributes.ContentState?, now: Date
    ) {
        var state = shown ?? AgentActivityAttributes.ContentState(
            phase: .finished, detail: "", startedAt: now, endedAt: nil, updatedAt: now
        )
        state.phase = switch ending {
        case .finished: .finished
        case .failed: .failed
        case .stopped: .stopped
        }
        state.detail = AgentActivityText.ended(state.phase)
        state.endedAt = now
        state.updatedAt = now
        let finished = state
        let dismissAt = now + Self.lingers
        Task { await AgentActivityBridge.end(conversationID: conversationID, with: finished, at: dismissAt) }
    }

    nonisolated static func key(_ attributes: AgentActivityAttributes) -> String {
        attributes.conversationID.isEmpty ? attributes.profile : attributes.conversationID
    }
}

/// Changes an activity where ActivityKit's own handle never has to cross
/// isolation: it is found and used in the same place.
private enum AgentActivityBridge {
    nonisolated static func update(
        conversationID: String, to state: AgentActivityAttributes.ContentState, staleDate: Date
    ) async {
        guard let activity = current(conversationID) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated static func end(
        conversationID: String, with state: AgentActivityAttributes.ContentState, at dismissAt: Date
    ) async {
        guard let activity = current(conversationID) else { return }
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(dismissAt)
        )
    }

    nonisolated private static func current(_ conversationID: String) -> Activity<AgentActivityAttributes>? {
        Activity<AgentActivityAttributes>.activities.first {
            AgentActivities.key($0.attributes) == conversationID
                && $0.activityState == .active && !$0.content.state.isDone
        }
    }
}
