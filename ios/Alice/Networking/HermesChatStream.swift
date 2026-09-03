import CryptoKit
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
        case started(HermesRunProtocol.Start)
        case unsupported
        case failed(message: String, limit: ModelLimit?)
    }

    /// Streams one assistant reply.
    ///
    /// Durable runs are the preferred transport because they can pause for an
    /// explicit tool approval and then continue the same execution. The older
    /// OpenAI-compatible endpoint remains a compatibility fallback.
    func stream(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String? = nil,
        conversationID: String? = nil,
        preferRuns: Bool = true,
        runIdempotency: Bool = false
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var handledByRun = false
                    if preferRuns {
                        handledByRun = try await self.streamRun(
                            messages: messages,
                            model: model,
                            provider: provider,
                            profile: profile,
                            conversationID: conversationID,
                            idempotency: runIdempotency,
                            continuation: continuation
                        )
                    }
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

    /// Reattaches to an already-created run after an app restart or a lost SSE
    /// connection. Recovery polls snapshots instead of reopening the event
    /// stream: an event endpoint may replay old deltas, which would duplicate
    /// text already saved in the conversation, while the final snapshot is
    /// authoritative and safely replaces it.
    func resumeRun(
        runID: String,
        profile: String? = nil,
        conversationID: String? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initial = try await self.runSnapshot(
                        runID: runID,
                        profile: profile,
                        conversationID: conversationID
                    )
                    if let initial {
                        for event in HermesRunProtocol.events(from: initial) {
                            continuation.yield(event)
                        }
                        if initial.status.isTerminal {
                            continuation.finish()
                            return
                        }
                    }

                    try await self.pollRunUntilTerminal(
                        runID: runID,
                        profile: profile,
                        conversationID: conversationID,
                        previous: initial,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    let id = runID
                    Task { try? await self.stopRun(runID: id, profile: profile) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Durable runs

    /// Returns false only when this Hermes genuinely does not serve `/v1/runs`.
    private func streamRun(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String?,
        conversationID: String?,
        idempotency: Bool,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> Bool {
        let outcome = try await startRun(
            messages: messages,
            model: model,
            provider: provider,
            profile: profile,
            conversationID: conversationID,
            idempotency: idempotency
        )

        switch outcome {
        case .unsupported:
            return false

        case let .failed(message, limit):
            continuation.yield(.failure(message: message, limit: limit))
            return true

        case let .started(run):
            continuation.yield(.run(id: run.runID, status: run.status, output: nil))
            do {
                let terminal = try await consumeRunEvents(
                    runID: run.runID,
                    profile: profile,
                    conversationID: conversationID,
                    continuation: continuation
                )
                if !terminal, !Task.isCancelled {
                    try await pollRunUntilTerminal(
                        runID: run.runID,
                        profile: profile,
                        conversationID: conversationID,
                        previous: nil,
                        continuation: continuation
                    )
                }
                return true
            } catch is CancellationError {
                // A durable run survives closing its event stream. Stop it on
                // Hermes as well so the composer's Stop button means stop.
                let runID = run.runID
                Task { try? await self.stopRun(runID: runID, profile: profile) }
                throw CancellationError()
            }
        }
    }

    private func startRun(
        messages: [Turn],
        model: String?,
        provider: String?,
        profile: String?,
        conversationID: String?,
        idempotency: Bool
    ) async throws -> RunStartOutcome {
        guard let userIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            return .failed(message: "Empty chat.", limit: nil)
        }

        // The run contract accepts conversation turns, not OpenAI system
        // messages. Profile selection already travels in X-Hermes-Profile; a
        // local system directive is retained only for the chat-completions
        // compatibility path below.
        let history = messages[..<userIndex]
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { ["role": $0.role, "content": $0.content.json] }

        var body: [String: Any] = [
            "input": messages[userIndex].content.json,
            "conversation_history": history,
        ]
        if let sessionID = boundedSessionID(conversationID) { body["session_id"] = sessionID }
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }

        var payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var response = try await postRun(
            payload,
            profile: profile,
            conversationID: conversationID,
            idempotency: idempotency
        )

        if !response.http.isSuccess,
           [400, 422].contains(response.http.statusCode),
           model != nil || provider != nil {
            body["model"] = "hermes-agent"
            body.removeValue(forKey: "provider")
            payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            response = try await postRun(
                payload,
                profile: profile,
                conversationID: conversationID,
                idempotency: idempotency
            )
        }

        if [404, 405, 501].contains(response.http.statusCode) { return .unsupported }
        guard response.http.isSuccess else {
            let detail = Self.detail(from: response.data)
                ?? "Hermes returned \(response.http.statusCode)."
            return .failed(
                message: detail,
                limit: ModelLimitClassifier.classify(
                    status: response.http.statusCode,
                    message: detail,
                    retryAfter: response.http.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }

        guard let run = HermesRunProtocol.parseStart(response.data) else {
            throw Failure.badResponse
        }
        return .started(run)
    }

    private func postRun(
        _ payload: Data,
        profile: String?,
        conversationID: String?,
        idempotency: Bool
    ) async throws -> (data: Data, http: HTTPURLResponse) {
        var request = try self.request(
            "v1/runs",
            method: "POST",
            profile: profile,
            timeout: Self.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setSessionKey(conversationID, on: &request)
        if idempotency {
            request.setValue(
                idempotencyKey(payload: payload, conversationID: conversationID),
                forHTTPHeaderField: "Idempotency-Key"
            )
        }
        request.httpBody = payload
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        return (data, http)
    }

    private func consumeRunEvents(
        runID: String,
        profile: String?,
        conversationID: String?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> Bool {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/events",
            profile: profile,
            timeout: 600
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        setSessionKey(conversationID, on: &request)

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
                for event in HermesRunProtocol.events(
                    from: payload,
                    fallbackRunID: runID
                ) {
                    continuation.yield(event)
                    if case let .run(_, status, _) = event, status.isTerminal {
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
            // endpoint is the recovery path and also survives proxy timeouts.
            return false
        }
    }

    private func pollRunUntilTerminal(
        runID: String,
        profile: String?,
        conversationID: String?,
        previous: HermesRunProtocol.Snapshot?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var prior = previous
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let snapshot: HermesRunProtocol.Snapshot?
            do {
                snapshot = try await runSnapshot(
                    runID: runID,
                    profile: profile,
                    conversationID: conversationID
                )
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 { throw error }
                try await Task.sleep(for: .seconds(1))
                continue
            }

            guard let snapshot else {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 { throw Failure.badResponse }
                try await Task.sleep(for: .seconds(1))
                continue
            }
            consecutiveFailures = 0

            if snapshot != prior {
                for event in HermesRunProtocol.events(from: snapshot) {
                    continuation.yield(event)
                }
                prior = snapshot
            }
            if snapshot.status.isTerminal { return }

            // Waiting for a human choice does not need ten polls a second.
            let delay: Duration = snapshot.status == .waitingForApproval
                ? .seconds(2)
                : .milliseconds(750)
            try await Task.sleep(for: delay)
        }
        throw CancellationError()
    }

    private func runSnapshot(
        runID: String,
        profile: String?,
        conversationID: String?
    ) async throws -> HermesRunProtocol.Snapshot? {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))",
            profile: profile,
            timeout: Self.probeTimeout
        )
        setSessionKey(conversationID, on: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
        return HermesRunProtocol.parseSnapshot(data)
    }

    func respondToRunApproval(
        runID: String,
        choice: Message.ApprovalChoice,
        profile: String? = nil
    ) async throws {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/approval",
            method: "POST",
            profile: profile,
            timeout: Self.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["choice": choice.rawValue]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
    }

    func stopRun(runID: String, profile: String? = nil) async throws {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/stop",
            method: "POST",
            profile: profile,
            timeout: Self.probeTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess || [404, 409].contains(http.statusCode) else {
            let detail = Self.detail(from: data) ?? "Hermes could not stop that run."
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
                messages: messages,
                model: model,
                provider: provider,
                stream: false
            )
            if let profile { body["profile"] = profile }
            if let text = try await completeWithoutStreaming(body, profile: profile) {
                continuation.yield(.delta(text))
            }
            return
        }

        var request = try self.request(
            "v1/chat/completions",
            method: "POST",
            profile: profile,
            timeout: Self.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body = Self.chatBody(
            messages: messages,
            model: model,
            provider: provider,
            stream: true
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
        messages: [Turn],
        model: String?,
        provider: String?,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "messages": messages.map {
                ["role": $0.role, "content": $0.content.json]
            },
            "stream": stream,
        ]
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }
        return body
    }

    /// The same request, answered in one piece. Used when streamed chat
    /// completions have proved empty; run transport has its own recovery path.
    private func completeWithoutStreaming(
        _ body: [String: Any],
        profile: String?
    ) async throws -> String? {
        var once = body
        once["stream"] = false
        var request = try self.request(
            "v1/chat/completions",
            method: "POST",
            profile: profile,
            timeout: Self.replyTimeout
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

    // MARK: - Compatibility event decoding

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
                    id: (object["callId"] as? String)
                        ?? (object["id"] as? String)
                        ?? name,
                    name: name,
                    status: raw == "done" ? .done : .start,
                    detail: object["detail"] as? String
                )
            case "run":
                let raw = (object["status"] as? String) ?? Message.RunStatus.running.rawValue
                return .run(
                    id: (object["runId"] as? String) ?? "",
                    status: Message.RunStatus(rawValue: raw) ?? .running,
                    output: object["output"] as? String
                )
            default:
                break
            }
        }

        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let text = delta["content"] as? String,
               !text.isEmpty {
                return .delta(text)
            }
            if let message = first["message"] as? [String: Any],
               let text = message["content"] as? String,
               !text.isEmpty {
                return .delta(text)
            }
        }
        if let text = object["content"] as? String, !text.isEmpty {
            return .delta(text)
        }
        return nil
    }

    // MARK: - Run helpers

    private func setSessionKey(_ conversationID: String?, on request: inout URLRequest) {
        if let sessionID = boundedSessionID(conversationID) {
            request.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Key")
        }
    }

    private func boundedSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(128))
    }

    private func idempotencyKey(payload: Data, conversationID: String?) -> String {
        var input = Data((boundedSessionID(conversationID) ?? "").utf8)
        input.append(0)
        input.append(payload)
        let digest = SHA256.hash(data: input)
        return "alice-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}
