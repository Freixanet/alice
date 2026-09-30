import Foundation
import os

/// The last list of each kind Alice saw, so a screen opens on it instead of on a spinner.
///
/// Stale-while-revalidate, nothing more: a screen paints what is here, asks Hermes as it
/// always did, and replaces it when the answer lands. Only a successful answer is written;
/// a failure keeps the last good list. Nothing here is a credential. An entry is tied to the
/// Mac and user it came from (`scope`), and ignored after a week, so an old Mac's errands
/// never show up against a new one and a list left for days is not passed off as today's.
///
/// One small JSON file per list in Application Support/LaunchCache, kept out of backups.
enum LaunchCache {
    enum Key: String {
        case errands, routines, artifacts, models
    }

    static let lifetime: TimeInterval = 7 * 24 * 3600

    private struct Entry<Value: Codable>: Codable {
        var scope: String
        var savedAt: Date
        var value: Value
    }

    private static let log = Logger(subsystem: "alice", category: "launch-cache")

    nonisolated static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "LaunchCache", directoryHint: .isDirectory)
    }

    /// The Mac and user the lists belong to: the dashboard address and the user signed in.
    static func scope(dashboard: String, user: String) -> String {
        "\(dashboard.lowercased())|\(user.lowercased())"
    }

    /// The saved list, when it belongs to `scope` and is under a week old.
    static func read<Value: Codable>(
        _ key: Key, as type: Value.Type, scope: String, now: Date = Date(), in folder: URL? = LaunchCache.folder
    ) -> Value? {
        guard let file = folder?.appending(path: "\(key.rawValue).json"),
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data)
        else { return nil }
        guard entry.scope == scope, now.timeIntervalSince(entry.savedAt) < lifetime else { return nil }
        return entry.value
    }

    static func write<Value: Codable>(
        _ key: Key, _ value: Value, scope: String, now: Date = Date(), in folder: URL? = LaunchCache.folder
    ) {
        guard var folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            let data = try JSONEncoder().encode(Entry(scope: scope, savedAt: now, value: value))
            try data.write(
                to: folder.appending(path: "\(key.rawValue).json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            log.error("launch cache: \(key.rawValue) not saved")
        }
    }

    /// Forgets every list: another Mac, or signed out.
    static func clear(in folder: URL? = LaunchCache.folder) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
