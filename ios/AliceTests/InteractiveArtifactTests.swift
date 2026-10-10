import XCTest
@testable import Alice

final class InteractiveArtifactTests: XCTestCase {
    private let json = #"{"title":"Cuenta","summary":"Ejemplo local","initialHeight":300,"placeholderMessages":["Uno","Dos"],"css":"","html":"<p>10 €</p>","jsFunctions":"","jsExpressions":""}"#

    func testCompleteFenceIsOneInteractiveBlock() {
        let blocks = RichMarkdown.blocks("```alice-interactive\n\(json)\n```")
        XCTAssertEqual(blocks.count, 1)
        guard case .interactive(let artifact) = blocks[0] else { return XCTFail("Expected the native isolated renderer") }
        XCTAssertEqual(artifact.title, "Cuenta")
    }

    func testUnclosedFenceNeverBecomesExecutable() {
        let blocks = RichMarkdown.blocks("```alice-interactive\n\(json)")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(_, let original) = blocks[0] else { return XCTFail("Partial UI must remain inert") }
        XCTAssertEqual(original, json)
    }

    func testKnownChatMetadataVariationStillRenders() {
        let variant = json.replacingOccurrences(of: "{\"title\"", with: "{\"type\":\"alice-interactive\",\"title\"")
            .replacingOccurrences(of: "[\"Uno\",\"Dos\"]", with: "[\"Uno\"]")
        let blocks = RichMarkdown.blocks("```alice-interactive\n\(variant)\n```")
        XCTAssertEqual(blocks.count, 1)
        guard case .interactive(let artifact) = blocks[0] else { return XCTFail("Known loading/type metadata must render") }
        XCTAssertEqual(artifact.html, "<p>10 €</p>")
        XCTAssertEqual(artifact.placeholderMessages, ["Uno", "Uno"])
    }

    func testInvalidArtifactKeepsItsOriginalSource() {
        let invalid = json.replacingOccurrences(of: "<p>10 €</p>", with: "<iframe src='file:///private'>")
        let blocks = RichMarkdown.blocks("```alice-interactive\n\(invalid)\n```")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(_, let original) = blocks[0] else { return XCTFail("Invalid UI must remain inert") }
        XCTAssertEqual(original, invalid)
    }
}
