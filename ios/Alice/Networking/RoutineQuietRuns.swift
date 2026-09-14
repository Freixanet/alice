import Foundation

/// A routine run that finished with nothing to report.
///
/// Hermes delivers nothing for such a run — the agent answers `[SILENT]` and
/// delivery is suppressed (`cron/scheduler.py`) — so a routine with no news and
/// a routine that never ran looked exactly the same in the bot's chat. Alice
/// finds these runs in the routine's run history and shows a card for each.
struct QuietRoutineRun: Sendable, Equatable, Identifiable {
    let id: String
    let routineName: String
    let finishedAt: Date
}

extension QuietRoutineRun {
    /// How far back a bot's chat looks for runs without news.
    static let window: TimeInterval = 14 * 24 * 60 * 60

    /// Whether a routine's output lands in its bot's chat (`bot-chat`, or
    /// `bot-chat:<profile>`, alone or among other targets).
    static func deliversToBotChat(_ deliver: String?) -> Bool {
        (deliver ?? "").split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("bot-chat")
        }
    }

    /// When a run from `/api/cron/jobs/{id}/runs` finished normally; nil while
    /// it is still going or when it ended any other way (a failure is delivered
    /// by Hermes itself).
    static func finishedAt(_ run: [String: Any]) -> Date? {
        guard (run["end_reason"] as? String) == "cron_complete",
              let ended = (run["ended_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: ended)
    }

    /// The run, when its final answer was silence. `messages` is the latest
    /// page of the run's session, in either order.
    init?(run: [String: Any], messages: [[String: Any]], routineName: String) {
        guard let id = run["id"] as? String, let finished = Self.finishedAt(run) else { return nil }
        let answers = messages.filter {
            ($0["role"] as? String) == "assistant"
                && !(($0["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let final = answers.max(by: { Self.position($0) < Self.position($1) }),
              let text = final["content"] as? String, Self.isSilence(text)
        else { return nil }
        self.init(id: id, routineName: routineName, finishedAt: finished)
    }

    /// Hermes' matcher for an autonomous run with nothing to say
    /// (`gateway/response_filters.is_autonomous_silence_response`): `[SILENT]`
    /// opening the answer, or a marker as the whole answer or its own first or
    /// last line — never mid-sentence.
    static func isSilence(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        if stripped.uppercased().hasPrefix("[SILENT]") { return true }
        let lines = stripped.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return [stripped, lines.first ?? "", lines.last ?? ""].contains { markers.contains(canonical($0)) }
    }

    private static let markers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"]

    private static func canonical(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!*`")))
            .uppercased()
    }

    private static func position(_ message: [String: Any]) -> Double {
        (message["id"] as? NSNumber)?.doubleValue
            ?? (message["timestamp"] as? NSNumber)?.doubleValue
            ?? 0
    }
}

extension DashboardClient {
    /// Runs of `profile`'s bot-chat routines that finished without news since
    /// `since`, and every run id looked at, so a later refresh does not read the
    /// same run's messages again.
    func quietRoutineRuns(
        profile: String, routines: [JobRow], since: Date, skipping judged: Set<String>
    ) async throws -> (quiet: [QuietRoutineRun], judged: Set<String>) {
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~"))) ?? value
        }
        var quiet: [QuietRoutineRun] = []
        var looked: Set<String> = []
        for routine in routines where QuietRoutineRun.deliversToBotChat(routine.deliver) {
            let listing = try await get(
                "api/cron/jobs/\(encoded(routine.id))/runs?profile=\(encoded(profile))&limit=10"
            )
            for run in (listing["runs"] as? [[String: Any]]) ?? [] {
                guard let id = run["id"] as? String, !judged.contains(id),
                      let finished = QuietRoutineRun.finishedAt(run), finished >= since
                else { continue }
                let page = try await get(
                    "api/sessions/\(encoded(id))/messages?profile=\(encoded(profile))&order=latest&limit=4"
                )
                looked.insert(id)
                if let found = QuietRoutineRun(
                    run: run, messages: (page["messages"] as? [[String: Any]]) ?? [],
                    routineName: routine.name
                ) {
                    quiet.append(found)
                }
            }
        }
        return (quiet, looked)
    }
}
