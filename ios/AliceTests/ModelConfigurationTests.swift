import XCTest
@testable import Alice

final class ModelConfigurationTests: XCTestCase {
    func testModelInfoParsesCapabilitiesAndContext() {
        let info = DashboardClient.profileModelInfo(from: [
            "model": "grok-4.6",
            "provider": "xai-oauth",
            "auto_context_length": NSNumber(value: 256_000),
            "config_context_length": NSNumber(value: 0),
            "effective_context_length": NSNumber(value: 256_000),
            "capabilities": [
                "supports_tools": true,
                "supports_vision": true,
                "supports_reasoning": true,
                "context_window": NSNumber(value: 256_000),
                "max_output_tokens": NSNumber(value: 32_000),
                "model_family": "grok",
            ],
        ])
        XCTAssertEqual(info.model, "grok-4.6")
        XCTAssertEqual(info.provider, "xai-oauth")
        XCTAssertEqual(info.effectiveContextLength, 256_000)
        XCTAssertTrue(info.capabilities.tools)
        XCTAssertTrue(info.capabilities.vision)
        XCTAssertEqual(info.capabilities.maxOutputTokens, 32_000)
        XCTAssertEqual(info.capabilities.family, "grok")
    }

    func testProviderInventoryKeepsUnconfiguredRowsButDropsUnavailableModels() {
        let rows = DashboardClient.inferenceProviders(from: [
            "providers": [[
                "slug": "xai-oauth",
                "name": "xAI",
                "models": ["grok-4.6", "grok-broken"],
                "unavailable_models": ["grok-broken"],
                "total_models": NSNumber(value: 2),
                "authenticated": true,
                "is_current": true,
            ], [
                "slug": "openai-api",
                "name": "OpenAI API",
                "models": [],
                "authenticated": false,
            ]],
        ])
        XCTAssertEqual(rows.map(\.slug), ["xai-oauth", "openai-api"])
        XCTAssertEqual(rows[0].models, ["grok-4.6"])
        XCTAssertTrue(rows[0].authenticated)
        XCTAssertTrue(rows[0].isCurrent)
        XCTAssertFalse(rows[1].authenticated)
    }

    func testOAuthStatusIsProviderScopedPresentationOnly() {
        let rows = DashboardClient.oauthProviderStates(from: [
            "providers": [[
                "id": "xai-oauth", "name": "xAI", "flow": "device_code",
                "status": ["logged_in": true, "source_label": "SuperGrok"],
                "disconnectable": true,
            ]],
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "xai-oauth")
        XCTAssertTrue(rows[0].loggedIn)
        XCTAssertEqual(rows[0].source, "SuperGrok")
        XCTAssertTrue(rows[0].disconnectable)
    }

    func testCredentialInventoryIncludesOnlyProviderOwnedKeys() {
        let rows = DashboardClient.providerCredentials(from: [
            "OPENAI_API_KEY": [
                "category": "provider", "provider": "openai-api",
                "provider_label": "OpenAI API", "is_set": true,
                "redacted_value": "sk-…1234", "is_password": true,
            ],
            "TELEGRAM_BOT_TOKEN": [
                "category": "provider", "provider": "telegram",
                "channel_managed": true, "is_set": true,
            ],
            "GITHUB_TOKEN": ["category": "tool", "is_set": true],
        ])
        XCTAssertEqual(rows.map(\.key), ["OPENAI_API_KEY"])
        XCTAssertEqual(rows[0].provider, "openai-api")
        XCTAssertTrue(rows[0].isSet)
    }

    func testConfigurationParsesOnlyCuratedHermesKeys() {
        let config = DashboardClient.hermesConfiguration(from: [
            "timezone": "Europe/Madrid",
            "approvals": ["mode": "manual", "timeout": 999],
            "agent": ["service_tier": "auto", "verify_guidance": false, "environment_probe": true],
            "memory": ["memory_enabled": false, "user_profile_enabled": true],
            "compression": ["enabled": true, "threshold": 0.65, "max_attempts": 99],
            "unrelated": ["must_survive": true],
        ])
        XCTAssertEqual(config.timezone, "Europe/Madrid")
        XCTAssertEqual(config.approvalsMode, "manual")
        XCTAssertEqual(config.serviceTier, "auto")
        XCTAssertFalse(config.verifyGuidance)
        XCTAssertFalse(config.memoryEnabled)
        XCTAssertTrue(config.userProfileEnabled)
        XCTAssertEqual(config.compressionThreshold, 0.65, accuracy: 0.001)
    }

    func testExpensiveModelConfirmationAndStaleAuxArePreserved() {
        let result = DashboardClient.modelAssignmentResult(from: [
            "ok": false,
            "confirm_required": true,
            "confirm_message": "This model can be expensive.",
            "provider": "openrouter",
            "model": "vendor/flagship",
            "stale_aux": [["task": "vision", "provider": "xai", "model": "grok"]],
        ])
        XCTAssertTrue(result.confirmRequired)
        XCTAssertEqual(result.confirmMessage, "This model can be expensive.")
        XCTAssertEqual(result.staleAux.first?.task, "vision")
    }

    func testUsageParserKeepsCacheReasoningProviderAndCost() {
        let report = DashboardClient.usageReport(
            from: [
                "period_days": 7,
                "totals": [
                    "total_input": 100, "total_output": 20,
                    "total_cache_read": 60, "total_reasoning": 10,
                    "total_actual_cost": 1.25, "total_estimated_cost": 1.50,
                    "total_sessions": 2, "total_api_calls": 4,
                ],
                "by_model": [["model": "fallback-only"]],
                "tools": [["tool": "terminal", "count": 2, "percentage": 50.0]],
            ],
            modelObject: [
                "models": [[
                    "model": "grok-4.6", "provider": "xai-oauth",
                    "input_tokens": 100, "output_tokens": 20,
                    "cache_read_tokens": 60, "reasoning_tokens": 10,
                    "actual_cost": 1.25, "estimated_cost": 1.50,
                    "sessions": 2, "api_calls": 4,
                ]]
            ]
        )
        XCTAssertEqual(report.days, 7)
        XCTAssertEqual(report.cacheReadTokens, 60)
        XCTAssertEqual(report.reasoningTokens, 10)
        XCTAssertEqual(report.cost, 1.25, accuracy: 0.001)
        XCTAssertEqual(report.models.first?.provider, "xai-oauth")
        XCTAssertEqual(report.tools.first?.share ?? 0, 0.5, accuracy: 0.001)
    }

    func testBillingUsageFailOpenAndBars() {
        let usage = DashboardClient.billingUsage(from: [
            "available": true,
            "plan_name": "Pro",
            "renews_display": "in 12 days",
            "total_spendable_display": "$42.00",
            "plan_bar": [
                "kind": "subscription", "remaining_display": "$30.00",
                "total_display": "$50.00", "spent_display": "$20.00",
                "pct_used": 40.0, "fill_fraction": 0.60,
            ],
        ])
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.planBar?.percentUsed ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(usage.planBar?.fillFraction ?? 0, 0.60, accuracy: 0.001)
        XCTAssertFalse(DashboardClient.billingUsage(from: ["available": false]).available)
    }
}
