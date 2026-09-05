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

    init(_ object: [String: Any]) {
        ok = (object["ok"] as? Bool) ?? false
        alreadyRunning = (object["already_running"] as? Bool) ?? false
        message = object["message"] as? String
        error = object["error"] as? String
    }
}

extension HermesClient {
    /// Returns a synthetic assistant reply when the newest user turn is an
    /// explicit self-update command. Nil means "this is ordinary chat".
    ///
    /// The update is launched through Hermes' management endpoint rather than
    /// through an agent terminal tool. That distinction is critical: a tool
    /// call is owned by the process `hermes update` restarts, so waiting for
    /// that tool to return can leave the chat stuck forever. The management
    /// endpoint spawns the updater in the background and returns first.
    func selfUpdateReplyIfRequested(messages: [Turn]) async throws -> String? {
        guard let newestUser = messages.last(where: { $0.role == "user" }),
              case let .text(text) = newestUser.content,
              HermesSelfUpdateIntent.matches(text)
        else { return nil }

        let check = try await checkForSelfUpdate()
        if !check.updateAvailable {
            if let version = check.currentVersion, !version.isEmpty {
                return "Hermes is already up to date (\(version))."
            }
            return check.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Hermes is already up to date."
        }

        guard check.canApply else {
            let guidance = check.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? check.updateCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            return guidance.map { "Hermes found an update, but this installation cannot apply it from the app. \($0)" }
                ?? "Hermes found an update, but this installation cannot apply it from the app."
        }

        let started: HermesUpdateStart
        do {
            started = try await startSelfUpdate()
        } catch let failure as Failure {
            // Once POST has left the phone, a connection reset can simply mean
            // Hermes has already reached the restart phase. Never turn that
            // expected restart gap into another agent/tool attempt.
            switch failure {
            case .unreachable, .timedOut:
                return "The update request was sent. Hermes may be restarting now; reconnect in a moment."
            default:
                throw failure
            }
        }

        guard started.ok else {
            let detail = started.message?.nonEmpty ?? started.error?.nonEmpty
                ?? "Hermes refused the update."
            throw Failure.http(status: 502, detail: detail, limit: nil)
        }
        if started.alreadyRunning {
            return "A Hermes update is already running in the background."
        }
        return "Hermes update started in the background. It can restart its gateway without leaving this chat waiting on a terminal command."
    }

    private func checkForSelfUpdate() async throws -> HermesUpdateCheck {
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

    private func startSelfUpdate() async throws -> HermesUpdateStart {
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
