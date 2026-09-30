import Foundation
import os

/// Settings keys no build reads any more, moved out of preferences into files.
///
/// iOS rewrites the whole preferences file on every change, so a large value nobody reads still
/// costs a write each time any setting changes. The RSS reader's archive (`alice.newsFeed.v1`,
/// replaced by the editorial feed) was the largest thing in it, at ~150 KB. Its saved posts and
/// interests are the person's, so the bytes are kept, untouched, in Application Support/Retired
/// before the key is removed; the key goes only once the copy reads back identical.
enum RetiredPreferences {
    static let keys = ["alice.newsFeed.v1"]

    private static let log = Logger(subsystem: "alice", category: "retired-preferences")

    nonisolated static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Retired", directoryHint: .isDirectory)
    }

    /// Moves each retired key still in `defaults` to its own file. Safe to call on every launch.
    @discardableResult
    static func moveToFiles(_ defaults: UserDefaults, keys: [String] = keys, folder: URL? = folder) -> [String] {
        guard let folder else { return [] }
        var moved: [String] = []
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            do {
                let data = try (value as? Data)
                    ?? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appending(path: "\(key).data")
                // An earlier launch may have written it and stopped before removing the key.
                if (try? Data(contentsOf: file)) != data {
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                guard (try? Data(contentsOf: file)) == data else { continue }
                defaults.removeObject(forKey: key)
                moved.append(key)
            } catch {
                log.error("retired key not moved: \(key, privacy: .public)")
            }
        }
        return moved
    }
}
