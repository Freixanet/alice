import Foundation

/// A command the agent understands, typed into the composer.
struct SlashCommand: Identifiable, Hashable {
    let cmd: String
    let hint: String

    var id: String { cmd }

    init(_ cmd: String, _ hint: String) {
        self.cmd = cmd
        self.hint = hint
    }
}

/// The command list the composer offers, and how a draft narrows it.
///
/// Mirrors `src/lib/slash.ts`, so the phone and the web offer the same
/// vocabulary rather than each drifting toward its own. The two lists are
/// compared by `scripts/check-slash-parity.mjs` on every `npm run check`.
enum Slash {
    static let all: [SlashCommand] = [
        SlashCommand("/new", "Start a new chat"),
        SlashCommand("/control", "Manage Hermes from chat"),
        SlashCommand("/agents", "Agents"),
        SlashCommand("/bot", "Open or create a bot"),
        SlashCommand("/routines", "Routines"),
        SlashCommand("/routine", "Run, pause or resume a routine"),
        SlashCommand("/providers", "Model providers"),
        SlashCommand("/provider", "Connect or disconnect a provider"),
        SlashCommand("/usage", "Usage and cost"),
        SlashCommand("/project", "Use or create a Project"),
        SlashCommand("/model", "Switch model"),
        SlashCommand("/help", "List commands"),
        SlashCommand("/status", "Status of this session"),
        SlashCommand("/update", "Update Hermes"),
        SlashCommand("/tools", "Available tools"),
        SlashCommand("/skills", "Skills"),
        SlashCommand("/memory", "Memory"),
        SlashCommand("/save", "Save the conversation"),
        SlashCommand("/retry", "Retry the last message"),
        SlashCommand("/undo", "Remove the last turn"),
        SlashCommand("/title", "Set the chat title"),
        SlashCommand("/stop", "Stop what’s running"),
        SlashCommand("/plan", "Enter plan mode"),
        SlashCommand("/personality", "Change the tone"),
        SlashCommand("/compress", "Summarize the context"),
        SlashCommand("/clear", "Clear and start over"),
        SlashCommand("/config", "View configuration"),
        SlashCommand("/reasoning", "Reasoning level"),
        SlashCommand("/fast", "Faster replies"),
        SlashCommand("/focus", "Less noise in the reply"),
        SlashCommand("/yolo", "Act without asking"),
        SlashCommand("/approvals", "How to ask for permission"),
        SlashCommand("/browser", "The browser"),
        SlashCommand("/cron", "Scheduled jobs"),
        SlashCommand("/projects", "Projects"),
        SlashCommand("/learn", "Learn a skill"),
        SlashCommand("/resume", "Resume a previous chat"),
        SlashCommand("/sessions", "Your sessions"),
        SlashCommand("/history", "History of this chat"),
        SlashCommand("/context", "How much context is in use"),
        SlashCommand("/agents", "Agents running"),
        SlashCommand("/background", "Start a background task"),
        SlashCommand("/branch", "Branch this chat"),
        SlashCommand("/review", "Review recent work"),
        SlashCommand("/goal", "Session goal"),
        SlashCommand("/steer", "Note mid-reply"),
        SlashCommand("/queue", "Queue the next message"),
        SlashCommand("/bundles", "Skill bundles"),
        SlashCommand("/init", "Prepare the project"),
        SlashCommand("/verbose", "More detail from tools"),
        SlashCommand("/reset", "Same as /new"),
    ]

    /// What the draft is asking for, or nil if it is not asking for a command.
    ///
    /// A command is the whole of a single-line draft: once there is a space
    /// the reader has moved on to writing the command's argument, and a list
    /// of commands is no longer what they need in front of them.
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/"),
              !draft.contains("\n"),
              !draft.contains(" ")
        else { return nil }
        return draft.lowercased()
    }

    /// Everything the draft could still become: a prefix match, or a command
    /// containing what was typed, so "/mo" offers `/model` and "/em" still
    /// finds `/memory`.
    static func matches(_ draft: String) -> [SlashCommand] {
        guard let q = query(draft) else { return [] }
        let body = q.dropFirst()
        return all.filter { item in
            q == "/" || item.cmd.hasPrefix(q) || item.cmd.dropFirst().contains(body)
        }
        .prefix(14)
        .map { $0 }
    }
}
