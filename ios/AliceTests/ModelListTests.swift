import XCTest
@testable import Alice

/// Answers the model probes from a route table. A path with no entry is a 404,
/// and `.timeout` fails the request the way URLSession does when the gateway
/// is still building its answer.
final class ModelListStub: URLProtocol, @unchecked Sendable {
    enum Reply { case json(String), timeout }

    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [(path: String, timeout: TimeInterval)] = []
    private static let lock = NSLock()

    static func install(_ table: [String: Reply]) {
        lock.withLock {
            routes = table
            seen = []
        }
    }

    static var requests: [(path: String, timeout: TimeInterval)] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var key = String(url.path.dropFirst())
        if let query = url.query { key += "?\(query)" }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen.append((key, request.timeoutInterval))
            return Self.routes[key]
        }
        switch reply {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .json(let body):
            respond(status: 200, body: body)
        case nil:
            respond(status: 404, body: #"{"error":"not found"}"#)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `/v1/models` names one model; the catalogue names every one. What reaches
/// the picker has to say which of the two it is.
final class ModelListTransportTests: XCTestCase {
    private let oneModel = #"{"object":"list","data":[{"id":"radar-ia","object":"model"}]}"#
    private let catalogue = #"""
    {"model":"gpt-5","provider":"ai-gateway","providers":[
      {"slug":"ai-gateway","name":"AI Gateway","models":["gpt-5","claude-opus-5"]},
      {"slug":"copilot","name":"Copilot","models":["gpt-4.1"],"unavailable_models":[]}
    ]}
    """#

    private func client() async -> HermesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelListStub.self]
        let client = HermesClient(session: URLSession(configuration: config))
        await client.connect(to: .init(
            url: URL(string: "http://gateway.invalid/")!, key: "test-only"
        ))
        return client
    }

    /// The gateway log from the morning this was found: the catalogue timed
    /// out, the same handler was asked again with `include_unconfigured=1`,
    /// and the one model from `/v1/models` came back looking like a list.
    func testASlowCatalogueIsReportedAsAFallbackAndNotAskedForTwice() async throws {
        ModelListStub.install([
            "v1/models": .json(oneModel),
            "api/model/options": .timeout,
        ])

        let list = try await client().models()

        XCTAssertFalse(list.isCatalogue)
        XCTAssertEqual(list.options.map(\.id), ["radar-ia"])
        let paths = ModelListStub.requests.map(\.path)
        XCTAssertEqual(paths.filter { $0.hasPrefix("api/model/options") }, ["api/model/options"])
        XCTAssertFalse(paths.contains { $0.contains("include_unconfigured") })
    }

    /// A cold build took 21s. Ten seconds was never going to see it.
    func testTheCatalogueIsGivenTimeToBeBuilt() async throws {
        ModelListStub.install([
            "v1/models": .json(oneModel),
            "api/model/options": .json(catalogue),
        ])

        let list = try await client().models()

        XCTAssertTrue(list.isCatalogue)
        XCTAssertEqual(list.options.map(\.id), ["gpt-5", "claude-opus-5", "gpt-4.1"])
        let probe = try XCTUnwrap(
            ModelListStub.requests.first { $0.path == "api/model/options" }
        )
        XCTAssertGreaterThanOrEqual(probe.timeout, 30)
    }

    func testARefreshAsksForARecalculationFirst() async throws {
        ModelListStub.install([
            "v1/models": .json(oneModel),
            "api/model/options?refresh=1": .json(catalogue),
        ])

        let list = try await client().models(refreshing: true)

        XCTAssertTrue(list.isCatalogue)
        XCTAssertEqual(
            ModelListStub.requests.map(\.path),
            ["v1/models", "api/model/options?refresh=1"]
        )
    }
}

/// Several reads land in whatever order the network returns them. Which one
/// the picker keeps is decided here, not by arrival order.
final class ModelListPolicyTests: XCTestCase {
    private typealias Policy = ModelListPolicy

    private func option(_ id: String) -> HermesClient.ModelOption {
        .init(id: id, label: id)
    }

    private var fallback: HermesClient.ModelList {
        .init(options: [option("radar-ia")], isCatalogue: false)
    }

    private func catalogue(_ count: Int) -> HermesClient.ModelList {
        .init(options: (1...count).map { option("m\($0)") }, isCatalogue: true)
    }

    /// The order in the gateway log: the read that timed out finished first
    /// with the fallback, and the full list arrived two seconds later — and
    /// was thrown away, because the fallback had already been taken as the
    /// answer. It is the reason the phone showed one model.
    func testACatalogueArrivingAfterTheFallbackReplacesIt() {
        var state = Policy.State()
        state = Policy.apply(fallback, refreshing: false, to: state).state
        state = Policy.apply(catalogue(374), refreshing: false, to: state).state

        XCTAssertEqual(state.options.count, 374)
        XCTAssertEqual(state.source, .cached)
    }

    func testAFallbackNeverReplacesACatalogue() {
        var state = Policy.apply(catalogue(374), refreshing: false, to: .init()).state
        state = Policy.apply(fallback, refreshing: true, to: state).state
        XCTAssertEqual(state.options.count, 374)

        state = Policy.apply(catalogue(300), refreshing: true, to: state).state
        state = Policy.apply(fallback, refreshing: false, to: state).state
        XCTAssertEqual(state.options.count, 300)
        XCTAssertEqual(state.source, .refreshed)
    }

    /// The cached answer is the one that once marked a whole provider
    /// unavailable; a refresh corrects it and must stay corrected.
    func testACachedAnswerDoesNotUndoARefresh() {
        var state = Policy.apply(catalogue(374), refreshing: true, to: .init()).state
        state = Policy.apply(catalogue(336), refreshing: false, to: state).state

        XCTAssertEqual(state.options.count, 374)
        XCTAssertEqual(state.source, .refreshed)
    }

    /// A fallback asks for the refresh too — it is the case that most needs
    /// one — but only once, so a failing gateway is not polled in a loop.
    func testOneAutomaticRefreshIsAskedFor() {
        let first = Policy.apply(fallback, refreshing: false, to: .init())
        XCTAssertTrue(first.shouldRefresh)

        let again = Policy.apply(fallback, refreshing: false, to: first.state)
        XCTAssertFalse(again.shouldRefresh)

        let refreshed = Policy.apply(fallback, refreshing: true, to: again.state)
        XCTAssertFalse(refreshed.shouldRefresh)
        XCTAssertEqual(refreshed.state.source, .fallback)
    }

    func testNothingReachedAsksForNothing() {
        let empty = HermesClient.ModelList(options: [], isCatalogue: false)
        XCTAssertFalse(Policy.apply(empty, refreshing: false, to: .init()).shouldRefresh)
    }
}
