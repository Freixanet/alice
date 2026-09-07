import XCTest
@testable import Alice

final class AdvancedModelsTests: XCTestCase {
    func testAuxiliaryParserPreservesTaskPinsAndCustomEndpoint() throws {
        let parsed = try DashboardClient.auxiliaryModels(from: [
            "tasks": [
                ["task": "vision", "provider": "auto", "model": "", "base_url": ""],
                ["task": "review", "provider": "custom", "model": "reviewer", "base_url": "http://127.0.0.1:11434/v1"],
            ],
            "main": ["provider": "xai-oauth", "model": "grok-4.6"],
        ])

        XCTAssertEqual(parsed.mainProvider, "xai-oauth")
        XCTAssertEqual(parsed.mainModel, "grok-4.6")
        XCTAssertTrue(parsed.tasks[0].isAutomatic)
        XCTAssertFalse(parsed.tasks[1].isAutomatic)
        XCTAssertEqual(parsed.tasks[1].baseURL, "http://127.0.0.1:11434/v1")
    }

    func testMalformedAuxiliaryListingDoesNotBecomeAllAuto() {
        XCTAssertThrowsError(try DashboardClient.auxiliaryModels(from: [
            "tasks": [["task": "vision", "provider": "auto"]],
            "main": ["provider": "nous", "model": "some-model"],
        ]))
    }

    func testRecommendedDefaultPreservesNousTier() throws {
        let recommendation = try DashboardClient.recommendedModelDefault(from: [
            "provider": "nous", "model": "stepfun/step-3.7-flash:free", "free_tier": true,
        ])
        XCTAssertEqual(recommendation.provider, "nous")
        XCTAssertEqual(recommendation.model, "stepfun/step-3.7-flash:free")
        XCTAssertEqual(recommendation.freeTier, true)
    }

    func testMoAParserPreservesPresetsSlotsAndTuning() throws {
        let parsed = try DashboardClient.moaConfiguration(from: [
            "default_preset": "quality",
            "active_preset": "",
            "presets": [
                "quality": [
                    "reference_models": [
                        ["provider": "openai-codex", "model": "gpt-5.5", "reasoning_effort": "high", "enabled": true],
                        ["provider": "openrouter", "model": "deepseek/deepseek-v4-pro", "enabled": false],
                    ],
                    "aggregator": ["provider": "openrouter", "model": "anthropic/claude-opus-4.8"],
                    "reference_temperature": NSNull(),
                    "aggregator_temperature": NSNumber(value: 0.2),
                    "reference_timeout": NSNumber(value: 120.0),
                    "degraded_reference_policy": "silent",
                    "max_tokens": NSNumber(value: 8192),
                    "reference_max_tokens": NSNumber(value: 600),
                    "fanout": "every_n:3",
                    "enabled": true,
                ],
            ],
        ])

        let preset = try XCTUnwrap(parsed.presets["quality"])
        XCTAssertEqual(parsed.defaultPreset, "quality")
        XCTAssertEqual(preset.referenceModels.count, 2)
        XCTAssertEqual(preset.referenceModels[0].reasoningEffort, "high")
        XCTAssertFalse(preset.referenceModels[1].enabled)
        XCTAssertNil(preset.referenceTemperature)
        XCTAssertEqual(preset.aggregatorTemperature ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(preset.referenceTimeout ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(preset.referenceMaxTokens, 600)
        XCTAssertEqual(preset.fanout, "every_n:3")
        XCTAssertEqual(preset.degradedReferencePolicy, "silent")
    }

    func testMoABodyRoundTripsOptionalAndPerSlotFields() throws {
        let configuration = MoAConfiguration(
            defaultPreset: "default",
            activePreset: "",
            presets: [
                "default": MoAPreset(
                    referenceModels: [
                        MoAModelSlot(provider: "openai-codex", model: "gpt-5.5", reasoningEffort: "medium", enabled: true),
                    ],
                    aggregator: MoAModelSlot(provider: "openrouter", model: "anthropic/claude-opus-4.8", reasoningEffort: nil, enabled: true),
                    referenceTemperature: nil,
                    aggregatorTemperature: 0.3,
                    referenceTimeout: nil,
                    degradedReferencePolicy: "loud",
                    maxTokens: 4096,
                    referenceMaxTokens: 700,
                    fanout: "user_turn",
                    enabled: true
                ),
            ]
        )

        let body = DashboardClient.moaBody(configuration, profile: "radar-ia")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["profile"] as? String, "radar-ia")
        let presets = try XCTUnwrap(body["presets"] as? [String: Any])
        let preset = try XCTUnwrap(presets["default"] as? [String: Any])
        XCTAssertTrue(preset["reference_temperature"] is NSNull)
        XCTAssertEqual(preset["reference_max_tokens"] as? Int, 700)
        let refs = try XCTUnwrap(preset["reference_models"] as? [[String: Any]])
        XCTAssertEqual(refs[0]["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(refs[0]["enabled"] as? Bool, true)
    }

    func testCustomModelAssignmentCarriesSecretOnlyWhenProvided() {
        let custom = DashboardClient.modelAssignmentBody(
            scope: "auxiliary", provider: "custom", model: "qwen-local", task: "review",
            baseURL: "http://127.0.0.1:1234/v1", apiKey: "secret-key"
        )
        XCTAssertEqual(custom["base_url"] as? String, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(custom["api_key"] as? String, "secret-key")
        XCTAssertEqual(custom["task"] as? String, "review")

        let ordinary = DashboardClient.modelAssignmentBody(
            scope: "main", provider: "nous", model: "model"
        )
        XCTAssertNil(ordinary["base_url"])
        XCTAssertNil(ordinary["api_key"])
    }
}
