import XCTest
@testable import Alice

/// The app against the errands the plugin really produces: every state the purchase simulator
/// (`hermes-plugin/qa/sim.py`) passed through, written by `python scripts/qa.py snapshots` into
/// `hermes-plugin/tests/fixtures/errand_states.json`. A change on the plugin's side that the app
/// cannot read, or a card that would say something false, fails here.
final class ErrandContractTests: XCTestCase {
    private func states() throws -> [(String, [String: Any])] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "errand_states", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let states = try XCTUnwrap(root["states"] as? [String: [String: Any]])
        XCTAssertGreaterThanOrEqual(states.count, 10, "the simulator should have produced every main state")
        return try states.sorted { $0.key < $1.key }.map { key, value in
            (key, try XCTUnwrap(value["errand"] as? [String: Any], key))
        }
    }

    func testEveryStateTheMacProducesIsReadWithItsStatus() throws {
        for (key, row) in try states() {
            let errand = try XCTUnwrap(Errand.parse(row), key)
            XCTAssertEqual(errand.status.rawValue, row["status"] as? String, key)
            XCTAssertEqual(errand.language, .spanish, key)
            XCTAssertFalse(errand.title.isEmpty, key)
            if row["checkout"] is [String: Any] { XCTAssertNotNil(errand.checkout, key) }
            if row["receipt"] is [String: Any] { XCTAssertNotNil(errand.receipt, key) }
        }
    }

    @MainActor
    func testNoCardSaysNothingWasPaidOnceAPaymentWasApproved() throws {
        for (key, row) in try states() {
            let errand = try XCTUnwrap(Errand.parse(row), key)
            guard errand.checkout?.status == .approved else { continue }
            let words = [PurchaseSummaryText.stopped(errand, language: .spanish),
                         errand.receipt.map { PurchaseSummaryText.result($0, language: .spanish) }].compactMap { $0 }
            for text in words where errand.receipt?.outcome != "declined" && errand.receipt?.outcome != "not_charged" {
                XCTAssertFalse(text.contains("No se ha pagado nada"), key)
                XCTAssertFalse(text.contains("No se ha cobrado nada"), key)
            }
            if errand.status == .stuck {
                XCTAssertTrue(errand.receipt != nil || errand.paymentUnconfirmed, "\(key): a stop after approval says the payment is unconfirmed")
            }
        }
    }

    func testEveryStateThatNeedsThePersonIsToldAndEveryStopHasAReason() throws {
        for (key, row) in try states() {
            let errand = try XCTUnwrap(Errand.parse(row), key)
            if errand.status.needsPerson {
                XCTAssertNotNil(ErrandAlerts.event(for: errand, mark: key, installation: nil), "\(key) must be notified")
            }
            if errand.status == .stuck {
                XCTAssertFalse(errand.reason.isEmpty, "\(key) stops without saying why")
            }
            if errand.status == .needsInput { XCTAssertFalse(errand.questions.isEmpty, key) }
            if errand.status == .needsApproval { XCTAssertEqual(errand.checkout?.status, .pending, key) }
            if errand.status == .stuck, row["blocked"] as? [String: Any] != nil,
               (row["blocked"] as? [String: Any])?["kind"] as? String == "price" {
                XCTAssertNotNil(errand.blockedPrice, "\(key): the new price is offered to accept")
            }
        }
    }
}
