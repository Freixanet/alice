import XCTest
@testable import Alice

/// An alert has to say why it is there and what to do, in words that need no
/// knowledge of Hermes. The failure texts below are the ones a real
/// installation produced, verbatim, on the day these were written.
final class AlertAdviceTests: XCTestCase {

    private let driftMessage = """
    RuntimeError: [drift_skip:silent] Skipped to prevent unintended spend: global inference \
    config drifted since this job was created (provider 'openai-codex' -> 'nous'; model \
    'gpt-5.6-terra' -> 'stepfun/step-3.7-flash:free'), and this job is unpinned. No inference \
    call was made. To run on the new config, on the host running Hermes pin it explicitly: \
    `hermes cron edit 7624a7411796 --provider <provider> --model <model>` (or pin the original \
    values to keep them). This alert is sent once; the job stays skipped until the config is \
    pinned or restored. See #44585.
    """

    private func routine(
        error: String?, model: String? = nil, provider: String? = nil
    ) -> JobRow {
        JobRow(
            id: "7624a7411796", name: "limpieza-semanal", prompt: "", schedule: "0 23 * * 0",
            enabled: true, lastStatus: "error", lastError: error, lastRun: Date(), nextRun: nil,
            profile: "default", model: model, provider: provider
        )
    }

    // MARK: Automations

    func testTheSpendGuardIsExplainedAndOffersBothChoices() throws {
        let drift = try XCTUnwrap(AlertAdvice.drift(in: driftMessage))
        XCTAssertEqual(drift.provider, .init(from: "openai-codex", to: "nous"))
        XCTAssertEqual(drift.model, .init(from: "gpt-5.6-terra", to: "stepfun/step-3.7-flash:free"))
        XCTAssertFalse(drift.runsOnce)

        let advice = AlertAdvice.routineFailure(driftMessage)
        XCTAssertTrue(advice.headline.lowercased().contains("spending"))
        XCTAssertTrue(advice.explanation.contains("gpt-5.6-terra"))
        XCTAssertTrue(advice.explanation.contains("step-3.7-flash:free"))
        XCTAssertEqual(advice.fixes, [.useCurrentModel, .keepOriginalModel(name: "gpt-5.6-terra")])
        // Both change what Hermes will spend on, so both ask first.
        XCTAssertNotNil(AlertAdvice.Fix.useCurrentModel.confirmation)
        XCTAssertNotNil(advice.fixes[1].confirmation)
    }

    /// Choosing a model ends the problem, but the last error stays on record
    /// until the next run. The alert must not keep asking for the choice that
    /// was just made.
    func testAChosenModelSettlesTheAlert() {
        XCTAssertFalse(AlertAdvice.driftIsSettled(routine(error: driftMessage)))
        XCTAssertFalse(AlertAdvice.driftIsSettled(routine(error: driftMessage, model: "gpt-5.6-terra")))
        XCTAssertTrue(AlertAdvice.driftIsSettled(
            routine(error: driftMessage, model: "gpt-5.6-terra", provider: "openai-codex")
        ))

        let modelOnly = "RuntimeError: [drift_skip] Skipped to prevent unintended spend: global "
            + "inference config drifted since this job was created (model 'a' -> 'b'), and this "
            + "job is unpinned."
        XCTAssertTrue(AlertAdvice.driftIsSettled(routine(error: modelOnly, model: "a")))

        let items = EventDigest.attention(
            routines: [routine(error: driftMessage, model: "x", provider: "y")], components: []
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testARunOnceAutomationIsNotOfferedAFixThatCannotWork() {
        let text = "RuntimeError: [drift_skip] ... (model 'a' -> 'b') ... This finite one-shot "
            + "job is consumed by this attempted run; create a new one-shot job."
        let advice = AlertAdvice.routineFailure(text)
        XCTAssertEqual(advice.fixes, [.open(.routines, label: "Open automations")])
        XCTAssertFalse(AlertAdvice.driftIsSettled(routine(error: text, model: "b")))
    }

    func testAnUnreachableServiceOffersToTryAgain() {
        let advice = AlertAdvice.routineFailure("RuntimeError: Connection error.")
        XCTAssertEqual(advice.headline, "Couldn't reach the AI service")
        XCTAssertEqual(advice.fixes, [.runAgain])
        XCTAssertNil(AlertAdvice.Fix.runAgain.confirmation)
    }

    func testARefusedKeyPointsToSettings() {
        let advice = AlertAdvice.routineFailure("Error code: 401 - invalid api key")
        XCTAssertEqual(advice.fixes, [.open(.models, label: "Open Settings")])
    }

    /// Alice not recognising the reason is said, not disguised.
    func testAnUnknownFailureAdmitsItAndStillOffersSomething() {
        let advice = AlertAdvice.routineFailure("boom")
        XCTAssertTrue(advice.explanation.contains("More details"))
        XCTAssertEqual(advice.fixes, [.runAgain])
    }

    func testRowsAlreadyOnDiskAreExplainedToo() {
        let stored = AliceEvent(
            id: "routine:default/job:1", kind: .automationFailed, severity: .failure,
            title: "Monitor Cuba", summary: "This automation did not finish.",
            detail: "RuntimeError: Connection error.", occurred: Date()
        )
        XCTAssertEqual(AlertAdvice.advice(for: stored)?.headline, "Couldn't reach the AI service")
    }

    // MARK: Messaging apps

    /// The shape `/api/status` returned on this installation: WhatsApp switched
    /// on and never paired, and a second profile's gateway namespaced.
    private let status: [String: Any] = [
        "gateway_platforms": [
            "api_server": ["state": "connected", "error_code": NSNull(), "error_message": NSNull()],
            "telegram": ["state": "connected", "error_code": NSNull(), "error_message": NSNull()],
            "whatsapp": [
                "state": "fatal", "error_code": "whatsapp_not_paired",
                "error_message": "WhatsApp enabled but not paired — pair from the dashboard or run `hermes whatsapp`.",
            ],
            "radar-ia:telegram": ["state": "disconnected", "error_code": NSNull(), "error_message": NSNull()],
            "radar-ia:api_server": ["state": "connected"],
        ],
    ]

    func testPlatformHealthKeepsTheProfile() throws {
        let platforms = DashboardClient.platformHealth(from: status)
        XCTAssertEqual(platforms.count, 5)
        let radar = try XCTUnwrap(platforms.first { $0.key == "radar-ia:telegram" })
        XCTAssertEqual(radar.profile, "radar-ia")
        XCTAssertEqual(radar.platform, "telegram")
        let whatsapp = try XCTUnwrap(platforms.first { $0.key == "whatsapp" })
        XCTAssertEqual(whatsapp.profile, "default")
        XCTAssertEqual(whatsapp.errorCode, "whatsapp_not_paired")
    }

    /// "Messaging apps — Messages sent through this app won't arrive" named no
    /// app. With the channels in hand, each broken one is its own alert and
    /// the unnamed roll-up goes.
    func testEachBrokenChannelIsNamedAndTheRollUpGoes() throws {
        let items = EventDigest.attention(
            routines: [],
            components: [HermesSystemComponent(name: "platforms", status: "degraded")],
            platforms: DashboardClient.platformHealth(from: status),
            assistants: ["radar-ia": "Radar IA"]
        )

        XCTAssertEqual(items.map(\.title).sorted(), ["Telegram · Radar IA", "WhatsApp"])

        let whatsapp = try XCTUnwrap(items.first { $0.title == "WhatsApp" })
        XCTAssertEqual(whatsapp.summary, "Turned on, but never linked")
        XCTAssertEqual(whatsapp.advice?.fixes, [
            .turnOffChannel(platform: "whatsapp", profile: "default", name: "WhatsApp"),
            .open(.channels, label: "Link an account"),
        ])
        XCTAssertEqual(whatsapp.advice?.fixes.first?.confirmation?.destructive, true)
        // Hermes' own words are kept for anyone who wants them.
        XCTAssertTrue(whatsapp.detail?.contains("not paired") == true)

        let telegram = try XCTUnwrap(items.first { $0.title == "Telegram · Radar IA" })
        XCTAssertEqual(telegram.profile, "radar-ia")
        XCTAssertEqual(telegram.summary, "Lost its connection")
        XCTAssertTrue(telegram.advice?.explanation.contains("for Radar IA") == true)
    }

    /// Without channel detail the roll-up is all there is, and it stays.
    func testTheRollUpRemainsWhenChannelsAreUnknown() {
        let items = EventDigest.attention(
            routines: [], components: [HermesSystemComponent(name: "platforms", status: "degraded")]
        )
        XCTAssertEqual(items.map(\.title), ["Messaging apps"])
    }

    // MARK: Words

    /// Every sentence a person reads, checked for the vocabulary that made the
    /// old alerts unreadable.
    func testNoAdviceSpeaksHermesInternals() {
        let failures = [
            driftMessage, "RuntimeError: Connection error.", "401 Unauthorized",
            "429 rate limit", "delivery failed", "boom",
            "[drift_skip] (model 'a' -> 'b') finite one-shot",
        ]
        var advice = failures.map(AlertAdvice.routineFailure)
        for (state, code) in [("fatal", "whatsapp_not_paired"), ("disconnected", nil), ("fatal", "x")] {
            advice.append(AlertAdvice.channel(
                platform: "whatsapp", name: "WhatsApp", profile: "default",
                state: state, code: code, assistant: nil
            ))
        }
        let banned = ["drift", "gateway", "platform", "fatal", "unpinned", "config",
                      "provider", "profile", "cron", "api"]
        for item in advice {
            let words = ([item.headline, item.explanation] + item.fixes.map(\.label)
                + item.fixes.compactMap { $0.confirmation.map { $0.title + " " + $0.message } })
                .joined(separator: " ").lowercased()
            for word in banned {
                XCTAssertFalse(words.contains(word), "“\(word)” in: \(words)")
            }
            XCTAssertFalse(item.fixes.isEmpty, item.headline)
        }
    }
}
