import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct AliceApp: App {
    /// iOS runs this when it feels like it — which is the honest limit of
    /// background delivery here, and what the notification copy says.
    static let refreshTaskID = "com.freixanet.alice.refresh"

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()
    @State private var speech = ReadAloud()
    @State private var notifier = Notifier()
    @State private var router: NotificationRouter?
    @State private var showRadarBotInstaller = false
    @State private var pairingLink: PendingPairingLink?

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if physicalE2EMode != nil {
                    Color.clear
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
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
                    guard url.scheme?.lowercased() == "alice",
                          url.host?.lowercased() == "pair"
                    else { return }
                    pairingLink = PendingPairingLink(link: url.absoluteString)
                }
                .task {
                    installRouter()
                    #if DEBUG
                    if physicalE2EMode != nil {
                        await store.restoreDashboard()
                        store.enableDashboardOnlyPhysicalE2E()
                        await notifier.refreshPermission()
                        store.startWatchingLiveEvents()
                        await runPhysicalE2EIfRequested()
                        return
                    }
                    #endif
                    await store.restoreConnection()
                    await store.restoreDashboard()
                    // Hydrate canonical Bot Chat session ids before the watcher
                    // starts. Existing installs may predate remote Bot Chat and
                    // therefore have cached bot conversations with no server id;
                    // without this, a real pushed event cannot be attributed to
                    // its conversation until that bot is opened manually.
                    await store.refreshVisibleBotChats()
                    #if DEBUG
                    if !store.botChatFailure.isEmpty { print("ALICE_E2E_BOT_REFRESH", store.botChatFailure) }
                    #endif
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
                    #if DEBUG
                    if physicalE2EMode != nil {
                        physicalE2ERecord("ALICE_PHYSICAL_E2E scene=\(phase)")
                    }
                    #endif
                    guard phase == .active else {
                        store.isForeground = false
                        if phase == .background {
                            store.stopWatchingLiveEvents()
                            scheduleRefresh()
                        }
                        return
                    }
                    Task {
                        store.isForeground = true
                        await notifier.refreshPermission()
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
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await handleRefresh()
        }
    }



    #if DEBUG
    private var physicalE2EMode: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-alicePhysicalE2E"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Temporary physical-device harness used only to close the real Hermes
    /// delivery E2E. It calls the same AppStore methods as the UI and is
    /// removed before final validation/release.
    private func physicalE2ERecord(_ line: String) {
        print(line)
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("alice-physical-e2e.log")
        let data = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    @MainActor
    private func runPhysicalE2EIfRequested() async {
        guard let mode = physicalE2EMode else { return }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("alice-physical-e2e.log"))
        }
        physicalE2ERecord("ALICE_PHYSICAL_E2E start=\(mode)")
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        guard store.isConnected, store.dashboardReady else {
            physicalE2ERecord("ALICE_PHYSICAL_E2E \(mode) FAIL:not-connected")
            return
        }
        guard let conversation = store.conversations.first(where: {
            $0.routedBotName == "radar-ia" && $0.isCanonicalBotChat
        }) else {
            physicalE2ERecord("ALICE_PHYSICAL_E2E \(mode) FAIL:no-radar-chat")
            return
        }
        let conversationID = conversation.id
        store.activeID = conversationID
        let baseline = Set(store.activity.map(\.id))

        func waitForIdle(_ seconds: Int = 90) async -> Bool {
            for _ in 0..<(seconds * 4) {
                if !store.isSending { return true }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return false
        }
        func waitForEvent(
            _ predicate: @escaping (AliceEvent) -> Bool, seconds: Int = 90
        ) async -> AliceEvent? {
            for _ in 0..<(seconds * 4) {
                if let event = store.activity.first(where: predicate) { return event }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return nil
        }
        func send(_ text: String) {
            store.draft = text
            store.send()
        }

        switch mode {
        case "task":
            send("Integration check only. Reply with exactly ALICE_E2E_TASK_OK and do not call any tools.")
            let idle = await waitForIdle()
            await store.refreshBotChat(conversationID)
            let exactChat = store.activeConversation?.messages.contains {
                $0.role == .assistant &&
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "ALICE_E2E_TASK_OK"
            } == true
            let activityFinished = store.activity.contains {
                !baseline.contains($0.id) && $0.profile == "radar-ia" &&
                $0.kind == .finished && $0.reference.conversationID == conversationID
            }
            physicalE2ERecord("ALICE_PHYSICAL_E2E task idle=\(idle) exactChat=\(exactChat) activityFinished=\(activityFinished) session=\(store.activeConversation?.hermesSessionID != nil)")

        case "permit":
            send("Integration check only. Use the terminal tool to run exactly `systemctl restart sshd`. On this macOS test host `systemctl` is absent, so after approval the command can only fail with command-not-found and cannot mutate the system; Hermes nevertheless classifies the operation as a real system-service restart requiring approval. Do not simulate it and do not use another tool. Wait for the real approval. After the approved tool returns, regardless of exit status, reply with exactly ALICE_E2E_APPROVAL_DONE.")
            guard let event = await waitForEvent({
                !baseline.contains($0.id) && $0.profile == "radar-ia" &&
                $0.standing == .waiting && !$0.approvalChoices.isEmpty
            }) else {
                physicalE2ERecord("ALICE_PHYSICAL_E2E approval FAIL:no-request")
                return
            }
            let request = event.reference.requestID ?? ""
            physicalE2ERecord("ALICE_PHYSICAL_E2E approval request=\(!request.isEmpty) choices=\(event.approvalChoices.map(\.rawValue).joined(separator: ",")) transport=\(event.reference.transport.rawValue) session=\(event.reference.sessionID != nil) installation=\(event.reference.installation != nil)")
            physicalE2ERecord("ALICE_PHYSICAL_E2E approval resolving=true")
            let accepted = await store.resolvePendingRequest(event, choice: .once)
            physicalE2ERecord("ALICE_PHYSICAL_E2E approval resolveReturned=\(accepted)")
            let idle = await waitForIdle()
            await store.refreshBotChat(conversationID)
            _ = await store.syncEvents()
            let final = store.activity.first(where: { $0.id == event.id })
            let chatCardGone = store.activeConversation?.messages.allSatisfy {
                $0.approval?.requestID != request && $0.approval?.runID != request
            } == true
            let exactChat = store.activeConversation?.messages.contains {
                $0.role == .assistant &&
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "ALICE_E2E_APPROVAL_DONE"
            } == true
            physicalE2ERecord("ALICE_PHYSICAL_E2E approval accepted=\(accepted) idle=\(idle) standing=\(final?.standing.rawValue ?? "missing") chatCardGone=\(chatCardGone) exactChat=\(exactChat)")

        case "clarify":
            send("Integration check only. You MUST call the clarify tool exactly once using ONE batch with exactly two independent questions. First question: `E2E color?` with choices `Blue` and `Green`, single-select. Second question: `E2E note?` with no choices, free text. Do not answer either question yourself. Wait for both real user answers. After both answers are received, reply with exactly ALICE_E2E_CLARIFY_DONE.")
            guard let event = await waitForEvent({
                !baseline.contains($0.id) && $0.profile == "radar-ia" &&
                $0.standing == .waiting && $0.questions.count == 2
            }) else {
                physicalE2ERecord("ALICE_PHYSICAL_E2E clarify FAIL:no-batch")
                return
            }
            let q0 = event.questions[0].id
            let q1 = event.questions[1].id
            physicalE2ERecord("ALICE_PHYSICAL_E2E clarify request=\(event.reference.requestID != nil) q0=\(q0 ?? "nil") q1=\(q1 ?? "nil")")
            let first = await store.answerClarification(event, questionID: q0, answer: "Blue")
            let partial = store.activity.first(where: { $0.id == event.id })
            let partialOK = partial?.standing == .waiting && partial?.questions.first?.answer == "Blue" && partial?.questions.dropFirst().first?.answer == nil
            guard let refreshed = partial else {
                physicalE2ERecord("ALICE_PHYSICAL_E2E clarify FAIL:missing-after-first")
                return
            }
            let second = await store.answerClarification(refreshed, questionID: q1, answer: "E2E note")
            let idle = await waitForIdle()
            await store.refreshBotChat(conversationID)
            _ = await store.syncEvents()
            let final = store.activity.first(where: { $0.id == event.id })
            let exactChat = store.activeConversation?.messages.contains {
                $0.role == .assistant &&
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "ALICE_E2E_CLARIFY_DONE"
            } == true
            physicalE2ERecord("ALICE_PHYSICAL_E2E clarify first=\(first) partial=\(partialOK) second=\(second) idle=\(idle) standing=\(final?.standing.rawValue ?? "missing") answers=\(final?.questions.filter { $0.answer != nil }.count ?? -1)/2 exactChat=\(exactChat)")

        default:
            physicalE2ERecord("ALICE_PHYSICAL_E2E \(mode) FAIL:unknown-mode")
        }
    }
    #endif

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
    private func installRouter() {
        guard router == nil else { return }
        if let launchRoute { notifier.pendingRoute = launchRoute }
        store.notify = { events in await notifier.post(events) }
        store.withdraw = { id in notifier.withdraw(id) }
        let router = NotificationRouter { route in
            // Held rather than acted on immediately: on a cold start this
            // arrives before the interface exists.
            notifier.pendingRoute = route
        }
        UNUserNotificationCenter.current().delegate = router
        self.router = router
        drainPendingRoute()
    }

    /// Acts on a tap once there is something on screen to act with.
    private func drainPendingRoute() {
        guard let route = notifier.pendingRoute else { return }
        notifier.pendingRoute = nil
        store.open(route)
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
        guard notifier.permission.canDeliver else { return }
        await store.restoreDashboard()
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
