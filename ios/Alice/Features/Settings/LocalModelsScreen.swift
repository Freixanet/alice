import SwiftUI

/// Machine-global control surface for Hermes' managed llama.cpp runtime.
/// Local runtime state belongs to the Hermes host, not to an individual bot profile.
struct LocalModelsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var status: LocalModelsStatus?
    @State private var hardware: LocalModelHardware?
    @State private var catalog: [LocalModelCatalogItem] = []
    @State private var jobs: [LocalModelJob] = []
    @State private var loading = false
    @State private var working = false
    @State private var failure: String?
    @State private var search = ""
    @State private var browsing = false

    @State private var confirmInstall = false
    @State private var confirmStop = false
    @State private var confirmQuickstart: LocalModelCatalogItem?
    @State private var confirmDownload: LocalModelCatalogItem?
    @State private var confirmDelete: LocalStagedModel?

    private var visibleCatalog: [LocalModelCatalogItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return catalog }
        return catalog.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || $0.detail.localizedCaseInsensitiveContains(q)
                || ($0.quant?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var recommended: LocalModelCatalogItem? {
        catalog.first { $0.recommended && $0.fits && !$0.needsEngine }
    }

    private var runningJobKey: String {
        jobs.filter(\.running).map(\.jobID).sorted().joined(separator: "|")
    }

    var body: some View {
        List {
            machineSection
            runtimeSection
            jobsSection
            downloadedSection
            catalogSection
            discoverSection
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
        .navigationTitle("Local Models")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .searchable(text: $search, prompt: "Search curated models")
        .task { await refreshAll() }
        .task(id: runningJobKey) { await pollRunningJobs() }
        .refreshableWithFeedback { await refreshAll() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refreshAll() } } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
            }
        }
        .sheet(isPresented: $browsing) {
            LocalModelBrowserSheet(onChanged: { Task { await refreshAll() } })
                .environment(store)
        }
        .confirmationDialog("Install the local model runtime?", isPresented: $confirmInstall) {
            Button(status?.updateAvailable == true ? "Update llama.cpp" : "Install llama.cpp") {
                Task { await installRuntime() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will download the llama.cpp build selected for this Mac. This can use significant disk space and network bandwidth.")
        }
        .confirmationDialog("Stop the local model server?", isPresented: $confirmStop) {
            Button("Stop server", role: .destructive) { Task { await setServer("stop") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All local model GPU memory will be freed and automatic local-runtime startup will remain disabled until you turn it on again.")
        }
        .confirmationDialog(
            "Set up this local model?",
            isPresented: Binding(
                get: { confirmQuickstart != nil },
                set: { if !$0 { confirmQuickstart = nil } }
            )
        ) {
            Button("Install & use") {
                if let item = confirmQuickstart { Task { await quickstart(item) } }
                confirmQuickstart = nil
            }
            Button("Cancel", role: .cancel) { confirmQuickstart = nil }
        } message: {
            if let item = confirmQuickstart {
                Text("Hermes will install the runtime if needed, download \(item.displayName) (\(item.sizeLabel)), start the server and make it the host default for new chats.")
            }
        }
        .confirmationDialog(
            "Download this model?",
            isPresented: Binding(
                get: { confirmDownload != nil },
                set: { if !$0 { confirmDownload = nil } }
            )
        ) {
            Button("Download") {
                if let item = confirmDownload { Task { await download(item) } }
                confirmDownload = nil
            }
            Button("Cancel", role: .cancel) { confirmDownload = nil }
        } message: {
            if let item = confirmDownload {
                Text("Download \(item.displayName) (\(item.sizeLabel)) to this Hermes host?")
            }
        }
        .confirmationDialog(
            "Delete this local model?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            )
        ) {
            Button("Delete model", role: .destructive) {
                if let model = confirmDelete { Task { await delete(model) } }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            if let model = confirmDelete {
                Text("Hermes will remove every GGUF part and private asset belonging to \(model.id). This cannot be undone without downloading or sideloading it again.")
            }
        }
    }

    private var machineSection: some View {
        Section("This Hermes host") {
            if let hardware {
                HStack {
                    Label(hardware.uma ? "Unified memory" : "GPU memory", systemImage: "memorychip")
                    Spacer()
                    Text(bytes(hardware.vramTotalBytes)).foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))

                LabeledContent("Usable for local models", value: bytes(hardware.vramUsableBytes))
                    .listRowBackground(Palette.card(scheme))
                LabeledContent("System RAM available", value: bytes(hardware.ramAvailableBytes))
                    .listRowBackground(Palette.card(scheme))

                if let name = hardware.gpuName {
                    LabeledContent("GPU", value: name)
                        .listRowBackground(Palette.card(scheme))
                }
                if let util = hardware.gpuUtilPercent {
                    LabeledContent("GPU utilization", value: "\(util)%")
                        .listRowBackground(Palette.card(scheme))
                }
            } else if loading {
                ProgressView("Reading hardware…")
                    .listRowBackground(Palette.card(scheme))
            }
            if let status {
                Text(status.modelsDir)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var runtimeSection: some View {
        Section("llama.cpp runtime") {
            if let status {
                HStack(spacing: 10) {
                    Circle()
                        .fill(status.runtimeInstalled ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.runtimeInstalled ? "Runtime installed" : "Runtime not installed")
                            .font(.subheadline.weight(.medium))
                        Text(runtimeDetail(status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status.updateAvailable {
                        Text("UPDATE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                HStack(spacing: 8) {
                    Button { confirmInstall = true } label: {
                        Label(status.updateAvailable ? "Update engine" : "Install engine", systemImage: "arrow.down.circle")
                    }
                    .disabled(working || (!status.updateAvailable && status.runtimeInstalled))

                    if status.serverRunning {
                        Button(role: .destructive) { confirmStop = true } label: {
                            Label("Stop server", systemImage: "stop.circle")
                        }
                    } else if status.runtimeInstalled {
                        Button { Task { await setServer("start") } } label: {
                            Label("Start server", systemImage: "play.circle")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .listRowBackground(Palette.card(scheme))

                if let item = recommended {
                    Button {
                        confirmQuickstart = item
                    } label: {
                        Label("Quickstart \(item.displayName)", systemImage: "bolt.circle")
                    }
                    .disabled(working || jobs.contains(where: \.running))
                    .listRowBackground(Palette.card(scheme))
                } else if !catalog.isEmpty && !catalog.contains(where: { $0.fits && !$0.needsEngine }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("No curated model fits the current memory budget", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("You can still browse Hugging Face or sideload a GGUF manually, but Hermes' curated catalog does not currently recommend a safe quickstart on this machine.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if status.serverRunning, let url = status.serverBaseURL {
                    LabeledContent("Server", value: url)
                        .font(.caption)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    @ViewBuilder
    private var jobsSection: some View {
        if !jobs.isEmpty {
            Section("Recent local-model operations") {
                ForEach(jobs.prefix(8)) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.target).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(job.phase.replacingOccurrences(of: "-", with: " ").capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(jobStatus(job))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(jobTint(job))
                        }
                        if job.running, let fraction = jobFraction(job) {
                            ProgressView(value: fraction)
                        }
                        if !job.detail.isEmpty {
                            Text(job.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = job.error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let total = job.totalBytes, total > 0 {
                            Text("\(bytes(job.doneBytes)) of \(bytes(total))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    private var downloadedSection: some View {
        Section("Downloaded models") {
            if let status, status.models.isEmpty {
                Text("No GGUF models are staged on this host.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            } else if let status {
                ForEach(status.models) { model in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(model.id).font(.subheadline.weight(.medium)).lineLimit(2)
                                    if model.id == status.activeModelID {
                                        Text("DEFAULT")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary)
                                if let loaded = status.loadedModels[model.id] {
                                    Text(loaded.capitalized).font(.caption2).foregroundStyle(.orange)
                                }
                                if let placement = status.placement[model.id] {
                                    Text(placementText(placement)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                        }

                        if let progress = status.loading[model.id] {
                            VStack(alignment: .leading, spacing: 3) {
                                if let pct = progress.percent {
                                    ProgressView(value: max(0, min(100, pct)), total: 100)
                                } else {
                                    ProgressView()
                                }
                                Text(progress.stage.capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 8) {
                            if model.id != status.activeModelID, status.runtimeInstalled {
                                Button("Use") { Task { await activate(model.id) } }
                            }
                            if status.loadedModels[model.id] != nil {
                                Button("Eject") { Task { await eject(model.id) } }
                            }
                            Button("Delete", role: .destructive) { confirmDelete = model }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if !status.runtimeInstalled, model.id != status.activeModelID {
                            Text("Install the local engine before activating this model.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    private var catalogSection: some View {
        Section("Curated for this machine") {
            if catalog.isEmpty && !loading {
                Text("Hermes returned no curated local models.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }
            ForEach(visibleCatalog, id: \LocalModelCatalogItem.id) { (item: LocalModelCatalogItem) in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.displayName).font(.subheadline.weight(.semibold))
                        if item.recommended {
                            Text("RECOMMENDED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text(item.sizeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        fitBadge(item)
                        if item.vision { badge("Vision", tint: .blue) }
                        if item.mtp { badge("MTP", tint: .purple) }
                        Text(item.nativeContextLabel)
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(item.fitSummary).font(.caption).foregroundStyle(item.fits ? Color.secondary : Color.orange)
                    if let detail = item.fitDetail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.needsEngine, let minimum = item.minEngine {
                        Text("Requires llama.cpp \(minimum) or newer.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if item.downloaded, let id = item.downloadedModelID {
                        HStack(spacing: 8) {
                            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            if id != status?.activeModelID, status?.runtimeInstalled == true {
                                Button("Use") { Task { await activate(id) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            } else if id != status?.activeModelID, status?.runtimeInstalled != true {
                                Text("Install engine first")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    } else if item.fits && !item.needsEngine {
                        HStack(spacing: 8) {
                            Button("Download") { confirmDownload = item }
                                .buttonStyle(.bordered).controlSize(.small)
                            if !statusRuntimeReady {
                                Button("Install & use") { confirmQuickstart = item }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                            }
                        }
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var discoverSection: some View {
        Section("More models") {
            Button { browsing = true } label: {
                HStack {
                    Label("Browse Hugging Face GGUF models", systemImage: "magnifyingglass")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .listRowBackground(Palette.card(scheme))
            Text("Hugging Face results are outside Hermes' curated catalog. Fit is estimated from file size before download and refined from the GGUF after staging.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        }
    }

    private var statusRuntimeReady: Bool {
        status?.runtimeInstalled == true && status?.serverRunning == true
    }

    @ViewBuilder
    private func fitBadge(_ item: LocalModelCatalogItem) -> some View {
        if item.fits {
            badge(item.spilled == true ? "Uses RAM" : "Fits", tint: item.spilled == true ? .orange : .green)
        } else {
            badge("Too large", tint: .red)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func refreshAll() async {
        guard store.dashboardReady else {
            failure = "Connect the Hermes dashboard to manage local models."
            return
        }
        loading = true
        defer { loading = false }
        do {
            async let s = store.localModelsStatus()
            async let h = store.localModelHardware()
            async let c = store.localModelCatalog()
            async let j = store.localModelJobs()
            let result = try await (s, h, c, j)
            status = result.0
            hardware = result.1
            catalog = result.2
            jobs = result.3
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func refreshLive() async {
        do {
            async let s = store.localModelsStatus()
            async let j = store.localModelJobs()
            let result = try await (s, j)
            let wasRunning = jobs.contains(where: \.running)
            status = result.0
            jobs = result.1
            if wasRunning && !jobs.contains(where: \.running) {
                catalog = (try? await store.localModelCatalog()) ?? catalog
            }
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func pollRunningJobs() async {
        guard !runningJobKey.isEmpty else { return }
        while !Task.isCancelled {
            await refreshLive()
            if !jobs.contains(where: \.running) { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func installRuntime() async {
        await run {
            _ = try await store.installLocalRuntime()
            await refreshLive()
        }
    }

    private func quickstart(_ item: LocalModelCatalogItem) async {
        await run {
            _ = try await store.quickstartLocalModel(item.id)
            await refreshLive()
        }
    }

    private func download(_ item: LocalModelCatalogItem) async {
        await run {
            _ = try await store.downloadLocalModel(item.id)
            await refreshLive()
        }
    }

    private func activate(_ modelID: String) async {
        await run {
            _ = try await store.activateLocalModel(modelID)
            await refreshLive()
        }
    }

    private func eject(_ modelID: String) async {
        await run {
            try await store.ejectLocalModel(modelID)
            await refreshLive()
        }
    }

    private func delete(_ model: LocalStagedModel) async {
        await run {
            try await store.deleteLocalModel(model.id)
            await refreshAll()
        }
    }

    private func setServer(_ action: String) async {
        await run {
            try await store.setLocalModelServer(action)
            await refreshAll()
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await operation()
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func runtimeDetail(_ status: LocalModelsStatus) -> String {
        var parts = [status.tag]
        if let backend = status.runtimeBackend { parts.append(backend) }
        parts.append(status.serverRunning ? "server running" : "server stopped")
        return parts.joined(separator: " · ")
    }

    private func placementText(_ placement: LocalModelPlacement) -> String {
        var parts: [String] = []
        if let granted = placement.grantedWindowLabel ?? placement.windowLabel { parts.append("context \(granted)") }
        if placement.spilled == true { parts.append("RAM spill") }
        return parts.isEmpty ? "Placement available" : parts.joined(separator: " · ")
    }

    private func jobStatus(_ job: LocalModelJob) -> String {
        if job.running { return job.percent.map { "\(Int($0))%" } ?? "RUNNING" }
        return job.status == "done" ? "DONE" : "ERROR"
    }

    private func jobTint(_ job: LocalModelJob) -> Color {
        job.running ? .orange : (job.status == "done" ? .green : .red)
    }

    private func jobFraction(_ job: LocalModelJob) -> Double? {
        if let percent = job.percent { return max(0, min(1, percent / 100)) }
        if let total = job.totalBytes, total > 0 { return max(0, min(1, Double(job.doneBytes) / Double(total))) }
        return nil
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private struct LocalModelBrowserSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let onChanged: () -> Void

    @State private var query = ""
    @State private var hits: [LocalModelHFHit] = []
    @State private var selectedRepo: String?
    @State private var files: [LocalModelHFFileGroup] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var pendingDownload: LocalModelHFFileGroup?
    @State private var hostPath = ""
    @State private var sideloadResult: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Search Hugging Face") {
                    HStack {
                        TextField("Model, author or repo", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        Button { Task { await search() } } label: {
                            if loading && selectedRepo == nil { ProgressView() } else { Image(systemName: "magnifyingglass") }
                        }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    }
                }

                if let selectedRepo {
                    Section {
                        Button("Back to results") {
                            self.selectedRepo = nil
                            files = []
                            failure = nil
                        }
                        ForEach(files) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(file.label).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(bytes(file.totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    fitBadge(file.fit)
                                    Text(file.paths.count == 1 ? file.paths[0] : "\(file.paths.count) split GGUF parts")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Button("Download") { pendingDownload = file }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(loading)
                            }
                        }
                        if loading { ProgressView("Loading repository…") }
                    } header: {
                        Text(selectedRepo)
                    } footer: {
                        Text("Fit is a rough pre-download estimate. Hermes reads the real GGUF header after staging and then applies its runtime placement policy.")
                    }
                } else if !hits.isEmpty {
                    Section("Results") {
                        ForEach(hits) { hit in
                            Button { Task { await open(hit) } } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(hit.repo).font(.subheadline).foregroundStyle(.primary)
                                            if hit.gated {
                                                Text("GATED").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                                            }
                                        }
                                        Text("\(hit.downloads.formatted()) downloads · \(hit.likes.formatted()) likes\(hit.updated.isEmpty ? "" : " · \(hit.updated)")")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Sideload a GGUF already on the Mac") {
                    TextField("/absolute/path/model.gguf", text: $hostPath, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Register host file") { Task { await sideload() } }
                        .disabled(!hostPath.lowercased().hasSuffix(".gguf") || loading)
                    Text("This path is on the Hermes Mac, not on the iPhone. Hermes links the file into its managed models directory when possible; the original stays in place.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let sideloadResult {
                        Text(sideloadResult).font(.caption).foregroundStyle(.green)
                    }
                }

                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("Find Local Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Download this GGUF?",
                isPresented: Binding(
                    get: { pendingDownload != nil },
                    set: { if !$0 { pendingDownload = nil } }
                )
            ) {
                Button("Download") {
                    if let file = pendingDownload, let repo = selectedRepo {
                        Task { await download(repo: repo, file: file) }
                    }
                    pendingDownload = nil
                }
                Button("Cancel", role: .cancel) { pendingDownload = nil }
            } message: {
                if let file = pendingDownload {
                    Text("Hermes will download \(file.label) (\(bytes(file.totalBytes))) into its managed models directory.")
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        defer { loading = false }
        selectedRepo = nil
        files = []
        do {
            hits = try await store.searchLocalModels(q)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func open(_ hit: LocalModelHFHit) async {
        selectedRepo = hit.repo
        files = []
        loading = true
        defer { loading = false }
        do {
            files = try await store.localModelRepoFiles(hit.repo)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func download(repo: String, file: LocalModelHFFileGroup) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await store.downloadBrowsedLocalModel(repo: repo, paths: file.paths)
            failure = nil
            onChanged()
        } catch {
            failure = reason(error)
        }
    }

    private func sideload() async {
        let path = hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await store.sideloadLocalModel(path: path)
            sideloadResult = result.alreadyPresent ? "\(result.modelID) was already registered." : "Registered \(result.modelID)."
            failure = nil
            onChanged()
        } catch {
            failure = reason(error)
        }
    }

    private func fitBadge(_ fit: String) -> some View {
        let (label, tint): (String, Color) = switch fit {
        case "fits-gpu": ("Fits GPU", .green)
        case "needs-ram": ("Uses RAM", .orange)
        case "too-big": ("Too large", .red)
        default: ("Unknown", .secondary)
        }
        return Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
