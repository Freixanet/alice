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

            /// `/v1/runs` overloads a top-level array as a list of messages.
            /// A raw multimodal parts array is therefore misread as messages
            /// and Hermes cannot find the user turn. Wrap multimodal content
            /// in one explicit user message while keeping ordinary text as the
            /// compact string form the endpoint accepts.
            var runJSON: Any {
                switch self {
                case let .text(value):
                    return value
                case .parts:
                    return [["role": "user", "content": json]]
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
                    // Self-update is maintenance, not an agent tool call. If
                    // Hermes restarts the process that owns the tool call, the
                    // native chat can otherwise wait forever for that same
                    // process to report completion. The management endpoint
                    // launches the updater independently and returns first.
                    if let reply = try await self.selfUpdateReplyIfRequested(messages: messages) {
                        continuation.yield(.delta(reply))
                        continuation.finish()
                        return
                    }

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
                    // The command being approved may itself restart the
                    // gateway (notably `hermes update`). A failed first probe
                    // is therefore a recoverable state, not a terminal error.
                    let initial = try? await self.runSnapshot(
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
        // messages, so a system turn cannot be sent as one. Dropping it
        // outright was worse: profile selection travels in X-Hermes-Profile,
        // but this gateway answers every run as the default profile anyway,
        // and the system turn is the only thing that makes a bot a bot. Sent
        // as a run, a bot answered in the assistant's voice — its name, its
        // endearments — because the instruction not to had been discarded on
        // the way out.
        //
        // So it rides on the turn it governs, ahead of what was typed.
        let directives = messages[..<userIndex]
            .filter { $0.role == "system" }
            .compactMap { turn -> String? in
                if case let .text(value) = turn.content, !value.isEmpty {
                    return value
                }
                return nil
            }

        let history = messages[..<userIndex]
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { ["role": $0.role, "content": $0.content.json] }

        var body: [String: Any] = [
            "input": Self.runInput(
                messages[userIndex].content, prefacedBy: directives
            ),
            "conversation_history": history,
        ]
        if let sessionID = boundedSessionID(conversationID) { body["session_id"] = sessionID }
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }

        var payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // One attempt id for this send, shared by the fallback repost below
        // so a retry is still a retry rather than a second run.
        let attempt = UUID().uuidString
        var response = try await postRun(
            payload,
            profile: profile,
            conversationID: conversationID,
            idempotency: idempotency,
            attempt: attempt
        )

        // Match the web transport: retry only when the fallback changes the
        // request. Reposting an identical `hermes-agent` body is both wasteful
        // and unsafe on a server that does not advertise idempotency.
        if !response.http.isSuccess,
           [400, 422].contains(response.http.statusCode),
           model != "hermes-agent" || provider != nil {
            body["model"] = "hermes-agent"
            body.removeValue(forKey: "provider")
            payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            response = try await postRun(
                payload,
                profile: profile,
                conversationID: conversationID,
                idempotency: idempotency,
                attempt: attempt
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
        idempotency: Bool,
        attempt: String
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
                idempotencyKey(
                    payload: payload,
                    conversationID: conversationID,
                    attempt: attempt
                ),
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
        var lastError: Error?
        // Keep the same recovery budget as the web client. A Hermes update can
        // intentionally restart the gateway, so five failed one-second probes
        // would turn a successful update into a false client-side failure.
        let deadline = Date().addingTimeInterval(180)

        while !Task.isCancelled, Date() < deadline {
            do {
                guard let snapshot = try await runSnapshot(
                    runID: runID,
                    profile: profile,
                    conversationID: conversationID
                ) else {
                    lastError = Failure.badResponse
                    try await Task.sleep(for: .milliseconds(750))
                    continue
                }
                lastError = nil

                if snapshot != prior {
                    for event in HermesRunProtocol.events(from: snapshot) {
                        continuation.yield(event)
                    }
                    prior = snapshot
                }
                if snapshot.status.isTerminal { return }

                // Waiting for a human choice does not need frequent polling.
                let delay: Duration = snapshot.status == .waitingForApproval
                    ? .seconds(2)
                    : .milliseconds(750)
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(750))
            }
        }

        if Task.isCancelled { throw CancellationError() }
        if let lastError { throw lastError }
        throw Failure.timedOut
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

    /// Whether a run is still waiting on an approval, by Hermes' account now.
    ///
    /// `false` when Hermes has moved the run past waiting, or no longer knows it
    /// at all (`404 run_not_found`: finished and forgotten). Throws when Hermes
    /// could not be asked, which says nothing either way.
    func runIsWaitingForApproval(runID: String, profile: String?) async throws -> Bool {
        do {
            guard let snapshot = try await runSnapshot(
                runID: runID, profile: profile, conversationID: nil
            ) else { throw Failure.badResponse }
            return snapshot.status == .waitingForApproval
        } catch let failure as Failure {
            if case let .http(status, _, _) = failure, status == 404 { return false }
            throw failure
        }
    }

    /// Resolve the exact approval Hermes exposed for a durable run.
    ///
    /// A room-scoped run *requires* `request_id`; ordinary runs accept it and
    /// use it to avoid resolving a sibling request. A 2xx is still not enough
    /// evidence: the response must say that at least one approval resolved.
    @discardableResult
    func respondToRunApproval(
        runID: String,
        requestID: String? = nil,
        choice: Message.ApprovalChoice,
        profile: String? = nil
    ) async throws -> Int {
        var request = try self.request(
            "v1/runs/\(Self.pathSegment(runID))/approval",
            method: "POST",
            profile: profile,
            timeout: Self.replyTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["choice": choice.rawValue]
        if let requestID, !requestID.isEmpty { body["request_id"] = requestID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.isSuccess else {
            let detail = Self.detail(from: data) ?? "Hermes returned \(http.statusCode)."
            throw Failure.http(status: http.statusCode, detail: detail, limit: nil)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resolved = (object["resolved"] as? Int)
                ?? (object["resolved"] as? NSNumber)?.intValue,
              resolved > 0
        else { throw Failure.badResponse }
        return resolved
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

        // Streaming is the fast path when it works — four and a half seconds
        // against twenty for the same question asked in one piece — but this
        // gateway intermittently runs for fifteen seconds and then ends having
        // said nothing. Finding that out and only then asking again cost
        // thirty-five seconds for a four-second answer.
        //
        // Remembering the failure and giving up on streaming caps the worst
        // case but surrenders the best one: every later reply pays twenty
        // seconds whether or not streaming has recovered. So both run. The
        // stream gets three seconds; if it has produced nothing by then the
        // single request goes out alongside it, and whichever speaks first
        // wins while the other is cancelled.
        var carriedSomething = false
        let hedge = Task { [body] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !carriedSomething else { return }
            if let text = try? await self.completeWithoutStreaming(body, profile: profile),
               !carriedSomething {
                carriedSomething = true
                continuation.yield(.delta(text))
            }
        }
        defer { hedge.cancel() }

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = Self.decodeFrame(payload) else { continue }
            if carriedSomething { break }   // the hedge got there first
            carriedSomething = true
            hedge.cancel()
            continuation.yield(event)
            if case .failure = event { break }
        }

        if !carriedSomething, !Task.isCancelled {
            // The hedge may still be in flight; wait on the same answer
            // rather than opening a third request.
            if let text = try await completeWithoutStreaming(body, profile: profile) {
                continuation.yield(.delta(text))
            }
        }
    }

    /// The run's input, with any system directives ahead of it.
    ///
    /// Plain text keeps its shape and gains a preamble. A multimodal turn is
    /// already a list of messages, so the directives go in front as their own
    /// user turn rather than being spliced into the parts of the real one.
    private static func runInput(
        _ content: Turn.Content, prefacedBy directives: [String]
    ) -> Any {
        guard !directives.isEmpty else { return content.runJSON }
        let preamble = directives.joined(separator: "\n\n")
        switch content {
        case let .text(value):
            return "\(preamble)\n\n\(value)"
        case .parts:
            var turns: [[String: Any]] = [["role": "user", "content": preamble]]
            if let own = content.runJSON as? [[String: Any]] {
                turns.append(contentsOf: own)
            }
            return turns
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

    /// A key for *this send*, not for its contents.
    ///
    /// Hashing the conversation and the payload alone made the key a function
    /// of what was typed, so asking the same thing twice in the same chat
    /// asked for the same run — and a server honouring the header answered by
    /// replaying the first one. A run that had failed therefore kept failing
    /// with its original error however long ago it happened and whatever had
    /// been fixed since: an authentication error from before a login went on
    /// being served after it, because nothing was being run at all.
    ///
    /// The attempt is what makes two identical questions two different runs.
    /// Retries within one send share it, which is what the header is for.
    private func idempotencyKey(
        payload: Data, conversationID: String?, attempt: String
    ) -> String {
        var input = Data((boundedSessionID(conversationID) ?? "").utf8)
        input.append(0)
        input.append(Data(attempt.utf8))
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
