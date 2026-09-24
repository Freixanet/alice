import Foundation

/// The agent's replies to one request, shown as one message.
///
/// An agent that asks others answers in several turns — "consulting Mercado",
/// each teammate's answer, the conclusion — and each came out as a message of
/// its own, with its own time and its own copy and share buttons, while they
/// are all one task. Consecutive replies are one task: the time shows once at
/// its top and the actions once at its end, over the whole task, and neither
/// shows while the task is still going. A routine's report is its own message.
enum ChatTasks {
    struct Position: Equatable {
        /// The first reply of the task: where its time goes.
        var isFirst: Bool
        /// The last reply of the task: where its actions go.
        var isLast: Bool
        /// The task ends the transcript, so it may still be under way.
        var isLatest: Bool
        /// Everything the task said, for copying and sharing.
        var text: String
    }

    static func positions(_ messages: [Message]) -> [String: Position] {
        var positions: [String: Position] = [:]
        var start = 0
        while start < messages.count {
            guard messages[start].role == .assistant else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < messages.count, continues(messages[end], messages[end + 1]) {
                end += 1
            }
            let text = messages[start...end].map(\.content)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            for index in start...end {
                positions[messages[index].id] = Position(
                    isFirst: index == start, isLast: index == end,
                    isLatest: end == messages.count - 1, text: text
                )
            }
            start = end + 1
        }
        return positions
    }

    private static func continues(_ current: Message, _ next: Message) -> Bool {
        guard next.role == .assistant else { return false }
        // A routine's opening words, card and closing words are one delivery.
        if current.routineGroup != nil || next.routineGroup != nil {
            return current.routineGroup == next.routineGroup
        }
        return current.routineName == nil && next.routineName == nil
    }
}
