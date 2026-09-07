import XCTest
@testable import Alice

final class ChannelsTests: XCTestCase {
    func testMessagingPlatformParserPreservesStateCredentialsAndWhatsAppSetup() throws {
        let object: [String: Any] = [
            "env_path": "/srv/hermes/.env",
            "gateway_start_command": "hermes gateway start --profile default",
            "platforms": [[
                "id": "whatsapp",
                "name": "WhatsApp",
                "description": "WhatsApp bridge",
                "docs_url": "https://example.test/whatsapp",
                "enabled": true,
                "configured": true,
                "gateway_running": true,
                "state": "connected",
                "error_code": NSNull(),
                "error_message": NSNull(),
                "updated_at": "2026-09-07T20:00:00Z",
                "home_channel": ["platform": "whatsapp", "chat_id": "15551234567", "name": "Home"],
                "whatsapp_setup": ["mode": "self-chat", "allowed_users_set": true, "home_channel_set": true],
                "env_vars": [[
                    "key": "WHATSAPP_ALLOWED_USERS", "required": false, "is_set": true,
                    "redacted_value": "1555…", "description": "Allowed users",
                    "prompt": "Allowed WhatsApp users", "help": "Comma-separated",
                    "url": NSNull(), "is_password": false, "advanced": false,
                ]],
            ]],
        ]

        let snapshot = try DashboardClient.messagingPlatforms(from: object)
        XCTAssertEqual(snapshot.envPath, "/srv/hermes/.env")
        XCTAssertEqual(snapshot.platforms.count, 1)
        let platform = try XCTUnwrap(snapshot.platforms.first)
        XCTAssertEqual(platform.id, "whatsapp")
        XCTAssertEqual(platform.state, "connected")
        XCTAssertEqual(platform.homeChannel?.chatID, "15551234567")
        XCTAssertEqual(platform.whatsappSetup?.mode, "self-chat")
        XCTAssertEqual(platform.envVars.first?.redactedValue, "1555…")
    }

    func testMalformedMessagingListingDoesNotBecomeEmpty() {
        XCTAssertThrowsError(try DashboardClient.messagingPlatforms(from: ["platforms": [[:]]]))
        XCTAssertThrowsError(try DashboardClient.messagingPlatforms(from: [:]))
    }

    func testTelegramOnboardingParsersKeepOwnerAndExpiry() throws {
        let start = try DashboardClient.telegramOnboardingStart(from: [
            "pairing_id": "pair-1", "suggested_username": "HermesBot",
            "deep_link": "https://t.me/example", "qr_payload": "https://t.me/example",
            "expires_at": "2026-09-07T21:00:00Z",
        ])
        XCTAssertEqual(start.pairingID, "pair-1")

        let ready = try DashboardClient.telegramOnboardingStatus(from: [
            "status": "ready", "bot_username": "HermesBot",
            "owner_user_id": "123456789", "expires_at": "2026-09-07T21:00:00Z",
        ])
        XCTAssertEqual(ready.status, "ready")
        XCTAssertEqual(ready.ownerUserID, "123456789")
    }

    func testWhatsAppOnboardingParserKeepsLinkedAccount() throws {
        let session = try DashboardClient.whatsAppOnboardingSession(from: [
            "pairing_id": "wa-1", "status": "connected",
            "expires_at": "2026-09-07T21:00:00Z", "mode": "bot",
            "allowed_users": "", "account_id": "15551234567@s.whatsapp.net",
            "account_name": "Alice", "account_phone": "15551234567",
        ])
        XCTAssertEqual(session.status, "connected")
        XCTAssertEqual(session.accountPhone, "15551234567")
    }

    func testChannelApplyParserKeepsRestartOutcome() throws {
        let result = try DashboardClient.channelApplyResult(from: [
            "ok": true, "platform": "telegram", "needs_restart": false,
            "restart_started": true, "restart_action": "gateway-restart",
            "bot_username": "HermesBot",
        ])
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.restartStarted)
        XCTAssertFalse(result.needsRestart)
        XCTAssertEqual(result.botUsername, "HermesBot")
    }
}
