import XCTest
@testable import Alice

final class BotFallbackTests: XCTestCase {
    func testParseReadsProvidersThenLegacyModel() {
        let chain = BotFallbackChain.parse(from: [
            "fallback_providers": [[
                "provider": "opencode-free",
                "model": "muse-spark-1.3-contributor-free",
            ]],
            "fallback_model": ["provider": "openai-codex", "model": "gpt-5.6-luna"],
        ])
        XCTAssertEqual(chain.map(\.provider), ["opencode-free", "openai-codex"])
        XCTAssertEqual(chain.map(\.model), [
            "muse-spark-1.3-contributor-free", "gpt-5.6-luna",
        ])
    }

    func testParseSkipsIncompleteEntriesAndDeduplicatesLegacy() {
        let chain = BotFallbackChain.parse(from: [
            "fallback_providers": [
                ["provider": "openai-codex"],
                ["model": "gpt-5.6-luna"],
                ["provider": "openai-codex", "model": "gpt-5.6-luna"],
            ],
            "fallback_model": ["provider": "openai-codex", "model": "gpt-5.6-luna"],
        ])
        XCTAssertEqual(chain.count, 1)
        XCTAssertEqual(chain.first?.model, "gpt-5.6-luna")
    }

    func testReplacingFirstKeepsLaterHopsAndNilClearsTheChain() {
        let first = BotFallbackEntry(provider: "a", model: "one", baseURL: nil)
        let second = BotFallbackEntry(provider: "b", model: "two", baseURL: "https://example")
        let next = BotFallbackEntry(provider: "c", model: "three", baseURL: nil)
        XCTAssertEqual(
            BotFallbackChain.replacingFirst([first, second], with: next).map(\.model),
            ["three", "two"]
        )
        XCTAssertEqual(
            BotFallbackChain.replacingFirst([first, second], with: next)[1].baseURL,
            "https://example"
        )
        XCTAssertTrue(BotFallbackChain.replacingFirst([first, second], with: nil).isEmpty)
    }

    func testPutBodyReplacesTheListAndNeutralizesLegacyModel() {
        let body = BotFallbackChain.putBody([
            BotFallbackEntry(provider: "opencode-free", model: "muse-spark-1.3-contributor-free", baseURL: nil)
        ])
        let config = body["config"] as? [String: Any]
        let providers = config?["fallback_providers"] as? [[String: Any]]
        XCTAssertEqual(providers?.count, 1)
        XCTAssertEqual(providers?.first?["provider"] as? String, "opencode-free")
        XCTAssertEqual((config?["fallback_model"] as? [Any])?.count, 0)

        let cleared = BotFallbackChain.putBody([])["config"] as? [String: Any]
        XCTAssertEqual((cleared?["fallback_providers"] as? [Any])?.count, 0)
        XCTAssertEqual((cleared?["fallback_model"] as? [Any])?.count, 0)
    }

    func testANonePickIsAChangeOnlyWhenAHopExists() {
        let option = HermesClient.ModelOption(
            id: "gpt-5.6-luna", label: "Luna", provider: "openai-codex", providerName: nil
        )
        XCTAssertFalse(BotFallbackChain.isChange(nil, from: []))
        XCTAssertTrue(BotFallbackChain.isChange(nil, from: [
            BotFallbackEntry(provider: "openai-codex", model: "gpt-5.6-luna", baseURL: nil)
        ]))
        XCTAssertFalse(BotFallbackChain.isChange(option, from: [
            BotFallbackEntry(provider: "openai-codex", model: "gpt-5.6-luna", baseURL: nil)
        ]))
        XCTAssertTrue(BotFallbackChain.isChange(option, from: []))
    }

    func testDashboardParseUsesTheSharedChain() {
        let rows = DashboardClient.fallbackProviders(from: [
            "fallback_providers": [[
                "provider": "openai-codex",
                "model": "gpt-5.6-luna",
                "base_url": "https://chatgpt.com",
            ]]
        ])
        XCTAssertEqual(rows.first?.provider, "openai-codex")
        XCTAssertEqual(rows.first?.baseURL, "https://chatgpt.com")
    }
}
