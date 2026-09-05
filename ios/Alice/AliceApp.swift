import SwiftUI

@main
struct AliceApp: App {
    @State private var store = AppStore()
    @State private var speech = ReadAloud()
    @State private var showRadarBotInstaller = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(speech)
                .preferredColorScheme(store.theme.colorScheme)
                .sheet(isPresented: $showRadarBotInstaller) {
                    RadarIABotInstaller()
                        .environment(store)
                        .preferredColorScheme(store.theme.colorScheme)
                }
                .task {
                    await store.restoreConnection()
                    await store.restoreDashboard()
                    await offerRadarBotIfNeeded()
                }
        }
    }

    /// Radar IA was briefly shipped as a special Jobs setup card. The corrected
    /// representation is a normal Hermes profile. Offer that migration only
    /// when the dashboard is actually reachable and the real bot is absent (or
    /// was only partially created without standing instructions).
    @MainActor
    private func offerRadarBotIfNeeded() async {
        do {
            let bots = try await store.bots()
            guard bots.contains(where: { $0.name == RadarIA.botName }) else {
                showRadarBotInstaller = true
                return
            }

            let soul = try await store.soul(RadarIA.botName)
            if !soul.exists || soul.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showRadarBotInstaller = true
            }
        } catch {
            // No dashboard/profile management means Alice cannot truthfully
            // create a Hermes bot. Leave the existing app usable and do not
            // present a setup flow that could not complete.
        }
    }
}
