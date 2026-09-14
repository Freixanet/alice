import XCTest
@testable import Alice

/// A file that cannot be shown says why in plain words, not in Hermes' own.
final class RemoteFileProblemTests: XCTestCase {
    func testThePlainMeaningOfWhatHermesRefuses() {
        XCTAssertEqual(
            RemoteFileProblem.describe(DashboardClient.Failure.http(403, detail: "Access to sensitive files is not allowed")),
            "This file is private, so Alice doesn’t open it."
        )
        XCTAssertEqual(
            RemoteFileProblem.describe(DashboardClient.Failure.http(404, detail: "File not found")),
            "This file isn’t there any more. It may have been moved or deleted."
        )
        XCTAssertEqual(
            RemoteFileProblem.describe(DashboardClient.Failure.http(413, detail: "File too large")),
            "This file is too big to show here. You can still download it."
        )
    }

    func testAnythingElseKeepsItsOwnDescription() {
        XCTAssertEqual(
            RemoteFileProblem.describe(DashboardClient.Failure.unreachable),
            DashboardClient.Failure.unreachable.errorDescription
        )
    }

    func testFileSymbolsFollowTheType() {
        XCTAssertEqual(RemoteFileSymbol.name(mime: nil, fileName: "informe.pdf"), "doc.richtext")
        XCTAssertEqual(RemoteFileSymbol.name(mime: nil, fileName: "logo.png"), "photo")
        XCTAssertEqual(RemoteFileSymbol.name(mime: nil, fileName: "ventas.xlsx"), "tablecells")
        XCTAssertEqual(RemoteFileSymbol.name(mime: nil, fileName: "notas.md"), "doc.text")
    }
}
