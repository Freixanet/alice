import Foundation

/// The small bridge between a live Hermes run and the approval card in chat.
///
/// Approval requests arrive on the run's event stream. The stream owns the
/// authenticated Hermes client, while the button lives much higher in SwiftUI;
/// keeping only a short-lived handler here lets the UI answer that exact run
/// without exposing the Hermes key or connection details to the view layer.
actor RunApprovalBroker {
    static let shared = RunApprovalBroker()
    static let toolName = "__alice_run_approval__"

    typealias Handler = @Sendable (String) async throws -> Void

    enum BrokerError: Error, LocalizedError {
        case runEnded

        var errorDescription: String? {
            "That approval is no longer waiting. Ask Hermes to try the action again."
        }
    }

    private var handlers: [String: Handler] = [:]

    func register(runID: String, handler: @escaping Handler) {
        handlers[runID] = handler
    }

    func unregister(runID: String) {
        handlers.removeValue(forKey: runID)
    }

    func respond(runID: String, choice: String) async throws {
        guard let handler = handlers[runID] else { throw BrokerError.runEnded }
        try await handler(choice)
    }
}

/// Everything the approval card needs, encoded into the existing tool-event
/// detail field so old persisted conversations and the rest of the chat model
/// do not need a second parallel event system.
struct RunApprovalPayload: Codable, Hashable, Sendable {
    var title: String
    var detail: String?
    var command: String?
    var choices: [String]

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ value: String?) -> RunApprovalPayload? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
