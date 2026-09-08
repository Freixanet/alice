import Foundation

/// One JSON-RPC exchange with the agent, and the events it pushes back.
///
/// A protocol so the bot-chat source can be tested without a socket: the
/// interesting behaviour is which methods are called with which parameters,
/// and that is exactly what a fake can record.
protocol HermesRPCTransport: Sendable {
    /// Calls a method and returns its `result` object.
    func call(_ method: String, _ params: JSONObject) async throws -> JSONObject

    /// Every `event` frame the agent pushes, for as long as the caller listens.
    func events() -> AsyncStream<HermesRPCEvent>
}

/// A JSON object crossing an isolation boundary.
///
/// `[String: Any]` is not `Sendable`, but what `JSONSerialization` produces is:
/// value types throughout, made per message and handed on without being kept.
struct JSONObject: @unchecked Sendable {
    let fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }

    subscript(key: String) -> Any? { fields[key] }
    var rows: [[String: Any]] { (fields["messages"] as? [[String: Any]]) ?? [] }
}

/// A pushed frame: `{"method":"event","params":{"type":…,"session_id":…,"payload":…}}`
struct HermesRPCEvent: @unchecked Sendable {
    let type: String
    let sessionID: String
    let payload: [String: Any]
}

private final class HermesWebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var early: [Int: Result<Void, Error>] = [:]
    private var opened: Set<Int> = []

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    func waitForOpen(_ task: URLSessionWebSocketTask) async throws {
        let id = task.taskIdentifier
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Void, Error>? = lock.withLock {
                if let result = early.removeValue(forKey: id) { return result }
                waiters[id] = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: Int) {
        let continuation = lock.withLock { waiters.removeValue(forKey: id) }
        continuation?.resume(throwing: Failure(reason: "The Hermes WebSocket handshake timed out."))
    }

    private func settle(_ id: Int, _ result: Result<Void, Error>, remember: Bool) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            if case .success = result { opened.insert(id) }
            if let continuation = waiters.removeValue(forKey: id) { return continuation }
            if remember { early[id] = result }
            return nil
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        settle(webSocketTask.taskIdentifier, .success(()), remember: true)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let id = webSocketTask.taskIdentifier
        let wasOpen = lock.withLock { opened.remove(id) != nil }
        guard !wasOpen else { return }
        settle(
            id,
            .failure(Failure(reason: "Hermes closed the WebSocket during its handshake (code \(closeCode.rawValue)).")),
            remember: true
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        let wasOpen = lock.withLock { opened.contains(id) }
        guard !wasOpen else { return }
        settle(id, .failure(error), remember: true)
    }
}

/// The dashboard's JSON-RPC WebSocket.
///
/// Authentication reuses the dashboard login Alice already has. A browser
/// cannot set `Authorization` on an upgrade, so the agent mints a single-use
/// 30-second ticket for an authenticated session and the socket carries it in
/// the query — the same path the agent's own SPA and native clients use. The
/// ticket is short-lived and single-use by design, so every connect asks for a
/// fresh one and a reconnect is simply another connect.
actor HermesRPCClient: HermesRPCTransport {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Mints one ticket. Held as a closure so this actor never sees the
    /// password: `DashboardClient` owns the credential and the session cookie,
    /// and hands over only a value that expires in thirty seconds.
    private let ticket: @Sendable () async throws -> String
    private let endpoint: URL
    private let openDelegate: HermesWebSocketOpenDelegate
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    private var listeners: [UUID: AsyncStream<HermesRPCEvent>.Continuation] = [:]
    private var nextID = 1
    private var pump: Task<Void, Never>?
    // `actor` methods are re-entrant across `await`: two first calls can both
    // enter connectIfNeeded while the ticket request is suspended. Serialize
    // that first connection so they share one ticket/socket instead of one
    // replacing the other and stranding a pending RPC.
    private var connecting = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []

    init(
        endpoint: URL,
        ticket: @escaping @Sendable () async throws -> String
    ) {
        self.endpoint = endpoint
        self.ticket = ticket
        let delegate = HermesWebSocketOpenDelegate()
        self.openDelegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil
        )
    }

    /// The socket URL for one connection attempt.
    static func socketURL(dashboard: URL, ticket: String) -> URL? {
        guard var parts = URLComponents(url: dashboard, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = (parts.path.hasSuffix("/") ? parts.path : parts.path + "/") + "api/ws"
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url
    }

    func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
        #if DEBUG
        print("ALICE_E2E_RPC call", method)
        #endif
        try await connectIfNeeded()
        #if DEBUG
        print("ALICE_E2E_RPC connected", method)
        #endif
        let id = nextID
        nextID += 1
        let message = try Self.requestMessage(id: id, method: method, params: params)
        guard let socket else { throw Failure(reason: "Not connected to Hermes.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            #if DEBUG
            print("ALICE_E2E_RPC sending", method, id)
            #endif
            Task { [weak self] in
                do {
                    try await socket.send(message)
                } catch {
                    await self?.settle(id, with: .failure(error))
                }
            }
        }
    }

    /// Hermes' `/api/ws` transport reads text frames (`receive_text`).
    /// Keep the framing decision in one testable place: sending the same JSON
    /// as a binary frame leaves the server waiting without dispatching it.
    static func requestMessage(
        id: Int, method: String, params: JSONObject
    ) throws -> URLSessionWebSocketTask.Message {
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params.fields,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        return .string(String(decoding: data, as: UTF8.self))
    }

    nonisolated func events() -> AsyncStream<HermesRPCEvent> {
        AsyncStream { continuation in
            let key = UUID()
            Task { await self.addListener(key, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeListener(key) }
            }
        }
    }

    /// Drops the socket so the next call reconnects with a fresh ticket.
    /// Pending calls fail rather than hang; the caller keeps its cache.
    func disconnect(_ reason: Error? = nil) {
        #if DEBUG
        if let reason { print("ALICE_E2E_RPC disconnect", reason.localizedDescription) }
        else { print("ALICE_E2E_RPC disconnect requested") }
        #endif
        pump?.cancel()
        pump = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let failures = pending
        pending.removeAll()
        for (_, continuation) in failures {
            continuation.resume(throwing: reason ?? Failure(reason: "Hermes disconnected."))
        }
    }

    // MARK: - Internals

    private func addListener(
        _ key: UUID, _ continuation: AsyncStream<HermesRPCEvent>.Continuation
    ) {
        listeners[key] = continuation
    }

    private func removeListener(_ key: UUID) { listeners[key] = nil }

    private func settle(_ id: Int, with result: Result<JSONObject, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func connectIfNeeded() async throws {
        if socket != nil { return }

        if connecting {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiters.append(continuation)
            }
            return
        }

        connecting = true
        do {
            let value = try await ticket()
            guard let url = Self.socketURL(dashboard: endpoint, ticket: value) else {
                throw Failure(reason: "The dashboard address is not usable for a socket.")
            }
            let task = session.webSocketTask(with: url)
            task.resume()

            // `resume()` only starts the WebSocket handshake. Publishing the
            // task before Foundation reports `didOpen` races both send/receive;
            // probing it with `sendPing` is not a handshake either and can wait
            // forever on a physical device. The URLSession delegate is the
            // authority for when this task is actually open.
            try await openDelegate.waitForOpen(task)
            socket = task
            pump = Task { [weak self] in await self?.receive(on: task) }
            finishConnection(with: .success(()))
        } catch {
            finishConnection(with: .failure(error))
            throw error
        }
    }

    private func finishConnection(with result: Result<Void, Error>) {
        connecting = false
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for continuation in waiters { continuation.resume(with: result) }
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data?
                switch message {
                case let .data(payload): data = payload
                case let .string(text): data = text.data(using: .utf8)
                @unknown default: data = nil
                }
                guard let data,
                      let frame = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                else { continue }
                deliver(frame)
            } catch {
                // The socket is gone. Everything waiting is told so, and the
                // next call reconnects — the ticket it used is spent anyway.
                disconnect(error)
                return
            }
        }
    }

    private func deliver(_ frame: [String: Any]) {
        if let id = frame["id"] as? Int {
            #if DEBUG
            print("ALICE_E2E_RPC reply", id, frame["error"] == nil ? "result" : "error")
            #endif
            if let error = frame["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Hermes refused that."
                settle(id, with: .failure(Failure(reason: message)))
            } else {
                settle(id, with: .success(JSONObject((frame["result"] as? [String: Any]) ?? [:])))
            }
            return
        }
        guard frame["method"] as? String == "event",
              let params = frame["params"] as? [String: Any],
              let type = params["type"] as? String
        else { return }
        let event = HermesRPCEvent(
            type: type,
            sessionID: (params["session_id"] as? String) ?? "",
            payload: (params["payload"] as? [String: Any]) ?? [:]
        )
        for (_, continuation) in listeners { continuation.yield(event) }
    }
}
