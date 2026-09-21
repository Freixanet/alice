import XCTest
import UIKit
@testable import Alice

/// A photo in a note sits on its own line, at the caret — not in a row of chips.
final class NoteInlineInsertTests: XCTestCase {
    func testACaretAtTheEndPutsTheImageOnTheNextLine() {
        XCTAssertEqual(placed(caret: 5, in: "Hello"), "Hello\n¶\n")
    }

    func testACaretAtTheStartPutsTheImageAboveTheLine() {
        XCTAssertEqual(placed(caret: 0, in: "Hello"), "¶\nHello")
    }

    func testACaretInTheMiddleSplitsTheLine() {
        XCTAssertEqual(placed(caret: 6, in: "Hello world"), "Hello \n¶\nworld")
    }

    func testACaretAtTheEndOfALineGoesBelowIt() {
        XCTAssertEqual(placed(caret: 5, in: "Hello\nWorld"), "Hello\n¶\nWorld")
    }

    func testACaretAtTheStartOfTheNextLineGoesAboveIt() {
        XCTAssertEqual(placed(caret: 6, in: "Hello\nWorld"), "Hello\n¶\nWorld")
    }

    func testAnEmptyLineTakesTheImage() {
        XCTAssertEqual(placed(caret: 6, in: "Hello\n\nWorld"), "Hello\n¶\nWorld")
    }

    func testAnEmptyNoteGetsTheImageOnItsOwnLine() {
        XCTAssertEqual(placed(caret: 0, in: ""), "¶\n")
    }

    func testStyledCopyRemembersWhereThePhotoSat() throws {
        let jpeg = try XCTUnwrap(tinyJPEG())
        let photo = Attachment(
            id: "a1", name: "shot.jpg", mime: "image/jpeg", kind: .image, data: jpeg
        )
        let edited = NSMutableAttributedString(
            string: "Title\n",
            attributes: [.font: RichNote.bodyFont, .foregroundColor: UIColor.label]
        )
        edited.append(NSAttributedString(attachment: NoteInlineAttachment(item: photo)))
        edited.append(NSAttributedString(
            string: "\nAfter",
            attributes: [.font: RichNote.bodyFont, .foregroundColor: UIColor.label]
        ))
        let rich = try XCTUnwrap(RichNote.rtf(from: edited))
        let note = Note(
            id: "n1", createdAt: nil, text: NoteInlineInsert.words(from: edited),
            rich: rich, attachments: [photo]
        )
        let loaded = RichNote.attributed(from: note)
        XCTAssertEqual(NoteInlineInsert.attachments(in: loaded).map(\.id), ["a1"])
        let spoken = NoteInlineInsert.words(from: loaded)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
        XCTAssertEqual(spoken, "Title After")
        XCTAssertNotNil(loaded.string.firstIndex(of: "\u{FFFC}"))
        XCTAssertTrue(loaded.string.hasPrefix("Title"))
        XCTAssertTrue(loaded.string.contains("After"))
    }

    private func placed(caret: Int, in string: String) -> String {
        let plan = NoteInlineInsert.plan(caret: caret, in: string)
        let insert = plan.prefix + "¶" + plan.suffix
        return (string as NSString).replacingCharacters(
            in: NSRange(location: plan.location, length: 0), with: insert
        )
    }

    private func tinyJPEG() -> Data? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
