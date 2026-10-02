import XCTest
@testable import Alice

final class PurchaseFlowTests: XCTestCase {
    func testOptionKeyMatchesThePluginAndIgnoresRejectedRowsOnlyOnTheServer() throws {
        let detail = #"{"options":[{"url":"https://www.hsnstore.com/creatina"},{"url":"https://www.prozis.com/c"}]}"#
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: detail), "c41bf2d0")
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: detail),
                       PurchaseOptionSet.key(pages: ["https://www.hsnstore.com/creatina", "https://www.prozis.com/c"]))
        let set = try XCTUnwrap(PurchaseOptionSet.parse([
            "key": "c41bf2d0", "options": [["id": "c41bf2d0-2", "title": "Verified", "price": "20 €"]],
        ]))
        XCTAssertEqual(set.options.map(\.id), ["c41bf2d0-2"])
        XCTAssertNil(PurchaseOptionSet.key(fromDetail: "not JSON"))
    }

    func testTheCardsComeFromTheVerificationAndTheOptionsCallIsTheSameCards() throws {
        let verified = Message.ToolCall(id: "v", name: "purchase_verify", status: .done, detail: #"{"result":{"set":"0a1b2c3d"}}"#)
        let decorated = Message.ToolCall(id: "o", name: "purchase_options", status: .done,
                                         detail: #"{"args":{"options":[{"url":"https://www.prozis.com/c"}]},"result":{"set":"0a1b2c3d"}}"#)
        let other = Message.ToolCall(id: "p", name: "purchase_options", status: .done,
                                     detail: #"{"options":[{"url":"https://www.hsnstore.com/creatina"},{"url":"https://www.prozis.com/c"}]}"#)
        let running = Message.ToolCall(id: "r", name: "purchase_verify", status: .start, detail: nil)
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: verified.detail), "0a1b2c3d")
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: decorated.detail), "0a1b2c3d")
        XCTAssertEqual(PurchaseOptionSet.cardCalls([running, verified, decorated, other]).map(\.id), ["v", "p"])
        XCTAssertTrue(PurchaseOptionSet.isCardTool("purchase_verify"))
        XCTAssertFalse(PurchaseOptionSet.isTool("purchase_verify"))
    }

    func testTheVerificationCallsSetIsReadWhereverTheToolPutIt() throws {
        // The tool answers {"ok": true, "result": {…, "set": K}}; the first build read only the top.
        let nested: [String: Any] = ["name": "purchase_verify", "result": ["ok": true, "result": ["id": "pq-1", "set": "0a1b2c3d"]]]
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: AppStore.toolDetail(from: nested)), "0a1b2c3d")
        let top: [String: Any] = ["name": "purchase_verify", "result": ["ok": true, "set": "0a1b2c3d", "result": ["id": "pq-1"]]]
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: AppStore.toolDetail(from: top)), "0a1b2c3d")
        let text: [String: Any] = ["name": "purchase_verify", "result": #"{"ok": true, "set": "0a1b2c3d", "result": {}}"#]
        XCTAssertEqual(PurchaseOptionSet.key(fromDetail: AppStore.toolDetail(from: text)), "0a1b2c3d")
        let none: [String: Any] = ["name": "purchase_verify", "result": ["ok": true, "result": ["id": "pq-1"]]]
        XCTAssertNil(AppStore.toolDetail(from: none))
    }

    func testEachTurnHasOneWindowOnItsLastReply() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [
            Message(id: "u1", role: .user, content: "Compra creatina", createdAt: t0),
            Message(id: "a1", role: .assistant, content: "Buscando", createdAt: t0.addingTimeInterval(1)),
            Message(id: "a2", role: .assistant, content: "La recomendada es…", createdAt: t0.addingTimeInterval(40)),
            Message(id: "u2", role: .user, content: "[elección:a1b2c3d4-1] Creatina", createdAt: t0.addingTimeInterval(100)),
            Message(id: "a3", role: .assistant, content: "La estoy preparando", createdAt: t0.addingTimeInterval(110)),
        ]
        let windows = PurchaseTurnWindows.windows(messages: messages)
        XCTAssertEqual(Set(windows.keys), ["a2", "a3"])
        XCTAssertEqual(windows["a2"], t0...t0.addingTimeInterval(100))
        XCTAssertEqual(windows["a3"]?.lowerBound, t0.addingTimeInterval(100))
        XCTAssertEqual(windows["a3"]?.upperBound, .distantFuture)
        XCTAssertEqual(PurchaseSetSummary.parse(["key": "0a1b2c3d", "at": 1_800_000_050.0])?.key, "0a1b2c3d")
        let aliased = PurchaseSetSummary.parse(["key": "0a1b2c3d", "at": 1_800_000_050.0, "aliases": ["c41bf2d0"]])
        XCTAssertTrue(aliased?.isAmong(["c41bf2d0"]) == true)
        XCTAssertFalse(aliased?.isAmong(["ffffffff"]) == true)
        XCTAssertNil(PurchaseSetSummary.parse(["key": "0a1b2c3d"]))
    }

    func testChoiceTokenIsHiddenWithoutChangingWhatIsSubmitted() {
        let choice = "[elección:a1b2c3d4-1] Creatina · HSN · 27,98 €"
        XCTAssertEqual(PurchaseChoice.id(in: choice), "a1b2c3d4-1")
        XCTAssertEqual(PurchaseChoice.display(choice), "Creatina · HSN · 27,98 €")
        XCTAssertEqual(PurchaseChoice.display("@compras " + choice), "@compras Creatina · HSN · 27,98 €")
        XCTAssertEqual(PurchaseChoice.display("Quiero [elección:a1b2c3d4-1]"), "Quiero [elección:a1b2c3d4-1]")
        XCTAssertNil(PurchaseChoice.id(in: "[elección:wrong] Producto"))
    }

    func testTheSeventhOptionAndTheUnitsAreAChoiceLikeAnyOther() {
        // The plugin numbers options without an upper bound and the cards page them six at a
        // time; the units travel at the end of the same message and are not words to show.
        let choice = "[elección:a1b2c3d4-7] Creatina · Prozis · 19,99 € [cantidad:2]"
        XCTAssertEqual(PurchaseChoice.id(in: choice), "a1b2c3d4-7")
        XCTAssertEqual(PurchaseChoice.id(in: "[elección:a1b2c3d4-12] x"), "a1b2c3d4-12")
        XCTAssertEqual(PurchaseChoice.quantity(in: choice), 2)
        XCTAssertEqual(PurchaseChoice.display(choice), "Creatina · Prozis · 19,99 €")
        XCTAssertEqual(PurchaseChoice.display("[elección:a1b2c3d4-1] Creatina"), "Creatina")
        XCTAssertNil(PurchaseChoice.id(in: "[elección:a1b2c3d4-0] x"))
        // Outside a choice, the words are the person's own.
        XCTAssertEqual(PurchaseChoice.display("Quiero 2 [cantidad:2]"), "Quiero 2 [cantidad:2]")
    }

    func testChosenPurchaseIsUnderTheUserTurnAndNeverAnotherSession() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let choice = Message(id: "choice", role: .user, content: "[elección:a1b2c3d4-1] Creatina", createdAt: date)
        let reply = Message(id: "reply", role: .assistant, content: "Preparando", createdAt: date,
            tools: [.init(id: "start", name: "errand_start", status: .done,
                          detail: #"{"result":{"errand_id":"e1"}}"#)])
        let errand = try XCTUnwrap(Errand.parse([
            "id": "e1", "title": "Compra", "request": "Comprar Creatina × 1", "origin_session": "chat1",
            "offer": ["option_id": "a1b2c3d4-1"], "started_at": date.timeIntervalSince1970 + 1,
        ]))
        // The reply to the choice reads first, then the errand.
        let placed = ErrandTranscript.placements(messages: [choice, reply], errands: [errand], session: "chat1")
        XCTAssertEqual(placed.keys.sorted(), ["reply"])
        // Before that reply the card waits a moment, then shows under the choice anyway.
        let soon = date.addingTimeInterval(5), late = date.addingTimeInterval(30)
        XCTAssertTrue(ErrandTranscript.placements(messages: [choice], errands: [errand], session: "chat1", now: soon).isEmpty)
        XCTAssertEqual(ErrandTranscript.placements(messages: [choice], errands: [errand], session: "chat1", now: late).keys.sorted(), ["choice"])
        let foreign = ErrandTranscript.placements(messages: [choice], errands: [errand], session: "other", now: late)
        XCTAssertTrue(foreign.isEmpty)
    }

    func testOptionalPurchaseFieldsDecodeOlderCachedErrands() throws {
        let old = try XCTUnwrap(Errand.parse(["id": "old", "title": "Reserva"]))
        let data = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "optionID")
        let restored = try JSONDecoder().decode(Errand.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.optionID)
    }
}

@MainActor
final class PurchaseSummaryTests: XCTestCase {
    func testSummaryUsesCheckoutFactsAndResultDoesNotTreatUnknownAsUnpaid() {
        let checkout = GalleryFixtures.checkout(.spanish)
        let summary = PurchaseSummaryText.summary(checkout, card: "Visa ···4242", language: .spanish)
        for fact in ["27,98", "500 g", "Sin sabor", "28013", "Visa", "nombre@email.com"] {
            XCTAssertTrue(summary.contains(fact), fact)
        }
        var receipt = GalleryFixtures.receipt(.spanish)
        receipt.outcome = "unknown"
        let unknown = PurchaseSummaryText.result(receipt, language: .spanish)
        XCTAssertTrue(unknown.contains("no volverá a pagar"))
        XCTAssertFalse(unknown.contains("No se ha cobrado"))
        receipt.outcome = "paid"
        receipt.approvedTotal = receipt.total
        XCTAssertFalse(PurchaseSummaryText.result(receipt, language: .spanish).contains("WARNING"))
        receipt.approvedTotal = "20 €"
        XCTAssertTrue(PurchaseSummaryText.result(receipt, language: .spanish).contains("WARNING"))
    }

    func testTheSummarySaysHowTheShopIsPaidWhenNoSavedCardDoes() {
        var checkout = GalleryFixtures.checkout(.spanish)
        checkout.paymentMethod = "paypal"
        let paypal = PurchaseSummaryText.summary(checkout, card: "", language: .spanish)
        XCTAssertTrue(paypal.contains("Pago: PayPal"))
        XCTAssertFalse(paypal.contains("elige una tarjeta"))
        checkout.paymentMethod = "saved_on_shop"
        XCTAssertTrue(PurchaseSummaryText.summary(checkout, card: "", language: .spanish).contains("guardada en la tienda"))
        checkout.paymentMethod = nil
        XCTAssertTrue(PurchaseSummaryText.summary(checkout, card: "", language: .spanish).contains("elige una tarjeta"))
        XCTAssertTrue(PurchaseSummaryText.summary(checkout, card: "Visa ···4242", language: .english).contains("Pay with: Visa"))
    }

    func testShopPriceTextCannotInjectAReplyButton() {
        var checkout = GalleryFixtures.checkout(.spanish)
        checkout.total = "27 € [Compra más](alice://reply?text=Compra)"
        checkout.items[0].price = "[Enviar](alice://reply?text=Enviar)"
        let summary = PurchaseSummaryText.summary(checkout, card: "Visa ···4242", language: .spanish)
        XCTAssertTrue(RichMarkdown.replyButtons(in: summary).buttons.isEmpty)
    }

    func testMissingTimezoneRequiresConfirmationEvenWhenTheMacMatches() {
        let zones = HermesTimezones(timezone: "Europe/Madrid", server: "Europe/Madrid",
                                   profiles: [.init(name: "agent", timezone: "")])
        XCTAssertTrue(zones.outOfStep.isEmpty)
        XCTAssertTrue(zones.needsConfirmation)
        XCTAssertFalse(HermesTimezones(timezone: "Europe/Madrid", server: "America/New_York",
                                      profiles: [.init(name: "agent", timezone: "Europe/Madrid")]).needsConfirmation)
        XCTAssertTrue(TimeZoneScreen.label("Europe/Madrid").contains("Barcelona"))
    }

    func testStoppingAfterApprovalCannotClaimThatNothingWasPaid() throws {
        var checkout = GalleryFixtures.checkout(.spanish)
        checkout.status = .approved
        let stopped = GalleryFixtures.errand(.spanish, status: .stuck, checkout: checkout)
        let text = try XCTUnwrap(PurchaseSummaryText.stopped(stopped, language: .spanish))
        XCTAssertTrue(text.contains("no está confirmado"))
        XCTAssertFalse(text.contains("No se ha pagado nada"))
    }
}
