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
        SlashCommand("/debug", "Send this phone's diagnostic summary"),
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

    /// Hermes' slash grammar: `/` at the start, a name with no second `/`,
    /// then a space or the end. `/usr/local` is a path; `mira /reasoning` is
    /// prose. Matches `SLASH_COMMAND_RE` in Hermes' shared slash contract.
    static func looksLikeCommand(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return false }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return !name.contains("/")
    }

    /// Canonical name without the slash, lowercased.
    static func commandName(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeCommand(text) else { return "" }
        return String(text.dropFirst().prefix { !$0.isWhitespace }).lowercased()
    }

    /// `/new` and `/reset` start a fresh Alice home chat rather than a Hermes turn.
    static func isLocalNewChat(_ raw: String) -> Bool {
        let name = commandName(raw)
        return name == "new" || name == "reset"
    }
}

/// One option under a slash-command reply. Tapping it sends `command`.
struct SlashChoice: Identifiable, Hashable, Sendable, Codable {
    var label: String
    var command: String
    /// The value already in effect.
    var current: Bool

    var id: String { command }
}

/// Turns a slash command's terminal reply into a sentence and tappable options.
///
/// Hermes prints usage the way a shell does (`<low|medium|high>`, `Run \`/x
/// --confirm\``). Any command that does that — not only `/reasoning` and
/// `/model` — loses the grammar and offers the choices instead.
enum SlashReply {
    struct Presented: Equatable {
        var text: String
        var choices: [SlashChoice]
    }

    static func present(command: String, output: String) -> Presented {
        let cleaned = stripNoise(output)
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var choices = Self.choices(in: lines, command: command)
        markCurrent(&choices, lines: lines, command: command)
        let text = prose(command: command, lines: lines, choices: choices, original: cleaned)
        return Presented(text: text, choices: choices)
    }

    // MARK: - Choices

    private static func choices(in lines: [String], command: String) -> [SlashChoice] {
        let invoked = Slash.commandName(command)
        var found: [SlashChoice] = []
        var seen = Set<String>()

        func add(_ label: String, _ command: String, current: Bool = false) {
            let text = command.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            found.append(SlashChoice(label: label, command: text, current: current))
        }

        let blob = lines.joined(separator: "\n")
        for group in captures(#"[<\[(]([A-Za-z0-9_-]+(?:\|[A-Za-z0-9_-]+)+)[>\]\)]"#, in: blob, group: 1) {
            let line = lines.first { $0.contains(group) } ?? ""
            let options = group.split(separator: "|").map(String.init)
            // `<name|none>` is a template, not a menu. A real menu is every
            // token a person could send as written.
            guard !options.contains(where: { placeholders.contains($0.lowercased()) }) else { continue }
            let base = slashName(in: line).ifEmpty(invoked)
            guard !base.isEmpty else { continue }
            for option in options where option != "status" {
                add(optionLabel(option), "/\(base) \(option)")
            }
        }

        for line in lines {
            guard let list = commaList(line) else { continue }
            let base = slashName(in: line).ifEmpty(invoked)
            guard !base.isEmpty else { continue }
            for option in list where option != "status" {
                add(optionLabel(option), "/\(base) \(option)")
            }
        }

        let roster = lines.compactMap(rosterRow)
        if roster.count >= 2, blob.lowercased().contains("usage:") {
            let base = slashName(in: blob).ifEmpty(invoked)
            if !base.isEmpty {
                for row in roster {
                    add(optionLabel(row.name), "/\(base) \(row.name)", current: row.current)
                }
            }
        }

        for command in concreteCommands(in: blob) {
            add(commandLabel(command), command)
        }

        if let catalog = catalogAction(invoked) {
            for line in lines {
                guard let row = catalogRow(line) else { continue }
                add("\(catalog.verb) \(row.label)", catalog.command + quoted(row.id))
            }
        }
        return found
    }

    /// A bullet Hermes printed as `- **Name** (`id`)` is itself the choice.
    private static func catalogAction(_ command: String) -> (verb: String, command: String)? {
        switch command {
        case "agents", "bots": return ("Open", "/bot open ")
        case "routines": return ("Run", "/routine run ")
        case "projects": return ("Use", "/project use ")
        default: return nil
        }
    }

    private static func catalogRow(_ line: String) -> (label: String, id: String)? {
        guard let match = firstMatch(#"^-\s+\*\*([^*]+)\*\*\s+\(`([^`]+)`\)"#, in: line),
              match.count > 2 else { return nil }
        let label = match[1].trimmingCharacters(in: .whitespaces)
        let id = match[2].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !id.isEmpty else { return nil }
        return (label, id)
    }

    private static let placeholders: Set<String> = [
        "name", "names", "text", "id", "key", "value", "path", "expr", "provider",
        "model", "n", "folder", "title", "prompt", "schedule", "identifier",
        "command", "arg", "args", "name-or-id",
    ]

    private static func commaList(_ line: String) -> [String]? {
        guard let match = firstMatch(
            #"^(?i)(?:valid\b[^:\n]*|available\b[^:\n]*|levels|options)\s*:\s*(.+)$"#,
            in: line
        ), match.count > 1 else { return nil }
        let tokens = match[1].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard tokens.count >= 2, tokens.allSatisfy({ $0.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil }) else {
            return nil
        }
        return tokens
    }

    private static func rosterRow(_ line: String) -> (name: String, current: Bool)? {
        guard let match = firstMatch(#"^\s*(\*)?\s*([A-Za-z][A-Za-z0-9_.-]*)\s+-\s+\S"#, in: line),
              match.count > 2 else { return nil }
        return (match[2], !match[1].isEmpty)
    }

    /// A follow-up the person can run as written. Templates (`<name>`) are not choices.
    private static func concreteCommands(in text: String) -> [String] {
        captures(#"`(/[^`\n]+)`"#, in: text, group: 1).compactMap { raw in
            let command = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty,
                  command.rangeOfCharacter(from: CharacterSet(charactersIn: "<>[]{}")) == nil
            else { return nil }
            return command
        }
    }

    private static func markCurrent(
        _ choices: inout [SlashChoice], lines: [String], command: String
    ) {
        let invoked = Slash.commandName(command)
        var signals: [String] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("/"), !value.contains("|") else { continue }
            let words = value.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
            signals.append(contentsOf: words)
            if value.lowercased().contains("clamp") { signals.append("clamp") }
            if value.lowercased().contains("full") { signals.append("full") }
        }
        for index in choices.indices {
            let option = choices[index].command.split(whereSeparator: \.isWhitespace).last.map(String.init)?.lowercased() ?? ""
            let owner = Slash.commandName(choices[index].command)
            guard owner == invoked || owner.isEmpty else { continue }
            if signals.contains(where: { same($0, option) }) {
                choices[index].current = true
            }
        }
    }

    private static func same(_ signal: String, _ option: String) -> Bool {
        if signal == option { return true }
        switch signal {
        case "off": return option == "hide" || option == "off"
        case "on": return option == "show" || option == "on"
        default: return false
        }
    }

    // MARK: - Prose

    private static func prose(
        command: String, lines: [String], choices: [SlashChoice], original: String
    ) -> String {
        if let special = specialProse(command: command, lines: lines) { return special }
        let consumed = Set(choices.map(\.command))
        var kept: [String] = []
        for line in lines {
            var text = line
            var ateCommand = false
            for command in consumed where text.contains("`\(command)`") {
                text = text.replacingOccurrences(of: "`\(command)`", with: "")
                ateCommand = true
            }
            if ateCommand {
                // The instruction was "Run `/command` to confirm." The command
                // is a button now, so the sentence that only pointed at it goes.
                text = text.replacingOccurrences(
                    of: #"(?i)\s*(?:run|switch with|change one with|try)\b.*$"#,
                    with: "",
                    options: .regularExpression
                )
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || !keep(text, hasChoices: !choices.isEmpty) { continue }
            kept.append(soften(text))
        }
        let body = kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        if !choices.isEmpty { return "Choose one." }
        let fallback = original.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Done." : fallback
    }

    private static func specialProse(command: String, lines: [String]) -> String? {
        let name = Slash.commandName(command)
        let blob = lines.joined(separator: "\n")
        switch name {
        case "reasoning":
            return reasoningProse(blob)
        case "personality":
            return personalityProse(lines, blob: blob)
        case "fast":
            return fastProse(blob)
        case "approvals":
            return approvalsProse(blob)
        case "yolo":
            return yoloProse(blob)
        case "focus":
            return focusProse(blob)
        default:
            return nil
        }
    }

    private static func reasoningProse(_ text: String) -> String? {
        if let set = firstCapture(#"(?i)set to ['\"]?([a-z0-9_-]+)"#, in: text) {
            var sentence = effortSentence(set)
            if text.lowercased().contains("saved") || text.lowercased().contains("global") {
                sentence += " This applies to every chat."
            } else if text.lowercased().contains("session") {
                sentence += " This chat only."
            }
            return sentence
        }
        guard let effort = firstCapture(#"(?i)reasoning effort:\s*([a-z0-9_-]+)"#, in: text) else {
            return nil
        }
        var parts = [effortSentence(effort)]
        if let display = firstCapture(#"(?i)reasoning display:\s*(.+)$"#, in: text) {
            parts.append(displaySentence(display))
        }
        return parts.joined(separator: " ")
    }

    private static func effortSentence(_ level: String) -> String {
        switch level.lowercased() {
        case "none", "disabled":
            return "Alice answers without stopping to think."
        case "minimal":
            return "Alice thinks only a little before answering."
        case "low":
            return "Alice thinks briefly before answering."
        case "medium":
            return "Alice thinks a normal amount before answering."
        case "high":
            return "Alice thinks carefully before answering, so replies take longer."
        case "xhigh", "max", "ultra":
            return "Alice thinks for a long time before answering, so replies take much longer."
        default:
            return "Alice's thinking is set to \(optionLabel(level))."
        }
    }

    private static func displaySentence(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("off") || lower.hasPrefix("hide") {
            return "You don't see that thinking in the chat."
        }
        if lower.contains("full") && !lower.contains("clamp") {
            return "You can read all of that thinking."
        }
        return "You see a short version of that thinking."
    }

    private static func personalityProse(_ lines: [String], blob: String) -> String? {
        if let set = firstCapture(#"(?i)set to ['\"]?([a-z0-9_-]+)"#, in: blob) {
            if set == "none" || set.isEmpty { return "Alice is using her usual tone." }
            return "Alice's tone is now \(optionLabel(set))."
        }
        if blob.lowercased().contains("cleared") { return "Alice is using her usual tone." }
        let roster = lines.compactMap(rosterRow)
        guard !roster.isEmpty else { return nil }
        if let current = roster.first(where: \.current) {
            if current.name == "none" { return "Alice is using her usual tone. Pick another below." }
            return "Alice's tone is \(optionLabel(current.name)). Pick another below."
        }
        return "Pick a tone below."
    }

    private static func fastProse(_ text: String) -> String? {
        guard let value = firstCapture(#"(?i):\s*([a-z]+)\s*$"#, in: text) ?? firstCapture(
            #"(?i)set to ['\"]?([a-z]+)"#, in: text
        ) else { return nil }
        switch value {
        case "normal", "off": return "Replies are at normal speed."
        case "fast", "priority", "on": return "Replies are in fast mode, so they return sooner."
        case "auto": return "Alice picks the speed."
        case "cold": return "Fast mode is resting."
        default: return "Speed is \(optionLabel(value))."
        }
    }

    private static func approvalsProse(_ text: String) -> String? {
        guard let value = firstCapture(#"(?i)approval mode:\s*([a-z]+)"#, in: text) else {
            return text.lowercased().contains("usage:")
                ? "Choose when Alice should ask before a risky action."
                : nil
        }
        switch value {
        case "smart": return "Alice asks only when something looks risky."
        case "manual": return "Alice asks you before anything risky."
        case "off": return "Alice does not ask before risky actions."
        default: return "Alice asks according to \(optionLabel(value))."
        }
    }

    private static func yoloProse(_ text: String) -> String? {
        flagProse(
            text,
            on: "Alice will act without asking, including risky actions.",
            off: "Alice asks before risky actions."
        )
    }

    private static func focusProse(_ text: String) -> String? {
        flagProse(
            text,
            on: "The chat shows your question and the answer.",
            off: "The chat also shows the work behind the answer."
        )
    }

    /// Reads an on/off value from the status, ignoring the usage line that follows.
    private static func flagProse(_ text: String, on: String, off: String) -> String? {
        let status = text.components(separatedBy: "Usage:").first ?? text
        guard let value = firstCapture(#"(?i):\s*(on|off|enabled|disabled)\b"#, in: status) else {
            return nil
        }
        return value == "on" || value == "enabled" ? on : off
    }

    private static func keep(_ line: String, hasChoices: Bool) -> Bool {
        let lower = line.lowercased()
        if lower.contains("usage:") { return false }
        if lower.range(of: #"^(valid|available|levels|options)\b"#, options: .regularExpression) != nil {
            return false
        }
        if isBox(line) { return false }
        if rosterRow(line) != nil { return false }
        if hasChoices, catalogRow(line) != nil { return false }
        if hasChoices, line.rangeOfCharacter(from: CharacterSet(charactersIn: "<>")) != nil { return false }
        let letters = line.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return letters
    }

    private static func isBox(_ line: String) -> Bool {
        let marks = CharacterSet(charactersIn: "+-| ").inverted
        return line.rangeOfCharacter(from: marks) == nil
    }

    private static func soften(_ line: String) -> String {
        var text = line.replacingOccurrences(
            of: #"^\s*\([^A-Za-z)][^)]{0,10}\)\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        guard let match = firstMatch(#"^([^:]{2,40}):\s*(.+)$"#, in: text), match.count > 2 else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        let label = match[1].trimmingCharacters(in: .whitespaces)
        let value = match[2].trimmingCharacters(in: .whitespaces)
        if label.lowercased() == "reasoning effort" { return effortSentence(value.split(separator: " ").first.map(String.init) ?? value) }
        if label.lowercased() == "reasoning display" { return displaySentence(value) }
        return "\(label) is \(value)."
    }

    // MARK: - Labels

    static func optionLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "none": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Maximum"
        case "ultra": return "As much as possible"
        case "show": return "Show thinking"
        case "hide": return "Hide thinking"
        case "full": return "Show it all"
        case "clamp": return "Keep it short"
        case "on": return "On"
        case "off": return "Off"
        case "normal": return "Normal"
        case "fast": return "Fast"
        case "auto": return "Automatic"
        case "cold": return "Resting"
        case "manual": return "Ask first"
        case "smart": return "Only if risky"
        case "queue": return "Wait"
        case "steer": return "Add a note"
        case "interrupt": return "Interrupt"
        default: return HermesClient.prettify(raw)
        }
    }

    private static func commandLabel(_ command: String) -> String {
        if command.contains("--confirm") { return "Confirm" }
        let name = Slash.commandName(command)
        let tokens = command.split(whereSeparator: \.isWhitespace)
        if tokens.count == 1, let hint = Slash.all.first(where: { Slash.commandName($0.cmd) == name })?.hint {
            return hint
        }
        if name == "model", tokens.count >= 3 {
            return HermesClient.prettify(String(tokens[2]))
        }
        return optionLabel(tokens.last.map(String.init) ?? command)
    }

    // MARK: - Small parsing helpers

    private static func slashName(in text: String) -> String {
        firstCapture(#"/([A-Za-z][A-Za-z0-9_-]*)"#, in: text)?.lowercased() ?? ""
    }

    private static func quoted(_ token: String) -> String {
        token.contains(where: \.isWhitespace) ? "\"\(token)\"" : token
    }

    private static func stripNoise(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1b}\[[0-9;]*m"#, with: "", options: .regularExpression)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        let groups = firstMatch(pattern, in: text)
        return groups?.count ?? 0 > 1 ? groups?[1] : nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let found = match.range(at: index)
            guard found.location != NSNotFound, let slice = Range(found, in: text) else { return "" }
            return String(text[slice])
        }
    }

    private static func captures(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges else { return nil }
            let found = match.range(at: group)
            guard found.location != NSNotFound, let slice = Range(found, in: text) else { return nil }
            return String(text[slice])
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
