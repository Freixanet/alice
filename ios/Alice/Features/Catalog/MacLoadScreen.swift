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

/// What is using this Mac right now. The numbers move on their own while the
/// screen is open; leaving it stops the reading.
struct MacLoadScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var load: HostLoad?
    @State private var sort: HostLoadSort = .cpu
    @State private var failure: String?
    @State private var confirmingStop: HostLoad.Process?
    @State private var stoppingPID: Int?
    @State private var stopFailure: String?

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
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(failure == nil ? Palette.success(scheme) : Palette.warning(scheme))
                            .frame(width: 8, height: 8)
                        Text("Live")
                            .lineLimit(1)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityLabel(failure == nil ? "Live" : "Live, last refresh failed")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await watch() }
        .accessibilityIdentifier("mac.load")
    }

    private func reading(_ load: HostLoad) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(load.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(load.focus(sortedBy: sort))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 16) {
                        meter(
                            title: "CPU",
                            value: load.warming ? "—" : HostLoad.percent(load.cpuPercent, precise: true),
                            share: load.warming ? 0 : load.cpuPercent / 100,
                            caption: load.warming
                                ? "Measuring…"
                                : "\(load.cores) cores · load \(String(format: "%.1f", load.load1))",
                            tone: tone(forCPU: load.cpuPercent, warming: load.warming)
                        )
                        meter(
                            title: "Memory",
                            value: HostLoad.bytes(load.memoryUsed),
                            share: load.memoryTotal > 0
                                ? Double(load.memoryUsed) / Double(load.memoryTotal) : 0,
                            caption: "of \(HostLoad.bytes(load.memoryTotal))",
                            tone: tone(forPressure: load.memoryPressure)
                        )
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Palette.card(scheme))
            }

            Section {
                Picker("Sort", selection: $sort) {
                    ForEach(HostLoadSort.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                ForEach(ranked(load)) { process in
                    processRow(process, in: load)
                }
            } footer: {
                Text(footer(load))
            }
        }
        .confirmationDialog(
            confirmingStop.map(stopTitle) ?? "",
            isPresented: Binding(
                get: { confirmingStop != nil },
                set: { if !$0 { confirmingStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let process = confirmingStop {
                Button(stopButton(process), role: .destructive) {
                    let chosen = process
                    confirmingStop = nil
                    Task { await stop(chosen) }
                }
            }
            Button("Cancel", role: .cancel) { confirmingStop = nil }
        } message: {
            if let process = confirmingStop {
                Text(process.effectDetail.isEmpty
                     ? "\(process.name) will close. Unsaved work in it can be lost."
                     : process.effectDetail)
            }
        }
        .alert(
            "Couldn’t stop it",
            isPresented: Binding(get: { stopFailure != nil }, set: { if !$0 { stopFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stopFailure ?? "")
        }
    }

    private func meter(
        title: String, value: String, share: Double, caption: String, tone: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                Capsule()
                    .fill(Palette.muted(scheme))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tone)
                            .frame(width: max(0, geo.size.width * min(1, share)))
                    }
            }
            .frame(height: 6)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processRow(_ process: HostLoad.Process, in load: HostLoad) -> some View {
        let share = share(of: process, in: load)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("pid \(process.pid)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if !process.effectTitle.isEmpty {
                            Text(process.effectTitle)
                                .font(.caption2)
                                .foregroundStyle(effectColor(process))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(process.cpu.map { HostLoad.percent($0, precise: false) } ?? "—")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(HostLoad.bytes(process.memory))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Capsule()
                    .fill(Palette.muted(scheme))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(store.accent.primary(scheme).opacity(0.55))
                                .frame(width: max(0, geo.size.width * share))
                        }
                    }
                    .accessibilityHidden(true)
            }
            if process.canStop {
                Button {
                    confirmingStop = process
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Palette.danger(scheme))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(stoppingPID == process.pid)
                .accessibilityLabel("Stop \(process.name)")
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Palette.card(scheme))
    }

    private func ranked(_ load: HostLoad) -> [HostLoad.Process] {
        load.processes.sorted { lhs, rhs in
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

    /// How much of the busiest row this one is, so the eye finds the load.
    private func share(of process: HostLoad.Process, in load: HostLoad) -> Double {
        switch sort {
        case .cpu:
            let peak = load.processes.compactMap(\.cpu).max() ?? 0
            guard peak > 0, let cpu = process.cpu else { return 0 }
            return min(1, cpu / peak)
        case .memory:
            let peak = load.processes.map(\.memory).max() ?? 0
            guard peak > 0 else { return 0 }
            return min(1, Double(process.memory) / Double(peak))
        }
    }

    private func footer(_ load: HostLoad) -> String {
        if let failure {
            return failure
        }
        if load.warming {
            return "The first look only starts the clock. CPU appears on the next one."
        }
        return "Highest use first. Red can interrupt the Mac. Amber touches an open app. Grey ends only that process."
    }

    private func stopTitle(_ process: HostLoad.Process) -> String {
        switch process.effect {
        case "service": "Stop \(process.name) anyway?"
        case "app": "Close \(process.affects ?? process.name)?"
        case "helper": "Stop this part of \(process.affects ?? process.name)?"
        default: "Stop \(process.name)?"
        }
    }

    private func stopButton(_ process: HostLoad.Process) -> String {
        switch process.effect {
        case "service": "Stop anyway"
        case "app": "Close \(process.affects ?? process.name)"
        default: "Stop \(process.name)"
        }
    }

    private func effectColor(_ process: HostLoad.Process) -> Color {
        switch process.effect {
        case "session", "connection", "service": Palette.danger(scheme)
        case "app", "helper": Palette.warning(scheme)
        default: Color.secondary
        }
    }

    private func stop(_ process: HostLoad.Process) async {
        stoppingPID = process.pid
        defer { stoppingPID = nil }
        do {
            try await store.stopHostProcess(pid: process.pid, name: process.name)
            await refresh()
        } catch let DashboardClient.Failure.http(_, detail) {
            stopFailure = detail ?? "That process is still running."
        } catch {
            stopFailure = PlainWords.describe(error, doing: "stop \(process.name)")
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

    /// An old plugin has no route for this. Say that, rather than that the Mac
    /// itself disappeared.
    private static func explain(_ error: Error, hadReading: Bool) -> String {
        if let failure = error as? DashboardClient.Failure, case .http(404, _) = failure {
            return "Update the Alice plugin on this Mac to see this live."
        }
        return PlainWords.describe(error, doing: hadReading ? "refresh this Mac" : "read this Mac")
    }

    /// Every few seconds, for as long as the screen is open.
    private func watch() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            await refresh()
            let spent = started.duration(to: .now)
            let pause = Duration.seconds(4) - spent
            if pause > .zero {
                try? await Task.sleep(for: pause)
            }
        }
    }

    private func refresh() async {
        do {
            load = try await store.hostLoad()
            failure = nil
        } catch {
            // A miss keeps the last picture. Wiping it would look like the Mac
            // went quiet when the request merely failed.
            let said = Self.explain(error, hadReading: load != nil)
            failure = said
        }
    }
}
