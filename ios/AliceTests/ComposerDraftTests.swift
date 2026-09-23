import XCTest
import UIKit
@testable import Alice

@MainActor
final class ComposerDraftTests: XCTestCase {
    func testOnlyTheMentionIsBoldAndEverythingUsesTheNormalTextColor() {
        let text = "Before @Radar, after 👋"
        let range = text.range(of: "@Radar")!
        let styled = DraftMentionStyle.render(
            text, ranges: [range], font: UIFont.preferredFont(forTextStyle: .body)
        )

        let before = styled.attributes(at: 0, effectiveRange: nil)
        let mention = styled.attributes(at: (text as NSString).range(of: "@Radar").location, effectiveRange: nil)
        let after = styled.attributes(at: (text as NSString).range(of: "after").location, effectiveRange: nil)
        XCTAssertFalse((before[.font] as! UIFont).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue((mention[.font] as! UIFont).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse((after[.font] as! UIFont).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(before[.foregroundColor] as? UIColor, .label)
        XCTAssertEqual(mention[.foregroundColor] as? UIColor, .label)
        XCTAssertEqual(after[.foregroundColor] as? UIColor, .label)
    }

    func testDeletingAnEntireMentionMovesTheCaretToItsStart() {
        let old = "Ask Radar tomorrow"
        let new = "Ask  tomorrow"
        XCTAssertEqual(
            DraftSelection.remap(NSRange(location: 9, length: 0), from: old, to: new),
            NSRange(location: 4, length: 0)
        )
    }

    func testChoosingAnAgentPutsTheCaretAfterItsName() {
        XCTAssertEqual(
            DraftSelection.remap(NSRange(location: 5, length: 0), from: "Ask @", to: "Ask Radar "),
            NSRange(location: 10, length: 0)
        )
    }

    func testEditsAfterAnEmojiKeepUTF16SelectionPositions() {
        XCTAssertEqual(
            DraftSelection.remap(NSRange(location: 8, length: 0), from: "👋 Ask @", to: "👋 Ask Radar "),
            NSRange(location: 13, length: 0)
        )
    }
}
