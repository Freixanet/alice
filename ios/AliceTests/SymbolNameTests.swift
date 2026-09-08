import XCTest
import UIKit
@testable import Alice

/// Every SF Symbol the app names must exist on the deployment target.
///
/// A misspelled symbol is not a compile error and not a crash: SwiftUI logs
/// "No symbol named …" and draws nothing, so a button loses its icon on a
/// screen nobody opened during review. The names are read back out of the
/// source rather than listed here, so this keeps covering symbols added after
/// it was written.
final class SymbolNameTests: XCTestCase {

    func testEveryNamedSymbolExists() throws {
        let names = try Self.symbolNames()
        try XCTSkipIf(names.isEmpty, "sources not readable from the test host")
        XCTAssertGreaterThan(names.count, 50, "the scan found suspiciously few symbols")

        let missing = names.filter { UIImage(systemName: $0) == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "no such SF Symbol: \(missing.joined(separator: ", "))")
    }

    /// Every `systemImage:` / `systemName:` literal under `Alice/`.
    private static func symbolNames() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)      // …/ios/AliceTests/ThisFile.swift
            .deletingLastPathComponent()                 // …/ios/AliceTests
            .deletingLastPathComponent()                 // …/ios
            .appendingPathComponent("Alice")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let pattern = try NSRegularExpression(
            pattern: #"system(?:Image|Name):\s*"([^"]+)""#
        )
        var found: Set<String> = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                found.insert(String(text[captured]))
            }
        }
        return found
    }
}
