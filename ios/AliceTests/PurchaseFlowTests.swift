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

    func testChoiceTokenIsHiddenWithoutChangingWhatIsSubmitted() {
        let choice = "[elección:a1b2c3d4-1] Creatina · HSN · 27,98 €"
        XCTAssertEqual(PurchaseChoice.id(in: choice), "a1b2c3d4-1")
        XCTAssertEqual(PurchaseChoice.display(choice), "Creatina · HSN · 27,98 €")
        XCTAssertEqual(PurchaseChoice.display("@compras " + choice), "@compras Creatina · HSN · 27,98 €")
        XCTAssertEqual(PurchaseChoice.display("Quiero [elección:a1b2c3d4-1]"), "Quiero [elección:a1b2c3d4-1]")
        XCTAssertNil(PurchaseChoice.id(in: "[elección:wrong] Producto"))
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
        let placed = ErrandTranscript.placements(messages: [choice, reply], errands: [errand], session: "chat1")
        XCTAssertEqual(placed.keys.sorted(), ["choice"])
        let foreign = ErrandTranscript.placements(messages: [choice], errands: [errand], session: "other")
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
