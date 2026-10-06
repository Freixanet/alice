import XCTest
@testable import Alice

/// Cards, passwords and keys only travel encrypted; links in a reply cannot pair or type for you.
final class SecureTransportTests: XCTestCase {
    func testSecretsNeedHTTPSOrTailscale() {
        let encrypted = ["https://mac.example.com", "http://mac.tail1234.ts.net:9119", "http://100.101.2.3:9119",
                         "http://127.0.0.1:9119"]
        let plain = ["http://mac.local:9119", "http://192.168.1.20:9119", "http://10.0.0.5:9119"]
        for url in encrypted { XCTAssertTrue(DashboardClient.encrypted(URL(string: url)!), url) }
        for url in plain { XCTAssertFalse(DashboardClient.encrypted(URL(string: url)!), url) }
        XCTAssertTrue(DashboardClient.carriesSecrets("api/plugins/alice/vault/cards?profile=default"))
        XCTAssertTrue(DashboardClient.carriesSecrets("api/plugins/alice/secret"))
        XCTAssertTrue(DashboardClient.carriesSecrets("api/plugins/alice/errands/e1/access"))
        XCTAssertFalse(DashboardClient.carriesSecrets("api/plugins/alice/notes"))
    }

    func testRepliesCannotPairOrTypeForYou() {
        XCTAssertTrue(AgentLinks.refused(URL(string: "alice://pair?v=1&p=x")!))
        XCTAssertTrue(AgentLinks.refused(URL(string: "alice://compose?text=hola")!))
        XCTAssertFalse(AgentLinks.refused(URL(string: "alice://connect/secret/EXA_API_KEY")!))
        XCTAssertFalse(AgentLinks.refused(URL(string: "https://example.com")!))
    }
}
