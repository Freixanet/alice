import SwiftUI
import UniformTypeIdentifiers

/// Native administration surface for the Hermes host behind Alice.
///
/// Reads are harmless and refreshable. Actions that can interrupt service or
/// erase/replace state require an explicit confirmation before Alice asks
/// Hermes to perform them. Hermes remains the source of truth for every state.
struct SystemScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles: [SystemProfile] = [.init(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var health: HermesHealthStatus?
    @State private var status: HermesSystemStatus?
    @State private var stats: HermesSystemStats?
    @State private var checkpoints: HermesCheckpoints?
    @State private var loading = false
    @State private var failure: String?

    @State private var activeAction: HermesActionStart?
    @State private var actionStatus: HermesActionStatus?
    @State private var actionFailure: String?

    @State private var selectedLog = "agent"
    @State private var logSearch = ""
    @State private var logs: HermesLogSnapshot?
    @State private var logsLoading = false

    @State private var backupArchive: String?
    @State private var backupLocalURL: URL?
    @State private var backupBusy = false
    @State private var importing = false
    @State private var restoreURL: URL?

    @State private var confirmStop = false
    @State private var confirmRestart = false
    @State private var confirmPrune = false

    private let logFiles = ["agent", "errors", "gateway", "gui", "desktop", "mcp"]

    var body: some View {
        List {
            overviewSection
            gatewaySection
            hostSection
            Section("Administration") {
                NavigationLink { SystemExtrasScreen() } label: {
                    Label("Advanced operations", systemImage: "gearshape.2")
                }
                .listRowBackground(Palette.card(scheme))
                Text("Credential pools, shell hooks, Curator, Nous Portal, Computer Use permissions and additional diagnostics.")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
            if activeAction != nil || actionStatus != nil || actionFailure != nil {
                actionSection
            }
            diagnosticsSection
            logsSection
            backupSection
            checkpointsSection

            if let failure {
                Section("Last error") {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task {
            await loadProfiles()
            await refreshAll()
        }
        .task(id: activeAction?.name) { await pollActiveAction() }
        .onChange(of: selectedProfile) { _, _ in
            status = nil
            Task { await refreshStatus() }
        }
        .onChange(of: selectedLog) { _, _ in
            Task { await loadLogs() }
        }
        .refreshableWithFeedback { await refreshAll() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refreshAll() } } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
                .accessibilityLabel("Refresh system status")
            }
        }
        .confirmationDialog(
            "Stop Hermes gateway?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("Stop gateway", role: .destructive) {
                Task { await runGateway("stop") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats and channel connections for this profile will stop until the gateway is started again.")
        }
        .confirmationDialog(
            "Restart Hermes gateway?",
            isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart") { Task { await runGateway("restart") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active connections for this profile will disconnect briefly and reconnect.")
        }
        .confirmationDialog(
            "Prune all rollback checkpoints?",
            isPresented: $confirmPrune,
            titleVisibility: .visible
        ) {
            Button("Prune checkpoints", role: .destructive) {
                Task { await pruneCheckpoints() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing /rollback points will be deleted. This cannot be undone.")
        }
        .confirmationDialog(
            "Restore this Hermes backup?",
            isPresented: Binding(
                get: { restoreURL != nil },
                set: { if !$0 { restoreURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore backup", role: .destructive) {
                if let url = restoreURL { Task { await restoreBackup(url) } }
            }
            Button("Cancel", role: .cancel) { restoreURL = nil }
        } message: {
            Text("Hermes will import the archive with force enabled. Live configuration and state may be overwritten.")
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.zip, .archive],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            restoreURL = url
        }
    }

    private var overviewSection: some View {
        Section("Health") {
            if loading && status == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking Hermes…").foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))
            } else if let status {
                HStack(spacing: 12) {
                    Image(systemName: status.overall == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(status.overall == "ok" ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        // "Degraded" is Hermes' word for "running, but one part
                        // isn't right", and read as though Hermes were failing.
                        Text(status.overall == "ok" ? "Hermes is working normally" : "Hermes is running, with a problem")
                            .font(.subheadline.weight(.semibold))
                        Text("v\(status.version)\(status.releaseDate.isEmpty ? "" : " · \(status.releaseDate)")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let health {
                        Text(health.ok ? "API OK" : "API error")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(health.ok ? .green : .red)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                ForEach(status.components) { component in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(component.status == "ok" ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(EventDigest.label(for: component.name))
                            if let detail = componentDetail(component, in: status) {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(component.status == "ok" ? "Working" : "Needs a look")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(component.status == "ok" ? .green : .orange)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if status.overall != "ok" {
                    Text("Hermes is still running and answering. “Needs a look” means one part of it isn't fully right — the line under it says which.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }

                HStack {
                    Label("Memory pressure", systemImage: "memorychip")
                    Spacer()
                    pressureBadge(status.memoryPressure)
                }
                .listRowBackground(Palette.card(scheme))

                HStack {
                    Label("Disk pressure", systemImage: "internaldrive")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        pressureBadge(status.diskPressure)
                        if let used = status.diskUsedPercent {
                            Text("\(used.formatted(.number.precision(.fractionLength(1))))% used")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Palette.card(scheme))
            } else {
                stateRow("System unavailable", detail: failure ?? "Hermes did not answer.", systemImage: "server.rack")
            }
        }
    }

    private var gatewaySection: some View {
        Section("Gateway") {
            Picker("Profile", selection: $selectedProfile) {
                ForEach(profiles) { profile in Text(profile.label).tag(profile.id) }
            }
            .listRowBackground(Palette.card(scheme))

            if let status {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(status.gatewayRunning ? Color.green : Color.orange)
                                .frame(width: 9, height: 9)
                            Text(gatewayStateLabel(status.gatewayState)).font(.subheadline.weight(.medium))
                        }
                        Text("\(status.activeAgents) active agents · \(status.activeSessions) active sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !status.gatewayMode.isEmpty {
                            Text("Mode: \(status.gatewayMode)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let reason = status.gatewayExitReason, !reason.isEmpty {
                            Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 8)
                    if status.gatewayBusy {
                        Text("BUSY").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                HStack(spacing: 8) {
                    if status.gatewayRunning {
                        Button(role: .destructive) { confirmStop = true } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    } else {
                        Button { Task { await runGateway("start") } } label: {
                            Label("Start", systemImage: "play.circle")
                        }
                    }
                    Button { confirmRestart = true } label: {
                        Label("Restart", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(activeAction?.name.hasPrefix("gateway-") == true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var hostSection: some View {
        Section("Host") {
            if let stats {
                LabeledContent("Host", value: stats.hostname)
                    .listRowBackground(Palette.card(scheme))
                LabeledContent("System", value: "\(stats.os) \(stats.osRelease) · \(stats.arch)")
                    .listRowBackground(Palette.card(scheme))
                LabeledContent("Python", value: "\(stats.pythonImplementation) \(stats.pythonVersion)")
                    .listRowBackground(Palette.card(scheme))
                LabeledContent("CPU", value: cpuSummary(stats))
                    .listRowBackground(Palette.card(scheme))
                if !stats.loadAverage.isEmpty {
                    LabeledContent(
                        "Load average",
                        value: stats.loadAverage.prefix(3).map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")
                    )
                    .listRowBackground(Palette.card(scheme))
                }
                if let memory = stats.memory {
                    resourceRow("Memory", resource: memory, systemImage: "memorychip")
                        .listRowBackground(Palette.card(scheme))
                }
                if let disk = stats.disk {
                    resourceRow("Disk", resource: disk, systemImage: "internaldrive")
                        .listRowBackground(Palette.card(scheme))
                }
                if let uptime = stats.uptimeSeconds {
                    LabeledContent("Host uptime", value: duration(uptime))
                        .listRowBackground(Palette.card(scheme))
                }
                if !stats.psutil {
                    Text("Hermes does not have psutil available, so detailed CPU/memory/disk metrics may be limited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }
            } else {
                stateRow("Host metrics unavailable", detail: "Pull to refresh to try again.", systemImage: "cpu")
            }
        }
    }

    private var actionSection: some View {
        Section("Current operation") {
            if let actionStatus {
                HStack {
                    Label(actionStatus.name, systemImage: "terminal")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(actionStatus.running ? "RUNNING" : (actionStatus.exitCode == 0 ? "DONE" : "EXIT \(actionStatus.exitCode.map(String.init) ?? "?")"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(actionStatus.running ? .orange : (actionStatus.exitCode == 0 ? .green : .red))
                }
                .listRowBackground(Palette.card(scheme))

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(actionStatus.lines.isEmpty ? "Starting…" : actionStatus.lines.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(minWidth: 520, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
                .listRowBackground(Palette.card(scheme))

                if !actionStatus.running {
                    Button("Close operation log") {
                        activeAction = nil
                        self.actionStatus = nil
                        actionFailure = nil
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } else if activeAction != nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Starting operation…").foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))
            }
            if let actionFailure {
                Text(actionFailure).font(.caption).foregroundStyle(.red)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            operationButton("Doctor", detail: "Run Hermes' built-in environment and configuration checks.", systemImage: "stethoscope") {
                try await store.runHermesDoctor()
            }
            operationButton("Security audit", detail: "Inspect Hermes security posture and configuration.", systemImage: "checkmark.shield") {
                try await store.runHermesSecurityAudit()
            }
            operationButton("Prompt size", detail: "Measure the effective prompt/context footprint.", systemImage: "text.word.spacing") {
                try await store.runHermesPromptSize()
            }
            operationButton("Diagnostic dump", detail: "Generate Hermes' diagnostic dump and show its output.", systemImage: "doc.text.magnifyingglass") {
                try await store.runHermesDump()
            }
            unknownEventsRow
        }
    }

    /// What this Hermes sends that Alice has not learnt. Empty most of the
    /// time; after a Hermes update, the first place a new event kind shows.
    @ViewBuilder
    private var unknownEventsRow: some View {
        let sightings = HermesUnknownEvents.shared.all
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sightings.isEmpty ? "checkmark.circle" : "questionmark.circle")
                .frame(width: 22)
                .foregroundStyle(sightings.isEmpty ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Event kinds Alice does not know")
                if sightings.isEmpty {
                    Text("None so far. Everything this Hermes has sent is understood.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(sightings.count) seen since launch. Alice keeps working; these are what to add next.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(sightings.enumerated()), id: \.offset) { _, sighting in
                        Text("\(sighting.type) ×\(sighting.count) · \(sighting.keys.joined(separator: ", "))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var logsSection: some View {
        Section("Logs") {
            Picker("Log", selection: $selectedLog) {
                ForEach(logFiles, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.menu)
            .listRowBackground(Palette.card(scheme))

            HStack(spacing: 8) {
                TextField("Search log", text: $logSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await loadLogs() } }
                Button { Task { await loadLogs() } } label: {
                    if logsLoading { ProgressView() } else { Image(systemName: "magnifyingglass") }
                }
                .disabled(logsLoading)
            }
            .listRowBackground(Palette.card(scheme))

            if let logs {
                if logs.lines.isEmpty {
                    Text(logSearch.isEmpty ? "No log lines." : "No matching log lines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(logs.lines.joined(separator: ""))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(minWidth: 640, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                    .listRowBackground(Palette.card(scheme))
                }
            } else if logsLoading {
                ProgressView("Loading logs…")
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var backupSection: some View {
        Section("Backup & restore") {
            Button {
                Task { await createBackup() }
            } label: {
                if backupBusy { ProgressView() } else { Label("Create Hermes backup", systemImage: "archivebox") }
            }
            .disabled(backupBusy || activeAction?.name == "backup")
            .listRowBackground(Palette.card(scheme))

            if let backupArchive {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest backup")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: backupArchive).lastPathComponent)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button {
                            Task { await downloadBackup() }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .disabled(backupBusy || actionStatus?.name == "backup" && actionStatus?.running == true)
                        if let backupLocalURL {
                            ShareLink(item: backupLocalURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .listRowBackground(Palette.card(scheme))
            }

            Button(role: .destructive) {
                importing = true
            } label: {
                Label("Restore from ZIP…", systemImage: "arrow.uturn.backward.circle")
            }
            .listRowBackground(Palette.card(scheme))

            Text("Restore is force-enabled only after confirmation. Hermes validates that the uploaded archive is a ZIP before starting the import.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        }
    }

    private var checkpointsSection: some View {
        Section("Rollback checkpoints") {
            if let checkpoints {
                HStack {
                    Text("Stored checkpoints")
                    Spacer()
                    Text("\(checkpoints.sessions.count) · \(ByteCountFormatter.string(fromByteCount: checkpoints.totalBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))

                ForEach(checkpoints.sessions) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.session).font(.caption.monospaced()).lineLimit(1)
                        Text("\(item.files) files · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                Button(role: .destructive) { confirmPrune = true } label: {
                    Label("Prune checkpoints", systemImage: "trash")
                }
                .disabled(checkpoints.sessions.isEmpty || activeAction?.name == "checkpoints-prune")
                .listRowBackground(Palette.card(scheme))
            } else {
                ProgressView("Loading checkpoints…")
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    @ViewBuilder
    private func pressureBadge(_ pressure: String) -> some View {
        Text(pressure.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(pressureTint(pressure))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pressureTint(pressure).opacity(0.12), in: Capsule())
    }

    /// What a component's status amounts to. For messaging apps a count alone
    /// ("2 of 3 connected") left "degraded" unexplained, so the channels that
    /// are not connected are named — along with the case that confuses most:
    /// a channel switched off keeps its last error here until Hermes restarts.
    private func componentDetail(
        _ component: HermesSystemComponent, in status: HermesSystemStatus
    ) -> String? {
        if EventDigest.isChannelRollup(component.name), component.status != "ok" {
            let broken = status.platforms.filter { !$0.isHealthy && $0.platform != "api_server" }
            if !broken.isEmpty {
                let names = broken.map { EventDigest.label(for: $0.platform) }.joined(separator: ", ")
                return "Not connected: \(names). If you switched one off, it stays listed until Hermes restarts."
            }
        }
        if let state = component.state { return state.replacingOccurrences(of: "_", with: " ") }
        if let configured = component.configured, let connected = component.connected {
            return "\(connected) of \(configured) connected"
        }
        return nil
    }

    private func pressureTint(_ pressure: String) -> Color {
        switch pressure {
        case "ok": .green
        case "elevated": .orange
        case "critical": .red
        default: .secondary
        }
    }

    @ViewBuilder
    private func resourceRow(
        _ title: String, resource: HermesSystemStats.Resource, systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(resource.percent.formatted(.number.precision(.fractionLength(1))))%")
                    .foregroundStyle(resource.percent >= 95 ? .red : .secondary)
            }
            Text("\(ByteCountFormatter.string(fromByteCount: resource.used, countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: resource.total, countStyle: .memory)) used")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func operationButton(
        _ title: String, detail: String, systemImage: String,
        operation: @escaping () async throws -> HermesActionStart
    ) -> some View {
        Button {
            Task { await startOperation(operation) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(activeAction?.name != nil && actionStatus?.running != false)
        .listRowBackground(Palette.card(scheme))
    }

    private func stateRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.card(scheme))
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        do {
            profiles = try await store.routineProfiles().map { .init(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) {
                selectedProfile = profiles.first?.id ?? "default"
            }
        } catch {
            profiles = [.init(id: "default", label: "Alice")]
        }
    }

    private func refreshAll() async {
        guard store.dashboardReady else {
            failure = "Connect the Hermes dashboard to administer this system."
            return
        }
        loading = true
        defer { loading = false }
        async let healthResult: HermesHealthStatus? = try? store.hermesHealth()
        async let statusResult: HermesSystemStatus? = try? store.hermesSystemStatus(profile: selectedProfile)
        async let statsResult: HermesSystemStats? = try? store.hermesSystemStats()
        async let checkpointsResult: HermesCheckpoints? = try? store.hermesCheckpoints()
        let results = await (healthResult, statusResult, statsResult, checkpointsResult)
        health = results.0
        status = results.1
        stats = results.2
        checkpoints = results.3
        if status == nil && health == nil {
            failure = "The Hermes dashboard did not return system status."
        } else {
            failure = nil
        }
        await loadLogs()
    }

    private func refreshStatus() async {
        do {
            status = try await store.hermesSystemStatus(profile: selectedProfile)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func runGateway(_ verb: String) async {
        do {
            let start = try await store.hermesGatewayAction(verb, profile: selectedProfile)
            begin(start)
        } catch {
            failure = reason(error)
        }
    }

    private func startOperation(_ operation: () async throws -> HermesActionStart) async {
        do {
            begin(try await operation())
        } catch {
            failure = reason(error)
        }
    }

    private func begin(_ start: HermesActionStart) {
        activeAction = start
        actionStatus = nil
        actionFailure = nil
    }

    private func pollActiveAction() async {
        guard let name = activeAction?.name else { return }
        while !Task.isCancelled {
            do {
                let current = try await store.hermesActionStatus(name, lines: 500)
                guard !Task.isCancelled, activeAction?.name == name else { return }
                actionStatus = current
                actionFailure = nil
                if !current.running {
                    await actionCompleted(name, exitCode: current.exitCode)
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                actionFailure = reason(error)
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }

    private func actionCompleted(_ name: String, exitCode: Int?) async {
        if name.hasPrefix("gateway-") || name == "import" {
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStatus()
        }
        if name == "checkpoints-prune" {
            checkpoints = try? await store.hermesCheckpoints()
        }
        if name == "backup", exitCode != 0 {
            backupArchive = nil
        }
    }

    private func loadLogs() async {
        guard store.dashboardReady else { return }
        logsLoading = true
        defer { logsLoading = false }
        do {
            logs = try await store.hermesLogs(
                file: selectedLog, lines: 200,
                search: logSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            failure = reason(error)
        }
    }

    private func createBackup() async {
        backupBusy = true
        defer { backupBusy = false }
        do {
            let start = try await store.runHermesBackup()
            backupArchive = start.archive
            backupLocalURL = nil
            begin(start)
        } catch {
            failure = reason(error)
        }
    }

    private func downloadBackup() async {
        guard let backupArchive else { return }
        backupBusy = true
        defer { backupBusy = false }
        do {
            let data = try await store.downloadHermesBackup(backupArchive)
            let name = URL(fileURLWithPath: backupArchive).lastPathComponent
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "alice-hermes-backups", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: name)
            try data.write(to: url, options: .atomic)
            backupLocalURL = url
        } catch {
            failure = reason(error)
        }
    }

    private func restoreBackup(_ url: URL) async {
        restoreURL = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count >= 4,
                  data.prefix(2) == Data([0x50, 0x4B]) else {
                failure = "The selected file does not look like a ZIP archive."
                return
            }
            begin(try await store.restoreHermesBackup(data: data, filename: url.lastPathComponent))
        } catch {
            failure = reason(error)
        }
    }

    private func pruneCheckpoints() async {
        do {
            begin(try await store.pruneHermesCheckpoints())
        } catch {
            failure = reason(error)
        }
    }

    private func cpuSummary(_ stats: HermesSystemStats) -> String {
        var pieces: [String] = []
        if let count = stats.cpuCount { pieces.append("\(count) cores") }
        if let percent = stats.cpuPercent {
            pieces.append("\(percent.formatted(.number.precision(.fractionLength(0))))%")
        }
        return pieces.isEmpty ? "Unavailable" : pieces.joined(separator: " · ")
    }

    private func gatewayStateLabel(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Hermes did not answer."
    }
}

private struct SystemProfile: Identifiable, Hashable {
    let id: String
    let label: String
}
