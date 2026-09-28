import Foundation

/// Unsent work belongs to a conversation, including selected mentions.
struct ComposerDraft: Equatable, Sendable {
    var text = ""
    var mentions: [DraftMention] = []
    var attachments: [Attachment] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

/// Uses the conversation file store, keeping image bytes out of preferences.
/// Text edits do not re-encode or rewrite unchanged attachments.
final class ComposerDraftArchive {
    private struct TextRecord: Codable {
        var text: String
        var mentions: [DraftMention]
    }

    private let storage: ConversationStorage
    private var saved: [String: ComposerDraft] = [:]
    private var unreadable: Set<String> = []

    enum Failure: Error { case unreadable, writeFailed }

    init(storage: ConversationStorage) { self.storage = storage }

    static func key(_ id: String) -> String {
        ConversationArchive.recordKey(for: id) + ".draft"
    }

    func load(_ id: String, legacyText: String? = nil) throws -> ComposerDraft {
        if let cached = saved[id] { return cached }
        do {
            let key = Self.key(id)
            let text = try storage.data(forKey: key).map {
                try JSONDecoder().decode(TextRecord.self, from: $0)
            }
            let attachments = try storage.data(forKey: key + ".attachments").map {
                try JSONDecoder().decode([Attachment].self, from: $0)
            } ?? []
            let value = ComposerDraft(
                text: text?.text ?? legacyText ?? "",
                mentions: text?.mentions ?? [], attachments: attachments
            )
            saved[id] = value
            return value
        } catch {
            unreadable.insert(id)
            throw Failure.unreadable
        }
    }

    func save(_ value: ComposerDraft, for id: String) throws {
        guard !unreadable.contains(id) else { throw Failure.unreadable }
        let key = Self.key(id)
        if saved[id]?.attachments != value.attachments {
            try write(JSONEncoder().encode(value.attachments), key: key + ".attachments")
        }
        let text = TextRecord(text: value.text, mentions: value.mentions)
        try write(JSONEncoder().encode(text), key: key)
        saved[id] = value
    }

    func remove(_ id: String) {
        saved[id] = nil
        unreadable.remove(id)
        storage.removeObject(forKey: Self.key(id))
        storage.removeObject(forKey: Self.key(id) + ".attachments")
    }

    private func write(_ data: Data, key: String) throws {
        guard storage.data(forKey: key) != data else { return }
        storage.set(data, forKey: key)
        guard storage.data(forKey: key) == data else { throw Failure.writeFailed }
    }
}
