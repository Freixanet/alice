import XCTest
@testable import Alice

/// The claim response is where the gateway key and the dashboard password
/// enter the app. These pin down what the client accepts, what it maps
/// errors to, and that the request carries the one-time token.
final class PairingClientTests: XCTestCase {
    private let payload = try! PairingPayload.parse(
        "alice://pair?v=1&p=\(PairingClientTests.base64URL(#"{"c":"http://100.67.213.42:8643/claim","t":"tok","e":9999999999,"pr":"radar-ia"}"#))&s=\(String(repeating: "0", count: 64))",
        now: Date(timeIntervalSince1970: 1)
    )

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func client(_ handler: @escaping StubPairingURLProtocol.Handler) -> PairingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPairingURLProtocol.self]
        StubPairingURLProtocol.handler = handler
        return PairingClient(session: URLSession(configuration: configuration))
    }

    private let okBody = """
    {"profile":"radar-ia",
     "gateway":{"url":"http://100.67.213.42:8642","key":"gk-123"},
     "dashboard":{"url":"http://100.67.213.42:9119","username":"alice","password":"pw-123"}}
    """

    func testClaimCarriesTokenAndDeviceNameAndMapsTheResponse() async throws {
        var seenBody: Data?
        let claimed = try await client { request in
            seenBody = StubPairingURLProtocol.requestBody(request)
            return (200, self.okBody.data(using: .utf8)!)
        }.claim(payload, deviceName: "iPhone de prueba")

        let body = String(data: seenBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"token\":\"tok\""), body)
        XCTAssertTrue(body.contains("\"device_name\":\"iPhone de prueba\""), body)

        XCTAssertEqual(claimed.profileName, "radar-ia")
        XCTAssertEqual(claimed.gatewayURLText, "http://100.67.213.42:8642")
        XCTAssertEqual(claimed.gatewayKey, "gk-123")
        XCTAssertEqual(claimed.dashboardURLText, "http://100.67.213.42:9119")
        XCTAssertEqual(claimed.dashboardUsername, "alice")
        XCTAssertEqual(claimed.dashboardPassword, "pw-123")
    }

    func testClaimWithoutDashboardLeavesItNil() async throws {
        let claimed = try await client { _ in
            (200, Data("""
            {"profile":null,"gateway":{"url":"http://100.67.213.42:8642","key":"k"},"dashboard":null}
            """.utf8))
        }.claim(payload, deviceName: "iPhone")

        XCTAssertNil(claimed.dashboardURLText)
        XCTAssertNil(claimed.dashboardUsername)
        XCTAssertNil(claimed.dashboardPassword)
        // A null profile falls back to what the QR itself advertised.
        XCTAssertEqual(claimed.profileName, "radar-ia")
    }

    func testUsedOrExpiredQRReadsAsStale() async {
        for status in [410, 404] {
            do {
                _ = try await client { _ in (status, Data("{\"error\":\"used\"}".utf8)) }
                    .claim(payload, deviceName: "iPhone")
                XCTFail("status \(status) should have thrown")
            } catch let failure as PairingClient.Failure {
                guard case .stale = failure else {
                    return XCTFail("status \(status) mapped to \(failure)")
                }
            } catch {
                XCTFail("status \(status) threw \(error)")
            }
        }
    }

    func testForbiddenNetworkAndUnexpectedStatusesMapFaithfully() async {
        do {
            _ = try await client { _ in (403, Data("{}".utf8)) }
                .claim(payload, deviceName: "iPhone")
            XCTFail("403 should have thrown")
        } catch PairingClient.Failure.forbidden {}
        catch { XCTFail("403 threw \(error)") }

        do {
            _ = try await client { _ in (500, Data("nope".utf8)) }
                .claim(payload, deviceName: "iPhone")
            XCTFail("500 should have thrown")
        } catch let failure as PairingClient.Failure {
            guard case let .http(status) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("500 threw \(error)")
        }
    }

    func testGarbageSuccessBodyIsBadResponse() async {
        do {
            _ = try await client { _ in (200, Data("not json".utf8)) }
                .claim(payload, deviceName: "iPhone")
            XCTFail("garbage body should have thrown")
        } catch PairingClient.Failure.badResponse {}
        catch { XCTFail("garbage body threw \(error)") }
    }

    func testClaimCannotHandCredentialsToAnotherHost() async {
        let body = Data("""
        {"profile":"radar-ia",
         "gateway":{"url":"https://evil.example:8642","key":"gk"},
         "dashboard":null}
        """.utf8)
        do {
            _ = try await client { _ in (200, body) }
                .claim(payload, deviceName: "iPhone")
            XCTFail("cross-host config should have thrown")
        } catch PairingClient.Failure.badResponse {}
        catch { XCTFail("cross-host config threw \(error)") }
    }

    func testClaimRejectsBlankSecretsAndUnsafeSchemes() async {
        let bodies = [
            """
            {"gateway":{"url":"http://100.67.213.42:8642","key":""},"dashboard":null}
            """,
            """
            {"gateway":{"url":"ftp://100.67.213.42:8642","key":"gk"},"dashboard":null}
            """,
            """
            {"gateway":{"url":"http://100.67.213.42:8642","key":"gk"},
             "dashboard":{"url":"http://100.67.213.42:9119","username":"","password":"pw"}}
            """,
        ]

        for json in bodies {
            do {
                _ = try await client { _ in (200, Data(json.utf8)) }
                    .claim(payload, deviceName: "iPhone")
                XCTFail("unsafe config should have thrown: \(json)")
            } catch PairingClient.Failure.badResponse {}
            catch { XCTFail("unsafe config threw \(error)") }
        }
    }
}

/// Answers each request from a closure; one handler per test.
final class StubPairingURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, Data)

    nonisolated(unsafe) static var handler: Handler?

    /// URLSession hands the protocol a body stream, not `httpBody`.
    static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
