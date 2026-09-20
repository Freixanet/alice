import XCTest
@testable import Alice

/// The canonical Bot Chat: resolving it, reading it, and folding it into what
/// the phone already had.
///
/// The bug these cover: a bot chat in Alice was a private local conversation
/// keyed by a UUID Alice minted, so a cron report Hermes delivered to the
/// bot's own forever-chat was written somewhere Alice never looked.
final class BotChatSessionTests: XCTestCase {
    // MARK: - Fakes

    /// One profile's server-side state.
    private struct Remote {
        var chat: CanonicalBotChat?
        var turns: [BotChatTurn] = []
    }

    private actor FakeSource: BotChatSessionSource {
        private var profiles: [String: Remote]
        private(set) var creates: [String] = []
        private(set) var reads: [String] = []
        var failTranscript: Error?

        init(_ profiles: [String: Remote]) { self.profiles = profiles }

        func canonicalBotChat(profile: String) async throws -> CanonicalBotChat? {
            reads.append(profile)
            return profiles[profile]?.chat
        }

        func createCanonicalBotChat(profile: String) async throws -> CanonicalBotChat {
            creates.append(profile)
            // Mirrors the server: the title is unique, so a create on a
            // profile that already has one hands back the same row.
            if let existing = profiles[profile]?.chat { return existing }
            let chat = CanonicalBotChat(id: "session-\(profile)")
            profiles[profile, default: Remote()].chat = chat
            return chat
        }

        func transcript(profile: String, sessionID: String) async throws -> [BotChatTurn] {
            if let failTranscript { throw failTranscript }
            guard profiles[profile]?.chat?.resolvedID == sessionID else { return [] }
            return profiles[profile]?.turns ?? []
        }

        func append(_ turn: BotChatTurn, to profile: String) {
            profiles[profile, default: Remote()].turns.append(turn)
        }

        func fail(with error: Error) { failTranscript = error }
    }

    private enum Unreachable: Error, LocalizedError {
        case noAnswer
        var errorDescription: String? { "Hermes did not answer." }
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_788_000_000 + seconds)
    }

    private static func turn(
        _ id: String, _ role: Message.Role, _ text: String, _ seconds: TimeInterval
    ) -> BotChatTurn {
        BotChatTurn(id: id, role: role, content: text, createdAt: at(seconds))
    }

    private static let report = turn(
        "m-cron-1", .assistant,
        "**Radar IA — 6 de septiembre de 2026, Europe/Madrid**", 100
    )

    private static func conversation(
        _ profile: String, messages: [Message] = []
    ) -> Conversation {
        Conversation(
            id: UUID().uuidString, title: profile,
            createdAt: at(0), updatedAt: at(0),
            messages: messages, botName: profile
        )
    }

    // MARK: - 1. An existing canonical Bot Chat is what gets shown

    func testOpeningABotShowsTheCanonicalTranscript() async throws {
        let source = FakeSource([
            "radar-ia": Remote(
                chat: CanonicalBotChat(id: "20260905_104136_281747"),
                turns: [Self.report]
            )
        ])
        let sync = BotChatSync(source: source)

        let chat = try await sync.refresh(
            profile: "radar-ia", into: Self.conversation("radar-ia")
        )

        XCTAssertEqual(chat.hermesSessionID, "20260905_104136_281747")
        XCTAssertEqual(chat.messages.map(\.remoteID), ["m-cron-1"])
        XCTAssertEqual(chat.messages[0].botName, "radar-ia")
        XCTAssertTrue(chat.messages[0].content.hasPrefix("**Radar IA"))
        let created = await source.creates
        XCTAssertTrue(created.isEmpty, "an existing canonical chat must be reused")
    }

    // MARK: - 2. A cron delivery arriving later appears once

    func testAnExternalCronDeliveryAppearsExactlyOnce() async throws {
        let source = FakeSource([
            "radar-ia": Remote(chat: CanonicalBotChat(id: "s1"), turns: [
                Self.turn("m-1", .user, "hola", 10),
                Self.turn("m-2", .assistant, "buenas", 20),
            ])
        ])
        let sync = BotChatSync(source: source)
        var chat = try await sync.refresh(profile: "radar-ia", into: Self.conversation("radar-ia"))
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertNil(chat.messages[0].botName, "a real user turn must stay attributed to the user")
        XCTAssertEqual(chat.messages[1].botName, "radar-ia")

        await source.append(Self.report, to: "radar-ia")

        chat = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(chat.messages.map(\.remoteID), ["m-1", "m-2", "m-cron-1"])

        // Reopening again must not draw it a second time.
        chat = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(chat.messages.map(\.remoteID), ["m-1", "m-2", "m-cron-1"])
    }

    // MARK: - 3. Sending continues that session, not an Alice UUID

    func testTheResolvedSessionIsTheOneToContinue() async throws {
        let source = FakeSource([
            "radar-ia": Remote(chat: CanonicalBotChat(id: "20260905_104136_281747"))
        ])
        let sync = BotChatSync(source: source)
        let local = Self.conversation("radar-ia")

        let chat = try await sync.refresh(profile: "radar-ia", into: local)

        XCTAssertEqual(chat.hermesSessionID, "20260905_104136_281747")
        XCTAssertNotEqual(
            chat.hermesSessionID, chat.id,
            "the Hermes session must not be Alice's local UUID"
        )

        // The exchange that follows stays in that same chat.
        await source.append(Self.turn("m-9", .user, "y hoy?", 200), to: "radar-ia")
        await source.append(Self.turn("m-10", .assistant, "aquí va", 210), to: "radar-ia")
        let reloaded = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(reloaded.hermesSessionID, "20260905_104136_281747")
        XCTAssertEqual(reloaded.messages.map(\.remoteID), ["m-9", "m-10"])
    }

    // MARK: - 4. Profiles do not bleed into each other

    func testEachProfileKeepsItsOwnCanonicalChat() async throws {
        let source = FakeSource([
            "radar-ia": Remote(chat: CanonicalBotChat(id: "s-radar"), turns: [Self.report]),
            "researcher": Remote(
                chat: CanonicalBotChat(id: "s-researcher"),
                turns: [Self.turn("m-r", .assistant, "otra cosa", 50)]
            ),
        ])
        let sync = BotChatSync(source: source)

        let radar = try await sync.refresh(profile: "radar-ia", into: Self.conversation("radar-ia"))
        let researcher = try await sync.refresh(
            profile: "researcher", into: Self.conversation("researcher")
        )

        XCTAssertEqual(radar.hermesSessionID, "s-radar")
        XCTAssertEqual(researcher.hermesSessionID, "s-researcher")
        XCTAssertEqual(radar.messages.map(\.remoteID), ["m-cron-1"])
        XCTAssertEqual(researcher.messages.map(\.remoteID), ["m-r"])
    }

    // MARK: - 5. A bot with no chat yet gets exactly one

    func testANewBotGetsOneCanonicalChatAndNoMoreOnReopen() async throws {
        let source = FakeSource(["nuevo": Remote(chat: nil)])
        let sync = BotChatSync(source: source)

        let first = try await sync.resolve(profile: "nuevo")
        let second = try await sync.resolve(profile: "nuevo")

        XCTAssertEqual(first, second)
        let created = await source.creates
        XCTAssertEqual(created, ["nuevo"], "reopening must not mint a second forever-chat")
    }

    // MARK: - 6. A failed read never becomes an empty chat

    func testAFailedFetchKeepsTheCachedTranscript() async throws {
        let source = FakeSource(["radar-ia": Remote(chat: CanonicalBotChat(id: "s1"))])
        let cached = Self.conversation("radar-ia", messages: [
            Message(id: "local-1", role: .assistant, content: "informe de ayer",
                    createdAt: Self.at(10), remoteID: "m-old")
        ])
        await source.fail(with: Unreachable.noAnswer)
        let sync = BotChatSync(source: source)

        do {
            _ = try await sync.refresh(profile: "radar-ia", into: cached)
            XCTFail("a failed read must not resolve to a transcript")
        } catch {
            // The caller keeps `cached` on screen; nothing here emptied it.
            XCTAssertEqual(cached.messages.count, 1)
        }
    }

    // MARK: - 7. Migration of a chat Alice kept before this change

    func testAnOldLocalChatAttachesWithoutReplayingItsHistory() async throws {
        let source = FakeSource([
            "radar-ia": Remote(chat: CanonicalBotChat(id: "s1"), turns: [Self.report])
        ])
        let legacy = Self.conversation("radar-ia", messages: [
            Message(id: "local-1", role: .user, content: "pregunta vieja", createdAt: Self.at(1)),
            Message(id: "local-2", role: .assistant, content: "respuesta vieja", createdAt: Self.at(2)),
        ])
        XCTAssertNil(legacy.hermesSessionID)

        let chat = try await BotChatSync(source: source).refresh(
            profile: "radar-ia", into: legacy
        )

        XCTAssertEqual(chat.hermesSessionID, "s1")
        // Kept, marked, and in order — never pushed into Hermes, which has no
        // record of them and must not be given a fabricated one.
        XCTAssertEqual(chat.messages.map(\.content),
                       ["pregunta vieja", "respuesta vieja", Self.report.content])
        XCTAssertEqual(chat.messages.filter(\.localOnly).map(\.id), ["local-1", "local-2"])
        XCTAssertNil(chat.messages[0].botName)
        XCTAssertEqual(chat.messages[1].botName, "radar-ia")
        XCTAssertEqual(chat.messages[2].botName, "radar-ia")
        let created = await source.creates
        XCTAssertTrue(created.isEmpty)
    }

    // MARK: - 8. Ordinary chats are untouched

    func testANonBotConversationIsNotABotChat() {
        let ordinary = Conversation(
            id: "local", title: "New chat", createdAt: Self.at(0), updatedAt: Self.at(0)
        )
        XCTAssertNil(ordinary.botName)
        XCTAssertNil(ordinary.hermesSessionID)
        XCTAssertFalse(ordinary.isBotChat)
    }

    // MARK: - 9. A message arriving while the chat is open

    func testAMessageArrivingWhileOpenAppearsOnRefreshWithoutDuplicating() async throws {
        let source = FakeSource([
            "radar-ia": Remote(chat: CanonicalBotChat(id: "s1"), turns: [
                Self.turn("m-1", .assistant, "informe de ayer", 10)
            ])
        ])
        let sync = BotChatSync(source: source)
        var chat = try await sync.refresh(profile: "radar-ia", into: Self.conversation("radar-ia"))

        // Something in flight on this device while the report lands remotely.
        chat.messages.append(
            Message(id: "draft-reply", role: .assistant, content: "",
                    createdAt: Self.at(300), pending: true)
        )
        await source.append(Self.report, to: "radar-ia")

        chat = try await sync.refresh(profile: "radar-ia", into: chat)

        XCTAssertEqual(chat.messages.map(\.id), ["m-1", "m-cron-1", "draft-reply"])
        XCTAssertTrue(chat.messages.last?.pending == true, "the streaming reply survived")
        XCTAssertFalse(chat.messages.last?.localOnly == true, "in-flight is not local-only history")

        chat = try await sync.refresh(profile: "radar-ia", into: chat)
        XCTAssertEqual(chat.messages.map(\.id), ["m-1", "m-cron-1", "draft-reply"])
    }

    // MARK: - Merge invariants

    func testMergeIsIdempotent() {
        let remote = [Self.turn("a", .user, "1", 1), Self.turn("b", .assistant, "2", 2)]
        let once = BotChatSync.merge(remote, into: [])
        let twice = BotChatSync.merge(remote, into: once)
        XCTAssertEqual(once.map(\.id), twice.map(\.id))
        XCTAssertEqual(once.map(\.content), twice.map(\.content))
    }

    /// Two identical daily briefings are two messages. Deduplicating on text
    /// would silently delete one.
    func testIdenticalTextOnDifferentDaysStaysTwoMessages() {
        let merged = BotChatSync.merge([
            Self.turn("day-1", .assistant, "Sin novedades.", 10),
            Self.turn("day-2", .assistant, "Sin novedades.", 20),
        ], into: [])
        XCTAssertEqual(merged.count, 2)
    }

    /// A turn the agent re-rendered is still the same turn.
    func testAnEditedRemoteTurnReplacesRatherThanDuplicates() {
        let first = BotChatSync.merge([Self.turn("m", .assistant, "borrador", 10)], into: [])
        let second = BotChatSync.merge([Self.turn("m", .assistant, "definitivo", 10)], into: first)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].content, "definitivo")
    }

    /// Empty assistant rows imported by an older build were Hermes tool-call
    /// envelopes, not conversational turns. Once the canonical parser omits
    /// them, a refresh must also remove the cached timestamp-only shell.
    func testCachedEmptyRemoteAssistantShellIsRetired() {
        let ghost = Message(
            id: "194", role: .assistant, content: "", createdAt: Self.at(20),
            botName: "Cuba News", remoteID: "194"
        )
        let merged = BotChatSync.merge(
            [Self.turn("211", .assistant, "Configuración verificada", 30)],
            into: [ghost]
        )
        XCTAssertEqual(merged.map(\.id), ["211"])
    }

    /// Narration sealed before a tool call has text and no remote id. Hermes
    /// drops that row from the transcript; the phone must still keep it.
    func testSealedNarrationSurvivesATranscriptWithoutIt() {
        let narration = Message(
            id: "local-narration", role: .assistant,
            content: "Voy a buscar el precio", createdAt: Self.at(20),
            botName: "radar-ia", interim: true
        )
        let merged = BotChatSync.merge(
            [Self.turn("211", .assistant, "El precio es 12", 30)],
            into: [narration]
        )
        XCTAssertTrue(merged.contains(where: { $0.id == "local-narration" }))
        XCTAssertTrue(merged.contains(where: { $0.id == "211" }))
    }

    /// A message just sent, not yet persisted, must not vanish on the refresh
    /// that races it.
    func testAnUnacknowledgedSendSurvives() {
        let sent = Message(
            id: "local-send", role: .user, content: "¿y hoy?",
            createdAt: Self.at(500), runStatus: .running
        )
        let merged = BotChatSync.merge([Self.turn("m-1", .assistant, "ayer", 10)], into: [sent])
        XCTAssertEqual(merged.map(\.id), ["m-1", "local-send"])
        XCTAssertFalse(merged[1].localOnly)
    }

    func testRetryCorrelationFindsThePersistedOriginByItsRemoteIdentity() throws {
        let origin = Message(
            id: "local-send", role: .user, content: "repite",
            createdAt: Self.at(10), remoteMatchContent: "repite"
        )
        let reply = Message(
            id: "local-reply", role: .assistant, content: "falló",
            createdAt: Self.at(11), replyToMessageID: origin.id
        )
        let conversation = Self.conversation("radar-ia", messages: [origin, reply])

        let id = try AppStore.retryTurnID(
            in: [Self.turn("remote-current", .user, "repite", 10)],
            conversation: conversation,
            replyID: reply.id,
            origin: origin,
            profile: "radar-ia"
        )

        XCTAssertEqual(id, "remote-current")
    }

    func testRetryCorrelationDoesNotClaimAnEarlierIdenticalMessage() throws {
        let earlier = Message(
            id: "remote-earlier", role: .user, content: "repite",
            createdAt: Self.at(10), remoteID: "remote-earlier"
        )
        let origin = Message(
            id: "local-send", role: .user, content: "repite",
            createdAt: Self.at(20), remoteMatchContent: "repite"
        )
        let reply = Message(
            id: "local-reply", role: .assistant, content: "falló",
            createdAt: Self.at(21), replyToMessageID: origin.id
        )
        let conversation = Self.conversation(
            "radar-ia", messages: [earlier, origin, reply]
        )

        let id = try AppStore.retryTurnID(
            in: [Self.turn("remote-earlier", .user, "repite", 10)],
            conversation: conversation,
            replyID: reply.id,
            origin: origin,
            profile: "radar-ia"
        )

        XCTAssertNil(id, "the newer local send has nothing in Hermes to rewind")
    }

    func testRetryCorrelationFollowsAPersistedCopyOfTheFailedReply() throws {
        let origin = Message(
            id: "local-send", role: .user, content: "repite",
            createdAt: Self.at(10), remoteMatchContent: "repite"
        )
        let reply = Message(
            id: "local-reply", role: .assistant, content: "falló",
            createdAt: Self.at(11), replyToMessageID: origin.id
        )
        let conversation = Self.conversation("radar-ia", messages: [origin, reply])
        let remote = [
            Self.turn("remote-user", .user, "repite", 10),
            Self.turn("remote-reply", .assistant, "falló", 11),
        ]

        let id = try AppStore.retryTurnID(
            in: remote,
            conversation: conversation,
            replyID: reply.id,
            origin: origin,
            profile: "radar-ia"
        )

        XCTAssertEqual(id, "remote-user")
    }
}
