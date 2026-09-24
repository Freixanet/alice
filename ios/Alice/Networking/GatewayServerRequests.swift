import Foundation

/// Questions Hermes asks as JSON-RPC server→client requests.
///
/// Gateway contract v7 (hermes-agent #110677) replaced the `approval.request` /
/// `clarify.request` events and their `approval.respond` / `clarify.respond`
/// methods with real requests: `{"id":"srq-…","method":"approval"|"clarify",
/// "params":{"session_id":…}}`, answered by a response frame carrying the same
/// id, withdrawn with a `request.cancel {id, method, reason}` event, and replayed
/// on reconnect as `open_requests` in `session.resume`.
///
/// Older Hermes installs still speak events, so both reach the same cards: a
/// request becomes the event Alice already renders, keyed by the request's own
/// id, and the shape of that id says which way the answer goes back.
enum GatewayServerRequests {
    /// Hermes mints `srq-<hex>` for requests; ids from the event protocol never
    /// take that form.
    static func isServerRequestID(_ id: String) -> Bool { id.hasPrefix("srq-") }

    /// A request as the event the rest of Alice renders, or nil for one it cannot
    /// show — which the transport refuses so the agent does not wait on it.
    static func event(id: String, method: String, params: [String: Any]) -> HermesRPCEvent? {
        let sessionID = (params["session_id"] as? String) ?? ""
        var payload = params
        payload.removeValue(forKey: "session_id")
        switch method {
        case "approval":
            // The params' `request_id` is the approval queue's own id. The answer
            // is addressed to the request, so the request's id takes its place.
            if let queued = params["request_id"] { payload["approval_request_id"] = queued }
            payload["request_id"] = id
            return HermesRPCEvent(type: "approval.request", sessionID: sessionID, payload: payload)
        case "clarify":
            payload["request_id"] = id
            return HermesRPCEvent(type: "clarify.request", sessionID: sessionID, payload: payload)
        case "vault.save_login", "vault.code", "vault.unlock_prompt", "secret":
            // What only the person can type — a login, a code, a key — asked in a
            // secure card; the answer goes straight back to Hermes, never the chat.
            payload["request_id"] = id
            payload["kind"] = method
            return HermesRPCEvent(type: "secure.request", sessionID: sessionID, payload: payload)
        default:
            return nil
        }
    }

    /// The request a `request.cancel` event withdraws.
    static func cancelledRequestID(_ event: HermesRPCEvent) -> String? {
        guard event.type == "request.cancel",
              let id = event.payload["id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// The still-open requests a `session.resume` result replays, as events.
    /// Nil when the result has no `open_requests` at all: a Hermes from before
    /// server→client requests, which reports `pending_approval` and
    /// `pending_clarify` instead.
    static func openRequests(in resumed: JSONObject) -> [HermesRPCEvent]? {
        guard let entries = resumed["open_requests"] as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let method = entry["method"] as? String
            else { return nil }
            return event(id: id, method: method, params: (entry["params"] as? [String: Any]) ?? [:])
        }
    }
}
