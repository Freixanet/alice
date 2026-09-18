import XCTest
@testable import Alice

final class AgentCreationTests: XCTestCase {
    func testAgentMakerBecomesAgentMaker() throws {
        XCTAssertEqual(AgentProfileID.slugify("Agent Maker"), "agent-maker")
        XCTAssertEqual(try AgentProfileID.parse("Agent Maker"), "agent-maker")
        XCTAssertEqual(
            AgentProfileID.note(display: "Agent Maker", id: "agent-maker"),
            "Alice shows “Agent Maker”. Hermes knows this agent as `agent-maker`."
        )
    }

    func testReservedAndInvalidNames() {
        XCTAssertThrowsError(try AgentProfileID.parse("default"))
        XCTAssertThrowsError(try AgentProfileID.parse("hermes"))
        XCTAssertThrowsError(try AgentProfileID.parse("***"))
        XCTAssertThrowsError(try AgentProfileID.parse("   "))
    }

    func testSameNormalizedId() throws {
        XCTAssertEqual(try AgentProfileID.parse("Radar IA"), "radar-ia")
        XCTAssertEqual(try AgentProfileID.parse("radar-ia"), "radar-ia")
    }

    func testFormSpecDoesNotInventAModelOrTools() throws {
        let spec = try AgentSpec.form(
            title: "Resumen de Mercados",
            description: "Mornings.",
            soul: AgentDraft.soul(from: "Mornings.")
        )
        XCTAssertEqual(spec.profileID, "resumen-de-mercados")
        XCTAssertNil(spec.tools)
        XCTAssertNil(spec.model)
        XCTAssertEqual(spec.source, "form")
        XCTAssertNotNil(spec.soul)
    }

    func testOccupiedAndFailedResultsAreNotSuccess() throws {
        let occupied = try AgentOperationResult.parse([
            "ok": false,
            "status": "failed",
            "profile_id": "radar-ia",
            "error": "Ya existe un agente llamado `radar-ia`.",
            "confirmed": [],
        ])
        XCTAssertEqual(occupied.status, .failed)
        XCTAssertThrowsError(try occupied.requireCreated())
        let auth = try AgentOperationResult.parse([
            "ok": false,
            "status": "needs_auth",
            "profile_id": "radar-ia",
            "job_id": "job-auth-1",
            "confirmed": ["perfil"],
            "checks": ["autenticacion": false, "perfil_creado": true],
        ])
        XCTAssertEqual(try auth.requireCreated(), "radar-ia")
        XCTAssertFalse(auth.ok)
        XCTAssertEqual(auth.status, .needsAuth)
        XCTAssertFalse(auth.isReady)
        XCTAssertFalse(auth.shouldSendBrief)
        XCTAssertThrowsError(try auth.requireReady()) { error in
            guard case let AgentOperationError.incomplete(status, jobID, _) = error else {
                return XCTFail("expected incomplete, got \(error)")
            }
            XCTAssertEqual(status, .needsAuth)
            XCTAssertEqual(jobID, "job-auth-1")
        }
    }

    func testPartialKeepsJobAndDoesNotSendTheBrief() throws {
        let partial = try AgentOperationResult.parse([
            "ok": false,
            "status": "partial",
            "profile_id": "radar-ia",
            "job_id": "job-partial-1",
            "error": "Creation finished with unverified steps.",
            "confirmed": ["perfil"],
        ])
        XCTAssertTrue(partial.didCreateProfile)
        XCTAssertFalse(partial.isReady)
        XCTAssertFalse(partial.shouldSendBrief)
        XCTAssertEqual(try partial.requireCreated(), "radar-ia")
        XCTAssertThrowsError(try partial.requireReady()) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("job-partial-1"), text)
            XCTAssertTrue(text.contains("partial"), text)
        }
    }

    func testJobIDRejectsPathsAndTraversal() {
        XCTAssertThrowsError(try AgentJobID.parse("../etc/passwd"))
        XCTAssertThrowsError(try AgentJobID.parse("/tmp/job"))
        XCTAssertThrowsError(try AgentJobID.parse("foo/bar"))
        XCTAssertThrowsError(try AgentJobID.parse("..\\windows"))
        XCTAssertThrowsError(try AgentJobID.parse(""))
        XCTAssertEqual(try AgentJobID.parse("job-resume-1"), "job-resume-1")
        XCTAssertEqual(
            try AgentJobID.parse("maker-migrate-forja-to-agent-maker"),
            "maker-migrate-forja-to-agent-maker"
        )
    }

    func testOldOperationPayloadsStillDecode() throws {
        let legacy = try AgentOperationResult.parse([
            "ok": true,
            "hecho": ["perfil", "instrucciones"],
            "comprobaciones": ["perfil_creado": true],
            "name": "forja",
        ])
        XCTAssertEqual(legacy.status, .completed)
        XCTAssertEqual(legacy.confirmed, ["perfil", "instrucciones"])
        XCTAssertEqual(legacy.profileID, "forja")
        XCTAssertEqual(legacy.checks["perfil_creado"], true)
    }

    func testRenameCollisionAndRemoteFailureAreNotSuccess() throws {
        let collision = try AgentOperationResult.parse([
            "ok": false, "status": "failed", "from_id": "forja", "to_id": "agent-maker",
            "error": "`agent-maker` already exists.",
        ])
        XCTAssertThrowsError(try collision.requireRenamed())
        let partial = try AgentOperationResult.parse([
            "ok": false, "status": "partial", "from_id": "forja", "to_id": "agent-maker",
            "confirmed": ["renombrado"],
        ])
        let renamed = try partial.requireRenamed()
        XCTAssertEqual(renamed.from, "forja")
        XCTAssertEqual(renamed.to, "agent-maker")
        XCTAssertFalse(partial.ok)
    }
}

final class AgentMakerIdentityTests: XCTestCase {
    func testLegacyForjaAndStampedRoleBothMatch() {
        XCTAssertTrue(AgentMaker.matches(profile: "forja"))
        XCTAssertTrue(AgentMaker.matches(profile: "agent-maker", role: AgentMaker.role))
        XCTAssertTrue(AgentMaker.matches(profile: "taller", role: AgentMaker.role))
        XCTAssertFalse(AgentMaker.matches(profile: "radar-ia"))
        XCTAssertEqual(
            AgentMaker.displayIfNeeded(profile: "forja", shown: "Forja"),
            "Agent Maker"
        )
        XCTAssertEqual(
            AgentMaker.displayIfNeeded(profile: "agent-maker", shown: "agent-maker", role: AgentMaker.role),
            "Agent Maker"
        )
        XCTAssertEqual(
            AgentMaker.displayIfNeeded(profile: "taller", shown: "Taller", role: AgentMaker.role),
            "Taller"
        )
    }

    func testReuseInstructionNamesTheExistingProfile() {
        let text = AgentMaker.request(
            name: "Cuba watch", profile: "cuba-watch", brief: "Sanctions news.", jobID: "job-form-1"
        )
        XCTAssertTrue(text.contains("reuse_profile=cuba-watch"))
        XCTAssertTrue(text.contains("job_id=job-form-1"))
        XCTAssertTrue(text.contains("Do not create a second profile"))
        XCTAssertTrue(text.contains("another job"))
    }
}

@MainActor
final class AgentProfileRebindTests: XCTestCase {
    func testRebindMovesStructuredRefsAndLeavesMessageText() throws {
        let suite = "alice.rebind-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        var chat = Conversation.blank(title: "forja")
        chat.botName = "forja"
        chat.legacyBotName = "forja"
        chat.messages = [
            Message(id: "1", role: .user, content: "Ask @forja later", createdAt: Date(), botName: "forja"),
        ]
        store.conversations = [chat]
        store.botCustomNames["forja"] = "Agent Maker"
        store.botSections["forja"] = "Home"
        store.botOrder = ["forja"]
        store.rebindLocalProfile(from: "forja", to: "agent-maker", title: "Agent Maker")
        XCTAssertEqual(store.conversations.first?.botName, "agent-maker")
        XCTAssertEqual(store.conversations.first?.legacyBotName, "agent-maker")
        XCTAssertEqual(store.conversations.first?.messages.first?.botName, "agent-maker")
        XCTAssertEqual(store.conversations.first?.messages.first?.content, "Ask @forja later")
        XCTAssertEqual(store.botSections["agent-maker"], "Home")
        XCTAssertNil(store.botSections["forja"])
        XCTAssertEqual(store.botOrder, ["agent-maker"])
    }

    func testLocalCollisionCheckDoesNotMintASuffix() throws {
        XCTAssertEqual(try AgentProfileID.parse("Agente Prueba"), "agente-prueba")
        XCTAssertNotEqual(
            AppStore.uniqueBotSlug("Agente Prueba", taken: ["agente-prueba"]),
            "agente-prueba"
        )
    }
}
