import XCTest
@testable import Alice

/// An agent asking another agent through Hermes' `message_agent`.
final class AgentMessagesTests: XCTestCase {
    private let answer = "Message from 🤖 forja (@forja): Evaluación de nombres.\n\nRanking: 1º FlowPilot."
    private let notice = """
        [IMPORTANT: Background process proc_104e77d623aa completed normally (exit code 0).
        Command: /x/venv/bin/python /x/tools/bot_mode_dm.py --run-delivery --profile-home /x/profiles/forja hermes -p forja chat --in '~' -c 'Bot Chat' --create-if-missing -Q
        Output:
        (anon):setopt:7: can't change option: monitor
        """

    func testAnotherAgentsMessageIsReadAsThatAgents() {
        XCTAssertEqual(
            AgentMessages.incoming(answer),
            .init(handle: "forja", body: "Evaluación de nombres.\n\nRanking: 1º FlowPilot.")
        )
        XCTAssertNil(AgentMessages.incoming("Message from my boss (@work): written by a person"))
        XCTAssertNil(AgentMessages.incoming("Message from 🤖 a header on\ntwo lines (@x): y"))
        XCTAssertNil(AgentMessages.incoming("Quiero una prueba simple"))
    }

    func testTheDeliveryNoticeNamesItsAgentAndHowItEnded() {
        XCTAssertEqual(AgentMessages.notice(notice), .init(handle: "forja", succeeded: true))
        let failed = notice.replacingOccurrences(of: "completed normally (exit code 0)", with: "exited with code 1")
        XCTAssertEqual(AgentMessages.notice(failed), .init(handle: "forja", succeeded: false))
        XCTAssertNil(AgentMessages.notice("[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: npm test"))
    }

    func testTargetsAreTheHandleTheAnswerIsSignedWith() {
        XCTAssertEqual(AgentMessages.normalized("@forja"), "forja")
        XCTAssertEqual(AgentMessages.normalized("forja@studio"), "forja")
        XCTAssertEqual(AgentMessages.normalized("spark/researcher"), "researcher")
        XCTAssertNil(AgentMessages.normalized("  "))
    }

    func testADelegationIsOpenUntilTheAgentAnswers() {
        let now = Date(timeIntervalSince1970: 10_000)
        var rows: [[String: Any]] = [
            ["role": "user", "text": "Elige un nombre", "timestamp": 9_900.0],
            ["role": "assistant", "text": ""],
            ["role": "tool", "name": "message_agent", "args": ["target": "forja", "message": "…"]],
            ["role": "assistant", "text": "Delegado a @forja", "timestamp": 9_910.0],
        ]
        let open = AgentMessages.pending(in: rows, now: now)
        XCTAssertEqual(open, [.init(handle: "forja", sentAt: Date(timeIntervalSince1970: 9_900))])

        rows.append(["role": "user", "text": answer, "timestamp": 9_950.0])
        XCTAssertTrue(AgentMessages.pending(in: rows, now: now).isEmpty)
    }

    func testADeliveryThatEndedWithoutAnAnswerIsNoLongerWaitedFor() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [[String: Any]] = [
            ["role": "tool", "name": "message_agent", "args": ["target": "@forja"]],
            ["role": "user", "text": notice],
        ]
        XCTAssertTrue(AgentMessages.pending(in: rows, now: now).isEmpty)
    }

    func testAnAnswerThatNeverCameStopsBeingWaitedFor() {
        let rows: [[String: Any]] = [
            ["role": "user", "text": "hola", "timestamp": 1_000.0],
            ["role": "tool", "name": "message_agent", "args": ["target": "forja"]],
        ]
        let later = Date(timeIntervalSince1970: 1_000 + AgentMessages.patience + 1)
        XCTAssertTrue(AgentMessages.pending(in: rows, now: later).isEmpty)
    }

    func testTheChatShowsTheAnswerAsTheAgentsAndLeavesOutTheNoticeAndItsEcho() {
        let now = Date()
        let messages = [
            Message(id: "1", role: .user, content: "Elige un nombre", createdAt: now),
            Message(id: "2", role: .assistant, content: "Delegado a @forja.", createdAt: now),
            Message(id: "3", role: .user, content: answer, createdAt: now),
            Message(id: "4", role: .assistant, content: "Decisión final: FlowPilot.", createdAt: now),
            Message(id: "5", role: .user, content: notice, createdAt: now),
            Message(id: "6", role: .assistant, content: "Ya gestionado.", createdAt: now),
            Message(id: "7", role: .user, content: "Gracias", createdAt: now),
            Message(id: "8", role: .assistant, content: "De nada.", createdAt: now),
        ]
        let shown = RoutineDelivery.present(messages, botName: "chief-of-staff")
        XCTAssertEqual(shown.map(\.id), ["1", "2", "3", "4", "7", "8"])
        let card = shown[2]
        XCTAssertEqual(card.role, .assistant)
        XCTAssertEqual(card.fromAgent, "forja")
        XCTAssertEqual(card.content, "Evaluación de nombres.\n\nRanking: 1º FlowPilot.")
    }

    func testTheAskedAgentsChatShowsNothingOfTheExchange() {
        let now = Date()
        let request = "Message from 🤖 chief-of-staff (@chief-of-staff): Evalúa estos tres nombres."
        let messages = [
            Message(id: "1", role: .user, content: "Hola Forja", createdAt: now),
            Message(id: "2", role: .assistant, content: "¡Hola!", createdAt: now),
            Message(id: "3", role: .user, content: request, createdAt: now, remoteID: "30"),
            Message(id: "4", role: .assistant, content: "Ranking: 1º FlowPilot.", createdAt: now),
            Message(id: "5", role: .user, content: "Crea un agente", createdAt: now),
            Message(id: "6", role: .assistant, content: "Vale.", createdAt: now),
        ]
        let shown = RoutineDelivery.present(messages, botName: "forja")
        XCTAssertEqual(shown.map(\.id), ["1", "2", "5", "6"])
    }

    func testAnAnswerKnownFromHermesHistoryShowsBeforeItsNoticeArrives() {
        let now = Date()
        let messages = [
            Message(id: "1", role: .user, content: "Elige un nombre", createdAt: now),
            Message(id: "2", role: .user, content: answer, createdAt: now, remoteID: "42"),
            Message(id: "3", role: .assistant, content: "Decisión: FlowPilot.", createdAt: now),
        ]
        XCTAssertEqual(
            RoutineDelivery.present(messages, botName: "chief-of-staff", agentAnswers: ["42"]).map(\.id),
            ["1", "2", "3"]
        )
    }

    func testHistoryTellsAnswersFromRequests() {
        let rows: [[String: Any]] = [
            ["role": "user", "text": "Message from 🤖 researcher (@researcher): ¿me ayudas?", "row_id": 1],
            ["role": "assistant", "text": "Claro", "row_id": 2],
            ["role": "tool", "name": "message_agent", "args": ["target": "forja"]],
            ["role": "user", "text": answer, "row_id": 3],
        ]
        XCTAssertEqual(AgentMessages.delegations(in: rows).answers, ["3"])
    }

    private func noticeCarrying(_ handle: String, _ answer: String) -> String {
        """
        [IMPORTANT: Background process proc_cc244b84e258 completed normally (exit code 0).
        Command: /x/venv/bin/python /x/tools/bot_mode_dm.py --run-delivery --author '{"id":"bot:chief-of-staff"}' query-file /tmp/dm.txt --profile-home /x/profiles/\(handle) hermes -p \(handle) chat --in '~' -c 'Bot Chat' --create-if-missing -Q
        Output:
        (anon):setopt:7: can't change option: monitor

        [ERROR]: gitstatus failed to initialize.


          Add the following parameter to ~/.zshrc for extra diagnostics on error:

            GITSTATUS_LOG_LEVEL=DEBUG

          Restart Zsh to retry gitstatus initialization:

            exec zsh
        /Users/me/.zshrc:source:118: no such file or directory: /Users/%tu_usuario%/.oh-my-zsh/oh-my-zsh.sh
          ⚠ tirith security scanner enabled but not available — command scanning will use pattern matching only
        \(answer)
        Session 20260915_181701_3b0b47 found but has no messages. Starting fresh.

        session_id: 20260915_181701_3b0b47
        ]
        """
    }

    func testAnAnswerThatCameOnlyInsideItsNoticeIsReadFromIt() {
        let answer = "**ENTREGA · clínicas**\n\n⚠️ **Resultado:** viable.\n**Siguiente paso:** 3 entrevistas."
        let text = noticeCarrying("biz-producto", answer)
        XCTAssertEqual(AgentMessages.notice(text)?.handle, "biz-producto")
        XCTAssertEqual(AgentMessages.noticeAnswer(text), answer)
        XCTAssertNil(AgentMessages.noticeAnswer(notice), "only the shell's chatter: no answer")
    }

    func testAnAnswerInsideItsNoticeGetsTheAgentsCardOnce() {
        let now = Date()
        let body = "**ENTREGA · precio**\n- **Resultado:** 49 €/mes."
        let messages = [
            Message(id: "1", role: .user, content: "Valida la idea", createdAt: now),
            Message(id: "2", role: .assistant, content: "Consultas lanzadas.", createdAt: now),
            // Forja's answer arrives on its own, then its notice repeats it.
            Message(id: "3", role: .user, content: answer, createdAt: now),
            Message(id: "4", role: .user, content: noticeCarrying("forja", "Evaluación de nombres."), createdAt: now),
            Message(id: "5", role: .assistant, content: "Recibido lo de Forja.", createdAt: now),
            // Ingresos' answer only ever comes inside its notice.
            Message(id: "6", role: .user, content: noticeCarrying("biz-ingresos", body), createdAt: now),
            Message(id: "7", role: .assistant, content: "Recomendación final.", createdAt: now),
        ]
        let shown = RoutineDelivery.present(messages, botName: "chief-of-staff")
        XCTAssertEqual(shown.map(\.id), ["1", "2", "3", "6", "7"])
        XCTAssertEqual(shown[2].fromAgent, "forja")
        XCTAssertEqual(shown[3].fromAgent, "biz-ingresos")
        XCTAssertEqual(shown[3].content, body)
    }

    func testAWaitThePersonStoppedStaysStoppedUntilTheAgentIsAskedAgain() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let stoppedAt = Date(timeIntervalSince1970: 2_000)
        let work = AgentMessages.BackgroundWork(waitingOn: [
            .init(handle: "radar-ia", sentAt: earlier),
            .init(handle: "biz-mercado", sentAt: earlier),
            .init(handle: "radar-ia", sentAt: Date(timeIntervalSince1970: 3_000)),
        ])
        let left = work.withoutStopped(["radar-ia": stoppedAt])
        XCTAssertEqual(left.waitingOn.map(\.handle), ["biz-mercado", "radar-ia"])
        XCTAssertEqual(left.waitingOn.last?.sentAt, Date(timeIntervalSince1970: 3_000))
    }

    func testACallHermesRefusesIsNeverWaitedFor() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [[String: Any]] = [
            ["role": "user", "text": "Consulta a todos", "timestamp": 9_900.0],
            ["role": "tool", "name": "message_agent", "args": ["target": "biz-mercado"]],
            ["role": "tool", "name": "message_agent", "args": ["target": "radar-ia"]],
        ]
        let open = AgentMessages.pending(in: rows, now: now) { $0 != "radar-ia" }
        XCTAssertEqual(open.map(\.handle), ["biz-mercado"])
    }

    func testADeliveryThatFailedIsSaidAndTheBotsWordOnItKept() {
        let now = Date()
        let failed = notice.replacingOccurrences(of: "completed normally (exit code 0)", with: "exited with code 1")
        let messages = [
            Message(id: "1", role: .user, content: "Pregunta a Forja", createdAt: now),
            Message(id: "2", role: .user, content: failed, createdAt: now),
            Message(id: "3", role: .assistant, content: "Forja no respondió.", createdAt: now),
        ]
        let shown = RoutineDelivery.present(messages, botName: "chief-of-staff")
        XCTAssertEqual(shown.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(shown[1].content, AgentMessages.failure(to: "forja"))
        XCTAssertNil(shown[1].fromAgent)
    }
}
