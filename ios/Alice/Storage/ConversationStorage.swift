import Foundation

/// Where `ConversationArchive` keeps its records: one value per key.
///
/// `UserDefaults` is one, and was the only one; `FileConversationStorage` is
/// where conversations live now. Tests keep using a defaults suite.
protocol ConversationStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: ConversationStorage {}

/// Conversations as files, one per key, in the app's own storage.
///
/// They used to live in `UserDefaults`, which iOS keeps as a single property
/// list and rewrites whole on every change. With one chat carrying 2.3 MB of
/// attachments, every save — each streamed reply, each background sync, each
/// collapsed section — rewrote 3 MB: `cfprefsd` wrote 4.3 GB in a day on the
/// person's iPhone, past iOS's limit, and the app stalled waiting on it. A
/// file per chat costs that chat's bytes when it changes, and nothing else.
final class FileConversationStorage: ConversationStorage, @unchecked Sendable {
    let directory: URL
    /// The first write or removal that failed since it was last asked for,
    /// so a save that did not happen is said rather than assumed.
    private var failure: Error?

    /// What failed since the last call, clearing it.
    func takeFailure() -> Error? {
        defer { failure = nil }
        return failure
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `Application Support/Conversations` in the app's container.
    static var standardDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Conversations", directoryHint: .isDirectory)
    }

    /// Keys are `ConversationArchive`'s: fixed names, or `recordKey(for:)`,
    /// which already leaves only letters, digits, dots, dashes and underscores.
    private func url(for key: String) -> URL {
        directory.appending(path: key + ".json", directoryHint: .notDirectory)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func set(_ value: Any?, forKey key: String) {
        guard let data = value as? Data else {
            if value == nil { removeObject(forKey: key) }
            return
        }
        do {
            try data.write(to: url(for: key), options: .atomic)
        } catch {
            failure = failure ?? error
        }
    }

    func removeObject(forKey key: String) {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            failure = failure ?? error
        }
    }
}

extension ConversationArchive {
    /// Written last when an archive has moved to a new storage. Until it is
    /// there, the old storage is the one read.
    static let movedKey = "alice.conversations.moved"

    /// Makes `target` the conversations' storage, moving what `source` holds.
    ///
    /// The move copies the stored bytes as they are — records, index and any
    /// older blob — without decoding them, so an archive this build cannot
    /// read moves intact too. Every copy is read back and compared before the
    /// marker is written, and `source` is only emptied after that. Anything
    /// short of it leaves `source` untouched and returns false: the app goes
    /// on reading and writing it exactly as before.
    @discardableResult
    static func adopt(_ target: ConversationStorage, from source: ConversationStorage) -> Bool {
        let keys = sourceKeys(in: source)
        if target.data(forKey: movedKey) != nil {
            // Moved before. Anything still in the old storage is from before
            // the move, left by an interruption after the marker.
            for key in keys ?? [] { source.removeObject(forKey: key) }
            return true
        }
        guard let keys else { return false }
        let moving = keys.compactMap { key in source.data(forKey: key).map { (key: key, data: $0) } }
        // The index last among the copies, the marker after everything.
        let ordered = moving.filter { $0.key != indexKey } + moving.filter { $0.key == indexKey }
        for item in ordered { target.set(item.data, forKey: item.key) }
        guard ordered.allSatisfy({ target.data(forKey: $0.key) == $0.data }) else { return false }
        target.set(Data("1".utf8), forKey: movedKey)
        guard target.data(forKey: movedKey) != nil else { return false }
        for item in ordered { source.removeObject(forKey: item.key) }
        return true
    }

    /// The keys an archive occupies in `storage`: the index, the records it
    /// names and the older blob. Nil when the index cannot be read, since
    /// then its records cannot be found — nothing is moved.
    private static func sourceKeys(in storage: ConversationStorage) -> [String]? {
        guard let index = storage.data(forKey: indexKey) else { return [blobKey] }
        guard let ids = try? JSONDecoder().decode([String].self, from: index) else { return nil }
        return [blobKey, indexKey] + ids.map(recordKey(for:))
    }
}
