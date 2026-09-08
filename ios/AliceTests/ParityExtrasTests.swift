import XCTest
@testable import Alice

final class ParityExtrasTests: XCTestCase {
    func testPairingPreservesPendingAndApprovedIdentity() throws {
        let value = try DashboardClient.pairingSnapshot(from: [
            "pending": [["platform":"telegram","user_id":"42","user_name":"Marc","request_id":"req-1","age_minutes":2.5]],
            "approved": [["platform":"whatsapp","user_id":"15551234567"]],
        ])
        XCTAssertEqual(value.pending.first?.requestID, "req-1")
        XCTAssertEqual(value.pending.first?.ageMinutes, 2.5)
        XCTAssertEqual(value.approved.first?.platform, "whatsapp")
    }

    func testMalformedPairingNeverLooksEmpty() {
        XCTAssertThrowsError(try DashboardClient.pairingSnapshot(from: [:]))
        XCTAssertThrowsError(try DashboardClient.pairingSnapshot(from: ["pending":[["platform":"telegram"]],"approved":[]]))
    }

    func testPluginHubPreservesLifecycleAndDashboardOnlyEntries() throws {
        let value = try DashboardClient.pluginHub(from: [
            "plugins": [[
                "name":"demo","version":"1.2.3","description":"Demo plugin","source":"git",
                "runtime_status":"enabled","has_dashboard_manifest":true,"path":"/tmp/demo",
                "can_remove":true,"can_update_git":true,"auth_required":true,"auth_command":"hermes auth demo","user_hidden":false,
            ]],
            "orphan_dashboard_plugins": [[
                "name":"board","label":"Board","description":"UI","version":"1.0","source":"bundled","has_api":true,
                "tab":["path":"/board"],
            ]],
            "providers": ["context_engine":"compressor","context_options":[["name":"compressor","description":"Built in"]]],
        ])
        XCTAssertEqual(value.plugins.first?.runtimeStatus, "enabled")
        XCTAssertTrue(value.plugins.first?.canRemove == true)
        XCTAssertEqual(value.dashboardOnly.first?.path, "/board")
        XCTAssertEqual(value.contextOptions.first?.name, "compressor")
    }

    func testMalformedPluginHubThrowsInsteadOfHidingPlugins() {
        XCTAssertThrowsError(try DashboardClient.pluginHub(from: ["plugins": []]))
    }

    func testCredentialPoolCarriesOnlyServerPreviewAndMetadata() throws {
        let rows = try DashboardClient.credentialPool(from: ["providers":[[
            "provider":"openrouter","entries":[[
                "index":1,"id":"abc","label":"primary","auth_type":"api_key","source":"manual","priority":0,
                "last_status":"ok","request_count":12,"token_preview":"sk-o...1234","has_refresh":false,
            ]]
        ]]])
        let entry = try XCTUnwrap(rows.first?.entries.first)
        XCTAssertEqual(entry.tokenPreview, "sk-o...1234")
        XCTAssertEqual(entry.requestCount, 12)
        XCTAssertFalse(entry.hasRefresh)
    }

    func testHooksPreserveApprovalExecutableAndEventCatalog() throws {
        let value = try DashboardClient.hooksSnapshot(from: [
            "valid_events":["pre_tool_call","on_session_end"],
            "hooks":[["event":"pre_tool_call","command":"echo ok","matcher":"shell","timeout":5,"allowed":true,"approved_at":"now","executable":true]],
        ])
        XCTAssertEqual(value.validEvents.count, 2)
        XCTAssertTrue(value.hooks.first?.allowed == true)
        XCTAssertTrue(value.hooks.first?.executable == true)
    }

    func testCuratorAndPortalPreserveOperationalState() throws {
        let curator = try DashboardClient.curatorStatus(from: [
            "enabled":true,"paused":false,"interval_hours":168,"last_run_at":"2026-09-02T00:00:00Z","min_idle_hours":2.0,"stale_after_days":30,"archive_after_days":90,
        ])
        XCTAssertEqual(curator.intervalHours, 168)
        let portal = try DashboardClient.portalStatus(from: [
            "logged_in":true,"portal_url":"https://portal.example","inference_url":"https://infer.example/v1","provider":"nous","subscription_url":"https://portal.example/sub",
            "features":[["label":"Web tools","state":"ready"]],
        ])
        XCTAssertTrue(portal.loggedIn)
        XCTAssertEqual(portal.features.first?.state, "ready")
    }

    func testComputerUseKeepsPermissionReadinessDistinctFromInstall() throws {
        let value = try DashboardClient.computerUseStatus(from: [
            "platform":"darwin","platform_supported":true,"installed":true,"version":"cua-driver 1","ready":false,"can_grant":true,
            "checks":[["label":"binary","status":"ok","message":"installed"]],
            "accessibility":false,"screen_recording":NSNull(),"screen_recording_capturable":NSNull(),
        ])
        XCTAssertTrue(value.installed)
        XCTAssertFalse(value.ready)
        XCTAssertTrue(value.canGrant)
        XCTAssertEqual(value.accessibility, false)
        XCTAssertNil(value.screenRecording)
    }

    func testCronBlueprintPreservesDynamicFieldsAndNonStrictSuggestions() throws {
        let rows = try DashboardClient.cronBlueprints(from: ["blueprints":[[
            "key":"brief","title":"Brief","description":"Daily","category":"daily","tags":["daily"],
            "fields":[["name":"deliver","type":"enum","label":"Where","default":"origin","options":["origin","telegram"],"optional":false,"strict":false,"help":"target"]],
            "schedule":"0 8 * * *","scheduleHuman":"daily at 08:00","command":"/blueprint brief","appUrl":"hermes://blueprint/brief",
        ]]])
        XCTAssertEqual(rows.first?.fields.first?.defaultValue, "origin")
        XCTAssertFalse(rows.first?.fields.first?.strict == true)
        XCTAssertEqual(rows.first?.scheduleHuman, "daily at 08:00")
    }

    func testSavedEndpointNeverRequiresPlaintextKeyOnRead() throws {
        let value = try DashboardClient.savedCustomEndpoints(from: [
            "endpoints":[[
                "id":"lab","name":"Lab","base_url":"http://127.0.0.1:8000/v1","model":"model-a","models":["model-a"],
                "context_length":32768,"discover_models":true,"has_api_key":true,"api_key_preview":"sk...abcd","is_current":false,"source":"providers",
            ]],
            "current":["provider":"nous","model":"main","base_url":"https://example/v1"],
        ])
        XCTAssertTrue(value.endpoints.first?.hasAPIKey == true)
        XCTAssertEqual(value.endpoints.first?.APIKeyPreview, "sk...abcd")
        XCTAssertEqual(value.endpoints.first?.contextLength, 32768)
    }

    func testCustomEndpointValidationPreservesReachabilitySeparateFromAcceptance() throws {
        let value = try DashboardClient.customEndpointValidation(from: ["ok":false,"reachable":true,"message":"bad key","models":[]])
        XCTAssertFalse(value.ok)
        XCTAssertTrue(value.reachable)
        XCTAssertEqual(value.message, "bad key")
    }

    func testDebugShareRequiresExplicitSuccessfulEnvelope() throws {
        let value = try DashboardClient.debugShare(from: ["ok":true,"urls":["https://paste.example/a"],"failures":[],"redacted":true,"auto_delete_seconds":3600])
        XCTAssertTrue(value.redacted)
        XCTAssertEqual(value.autoDeleteSeconds, 3600)
        XCTAssertThrowsError(try DashboardClient.debugShare(from: ["ok":false,"urls":[],"failures":[],"redacted":true]))
    }

    func testTerminalBackendsPreserveReadinessSeparateFromActive() throws {
        let value = try DashboardClient.terminalBackends(from: [
            "active":"local",
            "backends":[
                ["name":"local","label":"Local","description":"Host","active":true,"status":"ready","detail":""],
                ["name":"ssh","label":"SSH","description":"Remote","active":false,"status":"needs_setup","detail":"missing host"],
            ],
        ])
        XCTAssertEqual(value.active, "local")
        XCTAssertEqual(value.backends.last?.status, "needs_setup")
        XCTAssertFalse(value.backends.last?.active == true)
    }

    func testLearningGraphPreservesNodeKindsWithoutFlatteningMemory() throws {
        let value = try DashboardClient.learningGraph(from: [
            "nodes":[["id":"skill-a","label":"Skill A","kind":"skill","timestamp":1.0,"category":"code","useCount":3,"state":"active","createdBy":NSNull(),"pinned":true]],
            "edges":[["source":"skill-a","target":"memory-1"]],
            "clusters":[["category":"code","count":1]],
            "memory":[["source":"memory","timestamp":1.0,"title":"T","body":"B"]],
            "stats":[:],
        ])
        XCTAssertEqual(value.nodes.first?.kind, "skill")
        XCTAssertEqual(value.edgeCount, 1)
        XCTAssertEqual(value.memoryCount, 1)
        XCTAssertTrue(value.nodes.first?.pinned == true)
    }

    func testLearningNodeRequiresSuccessfulEnvelope() throws {
        let value = try DashboardClient.learningNode(from: ["ok":true,"kind":"memory","id":"m1","label":"Memory","content":"body"])
        XCTAssertEqual(value.content, "body")
        XCTAssertThrowsError(try DashboardClient.learningNode(from: ["ok":false,"kind":"memory","id":"m1","label":"Memory","content":"body"]))
    }
}
