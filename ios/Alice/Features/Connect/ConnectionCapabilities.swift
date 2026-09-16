import Foundation

/// What a connected Hermes can actually do from this phone.
///
/// Chat can work while Agents, Projects, Memory and Usage still need the
/// dashboard. Empty, offline and unsupported are different; this only answers
/// “connected, and which half?”
enum ConnectionCapabilities {
    struct Row: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var available: Bool
    }

    static func rows(dashboardReady: Bool, modelCount: Int) -> [Row] {
        [
            Row(
                title: String(localized: "Chat"),
                detail: String(localized: "Available"),
                available: true
            ),
            Row(
                title: String(localized: "Agents"),
                detail: dashboardReady
                    ? String(localized: "Available")
                    : String(localized: "Needs the dashboard"),
                available: dashboardReady
            ),
            Row(
                title: String(localized: "Projects, Memory and Usage"),
                detail: dashboardReady
                    ? String(localized: "Available")
                    : String(localized: "Needs the dashboard"),
                available: dashboardReady
            ),
            Row(
                title: String(localized: "Models"),
                detail: modelCount > 0
                    ? String(localized: "\(modelCount) listed")
                    : String(localized: "Not listed yet"),
                available: modelCount > 0
            ),
        ]
    }
}
