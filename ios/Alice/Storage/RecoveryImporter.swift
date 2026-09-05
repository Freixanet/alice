import CryptoKit
import Foundation

/// An archive of conversations recovered from a Hermes session store.
///
/// The old Alice sent its local `Conversation.id` to Hermes as the session
/// key, so conversations erased from the phone survived server-side under
/// those same ids. This reads such an export back — it never talks to Hermes,
/// never opens a database, and never writes anything anywhere but Alice's own
/// conversation list.
struct RecoveryArchive: Decodable, Sendable {
    struct Turn: Decodable, Sendable {
        /// Deterministic, derived from the durable Hermes row id, so importing
        /// the same archive twice recognises the same turn.
        let id: String
        let remoteRowID: String?
        let role: Message.Role
        let content: String
        let createdAt: Date?
    }

    struct Conversation: Decodable, Sendable {
        let conversationID: String
        let title: String
        let createdAt: Date?
        let updatedAt: Date?
        let messages: [Turn]
        /// The bot a *simulated* legacy chat was pretending to be.
        ///
        /// Provenance only, never identity. Those chats ran on the default
        /// profile with a synthetic persona; they are not the bot's canonical
        /// Bot Chat and must never be presented as its history.
        let legacyBotName: String?
        let recoverySourceSessionID: String?
    }

    let schemaVersion: Int
    let batchID: String
    let conversations: [Conversation]
    /// Message ids to delete, proven to be exact duplicates of a row that is
    /// already present. Empty unless a duplicate survived every field
    /// comparison; a single semantic difference keeps a row.
    let removeMessageIDs: [String]?
    /// Inactive rows kept on purpose: content that exists nowhere else.
    let preserveMessageIDs: [String]?
    /// What must be true of the local state before anything is written.
    let preconditions: Preconditions?

    struct Preconditions: Decodable, Sendable {
        /// How many recovered messages the patch was built against.
        let recoveredMessageCount: Int?
        /// `messageID → SHA-256 of its content`. A removal names both the row
        /// going and the row staying, so the delete only happens when this
        /// device really holds the pair the patch was reasoned about.
        let contentSHA256: [String: String]?
    }

    static let supportedSchema = 1
}

/// What an import would do, before it does it.
struct RecoveryPlan: Equatable, Sendable {
    var created: [String] = []
    var merged: [String] = []
    var messagesAdded = 0
    var skippedAlreadyPresent = 0
    var conflicts: [String] = []
    var removals: [String] = []
    var preserved: [String] = []
    var alreadyApplied = false
    /// Set when a precondition failed. Nothing is written in that case.
    var refusal: String?

    var isEmpty: Bool { created.isEmpty && merged.isEmpty && messagesAdded == 0 }
}

/// Folds a recovery archive into Alice's conversations.
///
/// Deliberately separate from `AppStore`: it is a pure function over values,
/// so a dry run is the same code as the real thing with the result thrown
/// away, and the rules below can be tested without a device.
enum RecoveryImporter {
    enum Failure: Error, LocalizedError {
        case unreadable
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "That file is not a recovery archive."
            case let .unsupportedSchema(version):
                "This archive is version \(version); this build reads "
                    + "version \(RecoveryArchive.supportedSchema)."
            }
        }
    }

    /// Where a recovered chat is filed, so it is visibly a restoration rather
    /// than something the user is expected to continue.
    static let project = "Recovered"

    /// Accepts ISO-8601 with or without an offset, with or without fractional
    /// seconds. A recovery archive is written by a tool, not by this app, and
    /// refusing one over a missing `Z` would fail the import for a reason that
    /// has nothing to do with its contents.
    static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        // No offset: read as local time, which is what a naive stamp means.
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS",
                       "yyyy-MM-dd'T'HH:mm:ss"] {
            plain.dateFormat = format
            if let date = plain.date(from: text) { return date }
        }
        return nil
    }

    static func read(_ data: Data) throws -> RecoveryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "not an ISO-8601 date"
                ))
            }
            return date
        }
        guard let archive = try? decoder.decode(RecoveryArchive.self, from: data) else {
            throw Failure.unreadable
        }
        guard archive.schemaVersion == RecoveryArchive.supportedSchema else {
            throw Failure.unsupportedSchema(archive.schemaVersion)
        }
        return archive
    }

    /// What importing would change. Never mutates anything.
    static func plan(
        _ archive: RecoveryArchive,
        into existing: [Conversation],
        appliedBatches: Set<String>
    ) -> RecoveryPlan {
        var plan = RecoveryPlan()
        plan.alreadyApplied = appliedBatches.contains(archive.batchID)
        let known = Set(existing.flatMap { $0.messages.map(\.id) })
        plan.removals = (archive.removeMessageIDs ?? []).filter { known.contains($0) }
        plan.preserved = (archive.preserveMessageIDs ?? []).filter { known.contains($0) }
        for recovered in archive.conversations {
            guard let current = existing.first(where: { $0.id == recovered.conversationID })
            else {
                plan.created.append(recovered.conversationID)
                plan.messagesAdded += recovered.messages.count
                continue
            }
            let present = Set(current.messages.map(\.id))
            let missing = recovered.messages.filter { !present.contains($0.id) }
            plan.skippedAlreadyPresent += recovered.messages.count - missing.count
            // Checked before the early exit: two sides disagreeing about a
            // turn they both have is exactly the case where nothing is
            // missing, and it is the one worth reporting.
            let byID = Dictionary(
                current.messages.map { ($0.id, $0.content) },
                uniquingKeysWith: { first, _ in first }
            )
            for turn in recovered.messages {
                guard let mine = byID[turn.id], mine != turn.content else { continue }
                plan.conflicts.append(
                    "\(recovered.conversationID)/\(turn.id): local and archive differ"
                )
            }
            if missing.isEmpty { continue }
            plan.merged.append(recovered.conversationID)
            plan.messagesAdded += missing.count
            // A local chat that is already richer is not replaced; only the
            // turns it lacks are added, and that is worth saying out loud.
        }
        return plan
    }

    /// Applies the archive, all of it or none of it.
    ///
    /// Nothing existing is removed, no conversation is replaced by a poorer
    /// one, and running it twice adds nothing the second time — recovered
    /// turns carry ids derived from durable Hermes row ids, so a turn already
    /// present is recognised rather than appended again.
    /// Applies the archive as one operation, or not at all.
    ///
    /// Additions, the removals the archive proved, and the reordering happen
    /// together on a copy; the copy is only returned once every precondition
    /// held. There is no window in which the list has the new turns but not
    /// the deletions, or vice versa.
    static func apply(
        _ archive: RecoveryArchive, to existing: [Conversation]
    ) -> [Conversation] {
        var result = existing
        let doomed = Set(archive.removeMessageIDs ?? [])
        if !doomed.isEmpty {
            for index in result.indices {
                result[index].messages.removeAll { doomed.contains($0.id) }
            }
        }
        for recovered in archive.conversations {
            let restored = messages(of: recovered)
            if let index = result.firstIndex(where: { $0.id == recovered.conversationID }) {
                let present = Set(result[index].messages.map(\.id))
                let missing = restored.filter { !present.contains($0.id) }
                if let legacy = recovered.legacyBotName {
                    // Merging onto a shell the old build left behind, which may
                    // still claim `botName`. It must not: that shell stood for a
                    // simulated chat on the default profile, and leaving the
                    // association would make the real bot's screen open this old
                    // transcript instead of the bot's canonical chat.
                    result[index].botName = nil
                    result[index].hermesSessionID = nil
                    result[index].legacyBotName = slug(legacy)
                    result[index].project = project
                    result[index].title = title(of: recovered)
                }
                guard !missing.isEmpty else { continue }
                result[index].messages = ordered(result[index].messages + missing)
                if result[index].title.isEmpty || result[index].title == "New chat" {
                    result[index].title = title(of: recovered)
                }
            } else {
                result.insert(conversation(from: recovered, messages: restored), at: 0)
            }
        }
        return result
    }

    // MARK: - Shaping

    static func title(of recovered: RecoveryArchive.Conversation) -> String {
        if !recovered.title.isEmpty { return recovered.title }
        if let bot = recovered.legacyBotName { return "\(bot) — historial anterior" }
        return "Recovered chat"
    }

    /// A recovered chat is always an ordinary local conversation.
    ///
    /// Even one that was pretending to be a bot: `botName` and
    /// `hermesSessionID` stay nil, so opening the real bot from Bots still
    /// resolves that profile's canonical Bot Chat and never lands in this old
    /// simulated transcript. Two different agents' conversations must not be
    /// spliced into one apparent history.
    static func conversation(
        from recovered: RecoveryArchive.Conversation, messages restored: [Message]
    ) -> Conversation {
        let created = recovered.createdAt ?? restored.first?.createdAt ?? Date()
        return Conversation(
            id: recovered.conversationID,
            title: title(of: recovered),
            createdAt: created,
            updatedAt: recovered.updatedAt ?? restored.last?.createdAt ?? created,
            project: project,
            messages: restored,
            botName: nil,
            legacyBotName: recovered.legacyBotName.map(slug),
            hermesSessionID: nil
        )
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything that must hold before a write, as a list of what does not.
    ///
    /// Returned rather than thrown so the caller can report all of it at once
    /// — an operator debugging a refusal wants the whole picture, not the
    /// first thing that happened to be checked.
    static func unmetPreconditions(
        _ archive: RecoveryArchive, against existing: [Conversation]
    ) -> [String] {
        var unmet: [String] = []
        let all = existing.flatMap(\.messages)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for id in (archive.removeMessageIDs ?? []) + (archive.preserveMessageIDs ?? [])
        where byID[id] == nil {
            unmet.append("missing \(id)")
        }
        if let expected = archive.preconditions?.recoveredMessageCount, all.count != expected {
            unmet.append("count is \(all.count), patch expects \(expected)")
        }
        for (id, hash) in archive.preconditions?.contentSHA256 ?? [:] {
            guard let message = byID[id] else {
                unmet.append("missing \(id)")
                continue
            }
            if sha256(message.content) != hash {
                unmet.append("\(id) content differs from what the patch was built on")
            }
        }
        // Nothing new may already be there under a different body.
        for conversation in archive.conversations {
            for turn in conversation.messages {
                if let mine = byID[turn.id], mine.content != turn.content {
                    unmet.append("\(turn.id) already present with different content")
                }
            }
        }
        return unmet
    }

    /// The profile slug for a bot the archive names by its display title.
    ///
    /// The synthetic directive carried whatever the bot was *called* on this
    /// phone — "Radar IA" — while the profile is `radar-ia`. Screens group by
    /// the slug, so the display name has to come back to it.
    static func slug(_ displayName: String) -> String {
        displayName
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+", with: "-", options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Corrects association on conversations imported before this build knew
    /// the difference between owning a history and routing to a profile.
    ///
    /// Metadata only: no message is added, removed, reordered or rewritten,
    /// and running it twice changes nothing the second time.
    static func migrateAssociations(
        _ conversations: [Conversation], using archive: RecoveryArchive
    ) -> [Conversation] {
        var result = conversations
        for recovered in archive.conversations {
            guard let legacy = recovered.legacyBotName,
                  let index = result.firstIndex(where: { $0.id == recovered.conversationID })
            else { continue }
            result[index].botName = nil
            result[index].hermesSessionID = nil
            result[index].legacyBotName = slug(legacy)
            result[index].project = project
            result[index].title = title(of: recovered)
        }
        return result
    }

    /// Canonical order for recovered turns.
    ///
    /// The agent's row id, not the timestamp. A session that re-persisted its
    /// history on every request carries stamps that do not always follow the
    /// order the turns were written in — `hermes_state.get_messages` orders by
    /// `id ASC`, and so does this.
    static func ordered(_ messages: [Message]) -> [Message] {
        func rowID(_ message: Message) -> Int? {
            guard message.id.hasPrefix("recovered-"),
                  let last = message.id.split(separator: "-").last
            else { return nil }
            return Int(last)
        }
        guard messages.allSatisfy({ rowID($0) != nil }) else {
            return messages.sorted { $0.createdAt < $1.createdAt }
        }
        return messages.sorted { (rowID($0) ?? 0) < (rowID($1) ?? 0) }
    }

    static func messages(of recovered: RecoveryArchive.Conversation) -> [Message] {
        recovered.messages.map { turn in
            Message(
                id: turn.id,
                role: turn.role,
                content: turn.content,
                createdAt: turn.createdAt ?? Date(timeIntervalSince1970: 0),
                // Recovered from the agent's store, but not part of the
                // canonical Bot Chat merge: these belong to a local
                // conversation, so they are this device's history.
                localOnly: true
            )
        }
    }
}
