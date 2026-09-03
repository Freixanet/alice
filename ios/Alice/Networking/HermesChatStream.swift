import Foundation

extension HermesClient {
    struct Turn: Sendable {
        /// What one turn carries. A plain string for the ordinary case, and
        /// the OpenAI-compatible parts array only when there is an image to
        /// send — some providers reject the array form for text-only turns.
        enum Content: Sendable {
            case text(String)
            case parts(text: String, imageURLs: [String])

            var json: Any {
                switch self {
                case let .text(value):
                    return value
                case let .parts(text, imageURLs):
                    var parts: [[String: Any]] = []
                    if !text.isEmpty {
                        parts.append(["type": "text", "text": text])
                    }
                    for url in imageURLs {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": url, "detail": "auto"],
                        ])
                    }
                    return parts
                }
            }
        }

        var role: String
        var content: Content
    }

    private enum RunStartOutcome {
        case started(id: String, status: String)
        case unsupported
        case failed(message: String, limit: ModelLimit?)
    }

    /// Streams a reply.
    ///
    /// Pantheon run transport is attempted first. It is the surface that can
    /// pause for a tool approval and then continue the same execution after the
    /// reader answers. Older Hermes builds fall back to chat completions.
    func stream(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handledByRun = try await self.streamRun(
                        messages: messages,
                        model: model,
                        provider: provider,
                        profile: profile,
                        continuation: continuation
                    )
                    if !handledByRun {
                        try await self.streamChatCompletions(
                            messages: messages,
                            model: model,
                            provider: provider,
                            profile: profile,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Runs and approvals

    /// Returns false only when this Hermes does not serve runs, which is the
    /// one case where the ordinary chat endpoint should take over.
    private func streamRun(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> Bool {
        let started = try await startRun(
            messages: messages, model: model, provider: provider, profile: profile
        )
        switch started {
        case .unsupported:
            return false
        case let .failed(message, limit):
            continuation.yield(.failure(message: message, limit: limit))
            return true
        case let .started(runID, initialStatus):
            continuation.yield(.run(id: runID, status: initialStatus, output: nil))

            await RunApprovalBroker.shared.register(runID: runID) { choice in
                try await self.respondToRunApproval(
                    runID: runID, choice: choice, profile: profile
                )
            }

            do {
                let terminal = try await consumeRunEvents(
                    runID: runID,
                    profile: profile,
                    continuation: continuation
                )
                if !terminal, !Task.isCancelled {
                    try await pollRunUntilTerminal(
                        runID: runID,
                        profile: profile,
                        continuation: continuation
                    )
                }
                await RunApprovalBroker.shared.unregister(runID: runID)
                return true
            } catch {
                await RunApprovalBroker.shared.unregister(runID: runID)
                throw error
            }
        }
    }

    private func startRun(
        messages: [Turn], model: String?, provider: String?, profile: String?
    ) async throws -> RunStartOutcome {
        guard let userIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            return .failed(message: "Empty chat.", limit: nil)
        }

        var body: [String: Any] = [
            "input": messages[userIndex].content.json,
            "conversation_history": messages[..<userIndex].map {
                ["role": $0.role, "content": $0.content.json]
            },
        ]
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }

        func post(_ payload: [String: Any]) async throws -> (Data, HTTPURLResponse) {
            var request = try self.request(
                "v1/runs", method: "POST", profile: profile,
                timeout: HermesClient.replyTimeout
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
            return (data, http)
        }

        var (data, http) = try await post(body)
        if !http.isSuccess,
           [400, 422].contains(http.statusCode),
           model != nil || provider != nil {
            body["model"] = "hermes-agent"
            body.removeValue(forKey: "provider")
            (data, http) = try await post(body)
        }

        if [404, 405, 501].contains(http.statusCode) { return .unsupported }
        guard http.isSuccess else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            return .failed(
                message: detail,
                limit: ModelLimitClassifier.classify(
                    status: http.statusCode,
                    message: detail,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.badResponse }
        let runID = Self.string(object["run_id"])
        guard !runID.isEmpty else { throw Failure.badResponse }
        let raw = Self.string(object["status"])
        let status = raw == "queued" || raw == "running" ? raw : "started"
        return .started(id: runID, status: status)
    }

    /// The live event stream normally remains open while Hermes waits for a
    /// decision. If a proxy closes it, the caller falls through to polling and
    /// keeps the run alive rather than turning the approval into "Couldn't reply".
    private func consumeRunEvents(
        runID: String,
        profile: String?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> Bool {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/events",
            profile: profile,
            timeout: 600
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
            guard http.isSuccess else { return false }

            var terminal = false
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                for event in Self.decodeRunFrame(payload, fallbackRunID: runID) {
                    continuation.yield(event)
                    if case let .run(_, status, _) = event, Self.isTerminal(status) {
                        terminal = true
                    }
                }
                if terminal { break }
            }
            return terminal
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Once a run exists, losing SSE is not losing the work. The status
            // endpoint is the recovery path and also survives long approval
            // pauses that outlive a proxy's streaming timeout.
            return false
        }
    }

    private func pollRunUntilTerminal(
        runID: String,
        profile: String?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var lastApprovalJSON: String?
        while !Task.isCancelled {
            var request = try self.request(
                "v1/runs/\(Self.pathSegment(runID))",
                profile: profile,
                timeout: HermesClient.probeTimeout
            )
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
            guard http.isSuccess else {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Failure.badResponse }

            let status = Self.string(object["status"])
            let output = Self.string(object["output"])
            if !status.isEmpty {
                continuation.yield(.run(id: runID, status: status, output: output.isEmpty ? nil : output))
            }

            if let approval = Self.approvalPayload(from: object, fallbackRunID: runID),
               let encoded = approval.payload.encoded(), encoded != lastApprovalJSON {
                lastApprovalJSON = encoded
                continuation.yield(
                    .tool(
                        id: approval.runID,
                        name: RunApprovalBroker.toolName,
                        status: .start,
                        detail: encoded
                    )
                )
            }

            if Self.isTerminal(status) {
                if status == "failed" {
                    let error = Self.string(object["error"])
                    if !error.isEmpty {
                        continuation.yield(.failure(message: error, limit: nil))
                    }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(900))
        }
        throw CancellationError()
    }

    private func respondToRunApproval(
        runID: String, choice: String, profile: String?
    ) async throws {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/approval",
            method: "POST",
            profile: profile,
            timeout: HermesClient.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["choice": choice])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
    }

    // MARK: - Chat-completions fallback

    private func streamChatCompletions(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        // Straight to the single request when streaming has already proved
        // unreliable on this connection.
        if streamingIsUnreliable {
            var body = Self.chatBody(
                messages: messages, model: model, provider: provider, stream: false
            )
            if let profile { body["profile"] = profile }
            if let text = try await completeWithoutStreaming(body, profile: profile) {
                continuation.yield(.delta(text))
            }
            return
        }

        var request = try self.request(
            "v1/chat/completions", method: "POST",
            profile: profile, timeout: HermesClient.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body = Self.chatBody(
            messages: messages, model: model, provider: provider, stream: true
        )
        if let profile { body["profile"] = profile }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            let detail = Self.detail(from: raw) ?? "Hermes returned \(http.statusCode)."
            continuation.yield(
                .failure(
                    message: detail,
                    limit: ModelLimitClassifier.classify(
                        status: http.statusCode,
                        message: detail,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    )
                )
            )
            return
        }

        var carriedSomething = false
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = Self.decodeFrame(payload) else { continue }
            carriedSomething = true
            continuation.yield(event)
            if case .failure = event { break }
        }

        if !carriedSomething, !Task.isCancelled {
            noteStreamingCameBackEmpty()
            if let text = try await completeWithoutStreaming(body, profile: profile) {
                continuation.yield(.delta(text))
            }
        }
    }

    private static func chatBody(
        messages: [Turn], model: String?, provider: String?, stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content.json] },
            "stream": stream,
        ]
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }
        return body
    }

    /// The same request, answered in one piece. Used when streamed chat
    /// completions have proved empty; run transport has its own recovery path.
    private func completeWithoutStreaming(
        _ body: [String: Any], profile: String?
    ) async throws -> String? {
        var once = body
        once["stream"] = false
        var request = try self.request(
            "v1/chat/completions", method: "POST",
            profile: profile, timeout: HermesClient.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: once)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - Event decoding

    nonisolated static func decodeFrame(_ payload: String) -> ChatEvent? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = object["error"] {
            let message = (error as? String)
                ?? ((error as? [String: Any])?["message"] as? String)
                ?? "Hermes reported an error."
            return .failure(
                message: message,
                limit: ModelLimitClassifier.classify(status: nil, message: message)
            )
        }

        if let type = object["type"] as? String {
            switch type {
            case "tool", "tool_progress":
                let name = (object["name"] as? String) ?? "tool"
                let raw = (object["status"] as? String) ?? "start"
                return .tool(
                    id: (object["callId"] as? String) ?? (object["id"] as? String) ?? name,
                    name: name,
                    status: raw == "done" ? .done : .start,
                    detail: object["detail"] as? String
                )
            case "run":
                return .run(
                    id: (object["runId"] as? String) ?? "",
                    status: (object["status"] as? String) ?? "running",
                    output: object["output"] as? String
                )
            default:
                break
            }
        }

        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let text = delta["content"] as? String, !text.isEmpty {
                return .delta(text)
            }
            if let message = first["message"] as? [String: Any],
               let text = message["content"] as? String, !text.isEmpty {
                return .delta(text)
            }
        }
        if let text = object["content"] as? String, !text.isEmpty {
            return .delta(text)
        }
        return nil
    }

    nonisolated private static func decodeRunFrame(
        _ payload: String, fallbackRunID: String
    ) -> [ChatEvent] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let event = string(object["event"] ?? object["type"])
        let runID = string(object["run_id"] ?? object["runId"])
        let id = runID.isEmpty ? fallbackRunID : runID

        switch event {
        case "run.started":
            return [.run(id: id, status: "running", output: nil)]
        case "message.delta", "assistant.delta":
            let text = string(object["delta"])
            return text.isEmpty ? [] : [.delta(text)]
        case "tool.started":
            let name = string(object["tool"] ?? object["tool_name"])
            guard !name.isEmpty else { return [] }
            return [
                .tool(
                    id: string(object["call_id"] ?? object["tool_call_id"]),
                    name: name,
                    status: .start,
                    detail: optionalString(object["preview"])
                )
            ]
        case "tool.completed", "tool.failed":
            let name = string(object["tool"] ?? object["tool_name"])
            guard !name.isEmpty else { return [] }
            let detail = optionalString(object["preview"])
                ?? (event == "tool.failed" ? "Tool failed" : nil)
            return [
                .tool(
                    id: string(object["call_id"] ?? object["tool_call_id"]),
                    name: name,
                    status: .done,
                    detail: detail
                )
            ]
        case "subagent.start", "subagent.complete":
            let detail = optionalString(object["summary"])
                ?? optionalString(object["goal"])
                ?? optionalString(object["preview"])
            return [
                .tool(
                    id: string(object["subagent_id"] ?? object["child_session_id"]),
                    name: "delegate_task",
                    status: event == "subagent.start" ? .start : .done,
                    detail: detail
                )
            ]
        case "approval.request":
            guard let approval = approvalPayload(from: object, fallbackRunID: id),
                  let encoded = approval.payload.encoded()
            else { return [.run(id: id, status: "waiting_for_approval", output: nil)] }
            return [
                .run(id: id, status: "waiting_for_approval", output: nil),
                .tool(
                    id: approval.runID,
                    name: RunApprovalBroker.toolName,
                    status: .start,
                    detail: encoded
                ),
            ]
        case "approval.responded":
            return [
                .tool(
                    id: id,
                    name: RunApprovalBroker.toolName,
                    status: .done,
                    detail: nil
                ),
                .run(id: id, status: "running", output: nil),
            ]
        case "run.steered":
            return [.run(id: id, status: "running", output: nil)]
        case "run.completed":
            return [
                .run(
                    id: id,
                    status: "completed",
                    output: optionalString(object["output"])
                )
            ]
        case "run.cancelled":
            return [.run(id: id, status: "cancelled", output: nil)]
        case "run.failed":
            let message = optionalString(object["error"]) ?? "Hermes couldn’t finish."
            return [
                .run(id: id, status: "failed", output: nil),
                .failure(message: message, limit: nil),
            ]
        default:
            return []
        }
    }

    nonisolated private static func approvalPayload(
        from object: [String: Any], fallbackRunID: String
    ) -> (runID: String, payload: RunApprovalPayload)? {
        let nested = (object["approval"] as? [String: Any])
            ?? (object["pending_approval"] as? [String: Any])
            ?? (object["approval_request"] as? [String: Any])
            ?? object
        let choices = (nested["choices"] as? [Any])?
            .compactMap { optionalString($0) }
            .filter { ["once", "session", "always", "deny"].contains($0) }
            ?? []
        let status = string(object["status"])
        let looksLikeApproval = object["event"] as? String == "approval.request"
            || object["type"] as? String == "approval.request"
            || object["approval"] != nil
            || object["pending_approval"] != nil
            || object["approval_request"] != nil
            || status == "waiting_for_approval"
        guard looksLikeApproval else { return nil }
        let runID = string(object["run_id"] ?? object["runId"])
        let title = optionalString(nested["tool"] ?? nested["title"])
            ?? "Hermes needs approval"
        return (
            runID.isEmpty ? fallbackRunID : runID,
            RunApprovalPayload(
                title: title,
                detail: optionalString(
                    nested["description"] ?? nested["preview"] ?? nested["reason"]
                ),
                command: optionalString(nested["command"]),
                choices: choices.isEmpty ? ["once", "deny"] : choices
            )
        )
    }

    nonisolated private static func isTerminal(_ status: String) -> Bool {
        ["completed", "failed", "cancelled"].contains(status)
    }

    nonisolated private static func string(_ value: Any?) -> String {
        optionalString(value) ?? ""
    }

    nonisolated private static func optionalString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}
