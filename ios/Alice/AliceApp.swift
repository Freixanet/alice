import SwiftUI

@main
struct AliceApp: App {
    @State private var store = AppStore()
    @State private var speech = ReadAloud()
    @State private var showRadarBotInstaller = false
    @State private var pairingLink: PendingPairingLink?

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
                .sheet(item: $pairingLink) { pending in
                    PairingSheet(link: pending.link, onDismiss: { pairingLink = nil })
                        .environment(store)
                        .preferredColorScheme(store.theme.colorScheme)
                }
                // The pairing QR is an alice:// deep link, so the iPhone's
                // own Camera app can open Alice at the moment of pairing —
                // no in-app scanner needed, least of all on a first install.
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "alice",
                          url.host?.lowercased() == "pair"
                    else { return }
                    pairingLink = PendingPairingLink(link: url.absoluteString)
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
    /// was only partially created without standing instructions). A profile
    /// created by the buggy migration can contain Hermes' generic bootstrap
    /// SOUL; repair that in place without sending the scheduler setup twice.
    @MainActor
    private func offerRadarBotIfNeeded() async {
        do {
            let bots = try await store.bots()
            guard bots.contains(where: { $0.name == RadarIA.botName }) else {
                showRadarBotInstaller = true
                return
            }

            let soul = try await store.soul(RadarIA.botName)
            let emptySoul = !soul.exists
                || soul.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if emptySoul {
                showRadarBotInstaller = true
                return
            }

            // The first real-bot migration mistook Hermes' default profile SOUL
            // for user-authored content. Repair only that known bootstrap text;
            // custom instructions remain untouched.
            if RadarIA.isGenericHermesSoul(soul.text) {
                do {
                    try await store.setSoul(RadarIA.botName, RadarIA.editorialPrompt)
                    let verified = try await store.soul(RadarIA.botName)
                    if !verified.exists || !RadarIA.ownsSoul(verified.text) {
                        showRadarBotInstaller = true
                    }
                } catch {
                    showRadarBotInstaller = true
                }
            }
        } catch {
            // No dashboard/profile management means Alice cannot truthfully
            // create or repair a Hermes bot. Leave the existing app usable.
        }
    }
}

/// A deep link waiting for its sheet. Identifiable so SwiftUI presents one
/// at a time; a second scan while the sheet is up replaces the first.
private struct PendingPairingLink: Identifiable {
    let id = UUID()
    let link: String
}
