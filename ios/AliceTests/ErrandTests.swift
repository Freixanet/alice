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

    func testElapsedReadsShort() {
        XCTAssertEqual(TimeInterval(42).errandElapsed, "42 s")
        XCTAssertEqual(TimeInterval(180).errandElapsed, "3 min")
        XCTAssertEqual(TimeInterval(3900).errandElapsed, "1 h 5 min")
    }
}
