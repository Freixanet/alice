import XCTest
@testable import Alice

/// Switching WhatsApp off in Channels spun, then slid back on. Hermes reads a
/// channel's state from config.yaml, but `WHATSAPP_ENABLED` in `.env` wins over
/// it, and the switch only wrote the config.
final class ChannelEnablementTests: XCTestCase {

    private func field(_ key: String, set: Bool) -> MessagingEnvField {
        MessagingEnvField(
            key: key, required: false, isSet: set, redactedValue: nil, detail: "",
            prompt: key, help: "", docsURL: nil, isPassword: false, advanced: false
        )
    }

    private func whatsapp(_ fields: [MessagingEnvField]) -> MessagingPlatform {
        MessagingPlatform(
            id: "whatsapp", name: "WhatsApp", detail: "", docsURL: "", enabled: true,
            configured: true, gatewayRunning: true, state: "fatal", errorCode: "whatsapp_not_paired",
            errorMessage: nil, updatedAt: nil, homeChannel: nil, whatsappSetup: nil, envVars: fields
        )
    }

    /// The fields this installation has for WhatsApp, as Hermes lists them.
    func testASetEnabledFlagIsCleared() {
        let platform = whatsapp([
            field("WHATSAPP_ENABLED", set: true), field("WHATSAPP_MODE", set: true),
            field("WHATSAPP_ALLOWED_USERS", set: true), field("WHATSAPP_HOME_CHANNEL", set: true),
        ])
        XCTAssertEqual(AppStore.enablementFlags(in: platform), ["WHATSAPP_ENABLED"])
    }

    /// Nothing else is touched: an unset flag, and every other key, stay as they are.
    func testOnlyASetFlagIsCleared() {
        XCTAssertEqual(AppStore.enablementFlags(in: whatsapp([field("WHATSAPP_ENABLED", set: false)])), [])
        XCTAssertEqual(AppStore.enablementFlags(in: whatsapp([field("WHATSAPP_MODE", set: true)])), [])
    }
}
