import XCTest
@testable import Alice

final class WebhooksTests: XCTestCase {
    func testWebhookListingPreservesRouteDetailsWithoutSecret() throws {
        let snapshot = try DashboardClient.webhooks(from: [
            "enabled": true,
            "base_url": "http://localhost:8644",
            "subscriptions": [[
                "name": "github-push",
                "description": "Watch pushes",
                "events": ["push", "deployment"],
                "deliver": "telegram",
                "deliver_only": false,
                "prompt": "Summarize the payload",
                "script": "/opt/hermes/filter.py",
                "skills": ["github"],
                "created_at": "2026-09-07T20:00:00Z",
                "url": "http://localhost:8644/webhooks/github-push",
                "secret_set": true,
                "enabled": true,
            ]],
        ])

        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.baseURL, "http://localhost:8644")
        XCTAssertEqual(snapshot.subscriptions.count, 1)
        let sub = try XCTUnwrap(snapshot.subscriptions.first)
        XCTAssertEqual(sub.events, ["push", "deployment"])
        XCTAssertEqual(sub.deliver, "telegram")
        XCTAssertEqual(sub.script, "/opt/hermes/filter.py")
        XCTAssertEqual(sub.skills, ["github"])
        XCTAssertTrue(sub.secretSet)
    }

    func testEmptyWebhookListingIsARealEmptyAnswer() throws {
        let snapshot = try DashboardClient.webhooks(from: [
            "enabled": false,
            "base_url": "http://localhost:8644",
            "subscriptions": [[String: Any]](),
        ])
        XCTAssertFalse(snapshot.enabled)
        XCTAssertTrue(snapshot.subscriptions.isEmpty)
    }

    func testMalformedWebhookListingDoesNotBecomeEmpty() {
        XCTAssertThrowsError(try DashboardClient.webhooks(from: [
            "enabled": true,
            "base_url": "http://localhost:8644",
        ]))
    }

    func testMalformedWebhookRowDoesNotDisappearSilently() {
        XCTAssertThrowsError(try DashboardClient.webhooks(from: [
            "enabled": true,
            "base_url": "http://localhost:8644",
            "subscriptions": [["name": "broken"]],
        ]))
    }

    func testWebhookCreateBodyCarriesAdvancedFields() {
        let body = DashboardClient.webhookCreateBody(
            name: "deploy",
            description: "Deployment notification",
            events: ["deployment"],
            prompt: "Summarize",
            script: "/tmp/filter.sh",
            skills: ["github", "ops"],
            deliver: "slack",
            deliverOnly: true,
            deliverChatID: "C123",
            secret: "explicit-secret"
        )
        XCTAssertEqual(body["name"] as? String, "deploy")
        XCTAssertEqual(body["events"] as? [String], ["deployment"])
        XCTAssertEqual(body["skills"] as? [String], ["github", "ops"])
        XCTAssertEqual(body["script"] as? String, "/tmp/filter.sh")
        XCTAssertEqual(body["deliver"] as? String, "slack")
        XCTAssertEqual(body["deliver_only"] as? Bool, true)
        XCTAssertEqual(body["deliver_chat_id"] as? String, "C123")
        XCTAssertEqual(body["secret"] as? String, "explicit-secret")
    }

    func testWebhookCreateBodyOmitsGeneratedSecretInput() {
        let body = DashboardClient.webhookCreateBody(name: "simple")
        XCTAssertNil(body["secret"])
        XCTAssertNil(body["description"])
        XCTAssertNil(body["prompt"])
        XCTAssertNil(body["script"])
        XCTAssertNil(body["deliver_chat_id"])
        XCTAssertEqual(body["deliver"] as? String, "log")
        XCTAssertEqual(body["deliver_only"] as? Bool, false)
    }
}
