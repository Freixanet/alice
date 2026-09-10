import XCTest
import UserNotifications
@testable import Alice

/// The switch on a bot used to promise "get notified when this Bot finishes or
/// needs input" and wrote a Boolean into `UserDefaults` that nothing read.
/// There was no `UserNotifications` import in the app, no background mode and
/// no push of any kind. These cover the two halves of not doing that again:
/// only telling someone about something that actually happened, and only
/// claiming delivery the system will actually perform.
final class EventDigestTests: XCTestCase {

    private func routine(
        id: String = "job1", profile: String = "radar-ia", name: String = "Daily brief",
        status: String? = nil, error: String? = nil, lastRun: Date? = nil
    ) -> JobRow {
        JobRow(
            id: id, name: name, prompt: "", schedule: "0 9 * * *", enabled: true,
            lastStatus: status, lastError: error, lastRun: lastRun, nextRun: nil,
            profile: profile
        )
    }

    private var primed: EventWatermarks {
        var marks = EventWatermarks()
        marks.primed = true
        return marks
    }

    /// The first look at an installation is not news. Reporting every existing
    /// routine run and every component state the first time Alice reads them
    /// would notify a person about things that happened before they installed
    /// the app.
    func testFirstSyncOnlyRecords() {
        let result = EventDigest.digest(
            routines: [routine(status: "ok", lastRun: Date())],
            components: [.init(name: "telegram", status: "disconnected")],
            since: EventWatermarks()
        )
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.watermarks.primed)
        XCTAssertFalse(result.watermarks.routineRuns.isEmpty)
    }

    func testNewRunIsReportedOnce() {
        let run = Date()
        let first = EventDigest.digest(
            routines: [routine(status: "ok", lastRun: run)], components: [], since: primed
        )
        XCTAssertEqual(first.events.map(\.kind), [.automationSucceeded])

        // Same run read again is the same fact, not a second one.
        let second = EventDigest.digest(
            routines: [routine(status: "ok", lastRun: run)],
            components: [], since: first.watermarks
        )
        XCTAssertTrue(second.events.isEmpty)
    }

    func testFailureCarriesHermesOwnWords() throws {
        let result = EventDigest.digest(
            routines: [routine(status: "error", error: "model refused: 429", lastRun: Date())],
            components: [], since: primed
        )
        let event = try XCTUnwrap(result.events.first)
        XCTAssertEqual(event.kind, .automationFailed)
        XCTAssertEqual(event.severity, .failure)
        XCTAssertEqual(event.detail, "model refused: 429")
        // The human sentence never replaces the technical one; it accompanies it.
        XCTAssertFalse(event.summary.contains("429"))
    }

    /// A run Hermes has not classified is neither a success nor a failure.
    /// Guessing either would put a claim on the lock screen that the agent
    /// never made.
    func testUnclassifiedRunIsNotReported() {
        for status in [nil, "", "running", "queued", "weird-new-state"] {
            let result = EventDigest.digest(
                routines: [routine(status: status, lastRun: Date())],
                components: [], since: primed
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "status \(status ?? "nil") must not be reported as an outcome"
            )
        }
    }

    /// A delivery failure is a failure even when the run itself said "ok" —
    /// the person did not get the thing the automation exists to send.
    func testDeliveryFailureCountsAsFailure() {
        var row = routine(status: "ok", lastRun: Date())
        row.lastDeliveryError = "telegram: chat not found"
        let result = EventDigest.digest(routines: [row], components: [], since: primed)
        XCTAssertEqual(result.events.map(\.kind), [.automationFailed])
    }

    /// Routine ids are `uuid4().hex[:12]` minted per profile store with no
    /// cross-profile uniqueness, so two bots can hold the same id. Keyed by id
    /// alone, one bot's run would suppress the other's.
    func testRoutinesInDifferentProfilesAreDistinct() {
        let run = Date()
        let result = EventDigest.digest(
            routines: [
                routine(id: "same", profile: "radar-ia", name: "A", status: "ok", lastRun: run),
                routine(id: "same", profile: "default", name: "B", status: "ok", lastRun: run),
            ],
            components: [], since: primed
        )
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(Set(result.events.map(\.id)).count, 2)
    }

    func testComponentGoingBadAndRecoveringAreBothReported() throws {
        var marks = primed
        marks.componentStatus["telegram"] = "connected"

        let broke = EventDigest.digest(
            routines: [], components: [.init(name: "telegram", status: "disconnected")],
            since: marks
        )
        let attention = try XCTUnwrap(broke.events.first)
        XCTAssertEqual(attention.kind, .attention)
        XCTAssertEqual(attention.title, "Telegram")

        let fixed = EventDigest.digest(
            routines: [], components: [.init(name: "telegram", status: "connected")],
            since: broke.watermarks
        )
        XCTAssertEqual(fixed.events.map(\.kind), [.recovered])
    }

    /// An unfamiliar status word must not raise an alarm Alice cannot justify.
    func testUnknownComponentStatusIsNotAnAlarm() {
        XCTAssertTrue(EventDigest.healthy("connected"))
        XCTAssertTrue(EventDigest.healthy("brand-new-state"))
        XCTAssertFalse(EventDigest.healthy("disconnected"))
        XCTAssertFalse(EventDigest.healthy("degraded"))
    }

    /// Hermes' component names are its own vocabulary. Alice translates the
    /// ones it knows and makes the rest presentable — the same word, not a
    /// different one, so nothing is invented and the original is still
    /// recognisable. Printing them raw is what produced an alert reading
    /// "platforms" over the sentence "platforms needs attention".
    func testComponentLabelsAreReadable() {
        XCTAssertEqual(EventDigest.label(for: "gateway"), "Alice's connection")
        XCTAssertEqual(EventDigest.label(for: "cron"), "Automations")
        XCTAssertEqual(EventDigest.label(for: "platforms"), "Messaging apps")
        // Unknown: tidied, never renamed.
        XCTAssertEqual(EventDigest.label(for: "some_new_subsystem"), "Some New Subsystem")
    }

    /// A status is not an explanation. Every alert says what the problem means
    /// for the person reading it, and an unfamiliar component admits that
    /// Alice does not know rather than inventing a consequence.
    func testEveryComponentExplainsItsConsequence() {
        for component in ["gateway", "telegram", "cron", "mcp", "memory", "models"] {
            let text = EventDigest.consequence(for: component)
            XCTAssertFalse(text.isEmpty, component)
            XCTAssertFalse(
                text.lowercased().contains("needs attention"),
                "\(component) still just restates the status"
            )
        }
        XCTAssertTrue(
            EventDigest.consequence(for: "something_new").contains("More details")
        )
    }

    /// The summary a person reads must not be the bare status either.
    func testAttentionRowsCarryTheConsequence() throws {
        let items = EventDigest.attention(
            routines: [],
            components: [HermesSystemComponent(name: "telegram", status: "disconnected")]
        )
        let row = try XCTUnwrap(items.first)
        XCTAssertEqual(row.title, "Telegram")
        XCTAssertFalse(row.summary.contains("needs attention"))
        XCTAssertTrue(row.summary.lowercased().contains("won't arrive"))
    }
}

/// A stand-in for `UNUserNotificationCenter`, so permission behaviour can be
/// tested without the system asking a real person a real question.
final class FakeNotificationCenter: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var permission: Notifier.Permission
    private var granted: Notifier.Permission
    private(set) var posted: [String] = []
    private(set) var authorizationRequests = 0

    init(permission: Notifier.Permission, becomes granted: Notifier.Permission? = nil) {
        self.permission = permission
        self.granted = granted ?? permission
    }

    func currentPermission() async -> Notifier.Permission { lock.withLock { permission } }

    func requestAuthorization() async throws -> Bool {
        lock.withLock {
            authorizationRequests += 1
            permission = granted
            return permission.canDeliver
        }
    }

    func add(identifier: String, content: UNNotificationContent) async {
        lock.withLock {
            posted.append(identifier)
            bodies[identifier] = content.body
            routes[identifier] = content.userInfo
        }
    }

    func withdraw(_ identifiers: [String]) {
        lock.withLock {
            withdrawn.append(contentsOf: identifiers)
            posted.removeAll { identifiers.contains($0) }
        }
    }

    private(set) var withdrawn: [String] = []
    private var bodies: [String: String] = [:]
    private var routes: [String: [AnyHashable: Any]] = [:]
    func body(_ identifier: String) -> String? { lock.withLock { bodies[identifier] } }
    func route(_ identifier: String) -> [AnyHashable: Any]? { lock.withLock { routes[identifier] } }
}

@MainActor
final class NotifierTests: XCTestCase {

    private func event(id: String = "e1", kind: AliceEvent.Kind = .automationSucceeded) -> AliceEvent {
        AliceEvent(
            id: id, kind: kind, severity: .informational, profile: "radar-ia",
            title: "Daily brief", summary: "This automation finished.", occurred: Date()
        )
    }

    /// Nothing is posted when the system would not deliver it. A feature that
    /// looks armed but cannot fire is the defect this whole file exists for.
    func testNothingIsPostedWithoutPermission() async {
        let center = FakeNotificationCenter(permission: .refused)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        await notifier.post(event())

        XCTAssertTrue(center.posted.isEmpty)
        XCTAssertFalse(notifier.permission.canDeliver)
    }

    func testPostsOnceAllowed() async {
        let center = FakeNotificationCenter(permission: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        await notifier.post([event(id: "a"), event(id: "b")])

        XCTAssertEqual(center.posted, ["a", "b"])
    }

    /// iOS presents its prompt once. After a refusal, asking again does
    /// nothing at all, so Alice must not pretend it is asking.
    func testRefusalIsNotAskedAgain() async {
        let center = FakeNotificationCenter(permission: .refused)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        let granted = await notifier.requestPermission()

        XCTAssertFalse(granted)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testAskingInContextGrantsDelivery() async {
        let center = FakeNotificationCenter(permission: .notAsked, becomes: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        let granted = await notifier.requestPermission()

        XCTAssertTrue(granted)
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(notifier.permission, .allowed)
    }

    /// Permission revoked in iOS Settings while Alice was away.
    func testPermissionIsRereadNotRemembered() async {
        let center = FakeNotificationCenter(permission: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()
        XCTAssertTrue(notifier.permission.canDeliver)

        let revoked = FakeNotificationCenter(permission: .refused)
        let second = Notifier(center: revoked)
        await second.refreshPermission()
        XCTAssertFalse(second.permission.canDeliver)
    }

    /// A tap has to reach the thing it is about even after a cold start, when
    /// nothing of the session that produced it is left in memory. Everything
    /// needed to reopen it therefore travels on the notification itself.
    func testNotificationCarriesEnoughToReopenTheThing() async throws {
        let center = FakeNotificationCenter(permission: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        let event = AliceEvent(
            id: "approval:req-9", kind: .needsInput, severity: .needsAttention,
            profile: "radar-ia", title: "Needs your approval",
            summary: "Radar IA is waiting for permission to continue.",
            occurred: Date(),
            reference: .init(
                installation: "install-a", profile: "radar-ia",
                sessionID: "sess-1", sessionKey: "key-1",
                requestID: "req-9", conversationID: "conv-1"
            ),
            standing: .waiting
        )
        await notifier.post(event)

        let info = try XCTUnwrap(center.route("approval:req-9"))
        let route = try XCTUnwrap(Notifier.Route(userInfo: info))
        XCTAssertEqual(route.eventID, "approval:req-9")
        XCTAssertEqual(route.installation, "install-a")
        XCTAssertEqual(route.conversationID, "conv-1")
        XCTAssertEqual(route.requestID, "req-9")
    }

    /// Answering a question must take back the banner that asked it. Leaving it
    /// there is the same lie as the switch that promised delivery and sent none.
    func testAnsweredRequestWithdrawsItsNotification() async {
        let center = FakeNotificationCenter(permission: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        await notifier.post(AliceEvent(
            id: "approval:req-9", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "waiting", occurred: Date(),
            standing: .waiting
        ))
        XCTAssertEqual(center.posted, ["approval:req-9"])

        notifier.withdraw("approval:req-9")

        XCTAssertEqual(center.withdrawn, ["approval:req-9"])
        XCTAssertTrue(center.posted.isEmpty)
    }

    /// A finished research task can contain anything, and a lock screen is a
    /// public surface.
    func testAgentOutputNeverReachesTheNotificationBody() async throws {
        let center = FakeNotificationCenter(permission: .allowed)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        let secret = "Bank transfer approved for 12,400 EUR"
        let session = LiveEvents.SessionIdentity(
            profile: "radar-ia", sessionID: "s", sessionKey: "k",
            conversationID: "c", label: "Radar IA"
        )
        let event = try XCTUnwrap(LiveEvents.event(
            from: HermesRPCEvent(
                type: "message.complete", sessionID: "s",
                payload: ["text": secret, "status": "complete"]
            ),
            session: session
        ))
        await notifier.post(event)

        let body = try XCTUnwrap(center.body(event.id))
        XCTAssertFalse(body.contains(secret))
        XCTAssertFalse(body.contains("12,400"))
    }

    /// Allowed-but-silent still delivers to Notification Centre, so it counts
    /// as deliverable — but the UI says it will not appear as a banner.
    func testQuietDeliveryStillCounts() async {
        let center = FakeNotificationCenter(permission: .allowedQuietly)
        let notifier = Notifier(center: center)
        await notifier.refreshPermission()

        await notifier.post(event())

        XCTAssertEqual(center.posted.count, 1)
    }
}

@MainActor
final class NotificationApplicationDelegateTests: XCTestCase {
    @MainActor
    private final class RouteSink {
        var routes: [Notifier.Route] = []
    }

    /// A real notification response can arrive before SwiftUI's `.task` runs.
    /// The application delegate must retain it and deliver it exactly once when
    /// the shell installs its navigation handler.
    func testColdStartRouteWaitsForSwiftUIHandler() throws {
        let delegate = NotificationApplicationDelegate()
        let route = try XCTUnwrap(Notifier.Route(userInfo: [
            "event": "cold-start-event",
            "installation": "install-a",
            "conversation": "conversation-a",
        ]))
        let sink = RouteSink()

        delegate.accept(route)
        XCTAssertTrue(sink.routes.isEmpty)

        delegate.deliver = { sink.routes.append($0) }
        XCTAssertEqual(sink.routes, [route])

        // Replacing the handler must not replay an already-consumed tap.
        delegate.deliver = { sink.routes.append($0) }
        XCTAssertEqual(sink.routes, [route])
    }
}
