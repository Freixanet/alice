import SwiftUI

@main
struct AliceApp: App {
    @State private var store = AppStore()
    @State private var speech = ReadAloud()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(speech)
                .preferredColorScheme(store.theme.colorScheme)
                .tint(store.accent.primary(store.theme.colorScheme ?? .light))
                .task { await store.restoreConnection() }
        }
    }
}
