import XCTest
@testable import Alice

/// Folding recovered history back in.
///
/// All fixtures here are synthetic. The real recovery archive holds private
/// conversations and stays outside this repository.
final class RecoveryImporterTests: XCTestCase {
    private static func archive(
        batch: String = "batch-1", _ conversations: String
    ) -> Data {
        Data("""
        {"schemaVersion":1,"batchID":"\(batch)","conversations":[\(conversations)]}
        """.utf8)
    }

    private static func chat(
        _ id: String, title: String = "Saludo", legacyBot: String? = nil,
        turns: [(String, String, String)] = [("1", "user", "hola")]
    ) -> String {
        let messages = turns.map { row in
            """
            {"id":"recovered-\(id)-\(row.0)","remoteRowID":"\(row.0)",
             "role":"\(row.1)","content":"\(row.2)",
             "createdAt":"2026-09-03T15:0\(row.0):00Z"}
            """
        }.joined(separator: ",")
        let bot = legacyBot.map { "\"\($0)\"" } ?? "null"
        return """
        {"conversationID":"\(id)","title":"\(title)",
         "createdAt":"2026-09-03T15:00:00Z","updatedAt":"2026-09-03T16:00:00Z",
         "legacyBotName":\(bot),"recoverySourceSessionID":"\(id)",
         "messages":[\(messages)]}
        """
    }

    private static func read(_ data: Data) throws -> RecoveryArchive {
        try RecoveryImporter.read(data)
    }

    private static func local(
        _ id: String, botName: String? = nil, session: String? = nil,
        messages: [Message] = []
    ) -> Conversation {
        Conversation(
            id: id, title: "local", createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messages: messages, botName: botName, hermesSessionID: session
        )
    }

    // MARK: - 1. Four ordinary chats arrive

    func testImportingFourOrdinaryChatsCreatesFour() throws {
        let data = Self.archive([
            Self.chat("A"), Self.chat("B"), Self.chat("C"), Self.chat("D"),
        ].joined(separator: ","))
        let archive = try Self.read(data)

        let result = RecoveryImporter.apply(archive, to: [])

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(Set(result.map(\.id)), ["A", "B", "C", "D"])
        XCTAssertTrue(result.allSatisfy { $0.messages.count == 1 })
        XCTAssertTrue(result.allSatisfy { $0.project == RecoveryImporter.project })
    }

    // MARK: - 2. Running it twice changes nothing

    func testImportingTwiceAddsNothingTheSecondTime() throws {
        let archive = try Self.read(Self.archive(Self.chat("A", turns: [
            ("1", "user", "hola"), ("2", "assistant", "buenas"),
        ])))

        let once = RecoveryImporter.apply(archive, to: [])
        let twice = RecoveryImporter.apply(archive, to: once)

        XCTAssertEqual(once.count, twice.count)
        XCTAssertEqual(once[0].messages.map(\.id), twice[0].messages.map(\.id))
        XCTAssertEqual(twice[0].messages.count, 2, "no duplicates")
    }

    // MARK: - 3. A richer local chat is not degraded

    func testARicherLocalConversationIsNotReplaced() throws {
        let rich = Self.local("A", messages: (1...5).map {
            Message(id: "local-\($0)", role: .user, content: "turno \($0)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval($0)))
        })
        let archive = try Self.read(Self.archive(Self.chat("A")))

        let result = RecoveryImporter.apply(archive, to: [rich])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].messages.count, 6, "kept all five, added the one")
        XCTAssertTrue(result[0].messages.contains { $0.id == "local-5" })
    }

    // MARK: - 4. A partial local chat gains only what it lacks

    func testAPartialConversationGainsOnlyTheMissingTurns() throws {
        let partial = Self.local("A", messages: [
            Message(id: "recovered-A-1", role: .user, content: "hola",
                    createdAt: Date(timeIntervalSince1970: 1))
        ])
        let archive = try Self.read(Self.archive(Self.chat("A", turns: [
            ("1", "user", "hola"), ("2", "assistant", "buenas"),
        ])))

        let result = RecoveryImporter.apply(archive, to: [partial])

        XCTAssertEqual(result[0].messages.map(\.id), ["recovered-A-1", "recovered-A-2"])
    }

    // MARK: - 5. A legacy bot chat is an ordinary local conversation

    func testALegacyBotChatIsNotABotChat() throws {
        let archive = try Self.read(Self.archive(
            Self.chat("R", title: "Radar IA — historial anterior", legacyBot: "Radar IA")
        ))

        let result = RecoveryImporter.apply(archive, to: [])

        let restored = try XCTUnwrap(result.first)
        XCTAssertNil(restored.routedBotName, "nothing may be sent through it")
        XCTAssertNil(restored.hermesSessionID, "and it has no canonical session")
        XCTAssertFalse(restored.isCanonicalBotChat)
        XCTAssertEqual(restored.legacyBotName, "radar-ia", "but it is filed under the bot")
        XCTAssertTrue(restored.isRecoveredHistory)
        XCTAssertEqual(restored.title, "Radar IA — historial anterior")
        XCTAssertEqual(restored.project, RecoveryImporter.project)
    }

    // MARK: - 6. The real canonical bot chat is untouched

    func testImportingLegacyHistoryLeavesTheRealBotChatAlone() throws {
        let canonical = Self.local(
            "live-uuid", botName: "radar-ia", session: "20260905_104136_281747",
            messages: [Message(id: "m1", role: .assistant, content: "informe de hoy",
                               createdAt: Date(timeIntervalSince1970: 100),
                               remoteID: "108")]
        )
        let archive = try Self.read(Self.archive(
            Self.chat("R", legacyBot: "Radar IA")
        ))

        let result = RecoveryImporter.apply(archive, to: [canonical])

        let live = try XCTUnwrap(result.first { $0.id == "live-uuid" })
        XCTAssertEqual(live.hermesSessionID, "20260905_104136_281747")
        XCTAssertEqual(live.botName, "radar-ia")
        XCTAssertEqual(live.messages.map(\.id), ["m1"], "not spliced with legacy turns")
        XCTAssertEqual(result.count, 2, "the legacy history is a separate chat")
    }

    // MARK: - 7 & 8. Bad input writes nothing

    func testACorruptArchiveIsRejectedBeforeAnythingIsWritten() {
        XCTAssertThrowsError(try Self.read(Data("{ not an archive".utf8)))
        XCTAssertThrowsError(try Self.read(Data("""
        {"schemaVersion":99,"batchID":"b","conversations":[]}
        """.utf8))) { error in
            guard case RecoveryImporter.Failure.unsupportedSchema(99) = error else {
                return XCTFail("the version must be checked, not guessed at")
            }
        }
    }

    /// One unreadable conversation fails the whole archive: `read` decodes the
    /// document as a unit, so a half-valid file never lands half-applied.
    func testAPartiallyInvalidArchiveIsAllOrNothing() {
        let mixed = Data("""
        {"schemaVersion":1,"batchID":"b","conversations":[
          \(Self.chat("A")),
          {"conversationID":"B"}
        ]}
        """.utf8)
        XCTAssertThrowsError(try Self.read(mixed))
    }

    // MARK: - Planning

    func testThePlanDescribesTheWorkWithoutDoingIt() throws {
        let existing = [Self.local("A", messages: [
            Message(id: "recovered-A-1", role: .user, content: "hola",
                    createdAt: Date(timeIntervalSince1970: 1))
        ])]
        let archive = try Self.read(Self.archive([
            Self.chat("A", turns: [("1", "user", "hola"), ("2", "assistant", "b")]),
            Self.chat("Z"),
        ].joined(separator: ",")))

        let plan = RecoveryImporter.plan(archive, into: existing, appliedBatches: [])

        XCTAssertEqual(plan.created, ["Z"])
        XCTAssertEqual(plan.merged, ["A"])
        XCTAssertEqual(plan.messagesAdded, 2)
        XCTAssertEqual(plan.skippedAlreadyPresent, 1)
        XCTAssertFalse(plan.alreadyApplied)
        XCTAssertEqual(existing[0].messages.count, 1, "planning changed nothing")
    }

    func testAnAlreadyAppliedBatchIsRecognised() throws {
        let archive = try Self.read(Self.archive(batch: "b7", Self.chat("A")))
        let plan = RecoveryImporter.plan(archive, into: [], appliedBatches: ["b7"])
        XCTAssertTrue(plan.alreadyApplied)
    }

    // MARK: - 9 & 10. Persistence and migration together

    func testRecoveredHistorySurvivesEncodingAndDecoding() throws {
        let archive = try Self.read(Self.archive(Self.chat("A", turns: [
            ("1", "user", "hola"), ("2", "assistant", "buenas"),
        ])))
        let imported = RecoveryImporter.apply(archive, to: [])

        let data = try JSONEncoder().encode(imported)
        let reloaded = try JSONDecoder().decode([Conversation].self, from: data)

        XCTAssertEqual(reloaded.map(\.id), imported.map(\.id))
        XCTAssertEqual(reloaded[0].messages.map(\.content), ["hola", "buenas"])
        XCTAssertEqual(reloaded[0].project, RecoveryImporter.project)
    }

    /// An archive from the old schema and a recovery import in the same list.
    func testOldSchemaChatsAndRecoveredChatsCoexist() throws {
        let old = try JSONDecoder().decode([Conversation].self, from: Data("""
        [{"id":"old","title":"Antigua","createdAt":768000000,"updatedAt":768000000,
          "messages":[{"id":"m","role":"user","content":"viejo","createdAt":768000000}]}]
        """.utf8))
        let archive = try Self.read(Self.archive(Self.chat("A")))

        let result = RecoveryImporter.apply(archive, to: old)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.id == "old" }?.messages.count, 1)
        XCTAssertEqual(result.first { $0.id == "A" }?.messages.count, 1)
    }
}

/// Merging recovered history onto the empty shells the regression left behind.
extension RecoveryImporterTests {
    private static func shell(_ id: String, botName: String? = nil) -> Conversation {
        Conversation(
            id: id, title: botName.map { $0.capitalized } ?? "New chat",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messages: [], botName: botName
        )
    }

    /// A shell with the same id gains the turns; it does not become a second
    /// conversation beside itself.
    func testAnEmptyShellIsMergedNotDuplicated() throws {
        let archive = try RecoveryImporter.read(Self.archive(
            Self.chat("A", turns: [("1", "user", "hola"), ("2", "assistant", "b")])
        ))

        let result = RecoveryImporter.apply(archive, to: [Self.shell("A")])

        XCTAssertEqual(result.count, 1, "one conversation, not two")
        XCTAssertEqual(result[0].id, "A")
        XCTAssertEqual(result[0].messages.count, 2)
    }

    /// The important one. The old build left a shell claiming `botName`, and
    /// the recovered history for that id is a *simulated* chat from the
    /// default profile. Keeping the association would make the real bot's
    /// screen open this old transcript instead of its canonical Bot Chat.
    func testMergingLegacyHistoryOntoABotShellClearsTheBotAssociation() throws {
        let shell = Self.shell("R", botName: "radar-ia")
        XCTAssertEqual(shell.botName, "radar-ia")

        let archive = try RecoveryImporter.read(Self.archive(
            Self.chat("R", title: "Radar IA — historial anterior", legacyBot: "Radar IA")
        ))
        let result = RecoveryImporter.apply(archive, to: [shell])

        let merged = try XCTUnwrap(result.first { $0.id == "R" })
        XCTAssertNil(merged.routedBotName, "the shell's ROUTING must be dropped")
        XCTAssertNil(merged.hermesSessionID)
        XCTAssertFalse(merged.isCanonicalBotChat)
        XCTAssertEqual(merged.legacyBotName, "radar-ia", "ownership survives as display")
        XCTAssertEqual(merged.title, "Radar IA — historial anterior")
        XCTAssertEqual(merged.project, RecoveryImporter.project)
        XCTAssertEqual(merged.messages.count, 1)
        XCTAssertEqual(result.count, 1)
    }

    /// An ordinary chat merged onto a shell keeps being an ordinary chat.
    func testMergingOrdinaryHistoryDoesNotTouchOtherFields() throws {
        let archive = try RecoveryImporter.read(Self.archive(Self.chat("A")))
        let result = RecoveryImporter.apply(archive, to: [Self.shell("A")])

        XCTAssertNil(result[0].botName)
        XCTAssertNil(result[0].hermesSessionID)
    }
}

/// Where a recovered conversation is filed, and where its turns are sent.
///
/// Ownership and routing were one field, and conflating them cost twice: with
/// `botName` set, a recovered legacy thread would have routed into the bot's
/// real session; with it nil, the history landed in Home.
extension RecoveryImporterTests {
    private static func legacyRadar() -> Conversation {
        Conversation(
            id: "R", title: "Radar IA — historial anterior",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            botName: nil, legacyBotName: "radar-ia", hermesSessionID: nil
        )
    }

    private static func canonicalRadar() -> Conversation {
        Conversation(
            id: "live", title: "Radar IA",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            botName: "radar-ia", hermesSessionID: "20260905_104136_281747"
        )
    }

    // 1 & 7. Out of Home.
    func testRecoveredBotHistoryIsNotAHomeConversation() {
        let legacy = Self.legacyRadar()
        XCTAssertTrue(legacy.isBotOwnedConversation, "it belongs under its bot")
        XCTAssertTrue(legacy.isBotChat, "so the Home filters exclude it")
        // The filter Home and the drawer use.
        let home = [legacy, Self.canonicalRadar()].filter { !$0.isBotChat }
        XCTAssertTrue(home.isEmpty)
    }

    // 2. Visible under its bot.
    func testRecoveredBotHistoryIsFiledUnderThatBot() {
        XCTAssertEqual(Self.legacyRadar().owningBotName, "radar-ia")
    }

    // 3. It never routes.
    func testRecoveredHistoryHasNoRoutingIdentity() {
        let legacy = Self.legacyRadar()
        XCTAssertNil(legacy.routedBotName, "nothing may send through it")
        XCTAssertNil(legacy.hermesSessionID)
        XCTAssertFalse(legacy.isCanonicalBotChat)
        XCTAssertTrue(legacy.isRecoveredHistory)
    }

    // 4. A real bot chat still routes.
    func testACanonicalBotChatStillRoutes() {
        let live = Self.canonicalRadar()
        XCTAssertEqual(live.routedBotName, "radar-ia")
        XCTAssertTrue(live.isCanonicalBotChat)
        XCTAssertFalse(live.isRecoveredHistory)
    }

    // 5. A Home chat that merely @-mentioned a bot stays Home.
    func testAHomeChatThatMentionedABotStaysHome() throws {
        let archive = try RecoveryImporter.read(Self.archive(
            Self.chat("H", turns: [("1", "user", "@Chollometro y hoy?")])
        ))
        let result = RecoveryImporter.apply(archive, to: [])

        XCTAssertNil(result[0].legacyBotName, "a mention is not ownership")
        XCTAssertNil(result[0].botName)
        XCTAssertFalse(result[0].isBotChat)
    }

    // 6. Both threads coexist under one bot.
    func testLegacyAndCanonicalRadarCoexist() {
        let all = [Self.legacyRadar(), Self.canonicalRadar()]
        let underRadar = all.filter { $0.owningBotName == "radar-ia" }

        XCTAssertEqual(underRadar.count, 2)
        XCTAssertEqual(underRadar.filter(\.isCanonicalBotChat).count, 1)
        XCTAssertEqual(underRadar.filter(\.isRecoveredHistory).count, 1)
        XCTAssertEqual(Set(underRadar.map(\.id)).count, 2, "distinct identities")
    }

    // 8. Navigation picks deliberately.
    func testTheMostRecentBotConversationCanBeChosenByKind() {
        let all = [Self.legacyRadar(), Self.canonicalRadar()]
        XCTAssertEqual(all.first { $0.isCanonicalBotChat }?.id, "live")
        XCTAssertEqual(all.first { $0.isRecoveredHistory }?.id, "R")
    }

    // 9 & 10. The migration is metadata only, and idempotent.
    func testTheAssociationMigrationTouchesNoMessagesAndRepeatsCleanly() throws {
        let archive = try RecoveryImporter.read(Self.archive(
            Self.chat("R", title: "Radar IA — historial anterior", legacyBot: "Radar IA",
                      turns: [("1", "user", "hola"), ("2", "assistant", "buenas")])
        ))
        // As the FIRST import left it, before this build existed: the turns
        // are there, but nothing says which bot they belong to.
        var imported = RecoveryImporter.apply(archive, to: [])
        imported[0].legacyBotName = nil
        XCTAssertFalse(imported[0].isBotChat, "which is why it showed up in Home")

        let once = RecoveryImporter.migrateAssociations(imported, using: archive)
        let twice = RecoveryImporter.migrateAssociations(once, using: archive)

        XCTAssertEqual(once[0].legacyBotName, "radar-ia")
        XCTAssertNil(once[0].botName)
        XCTAssertNil(once[0].hermesSessionID)
        XCTAssertEqual(once.map(\.id), twice.map(\.id))
        XCTAssertEqual(once[0].legacyBotName, twice[0].legacyBotName)
        // Nothing about the turns moved.
        XCTAssertEqual(imported[0].messages.map(\.id), once[0].messages.map(\.id))
        XCTAssertEqual(imported[0].messages.map(\.content), once[0].messages.map(\.content))
        XCTAssertEqual(imported[0].messages.map(\.createdAt), once[0].messages.map(\.createdAt))
        XCTAssertEqual(once[0].messages.count, twice[0].messages.count)
    }

    func testTheDisplayNameBecomesTheProfileSlug() {
        XCTAssertEqual(RecoveryImporter.slug("Radar IA"), "radar-ia")
        XCTAssertEqual(RecoveryImporter.slug("Chollometro"), "chollometro")
    }
}

/// The legacy thread has to be reachable, and it has to stay unwritable.
extension RecoveryImporterTests {
    /// It is filed under the bot *and* listed there. Being merely absent from
    /// Home would leave it correctly classified and reachable from nowhere:
    /// `openBotConversation` looks a bot up by the profile it routes to, and
    /// recovered history has none.
    func testRecoveredHistoryIsListedUnderItsBot() {
        let all = [Self.legacyRadar(), Self.canonicalRadar(),
                   Conversation(id: "home", title: "New chat",
                                createdAt: Date(), updatedAt: Date())]

        let underRadar = all.filter {
            $0.isRecoveredHistory && $0.legacyBotName == "radar-ia"
        }
        XCTAssertEqual(underRadar.map(\.id), ["R"])

        // And the routed lookup still finds only the live chat.
        XCTAssertEqual(all.first { $0.routedBotName == "radar-ia" }?.id, "live")
    }

    /// Coming back to "the bot you were talking to" must never land on a
    /// transcript that cannot be replied to.
    func testTheLastBotConversationIsNeverRecoveredHistory() {
        let all = [Self.legacyRadar(), Self.canonicalRadar()]
        let candidates = all.filter { $0.isCanonicalBotChat || $0.isChannel == true }

        XCTAssertEqual(candidates.map(\.id), ["live"])
        XCTAssertFalse(candidates.contains { $0.isRecoveredHistory })
    }

    /// Every gate that stands between recovered history and a send.
    func testRecoveredHistoryCannotSendByAnyRoute() {
        let legacy = Self.legacyRadar()

        XCTAssertNil(legacy.routedBotName, "no profile to submit to")
        XCTAssertNil(legacy.hermesSessionID, "no session to continue")
        XCTAssertFalse(legacy.isCanonicalBotChat, "not the WebSocket path")
        XCTAssertTrue(legacy.isRecoveredHistory, "and send() refuses on this")
        // Nor can it become canonical by accident: nothing here names a bot to
        // route to, so a later refresh has nothing to attach a session to.
        XCTAssertNil(legacy.botName)
    }
}

/// Splitting a persisted row that carries the synthetic directive **and** the
/// user's real message.
///
/// The regression this exists for: the pre-patch `runInput` folded a plain-text
/// send into one string — `"\(preamble)\n\n\(value)"` — so a row that starts
/// with the directive usually ends with something the user actually typed.
/// Treating a prefix match as proof the whole row was scaffolding deleted 35
/// of their messages from the first export.
final class DirectiveSplitTests: XCTestCase {
    private static let directive = """
        You are 'Radar IA', a separate assistant with a voice of your own. \
        Any persona, name, personality or form of address established earlier \
        in this system prompt belongs to a different assistant and does not \
        apply to you: do not use its name for yourself, do not use terms of \
        endearment or a warm companion's register, and do not carry over its \
        habits of speech. Speak plainly as yourself unless your own \
        description below says otherwise.
        """

    /// The split the export must perform: everything after the directive and
    /// its `\n\n` separator is the user's message.
    private func userText(of row: String) -> String? {
        let tail = "Speak plainly as yourself unless your own description below says otherwise."
        guard let range = row.range(of: tail) else { return nil }
        var rest = String(row[range.upperBound...])
        if let what = rest.range(
            of: "^\n\nWhat you are for: [^\n]*", options: .regularExpression
        ) {
            rest = String(rest[what.upperBound...])
        }
        if rest.hasPrefix("\n\n") { rest.removeFirst(2) }
        return rest
    }

    func testAFoldedRowYieldsTheUsersRealMessage() throws {
        let row = Self.directive + "\n\n" + "Muéstrame un resultado de prueba"

        let text = try XCTUnwrap(userText(of: row))

        XCTAssertEqual(text, "Muéstrame un resultado de prueba")
        XCTAssertFalse(text.isEmpty, "this row is not zero messages")
    }

    func testTheDescriptionSuffixIsAlsoStripped() throws {
        let row = Self.directive
            + "\n\nWhat you are for: Editor de noticias de IA"
            + "\n\n" + "por qué no entregaste el job de hoy?"

        XCTAssertEqual(userText(of: row), "por qué no entregaste el job de hoy?")
    }

    func testAPureDirectiveYieldsNothing() throws {
        XCTAssertEqual(userText(of: Self.directive)?.isEmpty, true)
        XCTAssertEqual(userText(of: Self.directive + "\n\n")?.isEmpty, true)
    }

    func testAnOrdinaryMessageIsNotTouched() {
        XCTAssertNil(userText(of: "Hola Alice"), "no directive, nothing to split")
    }

    /// A mention conversation folded the same way, and its user text must
    /// survive even though the conversation stays in Home.
    func testAMentionConversationKeepsItsUserText() throws {
        let row = Self.directive.replacingOccurrences(of: "Radar IA", with: "Chollometro")
            + "\n\n" + "Dame los mejores chollos que tengas ahora, con enlace."

        XCTAssertEqual(
            userText(of: row),
            "Dame los mejores chollos que tengas ahora, con enlace."
        )
    }

    /// Two real sends of the same words are two messages.
    ///
    /// Identity is the persisted row, not the text. A user retrying because
    /// nothing answered typed the same thing twice on purpose, and collapsing
    /// those would delete half of what they said. What a re-persist looks
    /// like instead is two identical rows landing in the *same instant*.
    func testTwoRealSendsOfTheSameTextAreTwoMessages() throws {
        let patch = try RecoveryImporter.read(Data("""
        {"schemaVersion":1,"batchID":"p","conversations":[
          {"conversationID":"C","title":"","legacyBotName":null,
           "recoverySourceSessionID":"C","messages":[
             {"id":"recovered-C-1","remoteRowID":"1","role":"user","content":"hola",
              "createdAt":"2026-09-03T15:00:00Z"},
             {"id":"recovered-C-2","remoteRowID":"2","role":"user","content":"hola",
              "createdAt":"2026-09-03T15:07:00Z"}]}]}
        """.utf8))

        let result = RecoveryImporter.apply(patch, to: [])

        XCTAssertEqual(result[0].messages.count, 2, "seven minutes apart is two sends")
        XCTAssertEqual(result[0].messages.map(\.content), ["hola", "hola"])
        XCTAssertEqual(result[0].messages.map(\.id), ["recovered-C-1", "recovered-C-2"])
    }

    /// The same turn arriving five times from one re-persist is one message.
    /// The export decides this by the instant, and the importer honours the
    /// row identity it was given — one row per real send.
    func testARepersistedTurnCollapsesToOneMessage() throws {
        // What the export produces after applying the instant rule: a single
        // row survived, the four twins in the same instant did not.
        let patch = try RecoveryImporter.read(Data("""
        {"schemaVersion":1,"batchID":"p","conversations":[
          {"conversationID":"C","title":"","legacyBotName":null,
           "recoverySourceSessionID":"C","messages":[
             {"id":"recovered-C-1","remoteRowID":"1","role":"user","content":"hola",
              "createdAt":"2026-09-03T15:00:00Z"}]}]}
        """.utf8))

        let result = RecoveryImporter.apply(patch, to: [])
        XCTAssertEqual(result[0].messages.count, 1)
    }

    /// The patch is applied on top of what is already imported, and adds only
    /// what is missing — running it twice adds nothing.
    func testThePatchIsIdempotentOverAlreadyImportedHistory() throws {
        let existing = [Conversation(
            id: "R", title: "Radar IA — historial anterior",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messages: [Message(id: "recovered-R-9", role: .assistant,
                               content: "respuesta", createdAt: Date(timeIntervalSince1970: 9))],
            legacyBotName: "radar-ia"
        )]
        let patch = try RecoveryImporter.read(Data("""
        {"schemaVersion":1,"batchID":"patch-1","conversations":[
          {"conversationID":"R","title":"","legacyBotName":null,
           "recoverySourceSessionID":"R","messages":[
             {"id":"recovered-R-8","remoteRowID":"8","role":"user",
              "content":"Muéstrame un resultado de prueba",
              "createdAt":"2026-09-04T23:07:00Z"}]}]}
        """.utf8))

        let once = RecoveryImporter.apply(patch, to: existing)
        let twice = RecoveryImporter.apply(patch, to: once)

        XCTAssertEqual(once[0].messages.map(\.id), ["recovered-R-8", "recovered-R-9"],
                       "inserted in canonical order, assistant turn kept")
        XCTAssertEqual(twice[0].messages.count, 2, "no duplicate on a second run")
        XCTAssertEqual(once[0].legacyBotName, "radar-ia", "association untouched")
    }
}

/// Interleaving: a patch applied after the assistants must rebuild the source
/// order, not append itself at the end.
extension DirectiveSplitTests {
    private func archive(_ rows: [(Int, String, String)], batch: String) throws -> RecoveryArchive {
        let messages = rows.map { row in
            """
            {"id":"recovered-C-\(row.0)","remoteRowID":"\(row.0)","role":"\(row.1)",
             "content":"\(row.2)","createdAt":"2026-09-03T15:00:00Z"}
            """
        }.joined(separator: ",")
        return try RecoveryImporter.read(Data("""
        {"schemaVersion":1,"batchID":"\(batch)","conversations":[
          {"conversationID":"C","title":"","legacyBotName":null,
           "recoverySourceSessionID":"C","messages":[\(messages)]}]}
        """.utf8))
    }

    /// Assistants first, users second — the exact shape of this recovery.
    /// Every timestamp here is identical on purpose: only the row id can put
    /// these back in order.
    func testAUserTurnPatchInterleavesByRowID() throws {
        let assistants = try archive([(11, "assistant", "respuesta A"),
                                      (21, "assistant", "respuesta B")], batch: "first")
        let users = try archive([(10, "user", "pregunta A"),
                                 (20, "user", "pregunta B")], batch: "patch")

        let imported = RecoveryImporter.apply(assistants, to: [])
        let patched = RecoveryImporter.apply(users, to: imported)

        XCTAssertEqual(
            patched[0].messages.map(\.id),
            ["recovered-C-10", "recovered-C-11", "recovered-C-20", "recovered-C-21"]
        )
        XCTAssertEqual(patched[0].messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(patched[0].messages.map(\.content),
                       ["pregunta A", "respuesta A", "pregunta B", "respuesta B"])
    }

    func testApplyingTheSamePatchAgainAddsNothing() throws {
        let assistants = try archive([(11, "assistant", "a")], batch: "first")
        let users = try archive([(10, "user", "u")], batch: "patch")
        let once = RecoveryImporter.apply(users, to: RecoveryImporter.apply(assistants, to: []))
        let twice = RecoveryImporter.apply(users, to: once)

        XCTAssertEqual(once[0].messages.count, 2)
        XCTAssertEqual(twice[0].messages.count, 2)
        XCTAssertEqual(once[0].messages.map(\.id), twice[0].messages.map(\.id))
    }
}

/// Deciding what to keep, what to drop, and doing both at once.
extension DirectiveSplitTests {
    private func doc(
        _ conversations: String, remove: [String] = [], preserve: [String] = []
    ) -> Data {
        let r = remove.map { "\"\($0)\"" }.joined(separator: ",")
        let p = preserve.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {"schemaVersion":1,"batchID":"b","removeMessageIDs":[\(r)],
         "preserveMessageIDs":[\(p)],"conversations":[\(conversations)]}
        """.utf8)
    }

    private func chat(_ rows: [(Int, String, String)]) -> String {
        let messages = rows.map { row in
            """
            {"id":"recovered-C-\(row.0)","remoteRowID":"\(row.0)","role":"\(row.1)",
             "content":"\(row.2)","createdAt":"2026-09-03T15:00:00Z"}
            """
        }.joined(separator: ",")
        return """
        {"conversationID":"C","title":"","legacyBotName":null,
         "recoverySourceSessionID":"C","messages":[\(messages)]}
        """
    }

    private func existing(_ ids: [(String, String)]) -> [Conversation] {
        [Conversation(
            id: "C", title: "t", createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messages: ids.map {
                Message(id: $0.0, role: .assistant, content: $0.1,
                        createdAt: Date(timeIntervalSince1970: 0))
            }
        )]
    }

    /// A compacted row with no live twin is content that exists nowhere else.
    func testAUniqueInactiveMessageIsPreserved() throws {
        let archive = try RecoveryImporter.read(doc(
            chat([(20, "user", "nueva")]),
            preserve: ["recovered-C-8794"]
        ))
        let before = existing([("recovered-C-8794", "sólo aquí")])

        let plan = RecoveryImporter.plan(archive, into: before, appliedBatches: [])
        let after = RecoveryImporter.apply(archive, to: before)

        XCTAssertEqual(plan.preserved, ["recovered-C-8794"])
        XCTAssertTrue(after[0].messages.contains { $0.id == "recovered-C-8794" })
        XCTAssertEqual(after[0].messages.count, 2)
    }

    /// A proven exact duplicate goes, and the live twin stays.
    func testAProvenDuplicateIsRemovedInTheSamePass() throws {
        let archive = try RecoveryImporter.read(doc(
            chat([(20, "user", "nueva")]),
            remove: ["recovered-C-8832"]
        ))
        let before = existing([("recovered-C-8832", "mismo"), ("recovered-C-8867", "mismo")])

        let plan = RecoveryImporter.plan(archive, into: before, appliedBatches: [])
        let after = RecoveryImporter.apply(archive, to: before)

        XCTAssertEqual(plan.removals, ["recovered-C-8832"])
        XCTAssertFalse(after[0].messages.contains { $0.id == "recovered-C-8832" })
        XCTAssertTrue(after[0].messages.contains { $0.id == "recovered-C-8867" })
        XCTAssertEqual(after[0].messages.count, 2, "one gone, one added")
    }

    /// Nothing is deleted unless the archive names it. A row that differs
    /// semantically is simply never listed — as happened with 8832, which
    /// carries reasoning its live twin lacks.
    func testARowNotNamedForRemovalSurvives() throws {
        let archive = try RecoveryImporter.read(doc(chat([(20, "user", "nueva")])))
        let before = existing([("recovered-C-8832", "mismo"), ("recovered-C-8867", "mismo")])

        let after = RecoveryImporter.apply(archive, to: before)

        XCTAssertEqual(after[0].messages.count, 3)
        XCTAssertTrue(after[0].messages.contains { $0.id == "recovered-C-8832" })
        XCTAssertTrue(RecoveryImporter.plan(archive, into: before, appliedBatches: []).removals.isEmpty)
    }

    /// Additions and removals land together, in source-row order.
    func testAdditionsAndRemovalsAreOneOperationInRowOrder() throws {
        let archive = try RecoveryImporter.read(doc(
            chat([(10, "user", "u10"), (30, "user", "u30")]),
            remove: ["recovered-C-20"]
        ))
        let before = existing([("recovered-C-20", "fuera"), ("recovered-C-40", "queda")])

        let after = RecoveryImporter.apply(archive, to: before)

        XCTAssertEqual(after[0].messages.map(\.id),
                       ["recovered-C-10", "recovered-C-30", "recovered-C-40"])
    }

    /// A patch that only adds turns already present is a no-op.
    func testASecondApplyChangesNothing() throws {
        let archive = try RecoveryImporter.read(doc(
            chat([(10, "user", "u")]), remove: ["recovered-C-20"]
        ))
        let before = existing([("recovered-C-20", "fuera")])

        let once = RecoveryImporter.apply(archive, to: before)
        let twice = RecoveryImporter.apply(archive, to: once)

        XCTAssertEqual(once[0].messages.map(\.id), twice[0].messages.map(\.id))
        XCTAssertEqual(twice[0].messages.count, 1)
    }

    /// A local turn the archive does not mention is not a conflict.
    func testUnmentionedLocalHistoryIsNotAConflict() throws {
        let archive = try RecoveryImporter.read(doc(chat([(10, "user", "u")])))
        let before = existing([("recovered-C-5", "vieja"), ("recovered-C-6", "vieja")])

        XCTAssertTrue(
            RecoveryImporter.plan(archive, into: before, appliedBatches: []).conflicts.isEmpty
        )
    }

    /// The same id carrying different words is.
    func testDisagreementOverTheSameTurnIsAConflict() throws {
        let archive = try RecoveryImporter.read(doc(chat([(5, "user", "otra cosa")])))
        let before = existing([("recovered-C-5", "vieja")])

        XCTAssertEqual(
            RecoveryImporter.plan(archive, into: before, appliedBatches: []).conflicts.count, 1
        )
    }
}
