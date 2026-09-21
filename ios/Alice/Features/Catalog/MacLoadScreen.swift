import Charts
import SwiftUI

/// The full-screen page for one living artifact.
struct LibraryToolScreen: View {
    let tool: LibraryTool

    var body: some View {
        switch tool {
        case .mac: MacLoadScreen()
        }
    }
}

/// What is using this Mac right now, and what to do about it.
///
/// Leads with a verdict — what is going on, why, and the one app whose closing
/// would help most — then the trend of CPU and memory since the page opened,
/// then the apps themselves, each with its processes a tap away. The numbers
/// move on their own while the screen is open; leaving it stops the reading.
struct MacLoadScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var load: HostLoad?
    @State private var sort: HostLoadSort = .cpu
    @State private var failure: String?
    @State private var confirming: Stoppable?
    @State private var stoppingPID: Int?
    @State private var stopFailure: String?
    @State private var expanded: Set<String> = []
    /// Readings since the page opened, oldest first.
    @State private var history: [Sample] = []

    /// A few minutes at one reading every four seconds.
    private static let historyLength = 45

    private struct Sample: Identifiable, Equatable {
        let id: Int
        let cpu: Double
        let memory: Double
    }

    /// Something the person asked to stop: a whole app, or one of its processes.
    private struct Stoppable: Identifiable, Equatable {
        var id: Int { pid }
        let pid: Int
        let name: String
        let title: String
        let button: String
        let detail: String
    }

    var body: some View {
        Group {
            if let load {
                reading(load)
            } else if let failure {
                ContentUnavailableView(
                    "Mac", systemImage: "gauge.with.dots.needle.67percent",
                    description: Text(failure)
                )
            } else {
                ProgressView("Reading this Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(load?.host ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { liveBadge }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await watch() }
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { chosen in
            Button(chosen.button, role: .destructive) {
                confirming = nil
                Task { await stop(chosen) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { chosen in
            Text(chosen.detail)
        }
        .alert(
            "Couldn’t stop it",
            isPresented: Binding(get: { stopFailure != nil }, set: { if !$0 { stopFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stopFailure ?? "")
        }
        .accessibilityIdentifier("mac.load")
    }

    // MARK: - Page

    private func reading(_ load: HostLoad) -> some View {
        List {
            Section {
                verdictCard(load)
                    .listRowBackground(Palette.card(scheme))
            }

            Section {
                HStack(spacing: 12) {
                    gauge(
                        title: "CPU",
                        value: load.warming ? "—" : HostLoad.percent(load.cpuPercent, precise: false),
                        caption: "\(load.cores) cores · load \(String(format: "%.1f", load.load1))",
                        tone: tone(forCPU: load.cpuPercent, warming: load.warming),
                        series: history.map { ($0.id, $0.cpu) }
                    )
                    gauge(
                        title: "Memory",
                        value: HostLoad.bytes(load.memoryUsed),
                        caption: memoryCaption(load),
                        tone: tone(forPressure: load.memoryPressure),
                        series: history.map { ($0.id, $0.memory) }
                    )
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Sort", selection: $sort) {
                    ForEach(HostLoadSort.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                ForEach(ranked(load)) { group in
                    groupRow(group, in: load)
                        .listRowBackground(Palette.card(scheme))
                    if expanded.contains(group.id) {
                        ForEach(group.members) { member in
                            memberRow(member, of: group)
                                .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            } header: {
                Text(sort == .cpu ? "Busiest first" : "Largest first")
            } footer: {
                Text(footer(load))
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(failure == nil ? Palette.success(scheme) : Palette.warning(scheme))
                .frame(width: 7, height: 7)
            Text(failure == nil ? "Live" : "Paused")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(failure == nil ? "Live" : "Last refresh failed")
    }

    // MARK: - Verdict

    private func verdictCard(_ load: HostLoad) -> some View {
        let verdict = load.verdict()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: verdictSymbol(load))
                    .foregroundStyle(verdictTone(load))
                    .font(.headline)
                Text(verdict.headline)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = verdict.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remedy = verdict.remedy, let stoppable = stoppable(remedy) {
                Button {
                    confirming = stoppable
                } label: {
                    Label(
                        "Close \(remedy.name) · frees \(HostLoad.bytes(remedy.memory))",
                        systemImage: "xmark.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.accent.primary(scheme))
                .background(store.accent.primary(scheme).opacity(0.12), in: .capsule)
                .disabled(stoppingPID != nil)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private func verdictSymbol(_ load: HostLoad) -> String {
        if load.isSwapping || load.memoryPressure == "critical" { return "exclamationmark.triangle.fill" }
        if load.memoryPressure == "tight" || load.cpuPercent >= 75 { return "gauge.with.dots.needle.67percent" }
        return "checkmark.circle.fill"
    }

    private func verdictTone(_ load: HostLoad) -> Color {
        if load.isSwapping || load.memoryPressure == "critical" { return Palette.danger(scheme) }
        if load.memoryPressure == "tight" || load.cpuPercent >= 75 { return Palette.warning(scheme) }
        return Palette.success(scheme)
    }

    // MARK: - Gauges

    private func gauge(
        title: String, value: String, caption: String, tone: Color, series: [(Int, Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone == .primary ? Color.primary : tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Chart {
                ForEach(series, id: \.0) { point in
                    AreaMark(x: .value("t", point.0), y: .value(title, point.1))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [chartTint(tone).opacity(0.28), chartTint(tone).opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", point.0), y: .value(title, point.1))
                        .foregroundStyle(chartTint(tone))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: (series.first?.0 ?? 0)...max((series.first?.0 ?? 0) + Self.historyLength - 1, series.last?.0 ?? 0))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 38)
            .accessibilityHidden(true)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func chartTint(_ tone: Color) -> Color {
        tone == .primary ? store.accent.primary(scheme) : tone
    }

    private func memoryCaption(_ load: HostLoad) -> String {
        var caption = "of \(HostLoad.bytes(load.memoryTotal))"
        if load.swapUsed >= 512 * 1024 * 1024 {
            caption += " · \(HostLoad.bytes(load.swapUsed)) swap"
        }
        return caption
    }

    // MARK: - Rows

    private func groupRow(_ group: HostLoad.Group, in load: HostLoad) -> some View {
        let open = expanded.contains(group.id)
        return HStack(alignment: .center, spacing: 10) {
            Button {
                guard group.count > 1 else { return }
                if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(group.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if group.count > 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(open ? 90 : 0))
                                }
                            }
                            Text(subtitle(group))
                                .font(.caption)
                                .foregroundStyle(effectColor(group.effect))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(group.cpu.map { HostLoad.percent($0, precise: false) } ?? "—")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(sort == .cpu ? .primary : .secondary)
                            Text(HostLoad.bytes(group.memory))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(sort == .memory ? .primary : .secondary)
                        }
                        .contentTransition(.numericText())
                    }
                    shareBar(share(of: group, in: load))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(group.count > 1 ? (open ? "Hides its processes" : "Shows its processes") : "")

            if group.canStop, let stoppable = stoppable(group) {
                stopButton(label: "Close \(group.name)", pid: stoppable.pid) { confirming = stoppable }
            }
        }
        .padding(.vertical, 5)
    }

    private func memberRow(_ member: HostLoad.Process, of group: HostLoad.Group) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.muted(scheme))
                .frame(width: 2)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("pid \(member.pid)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(member.cpu.map { HostLoad.percent($0, precise: false) } ?? "—")
                    .font(.footnote)
                    .monospacedDigit()
                Text(HostLoad.bytes(member.memory))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if member.canStop {
                stopButton(label: "Stop \(member.name)", pid: member.pid) {
                    confirming = Stoppable(
                        pid: member.pid, name: member.name,
                        title: member.effect == "helper"
                            ? "Stop this part of \(member.affects ?? group.name)?"
                            : "Stop \(member.name)?",
                        button: "Stop \(member.name)",
                        detail: member.effectDetail.isEmpty
                            ? "\(member.name) will end." : member.effectDetail
                    )
                }
            }
        }
        .padding(.leading, 6)
    }

    private func stopButton(label: String, pid: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if stoppingPID == pid {
                    ProgressView()
                } else {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(stoppingPID != nil)
        .accessibilityLabel(label)
    }

    private func shareBar(_ share: Double) -> some View {
        Capsule()
            .fill(Palette.muted(scheme))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(store.accent.primary(scheme).opacity(0.6))
                        .frame(width: max(share > 0 ? 4 : 0, geo.size.width * share))
                }
            }
            .animation(.snappy(duration: 0.4), value: share)
            .accessibilityHidden(true)
    }

    private func subtitle(_ group: HostLoad.Group) -> String {
        let what = group.effectTitle.isEmpty ? nil : group.effectTitle
        let many = group.count > 1 ? "\(group.count) processes" : nil
        return [many, what].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Ordering

    private func ranked(_ load: HostLoad) -> [HostLoad.Group] {
        load.groups.sorted { lhs, rhs in
            switch sort {
            case .cpu:
                let left = lhs.cpu ?? -1
                let right = rhs.cpu ?? -1
                if left != right { return left > right }
                return lhs.memory > rhs.memory
            case .memory:
                if lhs.memory != rhs.memory { return lhs.memory > rhs.memory }
                return (lhs.cpu ?? -1) > (rhs.cpu ?? -1)
            }
        }
    }

    /// How much of the largest row this one is, so the eye finds the load.
    private func share(of group: HostLoad.Group, in load: HostLoad) -> Double {
        switch sort {
        case .cpu:
            let peak = load.groups.compactMap(\.cpu).max() ?? 0
            guard peak > 0, let cpu = group.cpu else { return 0 }
            return min(1, cpu / peak)
        case .memory:
            let peak = load.groups.map(\.memory).max() ?? 0
            guard peak > 0 else { return 0 }
            return min(1, Double(group.memory) / Double(peak))
        }
    }

    private func footer(_ load: HostLoad) -> String {
        if let failure { return failure }
        if load.warming { return "The first look only starts the clock. CPU appears on the next one." }
        return "Red keeps the Mac or Hermes running and can’t be stopped here. Amber closes an open app. Grey ends only that process."
    }

    private func effectColor(_ effect: String) -> Color {
        switch effect {
        case "session", "connection", "service", "hermes": Palette.danger(scheme)
        case "app", "helper": Palette.warning(scheme)
        default: Color.secondary
        }
    }

    private func tone(forCPU percent: Double, warming: Bool) -> Color {
        if warming { return .primary }
        if percent >= 90 { return Palette.danger(scheme) }
        if percent >= 75 { return Palette.warning(scheme) }
        return .primary
    }

    private func tone(forPressure pressure: String) -> Color {
        switch pressure {
        case "critical": Palette.danger(scheme)
        case "tight": Palette.warning(scheme)
        default: .primary
        }
    }

    // MARK: - Stopping

    private func stoppable(_ group: HostLoad.Group) -> Stoppable? {
        guard group.canStop, let pid = group.stopPid else { return nil }
        let name = group.stopName ?? group.name
        let app = group.effect == "app"
        return Stoppable(
            pid: pid, name: name,
            title: app ? "Close \(group.name)?" : "Stop \(group.name)?",
            button: app ? "Close \(group.name)" : "Stop \(group.name)",
            detail: group.effectDetail.isEmpty
                ? "\(group.name) will close. Unsaved work in it can be lost."
                : group.effectDetail
        )
    }

    private func stop(_ chosen: Stoppable) async {
        stoppingPID = chosen.pid
        defer { stoppingPID = nil }
        do {
            try await store.stopHostProcess(pid: chosen.pid, name: chosen.name)
            await refresh()
        } catch let DashboardClient.Failure.http(_, detail) {
            stopFailure = detail ?? "\(chosen.name) is still running."
        } catch {
            stopFailure = PlainWords.describe(error, doing: "stop \(chosen.name)")
        }
    }

    // MARK: - Reading

    /// An old plugin has no route for this. Say that, rather than that the Mac
    /// itself disappeared.
    private static func explain(_ error: Error, hadReading: Bool) -> String {
        if let failure = error as? DashboardClient.Failure, case .http(404, _) = failure {
            return "Update the Alice plugin on this Mac to see this live."
        }
        return PlainWords.describe(error, doing: hadReading ? "refresh this Mac" : "read this Mac")
    }

    /// Every four seconds, for as long as the screen is open.
    private func watch() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            await refresh()
            let pause = Duration.seconds(4) - started.duration(to: .now)
            if pause > .zero { try? await Task.sleep(for: pause) }
        }
    }

    private func refresh() async {
        do {
            let next = try await store.hostLoad()
            withAnimation(.snappy(duration: 0.35)) {
                load = next
                if !next.warming {
                    let id = (history.last?.id ?? -1) + 1
                    let memory = next.memoryTotal > 0
                        ? Double(next.memoryUsed) / Double(next.memoryTotal) : 0
                    history.append(Sample(id: id, cpu: min(1, next.cpuPercent / 100), memory: memory))
                    if history.count > Self.historyLength {
                        history.removeFirst(history.count - Self.historyLength)
                    }
                }
            }
            failure = nil
        } catch {
            // A miss keeps the last picture. Wiping it would look like the Mac
            // went quiet when the request merely failed.
            failure = Self.explain(error, hadReading: load != nil)
        }
    }
}
