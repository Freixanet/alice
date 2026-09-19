import XCTest
@testable import Alice

final class AgentDraftTests: XCTestCase {
    func testANameIsAShortHeadlineNotTheOpeningSentence() {
        XCTAssertEqual(
            AgentDraft.name(from: "Watch Cuban sanctions and tell me what actually changed"),
            "Cuban Sanctions"
        )
        XCTAssertEqual(
            AgentDraft.name(from: "Track hotel deals in Blanes."),
            "Hotel Deals"
        )
        XCTAssertEqual(
            AgentDraft.name(from: "I want an agent that summarizes markets every morning"),
            "Markets Morning"
        )
        // A lead-in turns the verb third-person; the name is still what the
        // agent is about, not the verb.
        XCTAssertEqual(
            AgentDraft.name(from: "An agent that watches hotel prices in Blanes"),
            "Hotel Prices"
        )
        XCTAssertEqual(AgentDraft.name(from: "  Radar\nsecond line"), "Radar")
        XCTAssertEqual(AgentDraft.name(from: "Radar IA"), "Radar IA")
        XCTAssertEqual(AgentDraft.name(from: "   "), "")
    }

    func testStandingInstructionsKeepTheBriefIntact() {
        let soul = AgentDraft.soul(from: "Track hotel deals in Blanes.")
        XCTAssertTrue(soul.contains("Track hotel deals in Blanes."))
        XCTAssertTrue(soul.contains("# Role"))
        XCTAssertTrue(soul.contains("## Examples"))
        XCTAssertTrue(soul.contains("On first contact"))
        XCTAssertTrue(soul.contains("Person: Track hotel deals in Blanes."))
    }

    func testAgentMakerIsAskedAboutTheProfileThatAlreadyExists() {
        let text = AgentMaker.request(
            name: "Cuba watch", profile: "cuba-watch", brief: "Sanctions news.", jobID: "job-form-1"
        )
        XCTAssertTrue(text.contains("`cuba-watch`"))
        XCTAssertTrue(text.contains("Cuba watch"))
        XCTAssertTrue(text.contains("Sanctions news."))
        XCTAssertTrue(text.contains("reuse_profile=cuba-watch"))
        XCTAssertTrue(text.contains("job_id=job-form-1"))
        XCTAssertTrue(text.contains("Do not create a second profile"))
        XCTAssertTrue(text.contains("intake"))
        XCTAssertTrue(text.contains("## Examples"))
        XCTAssertEqual(AgentMaker.legacyProfileID, "forja")
        XCTAssertEqual(AgentMaker.displayName, "Agent Maker")
        XCTAssertEqual(AgentMaker.preferredProfileID, "agent-maker")
    }

    func testStandingInstructionsKeepEveryAgentOnItsRoleAndInThePersonsLanguage() {
        let soul = AgentDraft.soul(from: "Track hotel deals in Blanes.")
        XCTAssertTrue(soul.contains("## How you treat this person"))
        XCTAssertTrue(soul.contains("language they write in"))
        XCTAssertTrue(soul.contains("Never show raw tool output"))
        XCTAssertTrue(soul.contains("if you have nothing useful to say, say nothing"))
        XCTAssertTrue(soul.contains("Never message them on your own schedule"))
        let request = AgentMaker.request(name: "X", profile: "x", brief: "Y", jobID: "job-1")
        XCTAssertTrue(request.contains("never show raw tool output"))
        XCTAssertTrue(request.contains("language this person writes in"))
    }

    func testAnEmptyBriefMakesNoStandingInstructions() {
        XCTAssertEqual(AgentDraft.soul(from: "   "), "")
        XCTAssertEqual(AgentDraft.name(from: ""), "")
    }
}
