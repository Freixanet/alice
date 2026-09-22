import EventKit
import Foundation
import UIKit

/// What one check found.
struct CheckResult: Equatable, Sendable {
    enum State: Int, Comparable, Sendable {
        /// Not applicable here, or nothing to say.
        case idle
        case ok
        case warning
        case failure

        static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var state: State
    /// One line, what the row says.
    var summary: String
    /// What it means and what to do, when there is something to do.
    var detail: String?

    static func ok(_ summary: String, _ detail: String? = nil) -> CheckResult { .init(state: .ok, summary: summary, detail: detail) }
    static func warning(_ summary: String, _ detail: String? = nil) -> CheckResult { .init(state: .warning, summary: summary, detail: detail) }
    static func failure(_ summary: String, _ detail: String? = nil) -> CheckResult { .init(state: .failure, summary: summary, detail: detail) }
    static func idle(_ summary: String, _ detail: String? = nil) -> CheckResult { .init(state: .idle, summary: summary, detail: detail) }
}

/// One thing developer mode verifies about the app and its Hermes.
///
/// A registry, so a feature that can break brings its own check: add one to
/// `DiagnosticChecks.all` and it is run, drawn and put in the shared report.
struct DiagnosticCheck: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let run: @MainActor @Sendable (AppStore, Notifier) async -> CheckResult
}

enum DiagnosticChecks {
    static let all: [DiagnosticCheck] = [
        connection, plugin, timeZone, calendar, notifications, routines, storage, responsiveness, hermesEvents,
    ]

    // MARK: - Hermes

    static let connection = DiagnosticCheck(id: "connection", title: "Hermes", symbol: "antenna.radiowaves.left.and.right") { store, _ in
        guard store.isConnected || store.dashboardReady else {
            return .failure("Not connected", "Alice cannot reach Hermes. Check that the Mac is on and that this iPhone is on the same network or Tailscale.")
        }
        let started = Date()
        do {
            _ = try await store.hermesTimezones()
        } catch {
            return .warning("Connected, but the dashboard did not answer", PlainWords.describe(error, doing: "reach the dashboard"))
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ms > 1500
            ? .warning("Slow: \(ms) ms to answer", "Replies and syncs will feel sluggish. The Mac may be busy — see Library › Mac.")
            : .ok("Answering in \(ms) ms")
    }

    static let plugin = DiagnosticCheck(id: "plugin", title: "Alice plugin", symbol: "puzzlepiece.extension") { store, _ in
        guard store.dashboardReady else { return .idle("Needs the dashboard") }
        do {
            _ = try await store.hermesTimezones()
            await store.refreshCalendarLink()
            return .ok("Up to date")
        } catch DashboardClient.Failure.http(404, _) {
            return .failure("Out of date", "Copy the Alice plugin from the repository to ~/.hermes/plugins/alice and restart the dashboard.")
        } catch {
            return .warning("Could not check", PlainWords.describe(error, doing: "check the plugin"))
        }
    }

    static let timeZone = DiagnosticCheck(id: "timezone", title: "Time zone", symbol: "clock") { store, _ in
        guard store.dashboardReady, let zones = try? await store.hermesTimezones() else { return .idle("Needs the dashboard") }
        let phone = TimeZone.current.identifier
        if !zones.outOfStep.isEmpty {
            return .warning(
                "\(zones.outOfStep.count) agents on another clock",
                "\(zones.outOfStep.map(\.name).joined(separator: ", ")) use \(zones.server.isEmpty ? "the Mac's clock" : zones.server). Set one zone for all in Settings › General › Time zone."
            )
        }
        if zones.effective != phone {
            return .warning("Hermes is on \(zones.effective), this iPhone on \(phone)", "Routines and dates follow Hermes. Change it in Settings › General › Time zone if you have moved.")
        }
        return .ok(zones.effective)
    }

    // MARK: - Features

    static let calendar = DiagnosticCheck(id: "calendar", title: "Calendar", symbol: "calendar") { store, _ in
        await store.refreshCalendarLink()
        let access = EKEventStore.authorizationStatus(for: .event)
        switch store.calendarLink {
        case let .connected(updatedAt):
            guard access == .fullAccess else {
                return .warning("Connected, but iOS access is off", "Hermes keeps the last copy, which is getting old. Turn on Calendars for Alice in iOS Settings.")
            }
            guard let updatedAt else { return .ok("Connected") }
            let hours = Date().timeIntervalSince(updatedAt) / 3600
            return hours > 24
                ? .warning("Last sent \(Int(hours)) h ago", "It is sent when Alice opens or iOS wakes her; open Alice to send it now.")
                : .ok("Connected · sent \(updatedAt.formatted(.relative(presentation: .named)))")
        case .declined:
            return .idle("Declined — agents won't offer it")
        case .notConnected:
            return .idle("Not connected")
        case .unknown:
            return .idle("Unknown")
        }
    }

    static let notifications = DiagnosticCheck(id: "notifications", title: "Notifications", symbol: "bell.badge") { store, notifier in
        await notifier.refreshPermission()
        if let warning = store.liveActivityWarning {
            return .warning("Live Activity could not start", warning)
        }
        switch notifier.permission {
        case .refused:
            return .warning("Off in iOS Settings", "Questions and approvals will not reach you while Alice is closed.")
        case .notAsked:
            return .idle("Not asked yet")
        case .allowedQuietly:
            return .warning("Allowed without banners", "They arrive in Notification Center only.")
        case .allowed:
            return .ok(store.barkRelays ? "On · replies and routines through Bark" : "On · Alice announces everything herself")
        }
    }

    static let routines = DiagnosticCheck(id: "routines", title: "Proactive routines", symbol: "sun.max") { store, _ in
        guard store.dashboardReady, let all = try? await store.allRoutines() else { return .idle("Needs the dashboard") }
        let alice = all["default"] ?? []
        let expected = ["Buenos días", "Antes de cada cita", "Cierre del día"]
        let missing = expected.filter { name in !alice.contains { $0.name == name } }
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        let failed = all.values.flatMap { $0 }.filter {
            $0.enabled && ($0.lastRun ?? .distantPast) > week
                && !["ok", "success", "succeeded", nil].contains($0.lastStatus?.lowercased())
        }
        if !failed.isEmpty {
            return .warning("\(failed.count) failed this week", failed.map(\.name).joined(separator: ", ") + ". See Routines.")
        }
        if !missing.isEmpty {
            return .warning("Missing: \(missing.joined(separator: ", "))", "Run hermes-agents/proactiva/instalar.py on the Mac.")
        }
        let paused = expected.filter { name in alice.first { $0.name == name }?.enabled == false }
        return paused.isEmpty ? .ok("All running") : .idle("Paused: \(paused.joined(separator: ", "))")
    }

    // MARK: - The app itself

    static let storage = DiagnosticCheck(id: "storage", title: "Storage", symbol: "internaldrive") { store, _ in
        if let warning = store.storageWarning { return .failure("Problem saving", warning) }
        let settings = preferencesBytes()
        let conversations = conversationFileBytes()
        let summary = "Settings \(bytes(settings)) · chats \(bytes(conversations))"
        return settings > 256 * 1024
            ? .warning(summary, "Settings storage is rewritten whole on every change; large data belongs in files.")
            : .ok(summary)
    }

    static let responsiveness = DiagnosticCheck(id: "responsiveness", title: "Responsiveness", symbol: "gauge.with.needle") { _, _ in
        let monitor = HitchMonitor.shared
        guard monitor.running else { return .idle("Measured while developer mode is on") }
        let worst = monitor.worst
        guard !monitor.stalls.isEmpty else { return .ok("No freezes this session") }
        let summary = "\(monitor.stalls.count) freezes · worst \(Int(worst * 1000)) ms"
        return worst >= 1
            ? .failure(summary, "The screen stopped answering for over a second. Relaunch with ALICE_STALL_SAMPLER=1 to see where.")
            : .warning(summary, "Short freezes; noticeable when scrolling or opening screens.")
    }

    static let hermesEvents = DiagnosticCheck(id: "events", title: "Hermes updates", symbol: "arrow.triangle.2.circlepath") { _, _ in
        let unknown = HermesUnknownEvents.shared.all
        return unknown.isEmpty
            ? .ok("Alice understands everything Hermes sends")
            : .warning(
                "\(unknown.count) kinds of message not understood",
                "Hermes sent " + unknown.prefix(4).map(\.type).joined(separator: ", ") + ". A newer Hermes may need a newer Alice."
            )
    }

    // MARK: - Helpers

    static func preferencesBytes() -> Int {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id),
              let data = try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        else { return 0 }
        return data.count
    }

    static func conversationFileBytes() -> Int {
        guard let directory = FileConversationStorage.standardDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
