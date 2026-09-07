import XCTest
@testable import Alice

final class MemoryProvidersTests: XCTestCase {
    func testMemoryProviderStatusPreservesSetupAndBuiltinSizes() throws {
        let status = try DashboardClient.memoryProviderStatus(from: [
            "active": "holographic",
            "builtin_files": ["memory": 120, "user": 80],
            "providers": [[
                "name": "holographic", "description": "Local memory",
                "available": true, "configured": true, "status": "ready",
                "setup": [
                    "pip_dependencies": [String](),
                    "external_dependencies": [[String: Any]](),
                    "required_env": [String](), "dependencies_installed": true,
                ],
            ]],
        ])
        XCTAssertEqual(status.active, "holographic")
        XCTAssertEqual(status.providers.count, 1)
        XCTAssertTrue(status.providers[0].active)
        XCTAssertEqual(status.builtinMemoryBytes, 120)
        XCTAssertEqual(status.builtinUserBytes, 80)
        XCTAssertTrue(status.setup["holographic"]?.dependenciesInstalled == true)
    }

    func testMalformedMemoryStatusDoesNotBecomeEmpty() {
        XCTAssertThrowsError(try DashboardClient.memoryProviderStatus(from: [
            "active": "", "providers": [[String: Any]](),
        ]))
    }

    func testMemoryProviderConfigPreservesSecretStateOptionsAndConditions() throws {
        let config = try DashboardClient.memoryProviderConfiguration(from: [
            "name": "example", "label": "Example",
            "fields": [[
                "key": "api_key", "label": "API key", "kind": "secret",
                "description": "Write only", "placeholder": "secret",
                "required": true, "value": "", "is_set": true,
                "options": [[String: Any]](), "url": "https://example.test",
            ], [
                "key": "enabled", "label": "Enabled", "kind": "boolean",
                "description": "", "placeholder": "", "required": false,
                "value": true, "is_set": true, "options": [[String: Any]](), "url": "",
                "when": ["mode": "cloud"],
            ], [
                "key": "api_key", "label": "API key duplicate", "kind": "secret",
                "description": "Later duplicate", "placeholder": "secret",
                "required": true, "value": "", "is_set": true,
                "options": [[String: Any]](), "url": "https://example.test",
            ], [
                "key": "mode", "label": "Mode", "kind": "select",
                "description": "", "placeholder": "", "required": false,
                "value": "cloud", "is_set": true, "url": "",
                "options": [["value": "cloud", "label": "Cloud", "description": "Hosted"]],
            ]],
        ], surface: "legacy")
        XCTAssertEqual(config.fields.count, 3)
        XCTAssertTrue(config.fields[0].isSecret)
        XCTAssertTrue(config.fields[0].isSet)
        XCTAssertEqual(config.fields[0].value, "")
        XCTAssertEqual(config.fields[0].label, "API key duplicate")
        XCTAssertEqual(config.fields[1].value, "true")
        XCTAssertEqual(config.fields[1].when["mode"], "cloud")
        XCTAssertEqual(config.fields[2].options.first?.label, "Cloud")
    }

    func testMalformedMemoryProviderFieldDoesNotDisappear() {
        XCTAssertThrowsError(try DashboardClient.memoryProviderConfiguration(from: [
            "name": "example", "label": "Example",
            "fields": [["label": "Missing key"]],
        ], surface: "legacy"))
    }

    func testMemorySetupResultPreservesFailureOutput() throws {
        let result = try DashboardClient.memoryProviderSetupResponse(from: [
            "ok": false, "provider": "hindsight",
            "results": [[
                "kind": "pip", "name": "hindsight-client", "status": "failed",
                "command": "pip install hindsight-client", "returncode": 1,
                "stdout": "", "stderr": "network unavailable",
            ]],
        ])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.results.first?.returnCode, 1)
        XCTAssertEqual(result.results.first?.stderr, "network unavailable")
    }

    func testMemoryOAuthStatusPreservesConnectionKind() throws {
        let status = try DashboardClient.memoryProviderOAuthStatus(from: [
            "state": "connected", "detail": "Honcho connected",
            "connected": true, "auth": "oauth",
        ])
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.state, "connected")
        XCTAssertEqual(status.auth, "oauth")
    }
}
