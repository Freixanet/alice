import Foundation

struct AliceBuildInfo: Equatable, Sendable {
    var version: String
    var build: String
    var revision: String?

    static var current: AliceBuildInfo {
        from(Bundle.main.infoDictionary ?? [:])
    }

    static func from(_ info: [String: Any]) -> AliceBuildInfo {
        let version = nonEmpty(info["CFBundleShortVersionString"] as? String) ?? "—"
        let build = nonEmpty(info["CFBundleVersion"] as? String) ?? "—"
        let rawRevision = nonEmpty(info["AliceSourceRevision"] as? String)
        let revision: String?
        if let rawRevision, rawRevision != "development", rawRevision != "local" {
            revision = String(rawRevision.prefix(8))
        } else {
            revision = nil
        }
        return AliceBuildInfo(version: version, build: build, revision: revision)
    }

    var versionLabel: String { "\(version) (\(build))" }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
