import SwiftUI
import UIKit

/// Settings › Developer: whether everything works, at a glance, and the tools
/// to find out why when it does not.
///
/// Quiet by design — one status card, rows that open to explain themselves,
/// tools a tap away — so it can stay on while Alice is used for real.
struct DeveloperScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Notifier.self) private var notifier
    @Environment(\.colorScheme) private var scheme

    @AppStorage(PerformanceHUD.key) private var showsHUD = false
    @State private var results: [String: CheckResult] = [:]
    @State private var running = false
    @State private var lastRun: Date?
    @State private var open: Set<String> = []
    @State private var toast: String?
    @State private var logLines: [String] = []
    @State private var onlyProblems = false

    var body: some View {
        List {
            Section { summaryCard }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            Section {
                ForEach(DiagnosticChecks.all) { check in
                    checkRow(check)
                }
            } header: {
                HStack {
                    Text("Checks")
                    Spacer()
                    if let lastRun {
                        Text(lastRun.formatted(date: .omitted, time: .shortened))
                            .textCase(nil)
                    }
                }
            }

            Section {
                Toggle(isOn: $showsHUD) {
                    Label("Performance meter", systemImage: "speedometer")
                }
            } header: {
                Text("Live")
            } footer: {
                Text("A small meter at the top of the screen shows frames per second and freezes as they happen. While developer mode is on, each reply also shows its model, tokens and tools.")
            }

            Section("Tools") {
                NavigationLink { ComponentGallery() } label: {
                    Label("Component gallery", systemImage: "square.grid.2x2")
                }
                ShareLink(item: report()) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task {
                        let sent = await store.pushDiagnostics(force: true)
                        show(sent ? "Sent to Hermes — ask Alice “what's wrong with the app?”" : "Hermes did not take it")
                    }
                } label: {
                    Label("Send diagnostics to Hermes", systemImage: "paperplane")
                }
                Button {
                    Task { await sendTestNotification() }
                } label: {
                    Label("Send a test notification", systemImage: "bell")
                }
                Menu {
                    Button("Show gesture tips again") {
                        GestureTips.showAgainNextLaunch()
                        show("Tips show at the next launch")
                    }
                    Button("Forget events added from cards") {
                        UserDefaults.standard.removeObject(forKey: "alice.calendar.added")
                        show("Event cards are ready again")
                    }
                    Button("Clear freezes this session") {
                        HitchMonitor.shared.reset()
                        show("Cleared")
                    }
                    Button("Let Alice announce replies again") {
                        store.barkRelays = false
                        show("Bark relay off")
                    }
                } label: {
                    Label("Reset…", systemImage: "arrow.counterclockwise")
                }
            }
            .foregroundStyle(.primary)

            Section {
                if visibleLog.isEmpty {
                    Text(onlyProblems ? "Nothing went wrong recently." : "Nothing recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(visibleLog.enumerated()), id: \.offset) { _, line in
                        logRow(line)
                    }
                }
            } header: {
                HStack {
                    Text("Recent activity")
                    Spacer()
                    Button(onlyProblems ? "All" : "Problems") { onlyProblems.toggle() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            } footer: {
                Text("Ids, states and timings only — never what was said.")
            }

            Section("This build") {
                let build = AliceBuildInfo.current
                LabeledContent("Version", value: "\(build.version) (\(build.build))")
                if let revision = build.revision { LabeledContent("Revision", value: revision) }
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await runChecks() }
        .task {
            loadLog()
            await runChecks()
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: toast)
        .animation(.snappy(duration: 0.25), value: open)
    }

    // MARK: Summary

    private var worstState: CheckResult.State {
        results.values.map(\.state).max() ?? .idle
    }

    private var attention: Int {
        results.values.filter { $0.state >= .warning }.count
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint(running ? .idle : worstState).opacity(0.15))
                if running {
                    ProgressView()
                } else {
                    Image(systemName: symbol(worstState))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint(worstState))
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                Text(running ? "Checking \(DiagnosticChecks.all.count) things…" : "\(DiagnosticChecks.all.count) checks · pull to run again")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .padding(.vertical, 4)
    }

    private var headline: String {
        if running && results.isEmpty { return "Checking…" }
        switch worstState {
        case .failure, .warning: return attention == 1 ? "1 thing needs attention" : "\(attention) things need attention"
        case .ok, .idle: return "Everything works"
        }
    }

    // MARK: Rows

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        let result = results[check.id]
        let expanded = open.contains(check.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                guard result?.detail != nil else { return }
                if expanded { open.remove(check.id) } else { open.insert(check.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: check.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.accent.primary(scheme))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .foregroundStyle(.primary)
                        Text(result?.summary ?? "…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }
                    Spacer(minLength: 8)
                    Circle()
                        .fill(tint(result?.state ?? .idle))
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(label(result?.state ?? .idle))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded, let detail = result?.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func logRow(_ line: String) -> some View {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let time = parts.first.flatMap { ISO8601DateFormatter().date(from: $0) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time?.formatted(date: .omitted, time: .standard) ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(parts.count > 1 ? parts[1] : line)
                .font(.caption.monospaced())
                .foregroundStyle(Self.isProblem(line) ? Palette.warning(scheme) : .secondary)
                .lineLimit(2)
        }
    }

    // MARK: Work

    private func runChecks() async {
        running = true
        defer { running = false; lastRun = Date() }
        for check in DiagnosticChecks.all {
            results[check.id] = await check.run(store, notifier)
        }
        loadLog()
    }

    private func loadLog() {
        logLines = Array(DiagnosticsLog.recentLines(limit: 120).reversed())
    }

    private var visibleLog: [String] {
        Array((onlyProblems ? logLines.filter(Self.isProblem) : logLines).prefix(60))
    }

    private static func isProblem(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["fail", "error", "timeout", "losttouch", "reconnecting", "endedunseen", "stall"].contains { lower.contains($0) }
    }

    private func sendTestNotification() async {
        await notifier.refreshPermission()
        guard notifier.permission.canDeliver else {
            show("Notifications are off for Alice")
            return
        }
        await notifier.post(AliceEvent(
            id: "developer.test.\(UUID().uuidString)", kind: .recovered, severity: .informational,
            profile: nil, title: "Alice", summary: "Test notification — they reach you.", occurred: Date()
        ))
        show("Sent — it shows as a banner if Alice is in the background")
    }

    private func show(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    /// Everything this screen knows, as text to share with whoever is looking
    /// into a problem. No message contents.
    private func report() -> String {
        let build = AliceBuildInfo.current
        var lines = [
            "Alice \(build.version) (\(build.build))\(build.revision.map { " · \($0)" } ?? "")",
            "iOS \(UIDevice.current.systemVersion) · Low Power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")",
            "Report \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
        ]
        for check in DiagnosticChecks.all {
            let result = results[check.id]
            lines.append("[\(label(result?.state ?? .idle))] \(check.title): \(result?.summary ?? "not run")")
            if let detail = result?.detail { lines.append("    \(detail)") }
        }
        lines.append("")
        lines.append("Recent activity:")
        lines += DiagnosticsLog.recentLines(limit: 200)
        return lines.joined(separator: "\n")
    }

    // MARK: Look

    private func tint(_ state: CheckResult.State) -> Color {
        switch state {
        case .ok: Palette.success(scheme)
        case .warning: Palette.warning(scheme)
        case .failure: Palette.danger(scheme)
        case .idle: Color.secondary.opacity(0.5)
        }
    }

    private func symbol(_ state: CheckResult.State) -> String {
        switch state {
        case .ok, .idle: "checkmark"
        case .warning: "exclamationmark"
        case .failure: "xmark"
        }
    }

    private func label(_ state: CheckResult.State) -> String {
        switch state {
        case .ok: "OK"
        case .warning: "Needs attention"
        case .failure: "Failing"
        case .idle: "Not applicable"
        }
    }
}
