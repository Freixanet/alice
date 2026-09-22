import XCTest
@testable import Alice

/// Finding a page's own picture in its head.
final class CardImagesTests: XCTestCase {
    private let base = URL(string: "https://www.thefork.es/restaurante/la-pubilla-r123")!

    func testOpenGraphImageWins() {
        let html = #"<head><meta name="twitter:image" content="https://t.co/b.jpg"><meta property="og:image" content="https://img.thefork.com/a.jpg?w=1200&amp;h=630"></head>"#
        XCTAssertEqual(CardImages.metaImage(in: html, base: base)?.absoluteString, "https://img.thefork.com/a.jpg?w=1200&h=630")
    }

    func testAttributesInAnyOrderAndRelativeAddresses() {
        let html = #"<meta content='/photos/cover.jpg' property='og:image'>"#
        XCTAssertEqual(CardImages.metaImage(in: html, base: base)?.absoluteString, "https://www.thefork.es/photos/cover.jpg")
    }

    func testTwitterImageWhenThereIsNoOpenGraph() {
        let html = #"<meta name="twitter:image:src" content="https://pbs.example/x.png">"#
        XCTAssertEqual(CardImages.metaImage(in: html, base: base)?.absoluteString, "https://pbs.example/x.png")
    }

    func testNoPictureAndNoScripts() {
        XCTAssertNil(CardImages.metaImage(in: "<head><title>x</title></head>", base: base))
        XCTAssertNil(CardImages.metaImage(in: #"<meta property="og:image" content="javascript:alert(1)">"#, base: base))
    }
}
