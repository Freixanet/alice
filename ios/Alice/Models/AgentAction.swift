import Foundation

/// Something an agent did that changed something: sent, scheduled, signed in,
/// saved, deleted.
///
/// Most come from the Alice plugin for Hermes, whose `post_tool_call` hook
/// keeps a record of every call with consequences (`hermes-plugin/action_log.py`)
/// — the kind of action and what it touched, never a message's words. The rest
/// are done on this phone at an agent's suggestion: an event added from a card,
/// or moved with a 👍.
struct AgentAction: Identifiable, Hashable, Sendable, Codable {
    enum Place: String, Hashable, Sendable, Codable {
        case chat, routine, phone
    }

    let id: String
    let at: Date
    /// The Hermes profile: `default` is Alice.
    let profile: String
    let session: String?
    let kind: String
    let target: String
    let ok: Bool
    let place: Place
    /// The chat's or the routine's name.
    let originTitle: String
    /// `profile/job id` for an action a routine took.
    let routineKey: String?
    /// Alice's own conversation, for one done on this phone.
    var conversationID: String? = nil

    static func parse(_ row: [String: Any]) -> AgentAction? {
        guard let id = row["id"] as? String, let kind = row["kind"] as? String, !kind.isEmpty,
              let at = (row["at"] as? Double) ?? (row["at"] as? Int).map(Double.init)
        else { return nil }
        let origin = row["origin"] as? [String: Any]
        let routine = (origin?["place"] as? String) == "routine"
        return AgentAction(
            id: id,
            at: Date(timeIntervalSince1970: at),
            profile: ((row["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "default",
            session: (row["session"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            kind: kind,
            target: (row["target"] as? String) ?? "",
            ok: (row["ok"] as? Bool) ?? true,
            place: routine ? .routine : .chat,
            originTitle: (origin?["title"] as? String) ?? "",
            routineKey: routine ? origin?["routine"] as? String : nil
        )
    }

    /// What it did, in a sentence whose subject is the agent.
    var sentence: String {
        let t = target
        let has = !t.isEmpty
        switch kind {
        case "email.sent": return has ? String(localized: "Sent an email to \(t)") : String(localized: "Sent an email")
        case "email.drafted": return has ? String(localized: "Drafted an email to \(t)") : String(localized: "Drafted an email")
        case "message.sent": return has ? String(localized: "Sent a message to \(t)") : String(localized: "Sent a message")
        case "agent.messaged": return String(localized: "Wrote to \(has ? t : String(localized: "another agent"))")
        case "calendar.created": return String(localized: "Added “\(t)” to the calendar")
        case "calendar.changed": return String(localized: "Changed “\(t)” in the calendar")
        case "calendar.removed": return String(localized: "Removed “\(t)” from the calendar")
        case "routine.created": return String(localized: "Created the routine “\(t)”")
        case "routine.changed": return String(localized: "Changed the routine “\(t)”")
        case "routine.removed": return String(localized: "Deleted the routine “\(t)”")
        case "routine.paused": return String(localized: "Paused the routine “\(t)”")
        case "routine.resumed": return String(localized: "Resumed the routine “\(t)”")
        case "routine.ran": return String(localized: "Ran the routine “\(t)”")
        case "memory.saved":
            return t == "user" ? String(localized: "Remembered something about you")
                : String(localized: "Saved a note to its memory")
        case "memory.updated": return String(localized: "Updated what it remembers")
        case "memory.forgot": return String(localized: "Forgot something it remembered")
        case "skill.created": return String(localized: "Learned a new skill: \(t)")
        case "skill.changed": return String(localized: "Improved the skill \(t)")
        case "skill.removed": return String(localized: "Removed the skill \(t)")
        case "file.written": return String(localized: "Saved \(t)")
        case "file.deleted": return String(localized: "Deleted \(t)")
        case "home.controlled": return String(localized: "Used \(t) at home")
        case "login.used": return String(localized: "Signed in to \(t) for you")
        case "login.saved": return String(localized: "Saved the sign-in for \(t)")
        case "agent.created": return String(localized: "Created the agent \(t)")
        case "agent.renamed": return String(localized: "Renamed an agent to \(t)")
        case "note.saved": return String(localized: "Saved a note")
        case "connector.changed": return String(localized: "Changed a connection: \(t)")
        case "package.installed": return String(localized: "Installed \(t)")
        case "code.pushed": return has ? String(localized: "Pushed code to \(t)") : String(localized: "Pushed code")
        case "settings.changed": return String(localized: "Changed the setting \(t)")
        case "web.sent": return String(localized: "Sent data to \(t)")
        case "phone.calendar.added": return String(localized: "Added “\(t)” to your calendar")
        case "phone.calendar.moved": return String(localized: "Moved “\(t)” in your calendar")
        case "phone.calendar.cancelled": return String(localized: "Cancelled “\(t)” in your calendar")
        default: return has ? String(localized: "Used \(t)") : String(localized: "Did something")
        }
    }

    var symbol: String {
        switch kind {
        case "email.sent", "email.drafted": "envelope"
        case "message.sent": "paperplane"
        case "agent.messaged": "bubble.left.and.bubble.right"
        case "calendar.created", "phone.calendar.added": "calendar.badge.plus"
        case "calendar.changed", "phone.calendar.moved": "calendar.badge.clock"
        case "calendar.removed", "phone.calendar.cancelled": "calendar.badge.minus"
        case _ where kind.hasPrefix("routine."): "clock.arrow.2.circlepath"
        case _ where kind.hasPrefix("memory."): "brain"
        case _ where kind.hasPrefix("skill."): "graduationcap"
        case "file.written": "doc"
        case "file.deleted": "trash"
        case "home.controlled": "house"
        case "login.used", "login.saved": "key"
        case "agent.created", "agent.renamed": "person.crop.circle.badge.plus"
        case "note.saved": "note.text"
        case "connector.changed": "link"
        case "package.installed": "shippingbox"
        case "code.pushed": "arrow.up.circle"
        case "settings.changed": "gearshape"
        case "web.sent": "network"
        default: "bolt"
        }
    }

    /// Actions that reach other people or undo something: worth a second look.
    var weighty: Bool {
        ["email.sent", "message.sent", "file.deleted", "calendar.removed", "routine.removed",
         "skill.removed", "memory.forgot", "login.used", "web.sent", "phone.calendar.cancelled"].contains(kind)
    }
}

/// Days, newest first, for the full list.
enum AgentActionDays {
    static func group(_ actions: [AgentAction], calendar: Calendar = .current) -> [(day: Date, actions: [AgentAction])] {
        let sorted = actions.sorted { $0.at > $1.at }
        var days: [(day: Date, actions: [AgentAction])] = []
        for action in sorted {
            let day = calendar.startOfDay(for: action.at)
            if let last = days.indices.last, days[last].day == day {
                days[last].actions.append(action)
            } else {
                days.append((day, [action]))
            }
        }
        return days
    }
}
