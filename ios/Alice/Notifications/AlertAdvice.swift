import Foundation

/// Why an alert is there and what can be done about it, in words someone who
/// has never heard of Hermes can act on.
///
/// Activity used to say *what* was wrong — "This automation did not finish",
/// "Messaging apps" — and leave the *why* under More details in Hermes' own
/// vocabulary: `[drift_skip:silent] … global inference config drifted since
/// this job was created …`. Someone reading that learns there is a problem and
/// nothing about what to do, which is the only question they have.
///
/// Derived from what Hermes reported rather than stored, so a row written to
/// disk before this existed is explained the same way as a new one.
struct AlertAdvice: Hashable, Sendable {
    /// Replaces the bare status under the title.
    var headline: String
    /// Why, in plain words.
    var explanation: String
    /// What can be done from here, most useful first.
    var fixes: [Fix]

    enum Fix: Hashable, Sendable {
        case runAgain
        /// Fixes the automation to the assistant's default model as it is when
        /// this is applied — read then, not taken from an old message.
        case useCurrentModel
        /// Fixes the automation back to what it was set up with.
        case keepOriginalModel(name: String?)
        case turnOffChannel(platform: String, profile: String, name: String)
        case open(AliceDestination.Target, label: String)

        var label: String {
            switch self {
            case .runAgain: return "Try again now"
            case .useCurrentModel: return "Use my current model"
            case let .keepOriginalModel(name):
                return name.map { "Keep \($0)" } ?? "Keep the original model"
            case let .turnOffChannel(_, _, name): return "Turn off \(name)"
            case let .open(_, label): return label
            }
        }

        struct Confirmation: Hashable, Sendable {
            var title: String
            var message: String
            var destructive: Bool
        }

        /// Anything that changes Hermes asks first. Moving an automation to
        /// another model can cost money, and switching a channel off stops
        /// messages.
        var confirmation: Confirmation? {
            switch self {
            case .runAgain, .open:
                return nil
            case .useCurrentModel:
                return Confirmation(
                    title: "Use your current model for this automation?",
                    message: "From now on it runs on the model your assistant uses by default. "
                        + "Depending on that model, runs may cost money.",
                    destructive: false
                )
            case .keepOriginalModel:
                return Confirmation(
                    title: "\(label)?",
                    message: "It goes back to the model it was set up with. If that service "
                        + "is no longer connected, the next run will fail and say so here.",
                    destructive: false
                )
            case let .turnOffChannel(_, _, name):
                return Confirmation(
                    title: "Turn off \(name)?",
                    message: "\(name) stops sending and receiving for this assistant. "
                        + "You can turn it back on in Messaging apps.",
                    destructive: true
                )
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case done
        /// Asked for; the result arrives when the run finishes.
        case started
        case failed(String)
    }

    /// The advice an event carries, or the advice its failure text implies.
    static func advice(for event: AliceEvent) -> AlertAdvice? {
        if let advice = event.advice { return advice }
        guard event.kind == .automationFailed, event.standing == .none else { return nil }
        return routineFailure(event.detail)
    }

    // MARK: - Automations

    /// Hermes skipping an automation because the default model changed under
    /// it, as stated in its own message.
    struct Drift: Hashable, Sendable {
        struct Change: Hashable, Sendable {
            var from: String
            var to: String
        }
        var provider: Change?
        var model: Change?
        /// A run-once automation is used up by the skipped attempt, so there is
        /// nothing left to fix.
        var runsOnce: Bool
    }

    static func drift(in text: String) -> Drift? {
        guard text.contains("[drift_skip") else { return nil }
        var drift = Drift(provider: nil, model: nil, runsOnce: text.contains("finite one-shot"))
        guard let regex = try? NSRegularExpression(
            pattern: #"(provider|model) '([^']*)' -> '([^']*)'"#
        ) else { return drift }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let axis = Range(match.range(at: 1), in: text),
                  let from = Range(match.range(at: 2), in: text),
                  let to = Range(match.range(at: 3), in: text)
            else { continue }
            let change = Drift.Change(from: String(text[from]), to: String(text[to]))
            if text[axis] == "provider" { drift.provider = change } else { drift.model = change }
        }
        return drift
    }

    /// A drift skip whose changed parts now have a model of their own.
    ///
    /// Hermes never counts a fixed part as drift, so the automation will run
    /// next time — but its last error stays on record until it does. Without
    /// this, choosing a model would leave the alert asking for the choice that
    /// was just made.
    static func driftIsSettled(_ row: JobRow) -> Bool {
        guard let drift = drift(in: EventDigest.failureDetail(row) ?? ""),
              !drift.runsOnce
        else { return false }
        let provider = drift.provider == nil || row.provider != nil
        let model = drift.model == nil || row.model != nil
        return provider && model
    }

    static func routineFailure(_ detail: String?) -> AlertAdvice {
        let text = detail ?? ""
        if let drift = drift(in: text) { return advice(for: drift) }
        let lower = text.lowercased()

        if contains(lower, ["401", "unauthorized", "invalid api key", "authenticationerror",
                            "authentication failed"]) {
            return AlertAdvice(
                headline: "The AI service didn't accept the sign-in",
                explanation: "The key or login this automation's AI service uses was refused. "
                    + "It may have expired or been removed, and has to be replaced before "
                    + "the automation can run.",
                fixes: [.open(.models, label: "Open Settings")]
            )
        }
        if contains(lower, ["402", "insufficient", "credit", "quota", "429", "rate limit",
                            "ratelimiterror"]) {
            return AlertAdvice(
                headline: "The AI service turned it down",
                explanation: "The AI service refused this run because a usage limit was reached "
                    + "or the account has run out of credit. A limit usually clears after a "
                    + "while; credit has to be topped up with the service.",
                fixes: [.runAgain]
            )
        }
        if contains(lower, ["connection error", "apiconnectionerror", "connecterror",
                            "connection refused", "timed out", "timeout"]) {
            return AlertAdvice(
                headline: "Couldn't reach the AI service",
                explanation: "When this automation started, the service that runs its AI model "
                    + "didn't answer. That is usually temporary. If it keeps happening, the "
                    + "service may be down or the account behind it may need attention.",
                fixes: [.runAgain]
            )
        }
        if lower.contains("deliver") {
            return AlertAdvice(
                headline: "It ran, but the result wasn't sent",
                explanation: "The automation did its work, but sending the result to where it "
                    + "was meant to go failed — often a messaging app that isn't connected.",
                fixes: [.open(.channels, label: "Open messaging apps")]
            )
        }
        return AlertAdvice(
            headline: "Hermes stopped this automation",
            explanation: "Alice doesn't recognise the reason Hermes gave. Its exact words are "
                + "under More details. Trying again sometimes clears it.",
            fixes: [.runAgain]
        )
    }

    private static func advice(for drift: Drift) -> AlertAdvice {
        let from = (drift.model?.from ?? drift.provider?.from).map(shortName)
        let to = (drift.model?.to ?? drift.provider?.to).map(shortName)
        var explanation: String
        if let from, let to {
            explanation = "This automation was set up to use \(from). Your assistant's default "
                + "has since changed to \(to), and Hermes won't move an automation onto a "
                + "different model — which can cost money — without asking you first."
        } else {
            explanation = "Your assistant's default model changed after this automation was set "
                + "up, and Hermes won't move an automation onto a different model — which can "
                + "cost money — without asking you first."
        }
        if drift.runsOnce {
            explanation += " It was set to run only once, so that run is used up; create it "
                + "again if you still need it."
            return AlertAdvice(
                headline: "Skipped to avoid spending on a different model",
                explanation: explanation,
                fixes: [.open(.routines, label: "Open automations")]
            )
        }
        explanation += " It will keep being skipped until you choose."
        return AlertAdvice(
            headline: "Paused to avoid spending on a different model",
            explanation: explanation,
            fixes: [.useCurrentModel, .keepOriginalModel(name: from)]
        )
    }

    // MARK: - Messaging apps

    static func channel(
        platform: String, name: String, profile: String, state: String,
        code: String?, assistant: String?
    ) -> AlertAdvice {
        let whose = assistant.map { " for \($0)" } ?? ""
        let turnOff = Fix.turnOffChannel(platform: platform, profile: profile, name: name)

        if let code, code.contains("not_paired") {
            return AlertAdvice(
                headline: "Turned on, but never linked",
                explanation: "\(name) is switched on\(whose), but no account was ever linked to "
                    + "it, so it can't send or receive anything. If you don't use \(name) with "
                    + "Alice, turn it off and this goes away.",
                fixes: [turnOff, .open(.channels, label: "Link an account")]
            )
        }
        if ["disconnected", "retrying", "reconnecting", "connecting"].contains(state.lowercased()) {
            return AlertAdvice(
                headline: "Lost its connection",
                explanation: "\(name)\(whose) isn't connected right now, so messages through it "
                    + "won't arrive and automations that send there will fail. Hermes keeps "
                    + "retrying on its own; if it doesn't come back, check it in Messaging apps.",
                fixes: [.open(.channels, label: "Open messaging apps")]
            )
        }
        return AlertAdvice(
            headline: "Stopped with an error",
            explanation: "Hermes gave up on \(name)\(whose). Its exact words are under More "
                + "details. If you don't use it, turning it off clears this.",
            fixes: [.open(.channels, label: "Open messaging apps"), turnOff]
        )
    }

    // MARK: - Helpers

    /// `stepfun/step-3.7-flash:free` reads as `step-3.7-flash:free`: the part
    /// before the slash is where the model is hosted, not what it is called.
    static func shortName(_ value: String) -> String {
        String(value.split(separator: "/").last ?? Substring(value))
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
