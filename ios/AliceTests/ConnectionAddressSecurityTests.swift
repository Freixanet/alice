import XCTest
@testable import Alice

final class ConnectionAddressSecurityTests: XCTestCase {
    func testPlainHTTPIsLimitedToPrivateAndTailnetDestinations() {
        for address in [
            "http://10.0.0.2:8642",
            "http://192.168.1.7:9119",
            "http://172.31.4.8",
            "http://100.67.213.42:8642",
            "http://[fd7a:115c:a1e0::1]:8642",
            "http://alice.local:8642",
            "http://macbook.tail123.ts.net:9119",
            "macbook:8642",
        ] {
            XCTAssertNotNil(AppStore.normalize(address), address)
        }

        for address in [
            "http://example.com:8642",
            "http://fd-example.com:8642",
            "http://fc.example.com:8642",
            "http://8.8.8.8:8642",
            "http://[2606:4700:4700::1111]:8642",
            "example.com:8642",
        ] {
            XCTAssertNil(AppStore.normalize(address), address)
        }
    }

    func testHTTPSRemainsAvailableForAnyValidHost() {
        XCTAssertEqual(
            AppStore.normalize("https://hermes.example.com:8642")?.absoluteString,
            "https://hermes.example.com:8642/"
        )
    }

    func testNonHTTPProtocolsAreRejected() {
        XCTAssertNil(AppStore.normalize("ftp://192.168.1.7/resource"))
        XCTAssertNil(AppStore.normalize("javascript:alert(1)"))
    }
}
