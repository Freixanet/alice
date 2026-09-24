import XCTest
@testable import Alice

final class SecureRequestTests: XCTestCase {
    func testHermesVaultRequestsBecomeSecureCards() {
        let login = SecureRequest.parse(["request_id": "srq-1", "kind": "vault.save_login",
                                         "origin": "https://www.piensosraposo.es", "site": "piensosraposo.es"])
        XCTAssertEqual(login?.kind, .saveLogin(origin: "https://www.piensosraposo.es", site: "piensosraposo.es"))
        let code = SecureRequest.parse(["request_id": "srq-2", "kind": "vault.code", "site": "Banco"])
        XCTAssertEqual(code?.kind, .code(site: "Banco", hint: nil))
        XCTAssertNil(SecureRequest.parse(["request_id": "srq-3", "kind": "vault.save_login"]))
        XCTAssertNil(SecureRequest.parse(["kind": "secret", "env_var": "X"]))
        XCTAssertEqual(GatewayServerRequests.event(id: "srq-9", method: "vault.code", params: ["session_id": "s"])?.type,
                       "secure.request")
    }

    func testTheLoginAnswerIsTheJSONHermesReads() throws {
        let text = SecureRequest.loginAnswer(identifier: "a@b.com", password: "p\"w")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        XCTAssertEqual(object, ["identifier": "a@b.com", "password": "p\"w"])
    }

    func testTheBrowserCaptionIsTheStepsOwnComment() {
        let tools = [Message.ToolCall(id: "1", name: "browser_exec", status: .start,
                                      detail: "# Adding the bag to the basket\nclick(\"#add\")")]
        XCTAssertEqual(BrowserActivity.caption(tools), "Adding the bag to the basket")
        XCTAssertNil(BrowserActivity.caption([Message.ToolCall(id: "2", name: "browser_exec", status: .start, detail: "click()")]))
    }
}
