import XCTest
@testable import Alice

final class StatusCaptionTests: XCTestCase {
    func testHermesPlumbingIsNotShownAndLongStatusesAreShort() {
        XCTAssertNil(AppStore.statusCaption("✅ Primary model restored: gemini-3.8-flash via copilot; fallback gpt-6-luna"))
        XCTAssertNil(AppStore.statusCaption("Compressing context…"))
        XCTAssertEqual(AppStore.statusCaption("Buscando vuelos"), "Buscando vuelos")
        XCTAssertEqual(AppStore.statusCaption("Leyendo la página de la tienda para encontrar el saco exacto"),
                       "Leyendo la página de la tienda para…")
    }
}
