import Foundation

/// How much the app keeps on the phone: settings, with what makes them big, and chat files.
/// Reads everything, so it is measured off the main thread.
struct StorageUsage: Sendable {
    struct Key: Sendable, Equatable {
        let key: String
        let bytes: Int
    }

    var settings = 0
    var conversations = 0
    /// The three largest settings, largest first.
    var largestKeys: [Key] = []

    nonisolated static func measure(
        defaults: UserDefaults = .standard,
        domain name: String? = Bundle.main.bundleIdentifier,
        conversations directory: URL? = FileConversationStorage.standardDirectory
    ) -> StorageUsage {
        var usage = StorageUsage()
        if let name, let domain = defaults.persistentDomain(forName: name) {
            usage.settings = size(of: domain)
            usage.largestKeys = domain
                .map { Key(key: $0.key, bytes: size(of: $0.value)) }
                .sorted { $0.bytes > $1.bytes }
                .prefix(3)
                .map { $0 }
        }
        if let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            usage.conversations = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return usage
    }

    private nonisolated static func size(of value: Any) -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))?.count ?? 0
    }
}
