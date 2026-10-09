import Foundation

struct ReviewTask: Decodable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable {
        case backlog, inProgress = "in_progress", needsReview = "needs_review", blocked, done, failed
        var label: String {
            switch self {
            case .backlog: String(localized: "Backlog")
            case .inProgress: String(localized: "In progress")
            case .needsReview: String(localized: "Needs review")
            case .blocked: String(localized: "Waiting for you")
            case .done: String(localized: "Done")
            case .failed: String(localized: "Couldn’t finish")
            }
        }
    }
    struct Proposal: Decodable, Sendable {
        let tool: String
        let description: String
        let args: TaskJSON
        // Arguments remain host-owned; the app can inspect but never edit them.
    }
    struct Block: Decodable, Identifiable, Sendable {
        struct Item: Decodable, Sendable { let text: String; let done: Bool }
        let type: String
        let text: String?
        let title: String?
        let columns: [String]?
        let rows: [[String]]?
        let items: [Item]?
        let channel: String?
        let to: [String]?
        let subject: String?
        let body: String?
        let startIso: String?
        let location: String?
        let url: String?
        // Stable per render, without trusting an action ID from source content.
        var id: String { type + (title ?? text ?? subject ?? body ?? "") }
    }
    let id: String
    let title: String
    let request: String
    let profile: String
    let session_id: String
    let status: Status
    let version: Int
    let summary: String
    let checks: [String]
    let blocks: [Block]
    let proposal: Proposal?
    let question: String?
    let attention_id: String?
    let resume_state: String?
}

indirect enum TaskJSON: Codable, Sendable {
    case object([String: TaskJSON]), array([TaskJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: TaskJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([TaskJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .integer(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ReviewTaskSnapshot: Decodable, Sendable {
    let tasks: [ReviewTask]
    let autonomy: String
}
