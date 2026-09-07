import XCTest
@testable import Alice

final class MCPTests: XCTestCase {
    func testServerListingPreservesProfileConfigurationWithoutInventingSecrets() throws {
        let object: [String: Any] = [
            "servers": [[
                "name": "notion", "transport": "http",
                "url": "https://mcp.notion.com/mcp", "command": NSNull(),
                "args": [String](), "env": [String: String](),
                "auth": "oauth", "enabled": false, "tools": NSNull(),
            ]],
        ]
        let servers = try DashboardClient.mcpServers(from: object)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "notion")
        XCTAssertEqual(servers[0].auth, "oauth")
        XCTAssertFalse(servers[0].enabled)
        XCTAssertNil(servers[0].tools)
        XCTAssertTrue(servers[0].env.isEmpty)
    }

    func testMalformedServerListingIsNotReportedAsEmpty() {
        XCTAssertThrowsError(try DashboardClient.mcpServers(from: [:]))
        XCTAssertThrowsError(try DashboardClient.mcpServers(from: [
            "servers": [["name": "broken"]],
        ]))
    }

    func testProbeKeepsToolsSchemaPromptsAndResources() throws {
        let result = try DashboardClient.mcpTestResult(from: [
            "ok": true,
            "tools": [[
                "name": "search", "description": "Search things", "schema_chars": 812,
            ]],
            "prompts": 2,
            "resources": 3,
        ])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.tools.first?.name, "search")
        XCTAssertEqual(result.tools.first?.schemaCharacters, 812)
        XCTAssertEqual(result.prompts, 2)
        XCTAssertEqual(result.resources, 3)
    }

    func testOAuthFlowCarriesAuthorizationURLAndApprovedTools() throws {
        let flow = try DashboardClient.mcpOAuthFlow(from: [
            "flow_id": "flow-1", "server_name": "notion", "status": "approved",
            "authorization_url": "https://example.com/oauth", "error": NSNull(),
            "tools": [["name": "pages", "description": "Read pages"]],
        ])
        XCTAssertEqual(flow.flowID, "flow-1")
        XCTAssertEqual(flow.authorizationURL, "https://example.com/oauth")
        XCTAssertEqual(flow.tools.map(\.name), ["pages"])
    }

    func testCatalogParsesRequiredEnvBootstrapAndNullToolDefaults() throws {
        let snapshot = try DashboardClient.mcpCatalog(from: [
            "entries": [[
                "name": "example", "description": "Example MCP", "source": "nous",
                "transport": "stdio", "auth_type": "api_key",
                "required_env": [["name": "API_KEY", "prompt": "API key", "required": true]],
                "command": "npx", "args": ["-y", "example"], "url": NSNull(),
                "install_url": "https://github.com/example/mcp", "install_ref": "main",
                "bootstrap": ["npm install"], "default_enabled": NSNull(),
                "post_install": "Restart your session", "needs_install": true,
                "installed": false, "enabled": false,
            ]],
            "diagnostics": [["name": "example", "kind": "warning", "message": "Review bootstrap"]],
        ])
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries[0].requiredEnv.first?.name, "API_KEY")
        XCTAssertEqual(snapshot.entries[0].bootstrap, ["npm install"])
        XCTAssertNil(snapshot.entries[0].defaultEnabledTools)
        XCTAssertEqual(snapshot.diagnostics.first?.message, "Review bootstrap")
    }

    func testMalformedCatalogDoesNotBecomeAnEmptyCatalog() {
        XCTAssertThrowsError(try DashboardClient.mcpCatalog(from: ["entries": []]))
        XCTAssertThrowsError(try DashboardClient.mcpCatalog(from: [
            "entries": [["name": "broken"]], "diagnostics": [],
        ]))
    }
}
