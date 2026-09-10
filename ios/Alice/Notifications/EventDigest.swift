import Foundation

/// Turns two readings of the installation into the events between them.
///
/// Pure on purpose: this is the part that decides what a person gets told, so
/// it must be checkable without a server, a socket, or a phone. The caller
/// supplies the durable state it just read; this says what is new and hands
/// back the watermarks to store.
enum EventDigest {

    /// The result of comparing a reading against what Alice last saw.
    struct Result: Sendable {
        var events: [AliceEvent]
        var watermarks: EventWatermarks
    }

    /// Everything worth telling someone about, given the current routines and
    /// component health.
    ///
    /// The first reading only primes the watermarks. Announcing an
    /// installation's entire existing state the first time Alice looks at it
    /// would be noise, and worse, it would be wrong: none of it just happened.
    static func digest(
        routines: [JobRow],
        components: [HermesSystemComponent],
        since previous: EventWatermarks,
        now: Date = Date()
    ) -> Result {
        var marks = previous
        var events: [AliceEvent] = []

        for row in routines {
            guard let run = row.lastRun else { continue }
            let key = Self.key(for: row)
            let seen = marks.routineRuns[key]
            marks.routineRuns[key] = run
            guard previous.primed, seen == nil || run > seen! else { continue }
            if let event = Self.event(for: row, run: run, key: key) { events.append(event) }
        }

        for component in components {
            let status = component.status.lowercased()
            let seen = marks.componentStatus[component.name]
            marks.componentStatus[component.name] = status
            guard previous.primed, let seen, seen != status else { continue }
            if let event = Self.event(for: component, wasHealthy: Self.healthy(seen), now: now) {
                events.append(event)
            }
        }

        marks.primed = true
        return Result(events: events.sorted { $0.occurred > $1.occurred }, watermarks: marks)
    }

    /// What is wrong *right now*, as opposed to what changed.
    ///
    /// Activity is a record of things that happened; this is current state
    /// that can still be acted on, which is what a status line should count.
    /// Both are derived from the same reading, so they cannot disagree.
    static func attention(
        routines: [JobRow], components: [HermesSystemComponent], now: Date = Date()
    ) -> [AliceEvent] {
        var items: [AliceEvent] = []

        for component in components where !Self.healthy(component.status) {
            let label = Self.label(for: component.name)
            items.append(AliceEvent(
                id: "attention:component:\(component.name)",
                kind: .attention, severity: .needsAttention,
                title: label, summary: Self.consequence(for: component.name),
                detail: [component.status, component.state]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                occurred: now
            ))
        }

        for row in routines where Self.failed(row) == true {
            items.append(AliceEvent(
                id: "attention:routine:\(Self.key(for: row))",
                kind: .automationFailed, severity: .failure, profile: row.profile,
                title: row.name.isEmpty ? "An automation" : row.name,
                summary: "This automation did not finish.",
                detail: Self.failureDetail(row),
                occurred: row.lastRun ?? now,
                reference: AliceEvent.Reference(
                    profile: row.profile, routineKey: Self.key(for: row)
                )
            ))
        }

        return items.sorted { $0.severity > $1.severity }
    }

    /// A routine's identity is the pair, not the id: ids are `uuid4().hex[:12]`
    /// minted per profile store with no cross-profile uniqueness.
    static func key(for row: JobRow) -> String {
        "\(row.profile ?? "default")/\(row.id)"
    }

    private static func event(for row: JobRow, run: Date, key: String) -> AliceEvent? {
        let failed = Self.failed(row)
        // A run Hermes has not classified is not a failure and not a success.
        // Saying either would be inventing the outcome.
        guard failed != nil else { return nil }
        let name = row.name.isEmpty ? "An automation" : row.name
        return AliceEvent(
            id: "routine:\(key):\(Int(run.timeIntervalSince1970))",
            kind: failed! ? .automationFailed : .automationSucceeded,
            severity: failed! ? .failure : .informational,
            profile: row.profile,
            title: name,
            summary: failed!
                ? "This automation did not finish."
                : "This automation finished.",
            detail: failed! ? Self.failureDetail(row) : row.lastStatus,
            occurred: run,
            reference: AliceEvent.Reference(profile: row.profile, routineKey: key)
        )
    }

    /// `nil` when Hermes reported no outcome for the run.
    static func failed(_ row: JobRow) -> Bool? {
        if let error = row.lastError, !error.isEmpty { return true }
        if let delivery = row.lastDeliveryError, !delivery.isEmpty { return true }
        guard let status = row.lastStatus?.lowercased(), !status.isEmpty else { return nil }
        if ["ok", "success", "succeeded", "done", "completed"].contains(status) { return false }
        if ["error", "failed", "failure", "timeout", "cancelled"].contains(status) { return true }
        return nil
    }

    static func failureDetail(_ row: JobRow) -> String? {
        for candidate in [row.lastError, row.lastDeliveryError, row.lastFireError, row.lastStatus] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    private static func event(
        for component: HermesSystemComponent, wasHealthy: Bool, now: Date
    ) -> AliceEvent? {
        let healthy = Self.healthy(component.status)
        guard healthy != wasHealthy else { return nil }
        let label = Self.label(for: component.name)
        return AliceEvent(
            id: "component:\(component.name):\(component.status.lowercased())",
            kind: healthy ? .recovered : .attention,
            severity: healthy ? .informational : .needsAttention,
            profile: nil,
            title: label,
            summary: healthy
                ? "\(label) is working again."
                : Self.consequence(for: component.name),
            detail: [component.status, component.state]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            occurred: now
        )
    }

    /// Hermes reports component status as a word. Only the words it uses for
    /// "this is fine" count as fine; an unfamiliar one is treated as healthy
    /// rather than raising an alarm Alice cannot justify.
    static func healthy(_ status: String) -> Bool {
        !["error", "failed", "failure", "disconnected", "fatal", "stopped",
          "degraded", "unhealthy", "missing", "expired"]
            .contains(status.lowercased())
    }

    /// Hermes' component names are its own vocabulary. Where Alice has a human
    /// word for one it uses it, and where it does not it keeps Hermes' name
    /// rather than inventing something that matches no documentation.
    static func label(for component: String) -> String {
        switch component.lowercased() {
        case "gateway": "Alice's connection"
        case "telegram": "Telegram"
        case "whatsapp": "WhatsApp"
        case "discord": "Discord"
        case "slack": "Slack"
        case "signal": "Signal"
        case "email", "mail": "Email"
        case "cron", "scheduler": "Automations"
        case "mcp": "Integrations"
        case "memory": "Memory"
        case "models", "providers": "Models"
        case "platforms", "messaging", "channels": "Messaging apps"
        case "tools", "toolsets": "Tools"
        case "skills": "Skills"
        case "storage", "disk": "Storage"
        default:
            // Hermes' internal name, made presentable rather than printed raw.
            // "platforms" arriving verbatim, lower-cased, under the sentence
            // "platforms needs attention" told a reader nothing at all.
            component
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    /// What a component being unwell actually means for the person reading.
    ///
    /// "X needs attention" is the shape of a status, not an explanation. Where
    /// Alice knows the consequence it says the consequence; where it does not,
    /// it says plainly that it does not, rather than dressing up a shrug.
    static func consequence(for component: String) -> String {
        switch component.lowercased() {
        case "gateway":
            "Alice can't reach the computer running Hermes, so nothing will run until it's back."
        case "telegram", "whatsapp", "discord", "slack", "signal",
             "platforms", "messaging", "channels":
            "Messages sent through this app won't arrive, and automations that deliver there will fail."
        case "cron", "scheduler":
            "Scheduled automations aren't running right now."
        case "mcp":
            "An integration is disconnected, so the abilities it adds aren't available."
        case "memory":
            "Alice may not remember things it learned about you."
        case "models", "providers":
            "Alice can't reach the service that does the thinking — replies will fail."
        case "storage", "disk":
            "The computer is low on space, which can stop work from being saved."
        default:
            "Hermes reported a problem here. The exact wording is under More details."
        }
    }
}
