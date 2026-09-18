import Foundation

/// A requested agent always runs in its own Hermes profile and session.
/// Gateway connectivity cannot stand in for an unavailable agent dashboard.
enum ChatTurnRoute: Equatable {
    case agent(profile: String, mention: Bool)
    case home
    case gateway

    static func resolve(
        in conversation: Conversation, invokedBot: String?,
        dashboardReady: Bool, updatingHermes: Bool
    ) -> ChatTurnRoute? {
        guard !conversation.isRecoveredHistory else { return nil }
        if let profile = conversation.routedBotName, conversation.isChannel != true {
            return .agent(profile: profile, mention: false)
        }
        if let profile = invokedBot, !profile.isEmpty {
            return .agent(profile: profile, mention: true)
        }
        guard conversation.isChannel != true else { return nil }
        return dashboardReady && !updatingHermes ? .home : .gateway
    }
}
