import Foundation

/// A deliberately narrow detector for commands that mean "update Hermes itself".
/// Questions and troubleshooting stay normal chat so mentioning an update can
/// never trigger maintenance by accident.
enum HermesSelfUpdateIntent {
    static func matches(_ value: String) -> Bool {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.lowercased() == "/update" { return true }

        text = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "es_ES")
        )
        text = text
            .replacingOccurrences(of: "[¿?¡!.,;:]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if text.hasPrefix("por favor ") {
            text.removeFirst("por favor ".count)
        }
        for prefix in ["puedes ", "podrias "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }

        let commands: Set<String> = [
            "actualizate",
            "actualizate a la ultima version",
            "actualiza hermes",
            "actualiza hermes a la ultima version",
            "actualiza hermes agent",
            "actualiza hermes agent a la ultima version",
            "actualizar hermes",
            "actualizar hermes a la ultima version",
            "actualizar hermes agent",
            "actualizar hermes agent a la ultima version",
            "update hermes",
            "update hermes a la ultima version",
            "update hermes agent",
            "update hermes agent a la ultima version",
            "upgrade hermes",
            "upgrade hermes a la ultima version",
            "upgrade hermes agent",
            "upgrade hermes agent a la ultima version",
            "instala la ultima actualizacion de hermes",
            "instala ultima actualizacion de hermes",
            "instala la nueva actualizacion de hermes",
            "instala nueva actualizacion de hermes",
            "instala la ultima actualizacion de hermes agent",
            "instala ultima actualizacion de hermes agent",
            "instala la nueva actualizacion de hermes agent",
            "instala nueva actualizacion de hermes agent",
        ]
        return commands.contains(text)
    }
}

struct HermesUpdateCheck: Sendable, Equatable {
    var currentVersion: String?
    var behind: Int?
    var updateAvailable: Bool
    var canApply: Bool
    var message: String?
    var updateCommand: String?

    init(_ object: [String: Any]) {
        currentVersion = object["current_version"] as? String
        behind = (object["behind"] as? NSNumber)?.intValue
        updateAvailable = (object["update_available"] as? Bool) ?? ((behind ?? 0) > 0)
        canApply = (object["can_apply"] as? Bool) ?? true
        message = object["message"] as? String
        updateCommand = object["update_command"] as? String
    }
}

struct HermesUpdateStart: Sendable, Equatable {
    var ok: Bool
    var alreadyRunning: Bool
    var message: String?
    var error: String?
    /// Names this run in the dashboard's action log once it has succeeded.
    var actionID: String?

    init(_ object: [String: Any]) {
        ok = (object["ok"] as? Bool) ?? false
        alreadyRunning = (object["already_running"] as? Bool) ?? false
        message = object["message"] as? String
        error = object["error"] as? String
        actionID = object["action_id"] as? String
    }
}

/// What the dashboard knows about the latest `hermes update`
/// (`GET /api/actions/hermes-update/status`).
struct HermesUpdateStatus: Sendable, Equatable {
    struct Receipt: Sendable, Equatable {
        /// `running`, `success`, `partial`, `failed` or `refused`.
        var outcome: String?
        var startedAt: Date?
        var version: String?
    }

    var running: Bool
    var exitCode: Int?
    /// Set only once a run has completed successfully.
    var actionID: String?
    /// The tail of the update's own output.
    var lines: [String]
    var receipt: Receipt?

    init(_ object: [String: Any]) {
        running = (object["running"] as? Bool) ?? false
        exitCode = (object["exit_code"] as? NSNumber)?.intValue
        actionID = object["action_id"] as? String
        lines = (object["lines"] as? [String]) ?? []
        receipt = (object["receipt"] as? [String: Any]).map {
            Receipt(
                outcome: $0["outcome"] as? String,
                startedAt: Self.date($0["started_at"] as? String),
                version: $0["post_version"] as? String
            )
        }
    }

    /// Hermes writes microseconds, which `ISO8601DateFormatter` does not read.
    /// A second's precision is plenty to tell one run from another.
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

/// Follows one update to its end and decides when that is.
///
/// The dashboard stops and starts again in the middle of an update, and the
/// one that comes back has forgotten the process it launched: it reports
/// "not running" while the updater carries on, and may still be showing the
/// receipt of an earlier run. So a run counts as over only when the dashboard
/// can tie the evidence to this one — its completion marker, or a receipt
/// written after it was asked for.
struct HermesUpdateWatch {
    static let pollInterval: TimeInterval = 5
    /// A gateway drains its running work before restarting, which can be long.
    static let budget: TimeInterval = 20 * 60
    /// The phone's clock and the computer's disagree a little.
    static let clockSlack: TimeInterval = 120
    /// A run that exited without any receipt at all, which only a very early
    /// refusal does: how long to wait for one before believing the exit code.
    static let receiptGrace: TimeInterval = 30

    enum Verdict: Equatable {
        case waiting
        case finished(String)
    }

    let requestedAt: Date
    let actionID: String?
    private var exitedWithoutReceiptSince: Date?

    init(requestedAt: Date, actionID: String?) {
        self.requestedAt = requestedAt
        self.actionID = actionID
    }

    mutating func observe(_ status: HermesUpdateStatus?, at now: Date) -> Verdict {
        if let status, !status.running {
            let receipt = status.receipt.flatMap { receipt -> HermesUpdateStatus.Receipt? in
                guard let started = receipt.startedAt,
                      started >= requestedAt.addingTimeInterval(-Self.clockSlack),
                      receipt.outcome != "running"
                else { return nil }
                return receipt
            }
            if let actionID, status.actionID == actionID {
                return .finished(HermesUpdateOutcome.sentence(
                    outcome: receipt?.outcome ?? "success", version: receipt?.version,
                    exitCode: 0, lines: status.lines
                ))
            }
            if let receipt {
                return .finished(HermesUpdateOutcome.sentence(
                    outcome: receipt.outcome, version: receipt.version,
                    exitCode: status.exitCode, lines: status.lines
                ))
            }
            if status.receipt == nil, status.exitCode != nil {
                let since = exitedWithoutReceiptSince ?? now
                exitedWithoutReceiptSince = since
                if now.timeIntervalSince(since) >= Self.receiptGrace {
                    return .finished(HermesUpdateOutcome.sentence(
                        outcome: nil, version: nil, exitCode: status.exitCode, lines: status.lines
                    ))
                }
            } else {
                exitedWithoutReceiptSince = nil
            }
        } else {
            exitedWithoutReceiptSince = nil
        }
        if now.timeIntervalSince(requestedAt) >= Self.budget {
            return .finished(HermesUpdateOutcome.stillRunning)
        }
        return .waiting
    }
}

/// How an update went, said the way a person would say it.
///
/// The updater's own output is written for someone at a terminal — "Merge
/// conflict between local commits and upstream", a command to run. Only its
/// first "✗" line is read, to tell the common causes apart; anything else is
/// passed on in Hermes' words, after a plain sentence.
enum HermesUpdateOutcome {
    static let stillRunning = "Hermes is still updating — it finishes the work it has running before it restarts. Send /update again in a few minutes to see how it went."

    static func sentence(outcome: String?, version: String?, exitCode: Int?, lines: [String]) -> String {
        let version = version.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        switch outcome {
        case "success":
            return "Done — Hermes is up to date\(version)."
        case "partial":
            return "Hermes updated\(version), but part of it didn’t restart cleanly. If a bot stops answering, restart Hermes on its computer."
        case nil where exitCode == 0:
            return "Done — Hermes is up to date\(version)."
        default:
            return failure(in: thisRun(lines))
        }
    }

    private static func failure(in lines: [String]) -> String {
        let cause = lines.first { $0.contains("✗") }
            .map { $0.replacingOccurrences(of: "✗", with: "").trimmingCharacters(in: .whitespaces) }
        let everything = lines.joined(separator: "\n")
        let unchanged = "Nothing was changed — it keeps running the version it had."

        if everything.contains("No space left on device") {
            return "Hermes couldn’t update: its computer is out of disk space. Free some space there and send /update again."
        }
        guard let cause, !cause.isEmpty else {
            return "Hermes couldn’t finish updating. It keeps running the version it had."
        }
        let lowered = cause.lowercased()
        if lowered.contains("conflict") || lowered.contains("could not stash local changes") {
            return "Hermes couldn’t update: its program files on that computer have been changed by hand, and those changes clash with the new version. \(unchanged)"
        }
        if lowered.contains("network error") || lowered.contains("failed to fetch")
            || lowered.contains("github") {
            return "Hermes couldn’t download the update — it couldn’t reach GitHub. \(unchanged) Try /update again in a few minutes."
        }
        if lowered.contains("syntax error") {
            return "The new version of Hermes arrived damaged, so Hermes went back to the one it had. Try /update again later."
        }
        if lowered.contains("processes are running") || lowered.contains("launcher") {
            return "Hermes couldn’t update while other Hermes windows are open on its computer. Close them and send /update again."
        }
        return "Hermes couldn’t finish updating. It keeps running the version it had. Hermes said: “\(cause)”"
    }

    /// The action log keeps every run; only the latest one is this run.
    private static func thisRun(_ lines: [String]) -> [String] {
        guard let start = lines.lastIndex(where: { $0.contains("=== hermes-update started") }) else {
            return lines
        }
        return Array(lines[lines.index(after: start)...])
    }
}

private enum HermesSelfUpdateSurface {
    case dashboard(DashboardClient)
    case gateway
}

extension HermesClient {
    /// Answers the newest user turn through `say` when it is an explicit
    /// self-update command, and returns true. False means "this is ordinary
    /// chat".
    ///
    /// The update is launched through Hermes' management endpoint rather than
    /// through an agent terminal tool. That distinction is critical: a tool
    /// call is owned by the process `hermes update` restarts, so waiting for
    /// that tool to return can leave the chat stuck forever. The dashboard
    /// endpoint spawns the updater in the background and returns first; Alice
    /// then follows it there to its end, so the reply says how it went.
    func selfUpdateReplyIfRequested(
        messages: [Turn], say: @Sendable (String) -> Void
    ) async throws -> Bool {
        guard let newestUser = messages.last(where: { $0.role == "user" }),
              case let .text(text) = newestUser.content,
              HermesSelfUpdateIntent.matches(text)
        else { return false }

        let (check, surface) = try await selfUpdateCheckAndSurface()
        if !check.updateAvailable {
            if check.behind == 0 {
                if let version = check.currentVersion?.nonEmpty {
                    say("Hermes is already up to date (\(version)).")
                } else {
                    say("Hermes is already up to date.")
                }
            } else {
                say(check.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "Hermes reports that no update is currently available.")
            }
            return true
        }

        guard check.canApply else {
            let guidance = check.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? check.updateCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            say(guidance.map {
                "Hermes found an update, but this installation cannot apply it from the app. \($0)"
            } ?? "Hermes found an update, but this installation cannot apply it from the app.")
            return true
        }

        let requestedAt = Date()
        let started: HermesUpdateStart
        do {
            switch surface {
            case let .dashboard(dashboard):
                started = try await dashboard.startSelfUpdate()
            case .gateway:
                started = try await startSelfUpdateOnGateway()
            }
        } catch let failure as Failure {
            // Once POST has left the phone, a connection reset can simply mean
            // Hermes has already reached the restart phase. Never turn that
            // expected restart gap into another agent/tool attempt.
            switch failure {
            case .unreachable, .timedOut:
                say("The update request was sent. Hermes may be restarting now; reconnect in a moment.")
                return true
            default:
                throw failure
            }
        } catch DashboardClient.Failure.unreachable {
            say("The update request was sent. Hermes may be restarting now; reconnect in a moment.")
            return true
        }

        guard started.ok else {
            let detail = started.message?.nonEmpty ?? started.error?.nonEmpty
                ?? "Hermes refused the update."
            throw Failure.http(status: 502, detail: detail, limit: nil)
        }
        guard case let .dashboard(dashboard) = surface else {
            say(started.alreadyRunning
                ? "A Hermes update is already running in the background."
                : "Hermes update started in the background. It can restart its gateway without leaving this chat waiting on a terminal command.")
            return true
        }

        say(started.alreadyRunning
            ? "A Hermes update is already running. I’ll tell you here how it goes."
            : "Updating Hermes. It can take a few minutes and restarts itself along the way — I’ll tell you here how it goes.")
        // A run already under way began before this request; an hour back
        // still keeps the receipts of long-finished runs out.
        var watch = HermesUpdateWatch(
            requestedAt: started.alreadyRunning ? requestedAt.addingTimeInterval(-3600) : requestedAt,
            actionID: started.actionID
        )
        while true {
            try await Task.sleep(for: .seconds(HermesUpdateWatch.pollInterval))
            // The dashboard restarts during the update; a failed read is that gap.
            let status = try? await dashboard.selfUpdateStatus()
            if case let .finished(sentence) = watch.observe(status, at: Date()) {
                say("\n\n" + sentence)
                return true
            }
        }
    }

    /// Current Hermes exposes the updater on the dashboard, not on the API
    /// gateway at :8642. The app stores that dashboard connection separately,
    /// so use it first. A gateway attempt remains as a compatibility fallback
    /// for deployments that deliberately proxy both surfaces under one origin.
    private func selfUpdateCheckAndSurface() async throws -> (HermesUpdateCheck, HermesSelfUpdateSurface) {
        if let dashboard = await Self.savedDashboardForSelfUpdate() {
            do {
                return (try await dashboard.checkForSelfUpdate(), .dashboard(dashboard))
            } catch {
                // A unified/reverse-proxied install may expose the same route
                // on the connected gateway even if its dashboard login is stale.
                if let gateway = try? await checkForSelfUpdateOnGateway() {
                    return (gateway, .gateway)
                }
                throw error
            }
        }

        do {
            return (try await checkForSelfUpdateOnGateway(), .gateway)
        } catch let failure as Failure {
            switch failure {
            case let .http(status, _, _) where status == 404 || status == 405:
                throw Failure.http(
                    status: status,
                    detail: "Connect your Hermes dashboard in Alice’s Connect screen to update Hermes from the app.",
                    limit: nil
                )
            default:
                throw failure
            }
        }
    }

    private nonisolated static func savedDashboardForSelfUpdate() async -> DashboardClient? {
        // These are the same persisted fields AppStore uses. Reading them here
        // keeps the update path inside the transport, so normal send/pending/
        // persistence behaviour remains unchanged and no UI special case is
        // required.
        let defaults = UserDefaults.standard
        guard let rawURL = defaults.string(forKey: "alice.dashboard")?.nonEmpty,
              let username = defaults.string(forKey: "alice.dashboard.user")?.nonEmpty,
              let password = KeyStore.read(account: "dashboard-password")?.nonEmpty,
              let url = URL(string: rawURL)
        else { return nil }

        let dashboard = DashboardClient()
        await dashboard.use(
            .init(url: url, username: username, password: password)
        )
        return dashboard
    }

    private func checkForSelfUpdateOnGateway() async throws -> HermesUpdateCheck {
        let (data, response) = try await session.data(
            for: try request("api/hermes/update/check?force=true", timeout: 20)
        )
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.badResponse }
        return HermesUpdateCheck(object)
    }

    private func startSelfUpdateOnGateway() async throws -> HermesUpdateStart {
        var call = try request("api/hermes/update", method: "POST", timeout: 20)
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: call)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.badResponse }
        return HermesUpdateStart(object)
    }
}

extension DashboardClient {
    func checkForSelfUpdate() async throws -> HermesUpdateCheck {
        HermesUpdateCheck(try await get("api/hermes/update/check?force=true"))
    }

    func startSelfUpdate() async throws -> HermesUpdateStart {
        HermesUpdateStart(try await send("POST", "api/hermes/update"))
    }

    func selfUpdateStatus() async throws -> HermesUpdateStatus {
        HermesUpdateStatus(try await get("api/actions/hermes-update/status?lines=200"))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
