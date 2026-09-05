import XCTest
@testable import Alice

final class HermesRPCWireTests: XCTestCase {
    func testRequestIsEncodedAsJSONStringForTheTextWebSocketProtocol() throws {
        let text = try HermesRPCClient.wireText(
            id: 7,
            method: "profiles.list",
            params: JSONObject(["include_sessions": true])
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual(object["method"] as? String, "profiles.list")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["include_sessions"] as? Bool, true)
    }
}
