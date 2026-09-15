import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

@main
struct AliceApp: App {
    /// iOS runs this when it feels like it — which is the honest limit of
    /// background delivery here, and what the notification copy says.
    static let refreshTaskID = "com.freixanet.alice.refresh"

    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(NotificationApplicationDelegate.self) private var notificationDelegate
    @State private var store = AppStore()
    @State private var speech = ReadAloud()
    @State private var notifier = Notifier()
    @State private var activities = AgentActivities()
    @State private var showRadarBotInstaller = false
    @State private var pairingLink: PendingPairingLink?

    var body: some Scene {
        WindowGroup {
            RootView()
                // SwiftUI can resize its hosting hierarchy around the software
                // keyboard. Paint the actual UIWindow as well so the exposed /
                // translucent region beneath the keyboard never falls back to
                // UIKit's default white, especially in dark mode.
                .background(WindowSurface())
                .environment(store)
                .environment(speech)
                .environment(notifier)
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
                    if let link = NotificationLink(url: url) {
                        store.open(link)
                        return
                    }
                    guard url.scheme?.lowercased() == "alice",
                          url.host?.lowercased() == "pair"
                    else { return }
                    pairingLink = PendingPairingLink(link: url.absoluteString)
                }
                .task {
                    installRouter()
                    #if DEBUG
                    store.seedChannelAlertForUITests()
                    store.seedLongBotChatForUITests()
                    #endif
                    await store.restoreConnection()
                    await store.restoreDashboard()
                    // Hydrate canonical Bot Chat session ids before the watcher
                    // starts. Existing installs may predate remote Bot Chat and
                    // therefore have cached bot conversations with no server id;
                    // without this, a real pushed event cannot be attributed to
                    // its conversation until that bot is opened manually.
                    await store.refreshVisibleBotChats()
                    await notifier.refreshPermission()
                    store.startWatchingLiveEvents()
                    // Prime the watermarks without announcing the installation's
                    // existing state as news; the first digest only records.
                    await notifier.post(store.syncEvents())
                    await offerRadarBotIfNeeded()
                }
                // Permission can be revoked in Settings while Alice is away, and
                // work can finish while it is backgrounded. Both are worth
                // re-reading the moment it comes back.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else {
                        store.isForeground = false
                        if phase == .background {
                            store.persistConversations()
                            store.stopWatchingLiveEvents()
                            scheduleRefresh()
                        }
                        return
                    }
                    Task {
                        store.isForeground = true
                        await notifier.refreshPermission()
                        // Reachability is a fact to re-check, not a preference.
                        // A Mac can go offline while Alice is suspended; probing
                        // both saved surfaces here keeps the drawer's connection
                        // label from reporting yesterday's state.
                        await store.restoreConnection()
                        await store.restoreDashboard()
                        // Re-resolve the canonical tips before listening again:
                        // compression can advance a bot to a new session while
                        // Alice is suspended, and events must route by that live id.
                        await store.refreshVisibleBotChats()
                        // The socket does not survive suspension; this is where
                        // it comes back, and it is idempotent.
                        store.startWatchingLiveEvents()
                        await notifier.post(store.syncEvents())
                        drainPendingRoute()
                    }
                }
                // An agent set to work shows on the Lock Screen and in the
                // Dynamic Island, and says how it ended once it stops.
                .onChange(of: store.agentWorks, initial: true) { _, works in
                    activities.sync(working: works, ending: store.agentEnding)
                }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await handleRefresh()
        }
    }



    /// A tap injected by the UI suite, so the cold-start path can be driven
    /// without a real notification — which needs a granted permission and a
    /// server, neither of which a test can arrange on its own.
    ///
    /// Debug only: it exists in the build the tests run and in no shipped one.
    private var launchRoute: Notifier.Route? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-notificationRoute"),
              index + 1 < arguments.count,
              let data = arguments[index + 1].data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Notifier.Route(userInfo: info)
        #else
        return nil
        #endif
    }

    /// Connects the store to the notifier, and taps to the store.
    @MainActor
    private func installRouter() {
        if let launchRoute { notifier.pendingRoute = launchRoute }
        store.notify = { events in await notifier.post(events) }
        store.withdraw = { id in notifier.withdraw(id) }
        notificationDelegate.deliver = { route in
            // A genuine cold-start response may have been buffered by the app
            // delegate before SwiftUI existed. Once installed, later taps are
            // delivered through the same path immediately.
            notifier.pendingRoute = route
            drainPendingRoute()
        }
        drainPendingRoute()
    }

    /// Acts on a tap once there is something on screen to act with.
    private func drainPendingRoute() {
        guard let route = notifier.pendingRoute else { return }
        notifier.pendingRoute = nil
        _ = store.open(route)
    }

    /// Asks iOS to wake Alice at some point. iOS decides whether and when,
    /// and never does if the app was force-quit — which is exactly why the
    /// notification copy promises "when Alice next checks" and not "instantly".
    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One opportunistic catch-up: read the durable server state, report what
    /// changed, and ask for the next window.
    @MainActor
    private func handleRefresh() async {
        scheduleRefresh()
        await notifier.refreshPermission()
        await store.restoreDashboard()
        // The one moment Alice gets while closed: agents' Live Activities are
        // brought up to date — or ended — whether or not notifications are on.
        await store.refreshVisibleBotChats()
        activities.sync(working: store.agentWorks, ending: store.agentEnding)
        guard notifier.permission.canDeliver else { return }
        await notifier.post(store.syncEvents())
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


/// Keeps the real window surface in lock-step with Alice's theme. A SwiftUI
/// background only paints inside the hosting view's current bounds; those bounds
/// can change while the software keyboard is presented.
private struct WindowSurface: UIViewRepresentable {
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> WindowSurfaceView {
        let view = WindowSurfaceView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WindowSurfaceView, context: Context) {
        view.windowColor = UIColor(Palette.background(scheme))
    }
}

private final class WindowSurfaceView: UIView {
    var windowColor: UIColor = .clear {
        didSet { paintWindow() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        paintWindow()
    }

    private func paintWindow() {
        window?.backgroundColor = windowColor
    }
}
