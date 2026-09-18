import XCTest
@testable import Alice

/// Hermes marks the first choice "(Recommended)". That is advice on a question
/// with one answer, and noise on one where every row can be ticked.
@MainActor
final class ClarifyLabelTests: XCTestCase {
    func testTheRecommendationIsKeptWhenThereIsOneAnswerToGive() {
        XCTAssertEqual(
            ClarifyQuestionsView.label("Salud — 4 notas (Recommended)", multiple: false),
            "Salud — 4 notas (Recommended)"
        )
    }

    func testTheRecommendationIsDroppedWhenSeveralCanBeTicked() {
        XCTAssertEqual(
            ClarifyQuestionsView.label("Salud — 4 notas (Recommended)", multiple: true),
            "Salud — 4 notas"
        )
    }

    func testAnOrdinaryChoiceIsLeftAlone() {
        XCTAssertEqual(ClarifyQuestionsView.label("Compras — 3 notas", multiple: true),
                       "Compras — 3 notas")
    }
}
