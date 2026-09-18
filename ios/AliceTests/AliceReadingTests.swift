import UIKit
import XCTest
@testable import Alice

final class AliceReadingTests: XCTestCase {
    func testProseMeasureScalesWithBodySize() {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let measure = AliceReading.proseMeasure(for: body)
        XCTAssertEqual(measure, body.pointSize * 34, accuracy: 0.01)
        XCTAssertGreaterThan(measure, 400)
        XCTAssertLessThan(measure, 1_200)
    }

    func testExtraLeadingStaysNonNegativeAndNearTarget() {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let extra = AliceReading.extraLeading(for: body)
        XCTAssertGreaterThanOrEqual(extra, 0)
        let effective = (body.lineHeight + extra) / body.pointSize
        XCTAssertGreaterThan(effective, 1.19)
        XCTAssertLessThanOrEqual(effective, 1.45)
    }

    func testPresentTurnsProsePunctuationAndLeavesFlagsAlone() {
        XCTAssertEqual(AliceTypography.present("wait..."), "wait…")
        XCTAssertEqual(AliceTypography.present("yes -- no"), "yes — no")
        XCTAssertEqual(AliceTypography.present("don't"), "don\u{2019}t")
        XCTAssertEqual(AliceTypography.present("\"hello\""), "\u{201C}hello\u{201D}")
        XCTAssertEqual(AliceTypography.present("use --force"), "use --force")
        XCTAssertEqual(AliceTypography.present("--no-verify"), "--no-verify")
        XCTAssertEqual(AliceTypography.present("5'10\""), "5'10\"")
        XCTAssertEqual(AliceTypography.present("yes--no"), "yes--no")
    }

    func testMarkdownSourceIsNotRewritten() {
        let source = "use --force... then yes -- no"
        XCTAssertEqual(RichMarkdown.blocks(source), [.paragraph(source)])
    }

    @MainActor
    func testPresentationSkipsInlineCode() {
        let parsed = MessageRow.parsed("run `--force` then yes -- no")
        let text = String(parsed.characters)
        XCTAssertTrue(text.contains("--force"))
        XCTAssertFalse(text.contains("—force"))
        XCTAssertTrue(text.contains("yes — no"))
    }
}
