import XCTest
@testable import Alice

/// Developer › Components shows every sample, in both languages, and closed options keep their style.
@MainActor
final class ComponentGalleryTests: XCTestCase {
    func testEverySampleDrawsSomethingInBothLanguages() {
        for sample in GallerySample.allCases {
            for language in [ChatLanguage.spanish, .english] {
                switch sample.content(language) {
                case let .markdown(text):
                    XCTAssertFalse(text.isEmpty, "\(sample) is empty in \(language)")
                    XCTAssertFalse(RichMarkdown.blocks(text).isEmpty, "\(sample) draws no block in \(language)")
                case let .messages(messages):
                    XCTAssertFalse(messages.isEmpty, "\(sample) has no message in \(language)")
                case let .taskBlocks(blocks):
                    XCTAssertEqual(blocks.count, 1, "\(sample) needs a Task result")
                    XCTAssertTrue(TaskBlockGallery.allCases.map(\.rawValue).contains(blocks.first?.type ?? ""))
                case .view:
                    break
                }
            }
        }
    }

    func testEverySectionHasSamplesAndTitlesAreDistinct() {
        for section in GallerySection.allCases {
            XCTAssertFalse(GallerySample.allCases.filter { $0.section == section }.isEmpty, "\(section) is empty")
        }
        let titles = GallerySample.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testTheSandboxHasNoHermesBehindIt() {
        let sandbox = GalleryFixtures.sandbox(like: AppStore(defaults: UserDefaults(suiteName: "alice.tests.gallery")!))
        XCTAssertTrue(sandbox.gatewayURL.isEmpty)
        XCTAssertTrue(sandbox.dashboardURL.isEmpty)
        XCTAssertNotNil(sandbox.liveBrowser.image)
    }

    func testClosedOptionsKeepTheirStyle() {
        let parsed = RichMarkdown.replyButtons(in: """
        ¿Qué talla?
        [S](alice://reply?text=S&style=filled)
        [M](alice://reply?text=M&style=dotted)
        [Otra](alice://reply?text=Otra)
        """)
        XCTAssertEqual(parsed.buttons.map(\.style), [.filled, .dotted, .soft])
        XCTAssertEqual(parsed.buttons.map(\.reply), ["S", "M", "Otra"])
        XCTAssertEqual(parsed.text, "¿Qué talla?")
    }
}
