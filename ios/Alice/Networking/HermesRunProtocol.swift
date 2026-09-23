import Foundation

/// Pure parsing for Hermes' durable-run protocol.
///
/// Keeping wire-format knowledge out of the transport makes the networking
/// code small and lets the protocol be exercised without a live agent.
enum HermesRunProtocol {
    struct Start: Equatable, Sendable {
        var runID: String
        var status: Message.RunStatus
    }

    struct Snapshot: Equatable, Sendable {
        var runID: String
        var status: Message.RunStatus
        var output: String?
        var error: String?
        var approval: Message.Approval?
    }

    static func parseStart(_ data: Data) -> Start? {
        guard let object = object(from: data),
              let runID = bounded(object["run_id"], max: 160)
        else { return nil }
        let status = runStatus(object["status"]) ?? .started
        return Start(runID: runID, status: status)
    }

    static func parseSnapshot(_ data: Data) -> Snapshot? {
        guard let object = object(from: data),
              let runID = bounded(object["run_id"], max: 160),
              let status = runStatus(object["status"])
        else { return nil }
        return Snapshot(
            runID: runID,
            status: status,
            output: limitedText(object["output"], max: 1_000_000),
            error: bounded(object["error"], max: 8_000),
            approval: approval(from: object, fallbackRunID: runID)
        )
    }

    static func events(from chunk: String, fallbackRunID: String) -> [ChatEvent] {
        guard let data = chunk.data(using: .utf8), let object = object(from: data) else {
            return []
        }
        return events(from: object, fallbackRunID: fallbackRunID)
    }

    static func events(from snapshot: Snapshot) -> [ChatEvent] {
        var events: [ChatEvent] = [
            .run(id: snapshot.runID, status: snapshot.status, output: snapshot.output)
        ]
        if let approval = snapshot.approval, snapshot.status == .waitingForApproval {
            events.append(.approval(approval))
        }
        if snapshot.status == .failed || snapshot.status == .interrupted {
            events.append(
                .failure(
                    message: snapshot.error
                        ?? (snapshot.status == .interrupted
                            ? "Hermes restarted before this run could report a final result."
                            : "Hermes couldn’t finish."),
                    limit: nil
                )
            )
        }
        return events
    }

    private static func events(
        from object: [String: Any], fallbackRunID: String
    ) -> [ChatEvent] {
        guard let event = bounded(object["event"] ?? object["type"], max: 96) else {
            return []
        }
        let runID = bounded(object["run_id"] ?? object["runId"], max: 160)
            ?? fallbackRunID

        switch event {
        case "run.started":
            return [.run(id: runID, status: .running, output: nil)]

        case "message.delta", "assistant.delta":
            guard let text = limitedText(object["delta"], max: 1_000_000) else { return [] }
            return [.delta(text)]

        case "tool.started":
            guard let name = bounded(object["tool"] ?? object["tool_name"], max: 256)
            else { return [] }
            let callID = bounded(object["call_id"] ?? object["tool_call_id"], max: 160)
                ?? "\(runID):\(name)"
            let started = ChatEvent.tool(
                id: callID,
                name: name,
                status: .start,
                detail: bounded(object["preview"], max: 8_000)
            )
            // A run carries the plan only as the `todo` call's arguments.
            if TaskPlan.isTodoTool(name), let change = TaskPlan.call(object["args"]) {
                return [started, .plan(change)]
            }
            return [started]

        case "tool.completed", "tool.failed":
            guard let name = bounded(object["tool"] ?? object["tool_name"], max: 256)
            else { return [] }
            let callID = bounded(object["call_id"] ?? object["tool_call_id"], max: 160)
                ?? "\(runID):\(name)"
            let detail = bounded(object["preview"], max: 8_000)
                ?? (event == "tool.failed" || object["error"] as? Bool == true
                    ? "Tool failed" : nil)
            return [.tool(id: callID, name: name, status: .done, detail: detail)]

        case "subagent.start", "subagent.complete":
            let detail = bounded(object["summary"], max: 8_000)
                ?? bounded(object["goal"], max: 8_000)
                ?? bounded(object["preview"], max: 8_000)
            let callID = bounded(
                object["subagent_id"] ?? object["child_session_id"], max: 160
            ) ?? "\(runID):delegate_task"
            return [
                .tool(
                    id: callID,
                    name: "delegate_task",
                    status: event == "subagent.start" ? .start : .done,
                    detail: detail
                )
            ]

        case "approval.request":
            var output: [ChatEvent] = [
                .run(id: runID, status: .waitingForApproval, output: nil)
            ]
            if let approval = approval(from: object, fallbackRunID: runID) {
                output.append(.approval(approval))
            }
            return output

        case "approval.responded", "run.steered":
            return [.run(id: runID, status: .running, output: nil)]

        case "run.completed":
            return [
                .run(
                    id: runID,
                    status: .completed,
                    output: limitedText(object["output"], max: 1_000_000)
                )
            ]

        case "run.cancelled":
            return [.run(id: runID, status: .cancelled, output: nil)]

        case "run.failed":
            let message = bounded(object["error"], max: 8_000) ?? "Hermes couldn’t finish."
            return [
                .run(id: runID, status: .failed, output: nil),
                .failure(message: message, limit: nil),
            ]

        case "run.interrupted":
            let message = bounded(object["error"], max: 8_000)
                ?? "Hermes restarted before this run could report a final result."
            return [
                .run(id: runID, status: .interrupted, output: nil),
                .failure(message: message, limit: nil),
            ]

        default:
            // Kept on record, not acted on: a kind Alice has not learnt is
            // news about Hermes, never a reason to misread the run.
            HermesUnknownEvents.shared.record(event, transport: .runStream, payload: object)
            return []
        }
    }

    private static func approval(
        from object: [String: Any], fallbackRunID: String
    ) -> Message.Approval? {
        let nested = (object["approval"] as? [String: Any])
            ?? (object["pending_approval"] as? [String: Any])
            ?? (object["approval_request"] as? [String: Any])
            ?? object
        let status = runStatus(object["status"])
        let event = bounded(object["event"] ?? object["type"], max: 96)
        let looksLikeApproval = event == "approval.request"
            || object["approval"] != nil
            || object["pending_approval"] != nil
            || object["approval_request"] != nil
            || status == .waitingForApproval
        guard looksLikeApproval else { return nil }

        let runID = bounded(object["run_id"] ?? object["runId"], max: 160)
            ?? fallbackRunID
        guard !runID.isEmpty else { return nil }

        let rawChoices = nested["choices"] as? [Any] ?? []
        let choices = rawChoices.compactMap { raw -> Message.ApprovalChoice? in
            guard let value = bounded(raw, max: 16) else { return nil }
            return Message.ApprovalChoice(rawValue: value)
        }

        return Message.Approval(
            runID: runID,
            requestID: bounded(
                nested["request_id"] ?? nested["requestId"]
                    ?? object["request_id"] ?? object["requestId"],
                max: 256
            ),
            title: bounded(nested["tool"] ?? nested["title"], max: 256)
                ?? "Hermes needs approval",
            detail: bounded(
                nested["description"] ?? nested["preview"] ?? nested["reason"],
                max: 8_000
            ),
            command: bounded(nested["command"], max: 8_000),
            choices: choices.isEmpty ? [.once, .deny] : choices,
            resolving: nil,
            error: nil,
            smartDenied: (nested["smart_denied"] as? Bool) == true ? true : nil
        )
    }

    private static func runStatus(_ value: Any?) -> Message.RunStatus? {
        guard let raw = bounded(value, max: 32) else { return nil }
        return Message.RunStatus(rawValue: raw)
    }

    private static func bounded(_ value: Any?, max: Int) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max))
    }

    private static func limitedText(_ value: Any?, max: Int) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return String(value.prefix(max))
    }

    private static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
