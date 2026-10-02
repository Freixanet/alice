import XCTest
@testable import Alice

/// Errands as the plugin reports them (`hermes-plugin/errands.py`), and the chat's `errand_start` call.
final class ErrandTests: XCTestCase {
    private let row: [String: Any] = [
        "id": "a1b2c3d4e5", "title": "Comprar Creapure en HSN", "request": "Compra la creatina Creapure de HSN",
        "site": "hsnstore.com", "status": "needs_approval", "started_at": 1_790_000_000.0, "updated_at": 1_790_000_090.0,
        "checkout": [
            "id": "c1", "status": "pending", "merchant": "HSN", "site": "hsnstore.com", "total": "27,98 €",
            "card_label": "Visa ···4242", "delivery": "Envío gratis", "currency": "EUR",
            "items": [["name": "Creatina 500 g", "variant": "Sin sabor", "qty": 1, "price": "27,98 €",
                       "image": "https://www.hsnstore.com/c.jpg"],
                      ["name": "Muestra", "image": "http://insecure.example/x.jpg"],
                      ["variant": "sin nombre"]],
        ],
        "steps": [["text": "Abrir HSN", "url": "https://www.hsnstore.com", "at": 1_790_000_010.0], ["text": ""]],
        "approval": NSNull(), "receipt": NSNull(), "questions": NSNull(),
    ]

    func testAnErrandWaitingForApprovalReadsWithItsCheckout() throws {
        let errand = try XCTUnwrap(Errand.parse(row))
        XCTAssertEqual(errand.status, .needsApproval)
        XCTAssertTrue(errand.status.needsPerson)
        XCTAssertEqual(errand.language, .spanish)
        let checkout = try XCTUnwrap(errand.checkout)
        XCTAssertEqual(checkout.status, .pending)
        XCTAssertEqual(checkout.total, "27,98 €")
        // Only named items, and only https images.
        XCTAssertEqual(checkout.items.map(\.name), ["Creatina 500 g", "Muestra"])
        XCTAssertEqual(checkout.items.first?.image?.absoluteString, "https://www.hsnstore.com/c.jpg")
        XCTAssertNil(checkout.items.last?.image)
        XCTAssertEqual(errand.steps.map(\.text), ["Abrir HSN"])
        XCTAssertNil(errand.receipt)
        XCTAssertNil(errand.approval)
    }

    func testTheErrandsOwnProfileNamesTheVaultForItsCards() throws {
        // A card added from an errand of another profile went to the default vault.
        var bot = row
        bot["profile"] = "compras"
        XCTAssertEqual(try XCTUnwrap(Errand.parse(bot)).vaultProfile, "compras")
        XCTAssertEqual(try XCTUnwrap(Errand.parse(row)).vaultProfile, "default")
        bot["profile"] = ""
        XCTAssertEqual(try XCTUnwrap(Errand.parse(bot)).vaultProfile, "default")
    }

    func testHowTheShopIsPaidAndAnEarlierPaymentRead() throws {
        // A saved card pays unless the checkout says otherwise; older rows have no method.
        XCTAssertTrue(try XCTUnwrap(Errand.parse(row)).checkout?.paysWithSavedCard == true)
        var paypal = row
        var checkout = try XCTUnwrap(row["checkout"] as? [String: Any])
        checkout["payment_method"] = "paypal"
        checkout["card_label"] = ""
        paypal["checkout"] = checkout
        let parsed = try XCTUnwrap(Errand.parse(paypal))
        XCTAssertEqual(parsed.checkout?.paymentMethod, "paypal")
        XCTAssertFalse(parsed.checkout?.paysWithSavedCard ?? true)
        // Stopped because the shop was paid before: «Seguir» means «another order».
        var stopped = row
        stopped["status"] = "stuck"
        stopped["blocked"] = ["kind": "paid_before", "shop": "hsnstore.com"]
        let earlier = try XCTUnwrap(Errand.parse(stopped))
        XCTAssertTrue(earlier.stoppedOnEarlierPayment)
        XCTAssertNil(earlier.blockedPrice)
        XCTAssertFalse(try XCTUnwrap(Errand.parse(row)).stoppedOnEarlierPayment)
    }

    func testAStopAfterApprovalNeverClaimsNothingWasPaid() throws {
        var approved = row
        approved["status"] = "stuck"
        var checkout = try XCTUnwrap(row["checkout"] as? [String: Any])
        checkout["status"] = "approved"
        approved["checkout"] = checkout
        XCTAssertTrue(try XCTUnwrap(Errand.parse(approved)).paymentUnconfirmed)
        // Before approval nothing could have gone out; with a receipt the receipt says it.
        XCTAssertFalse(try XCTUnwrap(Errand.parse(row)).paymentUnconfirmed)
        approved["receipt"] = ["outcome": "unknown", "total": "27,98 €"]
        XCTAssertFalse(try XCTUnwrap(Errand.parse(approved)).paymentUnconfirmed)
        // «Ya pagada» stops the card fill itself: nothing was paid in this errand, and it is not said otherwise.
        approved["receipt"] = NSNull()
        approved["blocked"] = ["kind": "paid_before", "shop": "hsnstore.com"]
        XCTAssertFalse(try XCTUnwrap(Errand.parse(approved)).paymentUnconfirmed)
    }

    func testCachedErrandsWithoutTheNewFieldsStillDecode() throws {
        let errand = try XCTUnwrap(Errand.parse(row))
        let data = try JSONEncoder().encode(errand)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "blockedKind")
        var checkout = try XCTUnwrap(object["checkout"] as? [String: Any])
        checkout.removeValue(forKey: "paymentMethod")
        object["checkout"] = checkout
        let restored = try JSONDecoder().decode(Errand.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.blockedKind)
        XCTAssertNil(restored.checkout?.paymentMethod)
        XCTAssertTrue(restored.checkout?.paysWithSavedCard == true)
    }

    func testErrandAlertsStayQuietOnTheFirstReadingAndSayEachChangeOnce() throws {
        var working = row
        working["status"] = "working"
        working["origin_session"] = "chat-1"
        let first = ErrandAlerts.digest(previous: nil, current: [try XCTUnwrap(Errand.parse(working))], installation: "mac")
        XCTAssertTrue(first.events.isEmpty)
        var waiting = working
        waiting["status"] = "needs_approval"
        let now = ErrandAlerts.digest(previous: first.seen, current: [try XCTUnwrap(Errand.parse(waiting))], installation: "mac")
        XCTAssertEqual(now.events.count, 1)
        let event = try XCTUnwrap(now.events.first)
        XCTAssertEqual(event.kind, .needsInput)
        XCTAssertEqual(event.reference.sessionID, "chat-1")
        XCTAssertEqual(event.reference.installation, "mac")
        XCTAssertFalse(event.summary.contains("27,98"))
        // Read again unchanged: nothing new.
        XCTAssertTrue(ErrandAlerts.digest(previous: now.seen, current: [try XCTUnwrap(Errand.parse(waiting))], installation: "mac").events.isEmpty)
        // The same change always has the same id, so it is notified once across launches.
        XCTAssertEqual(ErrandAlerts.stableHash("a|b"), ErrandAlerts.stableHash("a|b"))
        XCTAssertEqual(ErrandAlerts.waiting([try XCTUnwrap(Errand.parse(waiting)), try XCTUnwrap(Errand.parse(working))]), 1)
    }

    func testErrandAlertsSayHowItEndedAndNeverThatNothingWasPaidAfterAnApproval() throws {
        var working = row
        working["status"] = "working"
        let seen = ErrandAlerts.digest(previous: nil, current: [try XCTUnwrap(Errand.parse(working))], installation: nil).seen
        var paid = working
        paid["status"] = "done"
        paid["receipt"] = ["outcome": "paid", "order": "1", "total": "27,98 €"]
        XCTAssertEqual(ErrandAlerts.digest(previous: seen, current: [try XCTUnwrap(Errand.parse(paid))], installation: nil)
            .events.first?.summary, "Pedido hecho.")
        var stuck = working
        stuck["status"] = "stuck"
        var checkout = try XCTUnwrap(row["checkout"] as? [String: Any])
        checkout["status"] = "approved"
        stuck["checkout"] = checkout
        let said = try XCTUnwrap(ErrandAlerts.digest(previous: seen, current: [try XCTUnwrap(Errand.parse(stuck))], installation: nil).events.first)
        XCTAssertTrue(said.summary.contains("no está confirmado"))
        XCTAssertEqual(said.severity, .failure)
        // What the person did themselves is not news to them.
        var stopped = working
        stopped["status"] = "stopped"
        XCTAssertTrue(ErrandAlerts.digest(previous: seen, current: [try XCTUnwrap(Errand.parse(stopped))], installation: nil).events.isEmpty)
    }

    @MainActor
    func testAFailedAnswerReadsAsOneShortSentence() {
        XCTAssertEqual(ErrandBoard.readable(URLError(.timedOut), language: .spanish), "Tu Mac ha tardado demasiado en responder.")
        XCTAssertEqual(ErrandBoard.readable(URLError(.cannotConnectToHost), language: .english), "Your Mac cannot be reached right now.")
    }

    func testAnUnknownStatusIsReadAsWorkingAndARowWithoutIdIsDropped() {
        var odd = row
        odd["status"] = "something_new"
        XCTAssertEqual(Errand.parse(odd)?.status, .working)
        XCTAssertNil(Errand.parse(["title": "sin id"]))
    }

    func testAPaidReceiptAndQuestionsRead() throws {
        var done = row
        done["status"] = "done"
        done["receipt"] = ["outcome": "paid", "order": "100123456", "total": "27,98 €", "card_label": "Visa ···4242"]
        done["questions"] = ["title": "Tamaño", "items": [["id": "size", "question": "¿Qué tamaño?", "choices": ["500 g", "1 kg"]]]]
        let errand = try XCTUnwrap(Errand.parse(done))
        XCTAssertEqual(errand.receipt?.paid, true)
        XCTAssertEqual(errand.receipt?.order, "100123456")
        XCTAssertEqual(errand.questions.first?.choices, ["500 g", "1 kg"])
        XCTAssertFalse(errand.status.isOpen)
    }

    func testTheChatCallFindsItsErrandByIdOrElseByTitle() throws {
        let complete = #"{"args":{"task":"Compra la creatina","title":"Comprar Creapure en HSN"},"result":{"ok":true,"errand_id":"a1b2c3d4e5","title":"Comprar Creapure en HSN"}}"#
        let ref = try XCTUnwrap(ErrandRef.parse(complete))
        XCTAssertEqual(ref.errandID, "a1b2c3d4e5")
        let errands = [try XCTUnwrap(Errand.parse(row))]
        XCTAssertEqual(ref.find(in: errands)?.id, "a1b2c3d4e5")

        // A transcript read back later keeps only the arguments.
        let started = try XCTUnwrap(ErrandRef.parse(#"{"args":{"title":"Comprar Creapure en HSN"}}"#))
        XCTAssertNil(started.errandID)
        XCTAssertEqual(started.find(in: errands)?.id, "a1b2c3d4e5")
        XCTAssertNil(ErrandRef.parse("not json"))
        XCTAssertNil(ErrandRef.parse(#"{"args":{}}"#))
        XCTAssertTrue(ErrandRef.isTool("errand_start"))
    }

    func testTheStepsReadAsStagesOfThePurchase() throws {
        var working = row
        working["status"] = "needs_card"
        working["card_origin"] = "https://secure9.store.apple.com"
        working["steps"] = [
            ["text": "Abrir la ficha", "url": "https://www.apple.com/es/shop/buy-iphone/iphone-18-pro", "at": 1.0],
            ["text": "Elegir color", "url": "https://www.apple.com/es/shop/buy-iphone/iphone-18-pro", "at": 2.0],
            ["text": "Ver la bolsa", "url": "https://www.apple.com/es/shop/bag", "at": 3.0],
            ["text": "Rellenar dirección", "url": "https://secure9.store.apple.com/es/shop/checkout?_s=Shipping-init", "at": 4.0],
            ["text": "Otra vez", "url": "https://secure9.store.apple.com/es/shop/checkout?_s=Shipping-init", "at": 5.0],
            ["text": "Pagar", "url": "https://secure9.store.apple.com/es/shop/checkout/payment", "at": 6.0],
        ]
        let errand = try XCTUnwrap(Errand.parse(working))
        XCTAssertEqual(errand.status, .needsCard)
        XCTAssertTrue(errand.status.needsPerson)
        XCTAssertEqual(errand.cardOrigin, "https://secure9.store.apple.com")
        XCTAssertEqual(errand.milestones, ["Abrir la ficha", "Cesta", "Datos de envío", "Pago"])
    }

    func testTheStageUnderWayIsNotListedTwice() throws {
        var working = row
        working["status"] = "working"
        working["steps"] = [
            ["text": "Abrir la ficha de Prozis y revisar la variante elegida", "url": "https://www.prozis.com/es/es/prozis/creatina", "at": 1.0],
        ]
        let errand = try XCTUnwrap(Errand.parse(working))
        XCTAssertEqual(errand.currentStage, "Abrir la ficha de Prozis y revisar la variante elegida")
        XCTAssertEqual(errand.earlierStages, [])
        working["steps"] = [
            ["text": "Abrir la ficha", "url": "https://www.prozis.com/es/es/prozis/creatina", "at": 1.0],
            ["text": "Ver la cesta", "url": "https://www.prozis.com/es/es/checkout/index", "at": 2.0],
        ]
        let later = try XCTUnwrap(Errand.parse(working))
        XCTAssertEqual(later.earlierStages, ["Abrir la ficha"])
        // Waiting for the person, every stage is history and listed.
        working["status"] = "needs_login"
        XCTAssertEqual(try XCTUnwrap(Errand.parse(working)).earlierStages, ["Abrir la ficha", "Cesta"])
    }

    func testAVerificationCodeIsNotASecondSignIn() throws {
        var pending = row
        pending["status"] = "needs_login"
        pending["secure_request"] = ["request_id": "srq-c", "kind": "vault.code", "origin": "https://www.prozis.com", "site": "www.prozis.com"]
        let errand = try XCTUnwrap(Errand.parse(pending))
        XCTAssertTrue(try XCTUnwrap(errand.access).isCode)
        if case .code = try XCTUnwrap(errand.accessRequest).kind {} else { XCTFail("a code request") }
        pending["secure_request"] = ["request_id": "srq-l", "kind": "vault.save_login", "origin": "https://www.prozis.com", "site": "www.prozis.com"]
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(Errand.parse(pending)).access).isCode)
    }

    func testPendingShopAccessSurvivesOldAndNewCachedArchives() throws {
        var pending = row
        pending["status"] = "needs_login"
        pending["secure_request"] = ["request_id": "srq-e", "kind": "vault.save_login", "origin": "https://example.com", "site": "Tienda"]
        let errand = try XCTUnwrap(Errand.parse(pending))
        XCTAssertTrue(errand.status.needsPerson)
        XCTAssertEqual(errand.accessRequest?.errandID, errand.id)
        XCTAssertEqual(try JSONDecoder().decode(Errand.self, from: JSONEncoder().encode(errand)).access?.requestID, "srq-e")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(errand)) as! [String: Any]
        legacy.removeValue(forKey: "access")
        XCTAssertNil(try JSONDecoder().decode(Errand.self, from: JSONSerialization.data(withJSONObject: legacy)).access)
    }

    func testElapsedReadsShort() {
        XCTAssertEqual(TimeInterval(42).errandElapsed, "42 s")
        XCTAssertEqual(TimeInterval(180).errandElapsed, "3 min")
        XCTAssertEqual(TimeInterval(3900).errandElapsed, "1 h 5 min")
    }
}
