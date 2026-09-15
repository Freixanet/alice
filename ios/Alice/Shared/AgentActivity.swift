import ActivityKit
import Foundation

/// A Live Activity for an agent at work: on the Lock Screen, in the Dynamic
/// Island and at the top of the screen while another app is open.
///
/// Shared by the app, which starts, updates and ends it, and by the widget
/// extension that draws it. Alice has no push for it (a free signing account
/// cannot use push), so iOS lets Alice change it only while Alice runs: the
/// elapsed time counts on its own, and a state Alice could not refresh goes
/// stale and says so rather than passing for current.
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case working, waiting, finished, failed, stopped
        }

        var phase: Phase
        /// What the agent is doing, in a few words: "Waiting for Mercado".
        var detail: String
        var startedAt: Date
        var endedAt: Date?
        var updatedAt: Date

        var isDone: Bool { endedAt != nil }
    }

    let profile: String
    let name: String
    /// The agent's mark (`BotMark`): its colour and silhouette.
    let colour: Int
    let shape: Int
}

enum AgentActivityText {
    static func waiting(for names: [String]) -> String {
        switch names.count {
        case 0: "Working"
        case 1: "Waiting for \(names[0])"
        case 2: "Waiting for \(names[0]) and \(names[1])"
        default: "Waiting for \(names[0]) and \(names.count - 1) more"
        }
    }

    static func ended(_ phase: AgentActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .failed: "Failed"
        case .stopped: "Stopped"
        default: "Done"
        }
    }
}
