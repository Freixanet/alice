#if DEBUG
import Foundation

extension AppStore {
    func seedMessageReplyForUITests() {
        guard ProcessInfo.processInfo.arguments.contains("-messageReplyReview") else { return }
        newChat()
        guard let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        conversations[index].messages = [
            Message(id: "reply-fixture", role: .assistant, content: "Choose A or B for this plan.", createdAt: .now)
        ]
    }
}
#endif
