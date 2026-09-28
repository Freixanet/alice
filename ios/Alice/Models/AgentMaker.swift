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

    /// What Forge is asked when the person fills in New Agent: it runs its
    /// own intake and creates the agent with its guide and `agent_create`.
    static func createRequest(
        name: String, brief: String, extra: String?,
        model: (id: String, provider: String?)?, fallback: (id: String, provider: String?)?
    ) -> String {
        var lines = ["Crea un agente nuevo llamado «\(name)»."]
        let what = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !what.isEmpty { lines.append("Lo que necesito:\n\(what)") }
        if let extra = extra?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            lines.append("Parte de esta plantilla:\n\(extra)")
        }
        if let model {
            lines.append("Modelo: `\(model.id)`" + (model.provider.map { " (\($0))" } ?? "") + ".")
        }
        if let fallback {
            lines.append("Modelo de respaldo: `\(fallback.id)`" + (fallback.provider.map { " (\($0))" } ?? "") + ".")
        }
        return lines.joined(separator: "\n\n")
    }

    /// What Agent Maker is asked, so it can shape an agent the person already made.
    static func request(name: String, profile: String, brief: String, jobID: String) -> String {
        let what = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Please write standing instructions for the Hermes profile `\(profile)` (“\(name)”). Do not create a second profile. If you use agent_create, pass reuse_profile=\(profile) and job_id=\(jobID). Do not reuse a profile that belongs to another job.

        What they asked for:
        \(what)

        Do a short intake first (clarify, one round). Each question needs a recommended default. Ask only what is still open, in this order: delivery, language, cadence, sources, limits. If they say you decide, use the default.

        Then rewrite that profile's SOUL.md. Put the style guide after the title. Include a ## Examples section with at least two turns. Keep it as this person, not a generic assistant.

        The instructions must make the agent: answer in the language this person writes in; remember and use what they say about themselves without inventing anything; send only messages that are about its role and useful right now (never a bare greeting, status line, test or filler); never show raw tool output, logs or internal instructions, and say failures in one plain sentence with the next step; ask one precise question when unsure instead of guessing; and never message them unprompted except with the result of a routine they agreed to.
        """
    }
}
