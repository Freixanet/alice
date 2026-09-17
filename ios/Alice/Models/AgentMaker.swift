import Foundation

/// The agent that designs other agents.
///
/// Identity is the stamped Hermes role `agent-maker`, not a fixed slug. Older
/// installs still live at `forja`; Alice keeps finding them after a rename.
enum AgentMaker {
    static let role = "agent-maker"
    static let legacyProfileID = "forja"
    static let preferredProfileID = "agent-maker"
    static let displayName = "Agent Maker"

    static func matches(profile: String, role: String? = nil) -> Bool {
        if role == Self.role { return true }
        return profile == legacyProfileID
    }

    /// Hermes may still store the profile as `forja`. Alice shows Agent Maker
    /// unless the person (or Hermes) already chose a different title.
    static func displayIfNeeded(profile: String, shown: String, role: String? = nil) -> String {
        guard matches(profile: profile, role: role) else { return shown }
        if shown.caseInsensitiveCompare("Forja") == .orderedSame
            || shown.caseInsensitiveCompare(legacyProfileID) == .orderedSame
            || shown.caseInsensitiveCompare(preferredProfileID) == .orderedSame {
            return displayName
        }
        return shown
    }

    /// What Agent Maker is asked, so it can shape an agent the person already made.
    static func request(name: String, profile: String, brief: String) -> String {
        let what = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Please write standing instructions for the Hermes profile `\(profile)` (“\(name)”). Do not create a second profile. If you use agent_create, pass reuse_profile=\(profile).

        What they asked for:
        \(what)

        Do a short intake first (clarify, one round). Each question needs a recommended default. Ask only what is still open, in this order: delivery, language, cadence, sources, limits. If they say you decide, use the default.

        Then rewrite that profile's SOUL.md. Put the style guide after the title. Include a ## Examples section with at least two turns. Keep it as this person, not a generic assistant.
        """
    }
}
