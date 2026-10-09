import SwiftUI

struct TaskBoard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var snapshot: ReviewTaskSnapshot?
    @State private var failure: String?
    @State private var selected: ReviewTask?
    @State private var configuring = false
    @State private var busy = false
    private let columns: [(String, [ReviewTask.Status])] = [
        (String(localized: "Backlog"), [.backlog]),
        (String(localized: "In progress"), [.inProgress, .failed]),
        (String(localized: "Needs review"), [.needsReview, .blocked]),
        (String(localized: "Done"), [.done]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Multi-step work lives here. Quick questions stay in chat.")
                    .foregroundStyle(.secondary)
                if snapshot?.tasks.isEmpty == true {
                    Text("Ask Alice in chat to prepare something, investigate a problem or carry out a task. She’ll track the work here.")
                }
                if let failure { Text(failure).foregroundStyle(Palette.danger(scheme)) }
                if let snapshot {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(columns, id: \.0) { title, statuses in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(title).font(.headline)
                                    let tasks = snapshot.tasks.filter { statuses.contains($0.status) }
                                    if tasks.isEmpty { Text("No tasks").foregroundStyle(.secondary).font(.subheadline) }
                                    ForEach(tasks) { task in
                                        Button { selected = task } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(task.title).font(.headline).foregroundStyle(.primary)
                                                Text(task.status.label).font(.caption).foregroundStyle(.secondary)
                                                if !task.summary.isEmpty { Text(task.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
                                                if let question = task.question { Text(question).font(.subheadline).foregroundStyle(.primary).lineLimit(3) }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(16)
                                            .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 18))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .frame(width: 270, alignment: .topLeading)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } else if busy { ProgressView("Loading tasks…") }
            }
            .padding(20)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { configuring = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Task autonomy")
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { task in
            NavigationStack { TaskDetailScreen(task: task) }
        }
        .sheet(isPresented: $configuring) {
            NavigationStack {
                List {
                    Section("How Alice works") {
                        Button {
                            Task { await configure("act") }
                        } label: {
                            Label("Act within the agreed task", systemImage: snapshot?.autonomy == "act" ? "checkmark.circle.fill" : "circle")
                        }
                        Text("Alice can prepare and carry out work. Decisions such as sending, publishing or paying still need your review.")
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await configure("draft_only") }
                        } label: {
                            Label("Only prepare", systemImage: snapshot?.autonomy == "draft_only" ? "checkmark.circle.fill" : "circle")
                        }
                        Text("Alice prepares the result and waits for your review before changing any external service. Unknown operations are held for review too.")
                            .foregroundStyle(.secondary)
                    }
                    if let failure { Text(failure).foregroundStyle(Palette.danger(scheme)) }
                }
                .disabled(busy)
                .navigationTitle("Task autonomy")
                .aliceFormPaper(scheme)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { configuring = false } } }
            }
        }
    }

    @MainActor private func refresh() async {
        busy = true
        defer { busy = false }
        do { snapshot = try await store.reviewTaskClient.load(); failure = nil }
        catch { failure = PlainWords.describe(error) }
    }
    @MainActor private func configure(_ mode: String) async {
        busy = true
        do { try await store.reviewTaskClient.configure(mode); await refresh() }
        catch { failure = PlainWords.describe(error); busy = false }
    }
}

private struct TaskDetailScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State var task: ReviewTask
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Text(task.status.label).foregroundStyle(.secondary)
                if !task.summary.isEmpty { Text(task.summary) }
            }
            Section("Original request") { Text(task.request) }
            if !task.blocks.isEmpty { Section("Prepared result") { TaskResultBlocks(blocks: task.blocks) } }
            if !task.checks.isEmpty {
                Section("What Alice checked") {
                    ForEach(Array(task.checks.enumerated()), id: \.offset) { _, check in Label(check, systemImage: "checkmark") }
                }
            }
            if task.status == .needsReview || task.status == .blocked {
                TaskReviewCard(task: task, busy: busy, onAccept: { respond("accept") }, onChange: { respond(task.status == .blocked ? "answer" : "change", message: $0) })
                    .id(task.attention_id)
            }
            if task.resume_state == "pending" {
                Section {
                    Text("Your decision is saved. Continue in the original conversation when Hermes is available.")
                    Button("Continue task") { Task { await continueTask() } }.disabled(busy)
                }
            } else if task.resume_state == "unknown" || task.resume_state == "dispatching" {
                Section {
                    Text("Alice couldn’t confirm whether the continuation arrived. Check the original chat before sending anything again. Your approval still covers one exact action only.")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(Palette.danger(scheme)) } }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    @MainActor private func respond(_ action: String, message: String = "") {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                task = try await store.reviewTaskClient.respond(task, action: action, message: message)
                await continueTask()
            } catch {
                if let error = error as? DashboardClient.Failure, case .http(409, _) = error {
                    if let current = try? await store.reviewTaskClient.load().tasks.first(where: { $0.id == task.id }) { task = current }
                    failure = String(localized: "This task changed. The current version is shown. Review it before accepting again.")
                } else { failure = PlainWords.describe(error) }
            }
            busy = false
        }
    }

    @MainActor private func continueTask() async {
        busy = true
        defer { busy = false }
        do {
            guard let source = await store.botChatSource() else { throw DashboardClient.Failure.notConfigured }
            // Resume the exact originating profile/session. Never create a replacement.
            let resumed = try await source.resume(profile: task.profile.isEmpty ? nil : task.profile, target: task.session_id, omitMessages: true)
            guard let liveID = resumed["session_id"] as? String, !liveID.isEmpty,
                  let durableID = WebSocketBotChatSource.durableID(of: resumed) else { throw DashboardClient.Failure.unreadable }
            try await store.reviewTaskClient.claim(task, aliases: Array(Set([liveID, durableID])))
            do {
                _ = try await source.submit(liveSessionID: liveID, text: String(localized: "Continue task “\(task.title)” using the decision saved in Tasks. Check the result before marking it complete."))
                try await store.reviewTaskClient.continuationResult(task, state: "submitted")
            } catch {
                try? await store.reviewTaskClient.continuationResult(task, state: "unknown")
                throw error
            }
            if let current = try await store.reviewTaskClient.load().tasks.first(where: { $0.id == task.id }) { task = current }
        } catch {
            failure = PlainWords.describe(error)
            if let current = try? await store.reviewTaskClient.load().tasks.first(where: { $0.id == task.id }) { task = current }
        }
    }
}
