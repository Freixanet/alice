import Foundation

/// What Hermes' `message_agent` leaves in a bot's chat.
///
/// An agent asks another through `message_agent`, which Hermes runs in the
/// background: the asking agent is told to end its turn at once, and the other
/// agent's answer comes back later as a turn addressed to it — "Message from
/// 🤖 forja (@forja): …" — followed by a notice that the background process
/// finished, carrying the raw command and whatever the shell printed. Drawn as
/// they are, the answer read as something the person had written, the notice
/// as a wall of shell errors, and the chat as finished while the other agent
/// was still working.
enum AgentMessages {
    /// A message from another agent, as Hermes attributes it
    /// (`tools/bot_mode_dm.py`).
    struct Incoming: Equatable, Sendable {
        /// The sender's handle, without the @.
        let handle: String
        let body: String
    }

    /// Hermes' notice that a delivery to another agent finished.
    struct Notice: Equatable, Sendable {
        /// The agent it was for, when the command names it.
        let handle: String?
        let succeeded: Bool
    }

    /// Another agent this chat asked, whose answer has not arrived.
    struct Delegation: Equatable, Sendable, Identifiable {
        let handle: String
        let sentAt: Date
        var id: String { "\(handle)|\(sentAt.timeIntervalSince1970)" }
    }

    /// What a bot chat has going on out of sight of this phone.
    struct BackgroundWork: Equatable, Sendable {
        var waitingOn: [Delegation] = []
        /// Hermes is running a turn in the chat that nothing here follows —
        /// an answer that came back woke the agent, or a routine did.
        var running = false
        var isEmpty: Bool { waitingOn.isEmpty && !running }

        /// Without the waits the person stopped: `stopped` is when they stopped
        /// waiting for each agent, and a request sent after that is waited for
        /// again.
        func withoutStopped(_ stopped: [String: Date]) -> BackgroundWork {
            var work = self
            work.waitingOn.removeAll { delegation in
                stopped[delegation.handle].map { delegation.sentAt <= $0 } ?? false
            }
            return work
        }
    }

    /// How long an answer is waited for. Hermes gives a delivery five minutes
    /// to reach a busy agent, and that agent a turn of its own to answer.
    static let patience: TimeInterval = 20 * 60

    static func incoming(_ text: String) -> Incoming? {
        // Hermes' attribution always carries the robot; a person writing
        // "Message from …" does not turn into an agent.
        guard text.hasPrefix("Message from 🤖 "),
              let open = text.range(of: "(@"),
              let close = text.range(of: "):", range: open.upperBound..<text.endIndex),
              !text[text.startIndex..<close.lowerBound].contains("\n")
        else { return nil }
        let handle = String(text[open.upperBound..<close.lowerBound])
        guard !handle.isEmpty, !handle.contains(" ") else { return nil }
        return Incoming(
            handle: handle,
            body: text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func notice(_ text: String) -> Notice? {
        guard text.hasPrefix("[IMPORTANT: Background process"),
              text.contains("bot_mode_dm.py")
        else { return nil }
        let firstLine = text.prefix { $0 != "\n" }
        var handle: String?
        if let flag = text.range(of: " -p ") {
            let name = text[flag.upperBound...].prefix { !$0.isWhitespace }
            handle = normalized(String(name))
        }
        return Notice(
            handle: handle,
            succeeded: firstLine.contains("completed normally") || firstLine.contains("exit code 0")
        )
    }

    /// The answer a delivery notice carries when Hermes handed it back only
    /// there: the asked agent's reply, printed by the delivery between the
    /// shell's start-up chatter and Hermes' session trailer.
    static func noticeAnswer(_ text: String) -> String? {
        guard notice(text) != nil, let output = text.range(of: "\nOutput:\n") else { return nil }
        var lines = text[output.upperBound...].components(separatedBy: "\n")
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            let trailer = line.isEmpty || line == "]" || line.hasPrefix("session_id: ")
                || line.hasPrefix("Resumed session")
                || (line.hasPrefix("Session ") && line.hasSuffix("Starting fresh."))
            guard trailer else { break }
            lines.removeLast()
        }
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty || isStartupNoise(first) {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// What a login shell and Hermes print before the answer: `(anon):setopt:7:
    /// …`, `~/.zshrc:source:118: …`, gitstatus' advice, Hermes' indented warnings.
    private static func isStartupNoise(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[ERROR]") || trimmed.hasPrefix("[WARN") || line.hasPrefix("  ⚠") { return true }
        if trimmed.hasPrefix("GITSTATUS_") || trimmed == "exec zsh"
            || trimmed.hasPrefix("Add the following parameter") || trimmed.hasPrefix("Restart Zsh") {
            return true
        }
        return line.range(of: #"^\S+:[a-z_]+:\d+: "#, options: .regularExpression) != nil
    }

    /// Said in the chat when a delivery ended without an answer.
    static func failure(to handle: String?) -> String {
        let who = handle.map { "@\($0)" } ?? "el otro agente"
        return "⚠️ No llegó la respuesta de \(who): la consulta terminó con un error en Hermes."
    }

    /// A `message_agent` target as the handle its answer is signed with:
    /// `@forja`, `forja@machine` and `peer/forja` are all `forja`.
    static func normalized(_ target: String) -> String? {
        var handle = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        if let at = handle.firstIndex(of: "@") { handle = String(handle[..<at]) }
        if let slash = handle.lastIndex(of: "/") { handle = String(handle[handle.index(after: slash)...]) }
        return handle.isEmpty ? nil : handle
    }

    /// The agents a chat asked that have not answered, from Hermes' projected
    /// history: a `message_agent` call is open until that agent's message, or
    /// the notice that its delivery ended, comes after it.
    static func pending(
        in rows: [[String: Any]], now: Date = Date(), deliverable: (String) -> Bool = { _ in true }
    ) -> [Delegation] {
        delegations(in: rows, now: now, deliverable: deliverable).pending
    }

    /// What a chat's `message_agent` calls came to: the agents still to answer,
    /// and the rows that are answers to something this chat asked — as opposed
    /// to another agent asking this one, which is that agent's business.
    ///
    /// `deliverable` says whether Hermes lets the message go at all. One it
    /// refuses on the spot (an agent outside the sender's team, or no such
    /// agent) leaves nobody to wait for, and Hermes' history keeps the call but
    /// not the refusal.
    static func delegations(
        in rows: [[String: Any]], now: Date = Date(), deliverable: (String) -> Bool = { _ in true }
    ) -> (pending: [Delegation], answers: Set<String>) {
        var waiting: [Delegation] = []
        var answers: Set<String> = []
        var clock: Date?
        for row in rows {
            if let seconds = (row["timestamp"] as? Double) ?? (row["timestamp"] as? NSNumber)?.doubleValue {
                clock = Date(timeIntervalSince1970: seconds)
            }
            switch row["role"] as? String {
            case "tool":
                guard (row["name"] as? String) == "message_agent",
                      let target = (row["args"] as? [String: Any])?["target"] as? String,
                      let handle = normalized(target),
                      deliverable(handle)
                else { continue }
                waiting.append(Delegation(handle: handle, sentAt: clock ?? now))
            case "user":
                guard let text = row["text"] as? String else { continue }
                if let answer = incoming(text) {
                    if settle(answer.handle, in: &waiting), let id = rowID(row) {
                        answers.insert(id)
                    }
                } else if let notice = notice(text) {
                    if let handle = notice.handle {
                        settle(handle, in: &waiting)
                    } else if !waiting.isEmpty {
                        waiting.removeFirst()
                    }
                }
            default:
                continue
            }
        }
        return (waiting.filter { now.timeIntervalSince($0.sentAt) < patience }, answers)
    }

    @discardableResult
    private static func settle(_ handle: String, in waiting: inout [Delegation]) -> Bool {
        let key = normalized(handle) ?? handle
        guard let index = waiting.firstIndex(where: { $0.handle == key }) else { return false }
        waiting.remove(at: index)
        return true
    }

    private static func rowID(_ row: [String: Any]) -> String? {
        if let value = row["row_id"] as? String, !value.isEmpty { return value }
        if let value = row["row_id"] as? Int { return String(value) }
        if let value = row["row_id"] as? NSNumber { return value.stringValue }
        return nil
    }

    /// Whether another agent's message in a chat answers something the chat
    /// asked. Known from Hermes' history once the chat has been read; before
    /// that, from the delivery notice that follows an answer in the chat that
    /// asked — a chat that was only asked never gets one.
    static func isAnswer(
        at index: Int, in messages: [Message], answers: Set<String>
    ) -> Bool {
        guard let from = incoming(messages[index].content) else { return false }
        if let id = messages[index].remoteID, answers.contains(id) { return true }
        for later in messages[(index + 1)...] where later.role == .user {
            if let notice = notice(later.content) {
                if notice.handle == from.handle { return true }
            } else if incoming(later.content) == nil, RoutineReport(later.content) == nil {
                // The person wrote before any notice came.
                return false
            }
        }
        return false
    }
}
