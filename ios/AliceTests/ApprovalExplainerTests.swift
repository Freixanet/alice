import XCTest
@testable import Alice

/// Approvals showed Hermes' class name or the raw command, and someone asked
/// to allow one had no idea what they were allowing. The descriptions below are
/// Hermes' own, from `tools/approval_detection.py` and `tools/approval.py`.
final class ApprovalExplainerTests: XCTestCase {

    private let fallbackAction = ApprovalExplainer.explain(description: "x-unknown", command: nil).action

    /// Every class of request that reaches a person, as Hermes writes it.
    private let hermesClasses = [
        "recursive delete", "recursive delete (long flag", "find -delete", "find -exec/-execdir rm",
        "xargs with rm", "delete in root path", "recognize force options when they follow operands",
        "force kill processes", "force kill processes (killall -KILL", "kill processes by regex (killall -r",
        "stop/restart system service", "stop/restart hermes gateway (kills running agents",
        "hermes update (restarts gateway, kills running agents", "overwrite system config",
        "overwrite system file via tee", "overwrite project env/config via redirection",
        "world/other-writable permissions", "recursive chown to root", "pipe remote content to shell",
        "execute remote script via process substitution", "pipe decoded content to shell (possible command obfuscation",
        "write to block device", "disk copy", "format filesystem", "access to SSH keys (Windows path",
        "registry delete (reg delete", "delete backups (wbadmin", "command parser limit exceeded",
    ]

    func testEveryHermesClassIsExplained() {
        for description in hermesClasses {
            let explanation = ApprovalExplainer.explain(description: description, command: nil)
            XCTAssertNotEqual(explanation.action, fallbackAction, "“\(description)” fell through")
        }
    }

    /// The approval people actually meet most: an assistant running a script.
    func testRunningAProgramIsSaidPlainly() {
        let hermes = "execute_code script execution. The script can spawn subprocesses or mutate files "
            + "without passing through terminal command approval; approval is one-shot for this run."
        XCTAssertEqual(ApprovalExplainer.explain(description: hermes, command: nil), ApprovalExplainer.program)
        // A row stored before descriptions were kept still has its command.
        XCTAssertEqual(
            ApprovalExplainer.explain(description: nil, command: "execute_code <<'PY'\nprint(1)\nPY"),
            ApprovalExplainer.program
        )
    }

    /// Where one class's words appear inside another's, the right one wins.
    func testLookalikeClassesAreNotConfused() {
        func action(_ d: String) -> String { ApprovalExplainer.explain(description: d, command: nil).action }
        XCTAssertEqual(action("world/other-writable permissions"), "change who is allowed to open or change files")
        XCTAssertEqual(action("delete backups (wbadmin"), "change core system settings or remove backups")
        XCTAssertEqual(action("force stop service (Stop-Service -Force"), "stop or restart a system service")
        XCTAssertEqual(action("access to Hermes secrets (Windows path"), "read your private keys or saved passwords")
        XCTAssertEqual(action("format filesystem"), "write directly to a disk")
    }

    /// Something new is described in Hermes' words rather than guessed at.
    func testAnUnknownClassIsQuotedNotInvented() {
        let explanation = ApprovalExplainer.explain(description: "brand new check", command: "x")
        XCTAssertTrue(explanation.risk.contains("brand new check"))
        XCTAssertFalse(ApprovalExplainer.explain(description: nil, command: "ls").risk.isEmpty)
    }

    func testTheWordsAvoidTerminalJargon() {
        let banned = ["execute_code", "subprocess", "shell", "redirection", "pattern", "gateway", " tee"]
        for description in hermesClasses + ["execute_code script execution"] {
            let explanation = ApprovalExplainer.explain(description: description, command: nil)
            let words = (explanation.action + " " + explanation.risk).lowercased()
            for word in banned {
                XCTAssertFalse(words.contains(word), "“\(word)” explaining “\(description)”: \(words)")
            }
        }
    }

    /// The buttons say what they do, and the hint only mentions what was offered.
    func testChoicesAreExplainedAsOffered() {
        XCTAssertEqual(ApprovalExplainer.label(.once), "Allow once")
        XCTAssertEqual(ApprovalExplainer.label(.deny), "Don't allow")
        let flagged = ApprovalExplainer.choiceHint([.once, .deny])
        XCTAssertFalse(flagged.contains("Always"))
        XCTAssertFalse(flagged.contains("conversation ends"))
        let full = ApprovalExplainer.choiceHint([.once, .session, .always, .deny])
        XCTAssertTrue(full.contains("Always allow"))
        XCTAssertTrue(full.contains("refuses"))
    }

    /// What Hermes said about a request survives the trip to disk and back.
    @MainActor
    func testAStoredApprovalKeepsItsClassAndWarning() {
        var event = AliceEvent(
            id: "approval:req-1", kind: .needsInput, severity: .needsAttention, profile: "radar-ia",
            title: "Radar IA needs your OK", summary: "Wants to run a small program it wrote",
            detail: "execute_code <<'PY' … PY", occurred: Date(),
            reference: .init(requestID: "req-1"), standing: .waiting, approvalChoices: [.once, .deny]
        )
        event.approvalDescription = "execute_code script execution"
        event.smartDenied = true
        let restored = AppStore.StoredEvent(event).event
        XCTAssertEqual(restored.approvalDescription, "execute_code script execution")
        XCTAssertTrue(restored.smartDenied)
    }
}
