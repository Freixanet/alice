import XCTest
@testable import Alice

final class PaymentCardTests: XCTestCase {
    func testTheCardLinkLeavesTheTextAndNamesThePaymentSite() throws {
        let (text, services) = RichMarkdown.connectOffers(
            in: "Falta la tarjeta para pagar.\n[Añadir tarjeta](alice://connect/card?origin=https://sis.redsys.es&profile=default)")
        XCTAssertEqual(text, "Falta la tarjeta para pagar.")
        let offer = try XCTUnwrap(services.first.flatMap(PaymentCardOffer.parse))
        XCTAssertEqual(offer.origin, "https://sis.redsys.es")
        XCTAssertEqual(offer.profile, "default")
        XCTAssertEqual(offer.host, "sis.redsys.es")
    }

    func testOnlySecurePagesAndPlainProfileNames() {
        XCTAssertNil(PaymentCardOffer.parse("card?origin=http://shop.example"))
        XCTAssertNil(PaymentCardOffer.parse("card?origin=https://pay.example&profile=../x"))
        XCTAssertEqual(PaymentCardOffer.parse("card?origin=https://pay.example/checkout?a=1")?.origin, "https://pay.example")
    }

    func testTheFormChecksWhatIsTypedBeforeSending() {
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 24).date!
        var card = PaymentCardFields(number: "4242 4242 4242 4242", name: "", expiry: "03/29", cvc: "123")
        XCTAssertTrue(card.isValid(now: now))
        XCTAssertEqual(card.body["exp_month"] as? String, "03")
        XCTAssertEqual(card.body["exp_year"] as? String, "2029")
        XCTAssertEqual(card.body["card_number"] as? String, "4242424242424242")
        card.number = "4242 4242 4242 4241"
        XCTAssertFalse(card.isValid(now: now))
        card.number = "4242424242424242"
        card.expiry = "08/26"
        XCTAssertFalse(card.isValid(now: now))
        XCTAssertEqual(PaymentCardFields.grouped("4242424242424242"), "4242 4242 4242 4242")
    }
}
