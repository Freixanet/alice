import Foundation

/// The agent that writes standing instructions for other agents.
///
/// Hermes still knows it as `forja`. Alice shows **Agent Maker**. The slug is
/// the wire identity; the display name is what a person reads.
enum AgentMaker {
    static let botName = "forja"
    static let displayName = "Agent Maker"

    /// Hermes still stores the profile as `forja`. Alice shows Agent Maker
    /// unless the person (or Hermes) already chose a different title.
    static func displayIfNeeded(profile: String, shown: String) -> String {
        guard profile == botName else { return shown }
        if shown.caseInsensitiveCompare("Forja") == .orderedSame
            || shown.caseInsensitiveCompare(botName) == .orderedSame {
            return displayName
        }
        return shown
    }

    /// What Agent Maker is asked, so it can shape an agent the person already made.
    static func request(name: String, profile: String, brief: String) -> String {
        let what = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Please write standing instructions for the Hermes profile `\(profile)` (“\(name)”). Do not create a second profile.

        What they asked for:
        \(what)

        Do a short intake first (clarify, one round). Each question needs a recommended default. Ask only what is still open, in this order: delivery, language, cadence, sources, limits. If they say you decide, use the default.

        Then rewrite that profile's SOUL.md. Put the style guide after the title. Include a ## Examples section with at least two turns. Keep it as this person, not a generic assistant.
        """
    }
}
