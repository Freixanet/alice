import Foundation

/// A skill or toolset as the management surface reports it.
struct CatalogRow: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var label: String
    var detail: String
    var enabled: Bool
    var group: String?
    /// Tool names for a toolset; empty for a skill.
    var tools: [String] = []
    /// Present on toolsets that need keys they do not have.
    var configured: Bool?
}

extension HermesClient {
    /// Reads a management collection.
    ///
    /// These live under `/api/*`, which is a different surface from the agent
    /// API at `/v1/*` — a build can serve one and not the other, which is why
    /// every screen checks before it asks.
    private func managementList(_ path: String) async throws -> [[String: Any]] {
        let (data, response) = try await session.data(for: try request(path))
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = HermesClient.detail(from: data)
                ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(
                status: http.statusCode,
                detail: detail,
                limit: ModelLimitClassifier.classify(status: http.statusCode, message: detail)
            )
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        if let rows = object as? [[String: Any]] { return rows }
        if let map = object as? [String: Any] {
            for key in ["skills", "toolsets", "items", "data", "results"] {
                if let rows = map[key] as? [[String: Any]] { return rows }
            }
        }
        return []
    }

    func skills() async throws -> [CatalogRow] {
        HermesClient.parseCatalog(try await managementList("api/skills"), kind: .skill)
    }

    func toolsets() async throws -> [CatalogRow] {
        HermesClient.parseCatalog(try await managementList("api/tools/toolsets"), kind: .toolset)
    }

    func mcpServers() async throws -> [CatalogRow] {
        HermesClient.parseCatalog(try await managementList("api/mcp/servers"), kind: .toolset)
    }

    /// Flips a skill on or off. Hermes owns the state; the row is refreshed
    /// from the response rather than assumed, so a rejected toggle does not
    /// leave the interface lying about what is enabled.
    func toggleSkill(name: String, enabled: Bool) async throws {
        var request = try self.request("api/skills/toggle", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["name": name, "enabled": enabled]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = HermesClient.detail(from: data) ?? "Hermes refused the change."
            throw Failure.http(status: status, detail: detail, limit: nil)
        }
    }

    enum CatalogKind { case skill, toolset }

    static func parseCatalog(_ rows: [[String: Any]], kind: CatalogKind) -> [CatalogRow] {
        rows.compactMap { row in
            let name = (row["name"] as? String) ?? (row["id"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let tools = (row["tools"] as? [String]) ?? []
            return CatalogRow(
                id: name,
                name: name,
                label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? prettify(name),
                detail: (row["description"] as? String) ?? "",
                enabled: (row["enabled"] as? Bool) ?? false,
                group: (row["group"] as? String) ?? (row["platform"] as? String),
                tools: tools,
                configured: row["configured"] as? Bool
            )
        }
    }
}
