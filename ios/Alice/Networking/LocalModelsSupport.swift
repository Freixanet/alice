import Foundation

struct LocalModelLoadProgress: Hashable, Sendable {
    var stage: String
    var value: Double?
    var percent: Double?
}

struct LocalModelPlacement: Hashable, Sendable {
    var window: Int?
    var windowLabel: String?
    var spilled: Bool?
    var grantedWindow: Int?
    var grantedWindowLabel: String?
}

struct LocalStagedModel: Identifiable, Hashable, Sendable {
    var id: String
    var sizeBytes: Int64
    var sizeLabel: String
}

struct LocalModelsStatus: Hashable, Sendable {
    var enabled: Bool
    var tag: String
    var configuredTag: String
    var updateAvailable: Bool
    var runtimeInstalled: Bool
    var runtimeBackend: String?
    var serverRunning: Bool
    var serverBaseURL: String?
    var activeModelID: String?
    var loadedModels: [String: String]
    var loading: [String: LocalModelLoadProgress]
    var placement: [String: LocalModelPlacement]
    var models: [LocalStagedModel]
    var modelsDir: String
}

struct LocalModelHardware: Hashable, Sendable {
    var uma: Bool
    var vramTotalBytes: Int64
    var vramUsableBytes: Int64
    var ramTotalBytes: Int64
    var ramAvailableBytes: Int64
    var vramLabel: String
    var gpuName: String?
    var gpuUtilPercent: Int?
    var vramUsedBytes: Int64?
}

struct LocalModelCatalogItem: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var detail: String
    var nativeContext: Int
    var nativeContextLabel: String
    var recommended: Bool
    var recommendedReason: String?
    var downloaded: Bool
    var downloadedModelID: String?
    var downloadedQuant: String?
    var mtp: Bool
    var vision: Bool
    var needsEngine: Bool
    var minEngine: String?
    var fits: Bool
    var modelID: String?
    var quant: String?
    var quantValidated: Bool?
    var sizeBytes: Int64
    var sizeLabel: String
    var variantCount: Int?
    var quantReason: String?
    var fitSummary: String
    var fitDetail: String?
    var startWindow: Int?
    var startWindowLabel: String?
    var spilled: Bool?
}

struct LocalModelJob: Identifiable, Hashable, Sendable {
    var id: String { jobID }
    var jobID: String
    var kind: String
    var target: String
    var modelID: String?
    var status: String
    var phase: String
    var detail: String
    var totalBytes: Int64?
    var doneBytes: Int64
    var startedAt: Double
    var error: String?
    var percent: Double?
    var running: Bool { status == "running" }
}

struct LocalRuntimeInstallStart: Hashable, Sendable {
    var jobID: String
    var backend: String
    var tag: String
}

struct LocalModelDownloadStart: Hashable, Sendable {
    var jobID: String?
    var alreadyDownloaded: Bool
    var modelID: String
}

struct LocalModelQuickstartStart: Hashable, Sendable {
    var jobID: String
    var modelID: String
    var displayName: String
    var needsRuntime: Bool
    var needsDownload: Bool
    var downloadBytes: Int64
}

struct LocalModelHFHit: Identifiable, Hashable, Sendable {
    var id: String { repo }
    var repo: String
    var downloads: Int
    var likes: Int
    var updated: String
    var gated: Bool
}

struct LocalModelHFFileGroup: Identifiable, Hashable, Sendable {
    var id: String { paths.joined(separator: "|") }
    var label: String
    var paths: [String]
    var totalBytes: Int64
    var fit: String
}

struct LocalModelSideloadResult: Hashable, Sendable {
    var ok: Bool
    var modelID: String
    var alreadyPresent: Bool
}

extension DashboardClient {
    func localModelsStatus() async throws -> LocalModelsStatus {
        try Self.localModelsStatus(from: await get("api/local-models/status"))
    }

    func localModelHardware() async throws -> LocalModelHardware {
        try Self.localModelHardware(from: await get("api/local-models/hardware"))
    }

    func localModelCatalog() async throws -> [LocalModelCatalogItem] {
        try Self.localModelCatalog(from: await get("api/local-models/catalog"))
    }

    func localModelJobs() async throws -> [LocalModelJob] {
        try Self.localModelJobs(from: await get("api/local-models/jobs"))
    }

    func localModelJob(_ jobID: String) async throws -> LocalModelJob {
        try Self.localModelJob(from: await get("api/local-models/jobs/\(Self.localSegment(jobID))"))
    }

    func installLocalRuntime(backend: String? = nil) async throws -> LocalRuntimeInstallStart {
        var body: [String: Any] = [:]
        if let backend, !backend.isEmpty { body["backend"] = backend }
        return try Self.localRuntimeInstallStart(
            from: await send("POST", "api/local-models/runtime/install", body)
        )
    }

    func quickstartLocalModel(_ modelID: String? = nil) async throws -> LocalModelQuickstartStart {
        var body: [String: Any] = [:]
        if let modelID, !modelID.isEmpty { body["model_id"] = modelID }
        return try Self.localModelQuickstartStart(
            from: await send("POST", "api/local-models/quickstart", body)
        )
    }

    func downloadLocalModel(_ modelID: String) async throws -> LocalModelDownloadStart {
        try Self.localModelDownloadStart(
            from: await send("POST", "api/local-models/download", ["model_id": modelID])
        )
    }

    func deleteLocalModel(_ modelID: String) async throws {
        let object = try await send("DELETE", "api/local-models/models/\(Self.localSegment(modelID))")
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func setLocalServer(_ action: String) async throws {
        let object = try await send("POST", "api/local-models/server", ["action": action])
        guard object["ok"] as? Bool == true,
              object["action"] as? String == action else { throw Failure.unreadable }
    }

    func ejectLocalModel(_ modelID: String) async throws {
        let object = try await send("POST", "api/local-models/eject", ["model_id": modelID])
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func activateLocalModel(_ modelID: String) async throws -> LocalModelJob {
        let object = try await send("POST", "api/local-models/activate", ["model_id": modelID])
        guard let jobID = Self.localString(object["job_id"]) else { throw Failure.unreadable }
        return LocalModelJob(
            jobID: jobID, kind: "model-activate", target: modelID, modelID: modelID,
            status: "running", phase: "starting", detail: "", totalBytes: nil,
            doneBytes: 0, startedAt: Date().timeIntervalSince1970, error: nil, percent: nil
        )
    }

    func searchLocalModels(_ query: String, limit: Int = 20) async throws -> [LocalModelHFHit] {
        let path = "api/local-models/search?q=\(Self.localQuery(query))&limit=\(max(1, min(limit, 50)))"
        return try Self.localModelSearch(from: await get(path))
    }

    func localModelRepoFiles(_ repo: String) async throws -> [LocalModelHFFileGroup] {
        try Self.localModelRepoFiles(
            from: await get("api/local-models/search/files?repo=\(Self.localQuery(repo))")
        )
    }

    func downloadBrowsedLocalModel(repo: String, paths: [String]) async throws -> LocalModelDownloadStart {
        try Self.localModelDownloadStart(
            from: await send("POST", "api/local-models/download-browsed", ["repo": repo, "paths": paths])
        )
    }

    func sideloadLocalModel(path: String) async throws -> LocalModelSideloadResult {
        try Self.localModelSideloadResult(
            from: await send("POST", "api/local-models/sideload", ["path": path])
        )
    }

    static func localModelsStatus(from object: [String: Any]) throws -> LocalModelsStatus {
        guard let enabled = object["enabled"] as? Bool,
              let tag = object["tag"] as? String,
              let configuredTag = object["configured_tag"] as? String,
              let updateAvailable = object["update_available"] as? Bool,
              let runtimeInstalled = object["runtime_installed"] as? Bool,
              let serverRunning = object["server_running"] as? Bool,
              let modelsDir = object["models_dir"] as? String,
              let loadedRaw = object["loaded_models"] as? [String: Any],
              let loadingRaw = object["loading"] as? [String: Any],
              let placementRaw = object["placement"] as? [String: Any],
              let modelRows = object["models"] as? [[String: Any]] else { throw Failure.unreadable }

        var loaded: [String: String] = [:]
        for (key, raw) in loadedRaw {
            guard let state = raw as? String else { throw Failure.unreadable }
            loaded[key] = state
        }
        var loading: [String: LocalModelLoadProgress] = [:]
        for (key, raw) in loadingRaw {
            guard let row = raw as? [String: Any] else { throw Failure.unreadable }
            loading[key] = .init(
                stage: row["stage"] as? String ?? "loading",
                value: Self.localDouble(row["value"]), percent: Self.localDouble(row["percent"])
            )
        }
        var placement: [String: LocalModelPlacement] = [:]
        for (key, raw) in placementRaw {
            guard let row = raw as? [String: Any] else { throw Failure.unreadable }
            placement[key] = .init(
                window: Self.localInt(row["window"]), windowLabel: row["window_label"] as? String,
                spilled: row["spilled"] as? Bool,
                grantedWindow: Self.localInt(row["granted_window"]),
                grantedWindowLabel: row["granted_window_label"] as? String
            )
        }
        let models = try modelRows.map { row -> LocalStagedModel in
            guard let id = Self.localString(row["id"]),
                  let bytes = Self.localInt64(row["size_bytes"]),
                  let label = row["size_label"] as? String else { throw Failure.unreadable }
            return .init(id: id, sizeBytes: bytes, sizeLabel: label)
        }
        return .init(
            enabled: enabled, tag: tag, configuredTag: configuredTag,
            updateAvailable: updateAvailable, runtimeInstalled: runtimeInstalled,
            runtimeBackend: Self.localString(object["runtime_backend"]), serverRunning: serverRunning,
            serverBaseURL: Self.localString(object["server_base_url"]),
            activeModelID: Self.localString(object["active_model_id"]), loadedModels: loaded,
            loading: loading, placement: placement, models: models, modelsDir: modelsDir
        )
    }

    static func localModelHardware(from object: [String: Any]) throws -> LocalModelHardware {
        guard let uma = object["uma"] as? Bool,
              let vramTotal = Self.localInt64(object["vram_total_bytes"]),
              let vramUsable = Self.localInt64(object["vram_usable_bytes"]),
              let ramTotal = Self.localInt64(object["ram_total_bytes"]),
              let ramAvailable = Self.localInt64(object["ram_available_bytes"]),
              let vramLabel = object["vram_label"] as? String else { throw Failure.unreadable }
        return .init(
            uma: uma, vramTotalBytes: vramTotal, vramUsableBytes: vramUsable,
            ramTotalBytes: ramTotal, ramAvailableBytes: ramAvailable, vramLabel: vramLabel,
            gpuName: Self.localString(object["gpu_name"]), gpuUtilPercent: Self.localInt(object["gpu_util_percent"]),
            vramUsedBytes: Self.localInt64(object["vram_used_bytes"])
        )
    }

    static func localModelCatalog(from object: [String: Any]) throws -> [LocalModelCatalogItem] {
        guard let rows = object["models"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let id = Self.localString(row["id"]),
                  let name = Self.localString(row["display_name"]),
                  let detail = row["description"] as? String,
                  let context = Self.localInt(row["native_context"]),
                  let contextLabel = row["native_context_label"] as? String,
                  let recommended = row["recommended"] as? Bool,
                  let downloaded = row["downloaded"] as? Bool,
                  let mtp = row["mtp"] as? Bool,
                  let vision = row["vision"] as? Bool,
                  let needsEngine = row["needs_engine"] as? Bool,
                  let fits = row["fits"] as? Bool,
                  let sizeBytes = Self.localInt64(row["size_bytes"]),
                  let sizeLabel = row["size_label"] as? String,
                  let fitSummary = row["fit_summary"] as? String else { throw Failure.unreadable }
            return .init(
                id: id, displayName: name, detail: detail, nativeContext: context,
                nativeContextLabel: contextLabel, recommended: recommended,
                recommendedReason: Self.localString(row["recommended_reason"]), downloaded: downloaded,
                downloadedModelID: Self.localString(row["downloaded_model_id"]),
                downloadedQuant: Self.localString(row["downloaded_quant"]), mtp: mtp, vision: vision,
                needsEngine: needsEngine, minEngine: Self.localString(row["min_engine"]), fits: fits,
                modelID: Self.localString(row["model_id"]), quant: Self.localString(row["quant"]),
                quantValidated: row["quant_validated"] as? Bool, sizeBytes: sizeBytes, sizeLabel: sizeLabel,
                variantCount: Self.localInt(row["variant_count"]), quantReason: Self.localString(row["quant_reason"]),
                fitSummary: fitSummary, fitDetail: Self.localString(row["fit_detail"]),
                startWindow: Self.localInt(row["start_window"]), startWindowLabel: Self.localString(row["start_window_label"]),
                spilled: row["spilled"] as? Bool
            )
        }
    }

    static func localModelJobs(from object: [String: Any]) throws -> [LocalModelJob] {
        guard let rows = object["jobs"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map(Self.localModelJob(from:))
    }

    static func localModelJob(from row: [String: Any]) throws -> LocalModelJob {
        guard let jobID = Self.localString(row["job_id"]),
              let kind = row["kind"] as? String,
              let target = row["target"] as? String,
              let status = row["status"] as? String,
              let phase = row["phase"] as? String,
              let detail = row["detail"] as? String,
              let done = Self.localInt64(row["done_bytes"]),
              let started = Self.localDouble(row["started_at"]) else { throw Failure.unreadable }
        return .init(
            jobID: jobID, kind: kind, target: target, modelID: Self.localString(row["model_id"]),
            status: status, phase: phase, detail: detail, totalBytes: Self.localInt64(row["total_bytes"]),
            doneBytes: done, startedAt: started, error: Self.localString(row["error"]),
            percent: Self.localDouble(row["percent"])
        )
    }

    static func localRuntimeInstallStart(from object: [String: Any]) throws -> LocalRuntimeInstallStart {
        guard let job = Self.localString(object["job_id"]), let backend = Self.localString(object["backend"]),
              let tag = Self.localString(object["tag"]) else { throw Failure.unreadable }
        return .init(jobID: job, backend: backend, tag: tag)
    }

    static func localModelDownloadStart(from object: [String: Any]) throws -> LocalModelDownloadStart {
        guard let model = Self.localString(object["model_id"]) else { throw Failure.unreadable }
        return .init(jobID: Self.localString(object["job_id"]), alreadyDownloaded: object["already_downloaded"] as? Bool ?? false, modelID: model)
    }

    static func localModelQuickstartStart(from object: [String: Any]) throws -> LocalModelQuickstartStart {
        guard let job = Self.localString(object["job_id"]), let model = Self.localString(object["model_id"]),
              let name = Self.localString(object["display_name"]), let runtime = object["needs_runtime"] as? Bool,
              let download = object["needs_download"] as? Bool, let bytes = Self.localInt64(object["download_bytes"]) else { throw Failure.unreadable }
        return .init(jobID: job, modelID: model, displayName: name, needsRuntime: runtime, needsDownload: download, downloadBytes: bytes)
    }

    static func localModelSearch(from object: [String: Any]) throws -> [LocalModelHFHit] {
        guard let rows = object["hits"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let repo = Self.localString(row["repo"]), let downloads = Self.localInt(row["downloads"]),
                  let likes = Self.localInt(row["likes"]), let updated = row["updated"] as? String,
                  let gated = row["gated"] as? Bool else { throw Failure.unreadable }
            return .init(repo: repo, downloads: downloads, likes: likes, updated: updated, gated: gated)
        }
    }

    static func localModelRepoFiles(from object: [String: Any]) throws -> [LocalModelHFFileGroup] {
        guard let rows = object["files"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let label = Self.localString(row["label"]), let paths = row["paths"] as? [String],
                  !paths.isEmpty, let bytes = Self.localInt64(row["total_bytes"]),
                  let fit = Self.localString(row["fit"]) else { throw Failure.unreadable }
            return .init(label: label, paths: paths, totalBytes: bytes, fit: fit)
        }
    }

    static func localModelSideloadResult(from object: [String: Any]) throws -> LocalModelSideloadResult {
        guard object["ok"] as? Bool == true, let model = Self.localString(object["model_id"]) else { throw Failure.unreadable }
        return .init(ok: true, modelID: model, alreadyPresent: object["already_present"] as? Bool ?? false)
    }

    private static func localString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localInt(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func localInt64(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }

    private static func localDouble(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Int { return Double(n) }
        return nil
    }

    private static func localQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+#"))) ?? value
    }

    private static func localSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value
    }
}
