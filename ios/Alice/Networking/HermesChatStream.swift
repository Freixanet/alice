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

    /// Streams a reply.
    ///
    /// Hermes speaks Server-Sent Events on the chat endpoint. Each frame is
    /// decoded as it arrives so the reply appears a token at a time rather than
    /// in one jump at the end.
    func stream(
        messages: [Turn],
        model: String?,
        provider: String?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.request("v1/chat/completions", method: "POST")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var body: [String: Any] = [
                        "messages": messages.map { ["role": $0.role, "content": $0.content.json] },
                        "stream": true,
                    ]
                    if let model { body["model"] = model }
                    if let provider { body["provider"] = provider }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw Failure.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain the body so the reason survives: without this the
                        // user gets "couldn't reply" for a spent quota.
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        let detail = HermesClient.detail(from: raw)
                            ?? "Hermes returned \(http.statusCode)."
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
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let event = HermesClient.decodeFrame(payload) else { continue }
                        continuation.yield(event)
                        if case .failure = event { break }
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

    /// Decodes one SSE frame. Unknown shapes are skipped rather than failing the
    /// stream, so a build that adds a field does not break the conversation.
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

        // OpenAI-shaped streaming chunk, which is what the chat endpoint emits.
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
}
