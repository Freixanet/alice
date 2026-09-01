import SwiftUI

@main
struct AliceApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
                .tint(store.accent.primary(store.theme.colorScheme ?? .light))
                .task { await store.restoreConnection() }
        }
    }
}
