import Foundation

/// Keep server diagnostics out of the everyday watch controls.
enum WatcherWords {
    static let missingFilter = String(localized: "This watch doesn’t say which emails to check. Ask Alice in chat to add the sender or topic before starting it.")

    static func status(_ status: String, reason: String?, incomplete: Bool) -> String {
        if incomplete { return String(localized: "Needs setup") }
        if status == "active" { return String(localized: "Watching") }
        if status == "paused", reason == "user" { return String(localized: "Paused") }
        return String(localized: "Needs attention")
    }

    static func failure(_ error: Error) -> String {
        if let failure = error as? DashboardClient.Failure, case let .http(status, detail) = failure {
            let text = (detail ?? "").lowercased()
            if text.contains("activation validation failed:") {
                return activationReason(detail ?? "")
            }
            if text.contains("gmail search query") { return missingFilter }
            if text.contains("non-empty watcher script") {
                return String(localized: "This watch has no alert rule yet. Ask Alice in chat to finish setting it up.")
            }
            if text.contains("classifier") || text.contains("cheap") || text.contains("route") {
                return String(localized: "The model used to check your watches isn’t ready. Review Notification setup. Your watch has not been started.")
            }
            if text.contains("gmail") {
                return String(localized: "Alice couldn’t read your email. Check that Gmail is connected to Hermes, then try again.")
            }
            if status == 400 || status == 422 {
                return String(localized: "Alice couldn’t apply this change. Ask her in chat to review this watch’s setup.")
            }
            if status >= 500 {
                return String(localized: "Your Hermes couldn’t complete this change. Try again in a moment.")
            }
        }
        return PlainWords.describe(error)
    }

    static func activationReason(_ detail: String) -> String {
        let prefix = "Activation validation failed: "
        let reason = detail.components(separatedBy: prefix).last ?? detail
        return String(localized: "This watch hasn’t started because its test failed.") + " " + reason
    }

    static func preview(_ rows: [[String: Any]]) -> String {
        if rows.isEmpty { return String(localized: "No matching emails or updates were found. Nothing was sent.") }
        let failed = rows.filter { $0["error"] != nil }.count
        if failed > 0 {
            return String(localized: "The test couldn’t finish checking every item. Nothing was sent. Ask Alice in chat to review this watch.")
        }
        let alerts = rows.filter { ($0["notified"] as? Bool) == true }.count
        let waiting = rows.filter { ($0["notified"] as? Bool) != true && ($0["acked"] as? Bool) != true }.count
        return String(localized: "Items checked: \(rows.count). Alerts Alice would send: \(alerts). Items still undecided: \(waiting). Nothing was sent.")
    }
}
