import XCTest
@testable import Alice

final class BotMarkTests: XCTestCase {
    func testDerivedMarksVaryThePortrait() {
        let names = ["inbox", "radar", "mercado", "growth", "notes", "alice"]
        let portraits = Set(names.map { BotMark.derived(from: $0).portrait })
        XCTAssertGreaterThan(portraits.count, 1)
    }

    func testDerivedNeverLeavesThePortraitUnset() {
        for name in ["a", "inbox", "", "mercado-radar"] {
            XCTAssertNotNil(BotMark.Portrait(rawValue: BotMark.derived(from: name).shape))
        }
    }

    func testAnUnsetShapePicksTheDerivedPortraitAndKeepsTheColour() {
        let filled = BotMark(colour: 3, shape: 0).fillingPortrait(from: "radar")
        XCTAssertEqual(filled.colour, 3)
        XCTAssertEqual(filled.portrait, BotMark.derived(from: "radar").portrait)
    }

    func testAChosenPortraitIsLeftAlone() {
        let chosen = BotMark(colour: 2, shape: BotMark.Portrait.poseidon.rawValue)
        XCTAssertEqual(chosen.fillingPortrait(from: "radar").shape, chosen.shape)
    }

    func testTheSameNameKeepsTheSameFace() {
        XCTAssertEqual(
            BotMark.derived(from: "inbox"),
            BotMark.derived(from: "inbox")
        )
    }
}
