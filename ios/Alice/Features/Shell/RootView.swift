import SwiftUI

/// The tab bar is Liquid Glass without asking: on iOS 26 `TabView` floats over
/// the content on its own glass, and the search role gets the separate capsule
/// Apple reserves for it. Alice only has to keep the page underneath edge to
/// edge so there is something worth refracting.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var selection: Destination = .chat

    enum Destination: Hashable {
        case chat, library, activity, connect
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Chat", systemImage: "message", value: Destination.chat) {
                ChatView()
            }
            Tab("Library", systemImage: "square.grid.2x2", value: Destination.library) {
                LibraryView()
            }
            Tab("Activity", systemImage: "chart.line.uptrend.xyaxis", value: Destination.activity) {
                ActivityView()
            }
            Tab("Connect", systemImage: "link", value: Destination.connect) {
                ConnectView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .background(Palette.background(scheme))
    }
}
