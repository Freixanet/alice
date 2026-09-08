import XCTest
@testable import Alice

/// A stand-in for the dashboard, so the parts of `DashboardClient` that only
/// exist in the presence of a server — signing in, retrying a lapsed session,
/// deciding what a 200 is allowed to mean — can be tested at all.
///
/// It records every request in order, which is the whole point: the defects
/// these cover were about *how many* requests Alice sent, not about what it
/// did with the answers.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data = Data("{}".utf8)
    }

    /// `(method, path)` in the order they were sent.
    nonisolated(unsafe) private static var log: [(String, String)] = []
    nonisolated(unsafe) private static var responder: (@Sendable (String, String) -> Reply)?
    private static let lock = NSLock()

    static func install(_ responder: @escaping @Sendable (String, String) -> Reply) {
        lock.withLock {
            log = []
            Self.responder = responder
        }
    }

    static var requests: [(String, String)] { lock.withLock { log } }

    static func count(_ method: String, _ path: String) -> Int {
        requests.filter { $0.0 == method && $0.1 == path }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append((method, path))
            return Self.responder?(method, path) ?? Reply(status: 200)
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A boolean shared between a test body and the stub's request handler.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool = false) { stored = value }
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

func makeStubbedDashboard() async -> DashboardClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let client = DashboardClient(session: URLSession(configuration: config))
    await client.use(
        .init(
            url: URL(string: "http://dashboard.invalid/")!,
            username: "operator", password: "unused-by-the-stub"
        )
    )
    return client
}

final class DashboardClientTests: XCTestCase {

    // MARK: - Signing in

    /// Hermes throttles `auth/password-login` to ten attempts a minute per
    /// address and counts the successful ones too. Screens fan requests out in
    /// parallel — six on Advanced Operations alone — and an actor lets the
    /// next caller in while the first is awaiting its login, so each of them
    /// used to send one. Two such screens inside a minute spent the budget and
    /// locked the phone out of its own dashboard with a 429.
    func testConcurrentRequestsSignInOnce() async throws {
        StubProtocol.install { _, _ in
            .init(status: 200, body: Data("{\"content\": \"x\"}".utf8))
        }
        let client = await makeStubbedDashboard()

        await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { _ = try await client.skillContent("skill-\(index)") }
            }
            while (try? await group.next()) != nil {}
        }

        XCTAssertEqual(StubProtocol.count("POST", "/auth/password-login"), 1)
        XCTAssertEqual(StubProtocol.count("GET", "/api/skills/content"), 8)
    }

    /// A lapsed session hits every request in flight at once. One replacement
    /// serves all of them; the rest must not each queue their own.
    func testConcurrent401sReauthenticateOnce() async throws {
        let valid = Flag()
        StubProtocol.install { _, path in
            if path == "/auth/password-login" {
                valid.set(true)
                return .init(status: 200)
            }
            return valid.value
                ? .init(status: 200, body: Data("{\"content\": \"x\"}".utf8))
                : .init(status: 401)
        }
        let client = await makeStubbedDashboard()
        // Sign in, then make that session stale behind Alice's back.
        _ = try await client.skillContent("warm")
        valid.set(false)

        await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask { _ = try await client.skillContent("skill-\(index)") }
            }
            while (try? await group.next()) != nil {}
        }

        // One login to warm up, one to replace the lapsed session. Not seven.
        XCTAssertEqual(StubProtocol.count("POST", "/auth/password-login"), 2)
    }

    /// A mutation must be retried at most once after a 401, never looped —
    /// otherwise a rejected session turns one delete into several.
    func testMutationIsSentAtMostTwiceOn401() async throws {
        StubProtocol.install { _, path in
            .init(status: path == "/auth/password-login" ? 200 : 401)
        }
        let client = await makeStubbedDashboard()

        do {
            try await client.setSkillEnabled("research", enabled: false, profile: nil)
            XCTFail("a permanently rejected request should not report success")
        } catch {}

        XCTAssertEqual(StubProtocol.count("PUT", "/api/skills/toggle"), 2)
    }

    /// The throttle is a different problem from a wrong password, and saying
    /// so is the difference between waiting a minute and re-entering a
    /// credential that was correct all along.
    func testLoginThrottleIsReportedAsItself() async throws {
        StubProtocol.install { _, path in
            .init(status: path == "/auth/password-login" ? 429 : 200)
        }
        let client = await makeStubbedDashboard()

        do {
            _ = try await client.skillContent("research")
            XCTFail("expected the throttled login to fail")
        } catch let failure as DashboardClient.Failure {
            guard case let .http(status, detail) = failure else {
                return XCTFail("expected an http failure, got \(failure)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertNotNil(detail)
        }
    }

    /// A rejected password is not retried behind the user's back.
    func testRejectedCredentialsDoNotRetry() async throws {
        StubProtocol.install { _, _ in .init(status: 401) }
        let client = await makeStubbedDashboard()

        do {
            _ = try await client.skillContent("research")
            XCTFail("expected a rejection")
        } catch let failure as DashboardClient.Failure {
            guard case .rejected = failure else {
                return XCTFail("expected .rejected, got \(failure)")
            }
        }
        XCTAssertEqual(StubProtocol.count("POST", "/auth/password-login"), 1)
    }

    // MARK: - What a 200 is allowed to mean

    /// A body that is not the object it claims to be is not an empty one.
    /// Reading a JSON array — or an HTML error page a proxy answered 200 with
    /// — as `[:]` made every listing built from it report that the agent has
    /// nothing configured.
    func testNonObjectBodyIsNotAnEmptyObject() async throws {
        for body in ["[{\"name\":\"a\"}]", "<html>proxy</html>", "\"nope\"", "null"] {
            StubProtocol.install { _, path in
                path == "/auth/password-login"
                    ? .init(status: 200)
                    : .init(status: 200, body: Data(body.utf8))
            }
            let client = await makeStubbedDashboard()

            do {
                _ = try await client.skillContent("research")
                XCTFail("\(body) must not pass as an empty object")
            } catch let failure as DashboardClient.Failure {
                guard case .unreadable = failure else {
                    return XCTFail("expected .unreadable for \(body), got \(failure)")
                }
            }
        }
    }

    /// A route that answers with nothing at all still answered.
    func testEmptyBodyStaysAnEmptyObject() async throws {
        StubProtocol.install { _, path in
            path == "/auth/password-login"
                ? .init(status: 200)
                : .init(status: 200, body: Data())
        }
        let client = await makeStubbedDashboard()

        try await client.setSkillEnabled("research", enabled: true, profile: nil)
        XCTAssertEqual(StubProtocol.count("PUT", "/api/skills/toggle"), 1)
    }

    // MARK: - Building the URL

    /// Profile ids are `[a-z0-9][a-z0-9_-]*` today, so nothing in one needs
    /// escaping — but the path is built from a name the server supplied, and a
    /// separator arriving in one must not silently address a different route.
    func testInterpolatedSegmentsAreEscaped() async throws {
        StubProtocol.install { _, _ in .init(status: 200) }
        let client = await makeStubbedDashboard()

        try? await client.deleteBot("radar/../default")

        XCTAssertEqual(StubProtocol.count("DELETE", "/api/profiles/radar%2F..%2Fdefault"), 1)
        XCTAssertEqual(StubProtocol.count("DELETE", "/api/profiles/default"), 0)
    }
}
