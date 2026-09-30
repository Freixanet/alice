import SwiftUI
import XCTest
@testable import Alice

/// Each touch means one thing app-wide (`Haptic`): these are the meanings, pinned.
final class HapticTests: XCTestCase {
    func testEachKindPlaysWhatItMeans() {
        XCTAssertEqual(Haptic.tap.kind, .impact(.light))
        XCTAssertEqual(Haptic.soft.kind, .impact(.soft))
        XCTAssertEqual(Haptic.heavy.kind, .impact(.medium))
        XCTAssertEqual(Haptic.selection.kind, .selection)
        XCTAssertEqual(Haptic.success.kind, .notification(.success))
        XCTAssertEqual(Haptic.warning.kind, .notification(.warning))
        XCTAssertEqual(Haptic.error.kind, .notification(.error))
    }

    func testNoTwoKindsFeelTheSame() {
        let kinds = Haptic.allCases.map(\.kind)
        for (index, kind) in kinds.enumerated() {
            XCTAssertFalse(kinds[(index + 1)...].contains(kind), "\(Haptic.allCases[index]) repeats another kind")
        }
    }
}
