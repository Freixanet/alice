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
                .task {
                    await store.restoreConnection()
                    await store.restoreDashboard()
                }
        }
    }
}
