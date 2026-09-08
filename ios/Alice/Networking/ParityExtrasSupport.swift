import Foundation

struct PairingUser: Identifiable, Hashable, Sendable {
    var id: String { requestID ?? "\(platform)|\(userID)" }
    var platform: String
    var userID: String
    var userName: String?
    var requestID: String?
    var ageMinutes: Double?
}

struct PairingSnapshot: Hashable, Sendable {
    var pending: [PairingUser]
    var approved: [PairingUser]
}

struct HermesPlugin: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var version: String
    var detail: String
    var source: String
    var runtimeStatus: String
    var hasDashboardManifest: Bool
    var path: String
    var canRemove: Bool
    var canUpdateGit: Bool
    var authRequired: Bool
    var authCommand: String
    var userHidden: Bool
}

struct HermesDashboardPlugin: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var label: String
    var detail: String
    var version: String
    var path: String
    var source: String
    var hasAPI: Bool
}

struct HermesContextEngine: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var detail: String
}

struct HermesPluginHub: Hashable, Sendable {
    var plugins: [HermesPlugin]
    var dashboardOnly: [HermesDashboardPlugin]
    var contextEngine: String
    var contextOptions: [HermesContextEngine]
}

struct CredentialPoolEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(index)|\(identifier ?? label ?? source ?? "entry")" }
    var index: Int
    var identifier: String?
    var label: String?
    var authType: String?
    var source: String?
    var priority: Int
    var lastStatus: String?
    var requestCount: Int
    var tokenPreview: String
    var hasRefresh: Bool
}

struct CredentialPoolProvider: Identifiable, Hashable, Sendable {
    var id: String { provider }
    var provider: String
    var entries: [CredentialPoolEntry]
}

struct HermesHook: Identifiable, Hashable, Sendable {
    var id: String { "\(event)|\(command)" }
    var event: String
    var matcher: String?
    var command: String
    var timeout: Int?
    var allowed: Bool
    var approvedAt: String?
    var executable: Bool?
}

struct HermesHooksSnapshot: Hashable, Sendable {
    var hooks: [HermesHook]
    var validEvents: [String]
}

struct HermesCuratorStatus: Hashable, Sendable {
    var enabled: Bool
    var paused: Bool
    var intervalHours: Double?
    var lastRunAt: String?
    var minimumIdleHours: Double?
    var staleAfterDays: Double?
    var archiveAfterDays: Double?
}

struct HermesPortalFeature: Identifiable, Hashable, Sendable {
    var id: String { label }
    var label: String
    var state: String
}

struct HermesPortalStatus: Hashable, Sendable {
    var loggedIn: Bool
    var portalURL: String?
    var inferenceURL: String?
    var provider: String
    var subscriptionURL: String
    var features: [HermesPortalFeature]
}

struct HermesComputerUseCheck: Identifiable, Hashable, Sendable {
    var id: String { label }
    var label: String
    var status: String
    var message: String
}

struct HermesComputerUseStatus: Hashable, Sendable {
    var platform: String
    var platformSupported: Bool
    var installed: Bool
    var version: String?
    var ready: Bool
    var canGrant: Bool
    var checks: [HermesComputerUseCheck]
    var source: String?
    var error: String?
    var accessibility: Bool?
    var screenRecording: Bool?
    var screenRecordingCapturable: Bool?
}

struct CronBlueprintField: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var type: String
    var label: String
    var defaultValue: String?
    var options: [String]
    var optional: Bool
    var strict: Bool
    var help: String
}

struct CronBlueprint: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var detail: String
    var category: String
    var tags: [String]
    var fields: [CronBlueprintField]
    var schedule: String?
    var scheduleHuman: String?
    var command: String
    var appURL: String
}

struct SavedCustomEndpoint: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var models: [String]
    var contextLength: Int?
    var discoverModels: Bool
    var hasAPIKey: Bool
    var APIKeyPreview: String
    var isCurrent: Bool
    var source: String
}

struct SavedCustomEndpointsSnapshot: Hashable, Sendable {
    var endpoints: [SavedCustomEndpoint]
    var currentProvider: String
    var currentModel: String
    var currentBaseURL: String
}

struct CustomEndpointValidation: Hashable, Sendable {
    var ok: Bool
    var reachable: Bool
    var message: String
    var models: [String]
}

struct ProfileAutoDescription: Hashable, Sendable {
    var ok: Bool
    var reason: String?
    var description: String
    var automatic: Bool
}

struct HermesDebugShare: Hashable, Sendable {
    var urls: [String]
    var failures: [String]
    var redacted: Bool
    var autoDeleteSeconds: Int?
}

struct HermesTerminalBackend: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var label: String
    var detail: String
    var active: Bool
    var status: String
    var statusDetail: String
}

struct HermesTerminalBackends: Hashable, Sendable {
    var active: String
    var backends: [HermesTerminalBackend]
}

struct HermesLearningNode: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var kind: String
    var timestamp: Double?
    var category: String?
    var useCount: Int
    var state: String?
    var createdBy: String?
    var pinned: Bool
}

struct HermesLearningCluster: Identifiable, Hashable, Sendable {
    var id: String { category }
    var category: String
    var count: Int
}

struct HermesLearningGraph: Hashable, Sendable {
    var nodes: [HermesLearningNode]
    var clusters: [HermesLearningCluster]
    var edgeCount: Int
    var memoryCount: Int
}

struct HermesLearningNodeDetail: Hashable, Sendable {
    var kind: String
    var id: String
    var label: String
    var content: String
}

extension DashboardClient {
    // MARK: Terminal backend & learning
    func terminalBackends(profile: String = "default") async throws -> HermesTerminalBackends {
        try Self.terminalBackends(from: await get("api/tools/terminal/backends?profile=\(Self.parityQuery(profile))"))
    }

    func setTerminalBackend(_ backend: String, profile: String = "default") async throws {
        let result = try await send("PUT", "api/tools/terminal/backend?profile=\(Self.parityQuery(profile))", ["backend": backend, "profile": profile])
        guard result["ok"] as? Bool == true, Self.parityString(result["backend"]) == backend else { throw Failure.unreadable }
    }

    func learningGraph(profile: String = "default") async throws -> HermesLearningGraph {
        try Self.learningGraph(from: await get("api/learning/graph?profile=\(Self.parityQuery(profile))"))
    }

    func learningNode(_ id: String, profile: String = "default") async throws -> HermesLearningNodeDetail {
        try Self.learningNode(from: await get("api/learning/node?id=\(Self.parityQuery(id))&profile=\(Self.parityQuery(profile))"))
    }

    func saveLearningNode(_ id: String, content: String, profile: String = "default") async throws {
        let result = try await send("PUT", "api/learning/node", ["id": id, "content": content, "profile": profile])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func deleteLearningNode(_ id: String, profile: String = "default") async throws {
        let result = try await send("DELETE", "api/learning/node", ["id": id, "profile": profile])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    // MARK: Pairing
    func pairing(profile: String = "default") async throws -> PairingSnapshot {
        try Self.pairingSnapshot(from: await get("api/pairing?profile=\(Self.parityQuery(profile))"))
    }

    func approvePairing(platform: String, requestID: String? = nil, code: String? = nil, profile: String = "default") async throws {
        var body: [String: Any] = ["platform": platform, "profile": profile]
        if let requestID, !requestID.isEmpty { body["request_id"] = requestID }
        if let code, !code.isEmpty { body["code"] = code }
        let result = try await send("POST", "api/pairing/approve", body)
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func revokePairing(platform: String, userID: String, profile: String = "default") async throws {
        let result = try await send("POST", "api/pairing/revoke", ["platform": platform, "user_id": userID, "profile": profile])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func clearPendingPairing(profile: String = "default") async throws -> Int {
        let result = try await send("POST", "api/pairing/clear-pending?profile=\(Self.parityQuery(profile))")
        guard result["ok"] as? Bool == true, let count = Self.parityInt(result["cleared"]) else { throw Failure.unreadable }
        return count
    }

    // MARK: Plugins
    func pluginHub() async throws -> HermesPluginHub {
        try Self.pluginHub(from: await get("api/dashboard/plugins/hub"))
    }

    func rescanPlugins() async throws -> Int {
        let result = try await get("api/dashboard/plugins/rescan")
        guard result["ok"] as? Bool == true, let count = Self.parityInt(result["count"]) else { throw Failure.unreadable }
        return count
    }

    func installAgentPlugin(identifier: String, force: Bool, enable: Bool) async throws -> [String] {
        let result = try await send("POST", "api/dashboard/agent-plugins/install", ["identifier": identifier, "force": force, "enable": enable])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
        return result["warnings"] as? [String] ?? []
    }

    func setAgentPlugin(_ name: String, enabled: Bool) async throws {
        let verb = enabled ? "enable" : "disable"
        let result = try await send("POST", "api/dashboard/agent-plugins/\(Self.paritySegment(name))/\(verb)")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func updateAgentPlugin(_ name: String) async throws -> String? {
        let result = try await send("POST", "api/dashboard/agent-plugins/\(Self.paritySegment(name))/update")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
        return Self.parityString(result["output"])
    }

    func removeAgentPlugin(_ name: String) async throws {
        let result = try await send("DELETE", "api/dashboard/agent-plugins/\(Self.paritySegment(name))")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func setPluginHidden(_ name: String, hidden: Bool) async throws {
        let result = try await send("POST", "api/dashboard/plugins/\(Self.paritySegment(name))/visibility", ["hidden": hidden])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func setContextEngine(_ name: String) async throws {
        let result = try await send("PUT", "api/dashboard/plugin-providers", ["context_engine": name])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    // MARK: Credentials & hooks
    func credentialPool() async throws -> [CredentialPoolProvider] {
        try Self.credentialPool(from: await get("api/credentials/pool"))
    }

    func addCredentialPool(provider: String, apiKey: String, label: String?) async throws {
        var body: [String: Any] = ["provider": provider, "api_key": apiKey]
        if let label, !label.isEmpty { body["label"] = label }
        let result = try await send("POST", "api/credentials/pool", body)
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func removeCredentialPool(provider: String, index: Int) async throws {
        let result = try await send("DELETE", "api/credentials/pool/\(Self.paritySegment(provider))/\(index)")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func hooks() async throws -> HermesHooksSnapshot {
        try Self.hooksSnapshot(from: await get("api/ops/hooks"))
    }

    func createHook(event: String, command: String, matcher: String?, timeout: Int?, approve: Bool) async throws {
        var body: [String: Any] = ["event": event, "command": command, "approve": approve]
        if let matcher, !matcher.isEmpty { body["matcher"] = matcher }
        if let timeout { body["timeout"] = timeout }
        let result = try await send("POST", "api/ops/hooks", body)
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func deleteHook(event: String, command: String) async throws {
        let result = try await send("DELETE", "api/ops/hooks", ["event": event, "command": command])
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    // MARK: Curator, portal, computer use
    func curatorStatus() async throws -> HermesCuratorStatus {
        try Self.curatorStatus(from: await get("api/curator"))
    }

    func setCuratorPaused(_ paused: Bool) async throws {
        let result = try await send("PUT", "api/curator/paused", ["paused": paused])
        guard result["ok"] as? Bool == true, result["paused"] as? Bool == paused else { throw Failure.unreadable }
    }

    func runCurator() async throws -> HermesActionStart {
        try Self.actionStart(from: await send("POST", "api/curator/run"), fallbackName: "curator-run")
    }

    func portalStatus() async throws -> HermesPortalStatus {
        try Self.portalStatus(from: await get("api/portal"))
    }

    func computerUseStatus(profile: String = "default") async throws -> HermesComputerUseStatus {
        try Self.computerUseStatus(from: await get("api/tools/computer-use/status?profile=\(Self.parityQuery(profile))"))
    }

    func grantComputerUsePermissions(profile: String = "default") async throws -> HermesActionStart {
        try Self.actionStart(from: await send("POST", "api/tools/computer-use/permissions/grant?profile=\(Self.parityQuery(profile))"), fallbackName: "computer-use-grant")
    }

    // MARK: Blueprints
    func cronBlueprints() async throws -> [CronBlueprint] {
        try Self.cronBlueprints(from: await get("api/cron/blueprints"))
    }

    func instantiateCronBlueprint(_ key: String, values: [String: String], profile: String = "default") async throws {
        _ = try await send("POST", "api/cron/blueprints/instantiate?profile=\(Self.parityQuery(profile))", ["blueprint": key, "values": values])
    }

    // MARK: Saved custom endpoints
    func savedCustomEndpoints(profile: String = "default") async throws -> SavedCustomEndpointsSnapshot {
        try Self.savedCustomEndpoints(from: await get("api/providers/custom-endpoints?profile=\(Self.parityQuery(profile))"))
    }

    func saveCustomEndpoint(id: String, name: String, baseURL: String, model: String, apiKey: String?, contextLength: Int?, discoverModels: Bool, makeDefault: Bool, profile: String = "default") async throws -> SavedCustomEndpointsSnapshot {
        var body: [String: Any] = ["id": id, "name": name, "base_url": baseURL, "model": model, "discover_models": discoverModels, "make_default": makeDefault]
        if let apiKey, !apiKey.isEmpty { body["api_key"] = apiKey }
        if let contextLength { body["context_length"] = contextLength }
        return try Self.savedCustomEndpoints(from: await send("POST", "api/providers/custom-endpoints?profile=\(Self.parityQuery(profile))", body))
    }

    func validateCustomEndpoint(name: String, baseURL: String, model: String, apiKey: String?, contextLength: Int?, discoverModels: Bool) async throws -> CustomEndpointValidation {
        var body: [String: Any] = ["name": name, "base_url": baseURL, "model": model, "discover_models": discoverModels]
        if let apiKey, !apiKey.isEmpty { body["api_key"] = apiKey }
        if let contextLength { body["context_length"] = contextLength }
        return try Self.customEndpointValidation(from: await send("POST", "api/providers/custom-endpoints/validate", body))
    }

    func activateCustomEndpoint(_ id: String, profile: String = "default") async throws {
        let result = try await send("POST", "api/providers/custom-endpoints/\(Self.paritySegment(id))/activate?profile=\(Self.parityQuery(profile))")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func deleteCustomEndpoint(_ id: String, profile: String = "default") async throws {
        let result = try await send("DELETE", "api/providers/custom-endpoints/\(Self.paritySegment(id))?profile=\(Self.parityQuery(profile))")
        guard result["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    // MARK: Profile & diagnostics extras
    func importProfileArchive(path: String, name: String? = nil) async throws -> String {
        var body: [String: Any] = ["archive": path]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["name"] = name }
        let result = try await send("POST", "api/profiles/import", body)
        guard result["ok"] as? Bool == true, let imported = Self.parityString(result["name"]) else { throw Failure.unreadable }
        return imported
    }

    func profileSetupCommand(_ name: String) async throws -> String {
        let result = try await get("api/profiles/\(Self.paritySegment(name))/setup-command")
        guard let command = Self.parityString(result["command"]) else { throw Failure.unreadable }
        return command
    }

    func describeProfileAutomatically(_ name: String, overwrite: Bool) async throws -> ProfileAutoDescription {
        let result = try await send("POST", "api/profiles/\(Self.paritySegment(name))/describe-auto", ["overwrite": overwrite])
        guard let ok = result["ok"] as? Bool, let automatic = result["description_auto"] as? Bool else { throw Failure.unreadable }
        return .init(ok: ok, reason: Self.parityString(result["reason"]), description: result["description"] as? String ?? "", automatic: automatic)
    }

    func runConfigMigration() async throws -> HermesActionStart {
        try Self.actionStart(from: await send("POST", "api/ops/config-migrate"), fallbackName: "config-migrate")
    }

    func debugShare(lines: Int = 500, redact: Bool = true) async throws -> HermesDebugShare {
        try Self.debugShare(from: await send("POST", "api/ops/debug-share", ["lines": max(1, min(lines, 5000)), "redact": redact]))
    }

    func resetBuiltinMemory(target: String) async throws -> [String] {
        let result = try await send("POST", "api/memory/reset", ["target": target])
        guard result["ok"] as? Bool == true, let deleted = result["deleted"] as? [String] else { throw Failure.unreadable }
        return deleted
    }

    // MARK: Parsers
    static func terminalBackends(from object: [String: Any]) throws -> HermesTerminalBackends {
        guard let active = parityString(object["active"]), let rows = object["backends"] as? [[String: Any]] else { throw Failure.unreadable }
        let backends = try rows.map { row -> HermesTerminalBackend in
            guard let name = parityString(row["name"]), let label = parityString(row["label"]), let detail = row["description"] as? String, let isActive = row["active"] as? Bool, let status = row["status"] as? String, let statusDetail = row["detail"] as? String else { throw Failure.unreadable }
            return .init(name: name, label: label, detail: detail, active: isActive, status: status, statusDetail: statusDetail)
        }
        return .init(active: active, backends: backends)
    }

    static func learningGraph(from object: [String: Any]) throws -> HermesLearningGraph {
        guard let rows = object["nodes"] as? [[String: Any]], let edges = object["edges"] as? [[String: Any]], let clustersRaw = object["clusters"] as? [[String: Any]], let memory = object["memory"] as? [[String: Any]] else { throw Failure.unreadable }
        let nodes = try rows.map { row -> HermesLearningNode in
            guard let id = parityString(row["id"]), let label = parityString(row["label"]), let kind = parityString(row["kind"]), let useCount = parityInt(row["useCount"]), let pinned = row["pinned"] as? Bool else { throw Failure.unreadable }
            return .init(id: id, label: label, kind: kind, timestamp: parityDouble(row["timestamp"]), category: parityString(row["category"]), useCount: useCount, state: parityString(row["state"]), createdBy: parityString(row["createdBy"]), pinned: pinned)
        }
        let clusters = try clustersRaw.map { row -> HermesLearningCluster in
            guard let category = parityString(row["category"]), let count = parityInt(row["count"]) else { throw Failure.unreadable }
            return .init(category: category, count: count)
        }
        return .init(nodes: nodes, clusters: clusters, edgeCount: edges.count, memoryCount: memory.count)
    }

    static func learningNode(from object: [String: Any]) throws -> HermesLearningNodeDetail {
        guard object["ok"] as? Bool == true, let kind = parityString(object["kind"]), let id = parityString(object["id"]), let label = parityString(object["label"]), let content = object["content"] as? String else { throw Failure.unreadable }
        return .init(kind: kind, id: id, label: label, content: content)
    }

    static func pairingSnapshot(from object: [String: Any]) throws -> PairingSnapshot {
        guard let p = object["pending"] as? [[String: Any]], let a = object["approved"] as? [[String: Any]] else { throw Failure.unreadable }
        return .init(pending: try p.map(pairingUser(from:)), approved: try a.map(pairingUser(from:)))
    }

    static func pairingUser(from row: [String: Any]) throws -> PairingUser {
        guard let platform = parityString(row["platform"]), let userID = parityString(row["user_id"]) else { throw Failure.unreadable }
        return .init(platform: platform, userID: userID, userName: parityString(row["user_name"]), requestID: parityString(row["request_id"]), ageMinutes: parityDouble(row["age_minutes"]))
    }

    static func pluginHub(from object: [String: Any]) throws -> HermesPluginHub {
        guard let rows = object["plugins"] as? [[String: Any]], let orphan = object["orphan_dashboard_plugins"] as? [[String: Any]], let providers = object["providers"] as? [String: Any] else { throw Failure.unreadable }
        let plugins = try rows.map { row -> HermesPlugin in
            guard let name = parityString(row["name"]), let version = row["version"] as? String, let detail = row["description"] as? String, let source = row["source"] as? String, let runtime = row["runtime_status"] as? String, let manifest = row["has_dashboard_manifest"] as? Bool, let path = row["path"] as? String, let canRemove = row["can_remove"] as? Bool, let canUpdate = row["can_update_git"] as? Bool, let authRequired = row["auth_required"] as? Bool, let authCommand = row["auth_command"] as? String, let hidden = row["user_hidden"] as? Bool else { throw Failure.unreadable }
            return .init(name: name, version: version, detail: detail, source: source, runtimeStatus: runtime, hasDashboardManifest: manifest, path: path, canRemove: canRemove, canUpdateGit: canUpdate, authRequired: authRequired, authCommand: authCommand, userHidden: hidden)
        }
        let dashboard = try orphan.map { row -> HermesDashboardPlugin in
            guard let name = parityString(row["name"]), let label = parityString(row["label"]), let detail = row["description"] as? String, let version = row["version"] as? String, let source = row["source"] as? String, let hasAPI = row["has_api"] as? Bool, let tab = row["tab"] as? [String: Any], let path = parityString(tab["path"]) else { throw Failure.unreadable }
            return .init(name: name, label: label, detail: detail, version: version, path: path, source: source, hasAPI: hasAPI)
        }
        let contextRows = providers["context_options"] as? [[String: Any]] ?? []
        let contexts = try contextRows.map { row -> HermesContextEngine in
            guard let name = parityString(row["name"]), let detail = row["description"] as? String else { throw Failure.unreadable }
            return .init(name: name, detail: detail)
        }
        return .init(plugins: plugins, dashboardOnly: dashboard, contextEngine: providers["context_engine"] as? String ?? "compressor", contextOptions: contexts)
    }

    static func credentialPool(from object: [String: Any]) throws -> [CredentialPoolProvider] {
        guard let rows = object["providers"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let provider = parityString(row["provider"]), let entries = row["entries"] as? [[String: Any]] else { throw Failure.unreadable }
            return .init(provider: provider, entries: try entries.map { e in
                guard let index = parityInt(e["index"]), let priority = parityInt(e["priority"]), let requests = parityInt(e["request_count"]), let preview = e["token_preview"] as? String, let refresh = e["has_refresh"] as? Bool else { throw Failure.unreadable }
                return .init(index: index, identifier: parityString(e["id"]), label: parityString(e["label"]), authType: parityString(e["auth_type"]), source: parityString(e["source"]), priority: priority, lastStatus: parityString(e["last_status"]), requestCount: requests, tokenPreview: preview, hasRefresh: refresh)
            })
        }
    }

    static func hooksSnapshot(from object: [String: Any]) throws -> HermesHooksSnapshot {
        guard let rows = object["hooks"] as? [[String: Any]], let events = object["valid_events"] as? [String] else { throw Failure.unreadable }
        return .init(hooks: try rows.map { row in
            guard let event = parityString(row["event"]), let command = parityString(row["command"]), let allowed = row["allowed"] as? Bool else { throw Failure.unreadable }
            return .init(event: event, matcher: parityString(row["matcher"]), command: command, timeout: parityInt(row["timeout"]), allowed: allowed, approvedAt: parityString(row["approved_at"]), executable: row["executable"] as? Bool)
        }, validEvents: events)
    }

    static func curatorStatus(from object: [String: Any]) throws -> HermesCuratorStatus {
        guard let enabled = object["enabled"] as? Bool, let paused = object["paused"] as? Bool else { throw Failure.unreadable }
        return .init(enabled: enabled, paused: paused, intervalHours: parityDouble(object["interval_hours"]), lastRunAt: parityString(object["last_run_at"]), minimumIdleHours: parityDouble(object["min_idle_hours"]), staleAfterDays: parityDouble(object["stale_after_days"]), archiveAfterDays: parityDouble(object["archive_after_days"]))
    }

    static func portalStatus(from object: [String: Any]) throws -> HermesPortalStatus {
        guard let logged = object["logged_in"] as? Bool, let provider = object["provider"] as? String, let subscription = object["subscription_url"] as? String, let rows = object["features"] as? [[String: Any]] else { throw Failure.unreadable }
        let features = try rows.map { row -> HermesPortalFeature in
            guard let label = parityString(row["label"]), let state = row["state"] as? String else { throw Failure.unreadable }
            return .init(label: label, state: state)
        }
        return .init(loggedIn: logged, portalURL: parityString(object["portal_url"]), inferenceURL: parityString(object["inference_url"]), provider: provider, subscriptionURL: subscription, features: features)
    }

    static func computerUseStatus(from object: [String: Any]) throws -> HermesComputerUseStatus {
        guard let platform = object["platform"] as? String, let supported = object["platform_supported"] as? Bool, let installed = object["installed"] as? Bool, let ready = object["ready"] as? Bool, let grant = object["can_grant"] as? Bool, let rows = object["checks"] as? [[String: Any]] else { throw Failure.unreadable }
        let checks = try rows.map { row -> HermesComputerUseCheck in
            guard let label = parityString(row["label"]), let status = row["status"] as? String, let message = row["message"] as? String else { throw Failure.unreadable }
            return .init(label: label, status: status, message: message)
        }
        return .init(platform: platform, platformSupported: supported, installed: installed, version: parityString(object["version"]), ready: ready, canGrant: grant, checks: checks, source: parityString(object["source"]), error: parityString(object["error"]), accessibility: object["accessibility"] as? Bool, screenRecording: object["screen_recording"] as? Bool, screenRecordingCapturable: object["screen_recording_capturable"] as? Bool)
    }

    static func cronBlueprints(from object: [String: Any]) throws -> [CronBlueprint] {
        guard let rows = object["blueprints"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let key = parityString(row["key"]), let title = parityString(row["title"]), let detail = row["description"] as? String, let category = row["category"] as? String, let tags = row["tags"] as? [String], let fieldsRaw = row["fields"] as? [[String: Any]], let command = row["command"] as? String, let appURL = row["appUrl"] as? String else { throw Failure.unreadable }
            let fields = try fieldsRaw.map { field -> CronBlueprintField in
                guard let name = parityString(field["name"]), let type = field["type"] as? String, let label = field["label"] as? String, let options = field["options"] as? [String], let optional = field["optional"] as? Bool, let help = field["help"] as? String else { throw Failure.unreadable }
                return .init(name: name, type: type, label: label, defaultValue: parityString(field["default"]), options: options, optional: optional, strict: field["strict"] as? Bool ?? true, help: help)
            }
            return .init(key: key, title: title, detail: detail, category: category, tags: tags, fields: fields, schedule: parityString(row["schedule"]), scheduleHuman: parityString(row["scheduleHuman"]), command: command, appURL: appURL)
        }
    }

    static func savedCustomEndpoints(from object: [String: Any]) throws -> SavedCustomEndpointsSnapshot {
        guard let rows = object["endpoints"] as? [[String: Any]], let current = object["current"] as? [String: Any] else { throw Failure.unreadable }
        let endpoints = try rows.map { row -> SavedCustomEndpoint in
            guard let id = parityString(row["id"]), let name = parityString(row["name"]), let base = parityString(row["base_url"]), let model = row["model"] as? String, let models = row["models"] as? [String], let discover = row["discover_models"] as? Bool, let hasKey = row["has_api_key"] as? Bool, let preview = row["api_key_preview"] as? String, let isCurrent = row["is_current"] as? Bool, let source = row["source"] as? String else { throw Failure.unreadable }
            return .init(id: id, name: name, baseURL: base, model: model, models: models, contextLength: parityInt(row["context_length"]), discoverModels: discover, hasAPIKey: hasKey, APIKeyPreview: preview, isCurrent: isCurrent, source: source)
        }
        return .init(endpoints: endpoints, currentProvider: current["provider"] as? String ?? "", currentModel: current["model"] as? String ?? "", currentBaseURL: current["base_url"] as? String ?? "")
    }

    static func customEndpointValidation(from object: [String: Any]) throws -> CustomEndpointValidation {
        guard let ok = object["ok"] as? Bool, let reachable = object["reachable"] as? Bool, let message = object["message"] as? String, let models = object["models"] as? [String] else { throw Failure.unreadable }
        return .init(ok: ok, reachable: reachable, message: message, models: models)
    }

    static func debugShare(from object: [String: Any]) throws -> HermesDebugShare {
        guard object["ok"] as? Bool == true, let urls = object["urls"] as? [String], let failures = object["failures"] as? [String], let redacted = object["redacted"] as? Bool else { throw Failure.unreadable }
        return .init(urls: urls, failures: failures, redacted: redacted, autoDeleteSeconds: parityInt(object["auto_delete_seconds"]))
    }

    private static func parityString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func parityInt(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
    private static func parityDouble(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Int { return Double(n) }
        return nil
    }
    private static func parityQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? value
    }
    private static func paritySegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value
    }
}
