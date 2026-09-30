import Foundation

/// A reply written by another model than the reply before it in the same chat.
///
/// The model is chosen in Settings, but Hermes also falls back on its own when the usual one fails
/// (out of credits, down): replies then came from another model with nothing in the chat saying so,
/// while `/model` still named the configured one. Read from each reply's own usage.
struct ModelChange: Hashable, Sendable {
    let from: String
    let to: String

    func said(in language: ChatLanguage) -> String {
        language.pick("Now answering: \(to) (before: \(from))", "Ahora responde \(to) (antes \(from))")
    }

    /// By reply id, the replies whose model differs from the previous reply that named one.
    static func changes(in messages: [Message]) -> [String: ModelChange] {
        var result: [String: ModelChange] = [:]
        var last: String?
        for message in messages where message.role == .assistant {
            guard let model = message.usage?.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { continue }
            if let last, last != model { result[message.id] = ModelChange(from: last, to: model) }
            last = model
        }
        return result
    }
}
