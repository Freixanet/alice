import Foundation

extension DashboardClient {
    /// Hermes' own updater, run in the background by its dashboard (the Update button).
    /// `/update` as a slash command timed out: an update rebuilds the TUI, the web UI and the
    /// desktop app, far longer than the slash worker waits.
    func startHermesUpdate() async throws -> (ok: Bool, alreadyRunning: Bool, message: String) {
        let object = try await send("POST", "api/hermes/update")
        return ((object["ok"] as? Bool) == true, (object["already_running"] as? Bool) == true,
                (object["message"] as? String) ?? (object["error"] as? String) ?? "")
    }
}
