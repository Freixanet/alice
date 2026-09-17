import Foundation

/// Shared create/rename vocabulary for the Alice form and Agent Maker.
///
/// The Python engine (`hermes-plugin/agent_engine.py`) is the writer. Alice
/// validates the same rules before it asks Hermes, so a collision or a bad
/// name fails locally instead of minting a silent `-2` slug.
enum AgentProfileID {
    /// Hermes reserved directory names (`hermes_cli.profiles._RESERVED_NAMES`).
    static let reserved: Set<String> = ["hermes", "default", "test", "tmp", "root", "sudo"]

    /// Visible name → Hermes profile id. "Agent Maker" → `agent-maker`.
    ///
    /// Hermes only lowercases; a space would make an invalid id. Alice maps
    /// punctuation to hyphens so the name a person types and the profile
    /// directory still correspond.
    static func slugify(_ display: String) -> String {
        let stripped = display.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !stripped.isEmpty else { return "" }
        if stripped.caseInsensitiveCompare("default") == .orderedSame { return "default" }
        var chars: [Character] = []
        chars.reserveCapacity(stripped.count)
        for ch in stripped {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                chars.append(ch)
            } else {
                chars.append("-")
            }
        }
        let collapsed = String(chars)
            .replacingOccurrences(of: "[-_]{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(64))
    }

    static func parse(_ display: String, explicit: String = "") throws -> String {
        let raw = explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? display : explicit
        let canon = slugify(raw)
        try validate(canon)
        return canon
    }

    static func validate(_ canon: String) throws {
        guard !canon.isEmpty else {
            throw AgentOperationError.invalidName("The name needs at least one letter or number.")
        }
        let allowed = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
        let range = NSRange(canon.startIndex..., in: canon)
        guard allowed.firstMatch(in: canon, range: range) != nil else {
            throw AgentOperationError.invalidName(
                "`\(canon)` is not a valid Hermes profile id. Use lowercase letters, numbers and hyphens."
            )
        }
        if reserved.contains(canon) {
            throw AgentOperationError.invalidName("`\(canon)` is reserved by Hermes. Choose another name.")
        }
    }

    static func note(display: String, id: String) -> String? {
        let shown = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty, shown.lowercased() != id else { return nil }
        return "Alice shows “\(shown)”. Hermes knows this agent as `\(id)`."
    }
}

enum AgentOperationStatus: String, Sendable, Codable, Equatable {
    case completed
    case partial
    case needsAuth = "needs_auth"
    case verificationPending = "verification_pending"
    case verificationFailed = "verification_failed"
    case failed
}

struct AgentSpec: Equatable, Sendable {
    var title: String
    var profileID: String
    var description: String
    var soul: String?
    var tools: [String]?
    var model: String?
    var provider: String?
    var reuseProfile: String?
    var jobID: String
    var source: String
    var slugNote: String?

    static func form(
        title: String,
        description: String,
        soul: String? = nil,
        model: HermesClient.ModelOption? = nil,
        reuseProfile: String? = nil
    ) throws -> AgentSpec {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = try AgentProfileID.parse(trimmed)
        let modelID = model?.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = model?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelID, !modelID.isEmpty {
            guard let provider, !provider.isEmpty else {
                throw AgentOperationError.invalidName("A model needs its provider. Alice will not pick one.")
            }
        }
        return AgentSpec(
            title: trimmed,
            profileID: id,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: soul,
            tools: nil,
            model: modelID?.isEmpty == false ? modelID : nil,
            provider: provider?.isEmpty == false ? provider : nil,
            reuseProfile: reuseProfile,
            jobID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            source: "form",
            slugNote: AgentProfileID.note(display: trimmed, id: id)
        )
    }

    var body: [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "name": profileID,
            "description": description,
            "job_id": jobID,
            "source": source,
            "smoke": false,
        ]
        if let soul, !soul.isEmpty { payload["soul"] = soul }
        if let tools { payload["tools"] = tools }
        if let model { payload["model"] = model }
        if let provider { payload["provider"] = provider }
        if let reuseProfile { payload["reuse_profile"] = reuseProfile }
        return payload
    }
}

struct AgentOperationResult: Equatable, Sendable {
    var status: AgentOperationStatus
    var ok: Bool
    var profileID: String?
    var title: String?
    var confirmed: [String]
    var checks: [String: Bool]
    var error: String?
    var jobID: String?
    var fromID: String?
    var toID: String?
    var reused: Bool
    var slugNote: String?
    var sameID: Bool

    static func parse(_ object: [String: Any]) throws -> AgentOperationResult {
        let rawStatus = object["status"] as? String ?? (object["ok"] as? Bool == true ? "completed" : "failed")
        guard let status = AgentOperationStatus(rawValue: rawStatus) else {
            throw DashboardClient.Failure.unreadable
        }
        let checks: [String: Bool]
        if let raw = object["checks"] as? [String: Any] {
            checks = raw.reduce(into: [:]) { bag, item in
                if let flag = item.value as? Bool { bag[item.key] = flag }
            }
        } else if let raw = object["comprobaciones"] as? [String: Any] {
            checks = raw.reduce(into: [:]) { bag, item in
                if let flag = item.value as? Bool { bag[item.key] = flag }
            }
        } else {
            checks = [:]
        }
        let confirmed = (object["confirmed"] as? [String]) ?? (object["hecho"] as? [String]) ?? []
        return AgentOperationResult(
            status: status,
            ok: (object["ok"] as? Bool) ?? (status == .completed),
            profileID: object["profile_id"] as? String ?? object["name"] as? String,
            title: object["title"] as? String,
            confirmed: confirmed,
            checks: checks,
            error: object["error"] as? String,
            jobID: object["job_id"] as? String,
            fromID: object["from_id"] as? String,
            toID: object["to_id"] as? String,
            reused: (object["reused"] as? Bool) ?? false,
            slugNote: object["slug_note"] as? String,
            sameID: (object["same_id"] as? Bool) ?? false
        )
    }

    /// The profile exists enough to open. Complete success is `status == .completed`.
    var didCreateProfile: Bool {
        confirmed.contains("perfil") || status == .completed || status == .needsAuth
    }

    func requireCreated() throws -> String {
        guard let profileID, !profileID.isEmpty else {
            throw AgentOperationError.remote(error ?? "Hermes did not create the agent.")
        }
        if status == .failed {
            throw AgentOperationError.remote(error ?? "Hermes could not create the agent.")
        }
        return profileID
    }

    func requireRenamed() throws -> (from: String, to: String, sameID: Bool) {
        if status == .failed {
            throw AgentOperationError.remote(error ?? "Hermes could not rename the agent.")
        }
        if sameID {
            return (fromID ?? profileID ?? "", toID ?? profileID ?? "", true)
        }
        guard status == .completed || confirmed.contains("renombrado") else {
            throw AgentOperationError.remote(error ?? "The rename did not finish.")
        }
        let from = fromID ?? ""
        let to = toID ?? profileID ?? ""
        guard !from.isEmpty, !to.isEmpty else {
            throw AgentOperationError.remote(error ?? "Hermes did not return both names.")
        }
        return (from, to, false)
    }
}

enum AgentOperationError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case occupied(String)
    case active(String)
    case remote(String)
    case retired(String)

    var errorDescription: String? {
        switch self {
        case let .invalidName(text), let .occupied(text), let .active(text),
             let .remote(text), let .retired(text):
            text
        }
    }
}
