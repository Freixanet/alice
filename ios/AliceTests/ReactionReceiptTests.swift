import XCTest
@testable import Alice

/// Answering with a thumb, citing past conversations, and the record of what
/// agents did.
final class ReactionTests: XCTestCase {
    private func message(_ id: String, _ role: Message.Role, _ content: String) -> Message {
        Message(id: id, role: role, content: content, createdAt: Date())
    }

    func testAThumbReadsBackWhateverWroteIt() {
        XCTAssertEqual(ReactionTurn.parse("👍")?.reaction, .yes)
        XCTAssertEqual(ReactionTurn.parse("👎🏽")?.reaction, .no)
        XCTAssertEqual(ReactionTurn.parse("@inbox 👍")?.reaction, .yes)
        let quoted = ReactionTurn.parse("> Te propongo mover la cena…\n👍\n(añadido a mi calendario)")
        XCTAssertEqual(quoted, ReactionTurn(reaction: .yes, quote: "Te propongo mover la cena…", note: "añadido a mi calendario"))
    }

    func testWordsAreNotAReaction() {
        XCTAssertNil(ReactionTurn.parse("👍 vale, hazlo"))
        XCTAssertNil(ReactionTurn.parse("sí"))
        XCTAssertNil(ReactionTurn.parse("> cita\nsí"))
        XCTAssertNil(ReactionTurn.parse("👍\nnota sin paréntesis"))
    }

    func testTheTurnSurvivesTheRoundTrip() {
        let turn = ReactionTurn(reaction: .no, quote: "El viernes a las 9", note: nil)
        XCTAssertEqual(turn.text, "> El viernes a las 9\n👎")
        XCTAssertEqual(ReactionTurn.parse(turn.text), turn)
    }

    func testTheQuoteIsPlainWordsCutOnAWord() {
        let reply = "**Plan:** mira [la web](https://x.com) y dime.\n```alice-ui\n{\"type\":\"events\"}\n```\n" + String(repeating: "palabra ", count: 30)
        let snippet = ReactionTurn.snippet(of: reply)
        XCTAssertTrue(snippet.hasPrefix("Plan: mira la web y dime. palabra"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual(snippet.count, ReactionTurn.quoteLength + 1)
        XCTAssertFalse(snippet.contains("alice-ui"))
    }

    func testABareThumbAnswersTheReplyBeforeIt() {
        let messages = [
            message("a1", .assistant, "¿Lo apunto?"),
            message("u1", .user, "👍"),
        ]
        XCTAssertEqual(Reactions.given(in: messages), ["a1": .yes])
    }

    func testAQuotedThumbAnswersTheReplyItQuotes() {
        let older = "Te propongo mover la cena al viernes a las nueve, que el jueves tienes pádel."
        let messages = [
            message("a1", .assistant, older),
            message("u1", .user, "vale"),
            message("a2", .assistant, "Otra cosa: ¿miro vuelos?"),
            message("u2", .user, ReactionTurn(reaction: .no, quote: ReactionTurn.snippet(of: older)).text),
        ]
        XCTAssertEqual(Reactions.given(in: messages), ["a1": .no])
    }

    func testAReactionDoesNotPassOverTheOthers() {
        XCTAssertTrue(Reactions.isReaction(message("u", .user, "👍")))
        XCTAssertFalse(Reactions.isReaction(message("u", .user, "vale")))
        XCTAssertFalse(Reactions.isReaction(message("a", .assistant, "👍")))
    }

    func testARepliesInvitesAThumbWhenItAsksOrOffers() {
        XCTAssertTrue(Reactions.invites(message("a", .assistant, "Lo tengo.\n\n¿Lo reservo?")))
        XCTAssertTrue(Reactions.invites(message("a", .assistant, "[Sí](alice://reply?text=S%C3%AD)")))
        XCTAssertFalse(Reactions.invites(message("a", .assistant, "Hecho, está reservado.")))
    }
}

final class ReceiptTests: XCTestCase {
    func testTokensAreFoundWithOrWithoutProfileAndMessage() {
        let text = "Lo dijiste en @session:default/20260922_165037_611d6d#10253 y en `@session:inbox/cron_cffca6f34c20_20260922_215139`."
        let cited = Receipts.cited(in: text)
        XCTAssertEqual(cited, [
            RichReceipt(profile: "default", session: "20260922_165037_611d6d", message: 10253),
            RichReceipt(profile: "inbox", session: "cron_cffca6f34c20_20260922_215139"),
        ])
        XCTAssertEqual(Receipts.cited(in: "@session:20260922_165037_611d6d.").first?.profile, nil)
    }

    func testTokensBecomeTitledLinksAndSources() {
        let text = "Quedasteis el viernes @session:default/20260922_165037_611d6d#12."
        let untitled = Receipts.titled(text, titles: [:], language: .spanish)
        XCTAssertTrue(untitled.hasPrefix("Quedasteis el viernes [esa conversación](alice://receipt?"), untitled)
        let titled = Receipts.titled(text, titles: ["20260922_165037_611d6d": "Plan de viaje"], language: .spanish)
        XCTAssertTrue(titled.contains("[Plan de viaje](alice://receipt?session=20260922_165037_611d6d&profile=default&m=12)."), titled)
        let blocks = RichMarkdown.blocks(titled)
        guard case let .receipts(list) = blocks.last else { return XCTFail("\(blocks)") }
        XCTAssertEqual(list, [RichReceipt(profile: "default", session: "20260922_165037_611d6d", message: 12)])
    }

    func testCodeKeepsTheTokenAsWritten() {
        let text = "```\n@session:default/20260922_165037_611d6d\n```"
        XCTAssertEqual(Receipts.titled(text, titles: [:], language: .english), text)
    }

    func testOnlyWellFormedReceiptLinksOpen() {
        XCTAssertNotNil(RichReceipt(url: URL(string: "alice://receipt?session=20260922_165037_611d6d&profile=inbox")!))
        XCTAssertNil(RichReceipt(url: URL(string: "alice://receipt?session=../../etc")!))
        XCTAssertNil(RichReceipt(url: URL(string: "https://receipt?session=20260922_165037_611d6d")!))
        let odd = RichReceipt(url: URL(string: "alice://receipt?session=20260922_165037_611d6d&profile=../x")!)
        XCTAssertNil(odd?.profile)
    }

    func testTheServersReceiptReads() {
        let parsed = ConversationReceipt.parse([
            "profile": "default", "session": "cron_cffca6f34c20_1", "title": "Cierre del día · Sep 22",
            "started_at": 1_790_114_724.0,
            "origin": ["place": "routine", "title": "Cierre del día", "routine": "default/cffca6f34c20"],
            "messages": [
                ["id": "1", "role": "user", "text": "¿Qué tengo mañana?", "at": 1.0, "anchor": false],
                ["id": "2", "role": "assistant", "text": "Nada.", "at": 2.0, "anchor": true],
                ["id": "3", "role": "tool", "text": "{}", "anchor": false],
            ],
        ])
        XCTAssertEqual(parsed?.routineKey, "default/cffca6f34c20")
        XCTAssertEqual(parsed?.turns.map(\.id), ["1", "2"])
        XCTAssertEqual(parsed?.turns.last?.anchor, true)
        XCTAssertEqual(parsed?.displayTitle(agent: "Alice"), "Cierre del día")
        XCTAssertEqual(ConversationReceipt.displayTitle("Bot Chat", routine: nil, agent: "Inbox"), String(localized: "Chat with Inbox"))
    }
}

final class AgentActionTests: XCTestCase {
    func testAServerRowReads() {
        let action = AgentAction.parse([
            "id": "abc", "at": 1_790_114_724.5, "profile": "inbox", "session": "cron_cffca6f34c20_1",
            "tool": "terminal", "kind": "email.sent", "target": "ana@example.com", "ok": false,
            "origin": ["place": "routine", "title": "Correo", "routine": "inbox/cffca6f34c20"],
        ])
        XCTAssertEqual(action?.kind, "email.sent")
        XCTAssertEqual(action?.place, .routine)
        XCTAssertEqual(action?.routineKey, "inbox/cffca6f34c20")
        XCTAssertEqual(action?.ok, false)
        XCTAssertEqual(action?.sentence, String(localized: "Sent an email to \("ana@example.com")"))
        XCTAssertTrue(action?.weighty ?? false)
    }

    func testRowsWithoutAKindAreDropped() {
        XCTAssertNil(AgentAction.parse(["id": "x", "at": 1.0]))
    }

    func testDaysGroupNewestFirst() {
        let calendar = Calendar(identifier: .gregorian)
        func action(_ at: TimeInterval) -> AgentAction {
            AgentAction(id: "\(at)", at: Date(timeIntervalSince1970: at), profile: "default", session: nil,
                        kind: "note.saved", target: "", ok: true, place: .chat, originTitle: "", routineKey: nil)
        }
        let days = AgentActionDays.group([action(0), action(90_000), action(100)], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.actions.map(\.id), ["90000.0"])
        XCTAssertEqual(days.last?.actions.map(\.id), ["100.0", "0.0"])
    }
}
