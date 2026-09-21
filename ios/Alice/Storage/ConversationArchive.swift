import Foundation

/// On-disk conversations: one record per chat, with a fallback for the older
/// single-array blob.
///
/// Streaming used to re-encode every conversation on every delta. A Radar
/// report sitting in another chat paid that cost. Each chat now has its own
/// key; only chats that actually changed are encoded. An archive written by a
/// previous build is still read, then rewritten in the split form on the
/// first successful save.
enum ConversationArchive {
    static let blobKey = "alice.conversations"
    static let indexKey = "alice.conversations.index"
    static let salvageKey = "alice.conversations.salvage"

    enum Source: Equatable {
        case blob
        case split
    }

    struct Skipped: Equatable {
        var id: String
        var reason: String
        var bytes: Data
    }

    struct Available: Equatable {
        var conversations: [Conversation]
        var source: Source
        var skipped: [Skipped]
    }

    enum Load: Equatable {
        case empty
        case available(Available)
        case unreadable(reason: String, bytes: Data)
    }

    struct Snapshot: Sendable {
        var conversations: [Conversation]
        var fingerprints: [String: Int]
        var persistedIDs: Set<String>
        var protectedIDs: Set<String>
    }

    struct Record: Sendable {
        var key: String
        var data: Data
    }

    struct PreparedWrite: Sendable {
        var records: [Record]
        var index: Data
        var removeKeys: [String]
        var fingerprints: [String: Int]
        var persistedIDs: Set<String>
    }

    static func recordKey(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let safe = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let clipped = safe.isEmpty ? "_" : String(safe.prefix(80))
        return "alice.conversation." + clipped
    }

    static func fingerprint(_ conversation: Conversation) -> Int {
        var hasher = Hasher()
        hasher.combine(conversation)
        return hasher.finalize()
    }

    static func load(from defaults: ConversationStorage) -> Load {
        if let indexData = defaults.data(forKey: indexKey), !indexData.isEmpty {
            switch loadSplit(indexData, from: defaults) {
            case .empty:
                break
            case let .available(loaded):
                return .available(loaded)
            case let .unreadable(reason, bytes):
                if let blob = loadBlob(from: defaults) { return blob }
                return .unreadable(reason: reason, bytes: bytes)
            }
        }
        return loadBlob(from: defaults) ?? .empty
    }

    static func prepare(_ snapshot: Snapshot) throws -> PreparedWrite {
        let encoder = JSONEncoder()
        var records: [Record] = []
        var fingerprints = snapshot.fingerprints
        let liveIDs = snapshot.conversations.map(\.id)
        for conversation in snapshot.conversations {
            let next = fingerprint(conversation)
            if fingerprints[conversation.id] == next { continue }
            records.append(
                Record(key: recordKey(for: conversation.id), data: try encoder.encode(conversation))
            )
            fingerprints[conversation.id] = next
        }
        let removed = snapshot.persistedIDs
            .subtracting(liveIDs)
            .subtracting(snapshot.protectedIDs)
        let indexIDs = liveIDs + snapshot.protectedIDs.subtracting(liveIDs).sorted()
        fingerprints = fingerprints.filter { indexIDs.contains($0.key) }
        return PreparedWrite(
            records: records,
            index: try encoder.encode(indexIDs),
            removeKeys: removed.map(recordKey(for:)) + [blobKey],
            fingerprints: fingerprints,
            persistedIDs: Set(indexIDs)
        )
    }

    /// Writes the prepared records, then the index, then drops the leftover
    /// blob. That order is the recovery path: a crash before the index is
    /// stored still leaves the older blob for the next launch.
    ///
    /// Only what changed is written. The index and the removals used to be
    /// written on every save, so a save with nothing new still rewrote the
    /// storage — all of it, while that was `UserDefaults`.
    static func apply(_ write: PreparedWrite, to defaults: ConversationStorage) {
        for record in write.records {
            defaults.set(record.data, forKey: record.key)
        }
        if defaults.data(forKey: indexKey) != write.index {
            defaults.set(write.index, forKey: indexKey)
        }
        for key in write.removeKeys where defaults.data(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    /// A description of a decode failure with nothing private in it.
    ///
    /// The coding path names fields and indexes, never contents, so this can
    /// go in a diagnostic without carrying anyone's messages with it.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(type(of: error))" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath
                .map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: " → ")
        }
        switch decoding {
        case let .keyNotFound(key, context):
            return "keyNotFound(\"\(key.stringValue)\") at [\(path(context))]"
        case let .typeMismatch(type, context):
            return "typeMismatch(\(type)) at [\(path(context))]"
        case let .valueNotFound(type, context):
            return "valueNotFound(\(type)) at [\(path(context))]"
        case let .dataCorrupted(context):
            return "dataCorrupted at [\(path(context))]"
        @unknown default:
            return "decodingError"
        }
    }

    private static func loadSplit(_ indexData: Data, from defaults: ConversationStorage) -> Load {
        let ids: [String]
        do {
            ids = try JSONDecoder().decode([String].self, from: indexData)
        } catch {
            return .unreadable(reason: describe(error), bytes: indexData)
        }
        guard !ids.isEmpty else { return .empty }

        var conversations: [Conversation] = []
        var skipped: [Skipped] = []
        conversations.reserveCapacity(ids.count)
        for id in ids {
            guard let data = defaults.data(forKey: recordKey(for: id)), !data.isEmpty else {
                continue
            }
            do {
                conversations.append(try JSONDecoder().decode(Conversation.self, from: data))
            } catch {
                skipped.append(Skipped(id: id, reason: describe(error), bytes: data))
            }
        }
        if conversations.isEmpty, skipped.isEmpty { return .empty }
        if conversations.isEmpty {
            let first = skipped[0]
            return .unreadable(reason: first.reason, bytes: first.bytes)
        }
        return .available(
            Available(conversations: conversations, source: .split, skipped: skipped)
        )
    }

    private static func loadBlob(from defaults: ConversationStorage) -> Load? {
        guard let data = defaults.data(forKey: blobKey), !data.isEmpty else { return nil }
        do {
            let saved = try JSONDecoder().decode([Conversation].self, from: data)
            if saved.isEmpty { return .empty }
            return .available(Available(conversations: saved, source: .blob, skipped: []))
        } catch {
            return .unreadable(reason: describe(error), bytes: data)
        }
    }
}
