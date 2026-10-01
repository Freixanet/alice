import XCTest
@testable import Alice

/// The option set key, computed here and in the plugin from the same fixture
/// (`hermes-plugin/tests/fixtures/option_keys.json`). A change on either side fails this test
/// instead of making the chat's option cards say the options are gone.
final class PurchaseOptionsKeyTests: XCTestCase {
    func testEverySharedVector() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "option_keys", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(vectors.count, 5)
        for vector in vectors {
            let options = try XCTUnwrap(vector["options"] as? [[String: Any]])
            XCTAssertEqual(PurchaseOptionSet.key(options: options), vector["key"] as? String, vector["name"] as? String ?? "")
        }
    }
}
