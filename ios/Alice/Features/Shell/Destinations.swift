import Foundation

/// Every place in Alice you can go, and the words a person might use to look
/// for it.
///
/// This exists because search could only find conversations. In an app with
/// thirteen destinations, several of which are named after Hermes internals, a
/// person who does not already know that "MCP" is where integrations live has
/// no way to get there except by opening things until one is right.
///
/// The synonyms are the point. They let someone type what they want —
/// "notifications", "telegram", "cron", "api key" — and arrive at the screen
/// that holds it, without the app having to rename that screen to whatever
/// they happened to type. Hermes' own vocabulary is in here too, so an expert
/// searching "webhook" or "gateway" is served by the same list.
struct AliceDestination: Identifiable, Hashable, Sendable {
    enum Target: String, Sendable {
        case bots, notes, agenda, activity, routines, projects, files, library
        case channels, mcp, skills, tools, webhooks, git, system
        case settings, connect, memory, models, usage, sessions, insights
        case configuration, pairing, plugins
    }

    var id: String { target.rawValue }
    let target: Target
    /// What the row says.
    let title: String
    /// Hermes' name for it, when Alice's differs and the difference matters.
    let technical: String?
    let systemImage: String
    /// Other words for the same thing. Never shown; only matched.
    let synonyms: [String]

    func matches(_ needle: String) -> Bool {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        if title.localizedCaseInsensitiveContains(query) { return true }
        if let technical, technical.localizedCaseInsensitiveContains(query) { return true }
        return synonyms.contains { synonym in
            // Typing part of a word: "notif" finds "notifications".
            if synonym.localizedCaseInsensitiveContains(query) { return true }
            // Typing a sentence: "what it knows about me" contains "knows
            // about me". Guarded by length so a short, common fragment cannot
            // match half the app from inside an unrelated phrase.
            return synonym.count >= 4 && query.localizedCaseInsensitiveContains(synonym)
        }
    }

    static let all: [AliceDestination] = [
        .init(target: .bots, title: "Agents", technical: "Hermes profiles",
              systemImage: "person.2",
              synonyms: ["assistant", "assistants", "agent", "agents", "profile", "profiles", "radar"]),
        .init(target: .notes, title: "Notes", technical: nil,
              systemImage: "note.text",
              synonyms: ["note", "nota", "notas", "memo", "write down", "jot",
                         "apuntar", "idea", "ideas", "thought", "thoughts"]),
        .init(target: .agenda, title: "Agenda", technical: nil,
              systemImage: "calendar",
              synonyms: ["calendar", "calendario", "agenda", "events", "eventos", "appointment", "appointments",
                         "cita", "citas", "reminders", "recordatorios", "to-do", "todo", "pending", "pendientes",
                         "commitments", "compromisos", "schedule today", "what's next", "upcoming", "tomorrow"]),
        .init(target: .activity, title: "Activity", technical: nil,
              systemImage: "bell",
              synonyms: ["notification", "notifications", "alerts", "history",
                         "what happened", "finished", "failed", "attention", "inbox"]),
        .init(target: .routines, title: "Routines", technical: "Cron",
              systemImage: "clock",
              synonyms: ["automation", "automations", "schedule", "scheduled",
                         "cron", "job", "jobs", "daily", "recurring", "timer"]),
        .init(target: .projects, title: "Projects", technical: nil,
              systemImage: "folder",
              synonyms: ["workspace", "workspaces", "folder"]),
        .init(target: .files, title: "Files", technical: "Managed files",
              systemImage: "folder.badge.gearshape",
              synonyms: ["upload", "download", "document", "documents", "filesystem", "workspace"]),
        .init(target: .library, title: "Library", technical: "Artifacts",
              systemImage: "photo.on.rectangle",
              synonyms: ["image", "images", "photo", "artifact", "artifacts", "output"]),
        .init(target: .channels, title: "Channels", technical: "Messaging platforms",
              systemImage: "bubble.left.and.bubble.right",
              synonyms: ["telegram", "whatsapp", "discord", "slack", "signal", "sms",
                         "messaging", "where it can reach me", "reconnect"]),
        .init(target: .mcp, title: "Integrations", technical: "MCP",
              systemImage: "shippingbox",
              synonyms: ["mcp", "integration", "server", "servers", "connector", "connectors", "tool server"]),
        .init(target: .skills, title: "Skills", technical: nil,
              systemImage: "sparkles",
              synonyms: ["skill", "instructions", "capability", "capabilities"]),
        .init(target: .tools, title: "Tools", technical: "Toolsets",
              systemImage: "wrench.adjustable",
              synonyms: ["toolset", "toolsets", "tool"]),
        .init(target: .webhooks, title: "Webhooks", technical: nil,
              systemImage: "link",
              synonyms: ["webhook", "callback", "http hook", "incoming"]),
        .init(target: .git, title: "Git", technical: "Remote development",
              systemImage: "arrow.triangle.branch",
              synonyms: ["repository", "repo", "branch", "commit", "pull request", "pr", "worktree", "github"]),
        .init(target: .system, title: "System", technical: "Health and operations",
              systemImage: "server.rack",
              synonyms: ["health", "status", "diagnostics", "doctor", "logs", "log",
                         "backup", "checkpoint", "restart", "gateway", "update", "version"]),
        .init(target: .memory, title: "Memory", technical: nil,
              systemImage: "brain",
              synonyms: ["remember", "remembers", "knows about me", "user.md", "memory.md", "forget"]),
        .init(target: .models, title: "Models & Providers", technical: nil,
              systemImage: "cpu",
              synonyms: ["model", "provider", "openai", "anthropic", "claude", "gpt",
                         "api key", "intelligence", "which model", "local model", "ollama"]),
        .init(target: .usage, title: "Usage", technical: nil,
              systemImage: "chart.bar",
              synonyms: ["cost", "costs", "spend", "spending", "tokens", "billing", "how much"]),
        .init(target: .sessions, title: "Sessions", technical: nil,
              systemImage: "clock.arrow.circlepath",
              synonyms: ["session", "conversation history", "past work"]),
        .init(target: .insights, title: "Insights", technical: nil,
              systemImage: "chart.line.uptrend.xyaxis",
              synonyms: ["stats", "statistics", "analytics"]),
        .init(target: .configuration, title: "Hermes Configuration", technical: "config.yaml",
              systemImage: "slider.horizontal.3",
              synonyms: ["config", "configuration", "settings file", "env", "environment"]),
        .init(target: .pairing, title: "Pairing", technical: nil,
              systemImage: "person.crop.circle.badge.checkmark",
              synonyms: ["pair", "qr", "device", "connect phone", "invite"]),
        .init(target: .plugins, title: "Plugins", technical: "Agent plugins",
              systemImage: "puzzlepiece.extension",
              synonyms: ["plugin", "extension", "addon", "add-on"]),
        .init(target: .settings, title: "Settings", technical: nil,
              systemImage: "gearshape",
              synonyms: ["preferences", "theme", "appearance", "dark mode"]),
        .init(target: .connect, title: "Connection", technical: "Gateway and dashboard",
              systemImage: "antenna.radiowaves.left.and.right",
              synonyms: ["connect", "disconnected", "offline", "address", "url",
                         "host", "port", "key", "token", "reconnect", "not working"]),
    ]

    static func matching(_ needle: String) -> [AliceDestination] {
        all.filter { $0.matches(needle) }
    }
}
