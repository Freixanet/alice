import Foundation

/// A reply's events without holes, across a dropped socket.
///
/// Hermes numbers each session's events and keeps its last 512 (`tui_gateway/event_replay.py`).
/// Events emitted while this phone's socket was down are never pushed again, so a reply used to
/// jump: the words and steps written meanwhile were lost, and the answer only appeared whole
/// from the transcript once the turn ended. This sits between the socket and the watch:
///
/// - an event already applied (same or lower number) is dropped;
/// - a jump in the numbers is filled first with `session.events.since`, in order;
/// - `catchUp` asks for anything newer, for the moment a reconnected watch hears nothing yet
///   (the turn may have ended while the socket was down).
///
/// When Hermes cannot give the stretch back — evicted from its ring (`truncated`), or its
/// numbering restarted with the process (`epoch`) — nothing is invented: the numbering moves
/// on, and the watch settles the reply from the transcript as it always has.
///
/// Only sessions being followed are filled; everything else passes through untouched.
actor EventResume {
    private let rpc: HermesRPCTransport
    private var continuation: AsyncStream<HermesRPCEvent>.Continuation?
    private var last: [String: Int] = [:]
    private var followed: Set<String> = []
    private var epoch: String?

    init(rpc: HermesRPCTransport) {
        self.rpc = rpc
    }

    /// `frames` in order, with duplicates removed and gaps filled for followed sessions.
    nonisolated func stream(_ frames: AsyncStream<HermesRPCEvent>) -> AsyncStream<HermesRPCEvent> {
        AsyncStream { continuation in
            let pumping = Task {
                await self.attach(continuation)
                for await frame in frames {
                    await self.accept(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pumping.cancel() }
        }
    }

    func follow(_ sessionID: String) {
        guard !sessionID.isEmpty else { return }
        followed.insert(sessionID)
    }

    private func attach(_ continuation: AsyncStream<HermesRPCEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Asks Hermes for anything after the last event applied for `sessionID`; returns how many
    /// were delivered. Zero when there is nothing, or nothing trustworthy, to add.
    @discardableResult
    func catchUp(_ sessionID: String) async -> Int {
        guard followed.contains(sessionID), let seen = last[sessionID] else { return 0 }
        return await fill(sessionID, after: seen, before: nil)
    }

    private func accept(_ event: HermesRPCEvent) async {
        if event.type == "gateway.ready" {
            noteEpoch(event.payload["replay_epoch"] as? String)
        }
        guard let seq = event.seq, !event.sessionID.isEmpty else {
            continuation?.yield(event)
            return
        }
        let sid = event.sessionID
        // A restarted Hermes numbers from 1 again, but it says so first (`gateway.ready`'s
        // epoch, on every connection) and its runtimes have new ids: an old number is a duplicate.
        if let seen = last[sid] {
            if seq <= seen {
                return
            } else if seq > seen + 1, followed.contains(sid) {
                DiagnosticsLog.write("resume.gap session=\(sid) after=\(seen) at=\(seq)")
                await fill(sid, after: seen, before: seq)
            }
        }
        deliver(event, seq: seq)
    }

    /// Delivers what Hermes still has after `seen` (and before `before`, when a live event is
    /// waiting to follow). Each event goes out only if it is newer than the last delivered, so
    /// a catch-up and a live gap filling at once never deliver anything twice.
    @discardableResult
    private func fill(_ sid: String, after seen: Int, before: Int?) async -> Int {
        let reply: JSONObject
        do {
            reply = try await rpc.call(
                "session.events.since",
                JSONObject(["session_id": sid, "last_seen": seen]),
                within: .seconds(10)
            )
        } catch {
            DiagnosticsLog.write("resume.failed session=\(sid) error=\(error.localizedDescription)")
            return 0
        }
        let replyEpoch = reply["epoch"] as? String
        if let replyEpoch, let epoch, replyEpoch != epoch {
            DiagnosticsLog.write("resume.epoch session=\(sid) changed")
            noteEpoch(replyEpoch)
            return 0
        }
        if epoch == nil { epoch = replyEpoch }
        if (reply["truncated"] as? Bool) == true {
            // Part of the stretch is gone: replaying the rest would stitch a reply with a hole
            // in it. The watch reads the transcript instead.
            DiagnosticsLog.write("resume.truncated session=\(sid) after=\(seen)")
            return 0
        }
        let events = ((reply["events"] as? [[String: Any]]) ?? [])
            .compactMap(HermesRPCEvent.parse)
            .filter { $0.sessionID.isEmpty || $0.sessionID == sid }
            .compactMap { event -> (HermesRPCEvent, Int)? in
                guard let seq = event.seq, before.map({ seq < $0 }) ?? true else { return nil }
                return (event, seq)
            }
            .sorted { $0.1 < $1.1 }
        var delivered = 0
        for (event, seq) in events where seq > (last[sid] ?? 0) {
            deliver(HermesRPCEvent(type: event.type, sessionID: sid, payload: event.payload, seq: seq), seq: seq)
            delivered += 1
        }
        if delivered > 0 {
            DiagnosticsLog.write("resume.replayed session=\(sid) events=\(delivered)")
        }
        return delivered
    }

    private func deliver(_ event: HermesRPCEvent, seq: Int) {
        last[event.sessionID] = max(last[event.sessionID] ?? 0, seq)
        continuation?.yield(event)
    }

    /// A different epoch is a different Hermes process: every number known so far is void.
    private func noteEpoch(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        if let epoch, epoch != value {
            DiagnosticsLog.write("resume.epoch reset sessions=\(last.count)")
            last.removeAll()
        }
        epoch = value
    }
}
