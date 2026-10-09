import SwiftUI

struct WatchersScreen: View {
    @Environment(AppStore.self) private var store
    @State private var snapshot: WatcherSnapshot?
    @State private var error: String?
    @State private var busy = false
    @State private var provider = ""
    @State private var model = ""
    @State private var endpoint = ""
    @State private var keyName = ""
    @State private var dryRun: String?
    @State private var discardID: String?
    @State private var feedbackKind = "muted_senders"
    @State private var feedbackValue = ""

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if snapshot?.setup_required != false {
                Section {
                    Text("Configure a cheap classifier before activating watchers. Alice will never use the main model instead.")
                }
            }
            Section("Cheap classifier on your Hermes") {
                TextField("Provider name", text: $provider)
                TextField("Model", text: $model)
                TextField("HTTPS API endpoint, ending in /v1", text: $endpoint)
                    .keyboardType(.URL)
                TextField("API key variable name on Hermes (optional)", text: $keyName)
                Button("Save classifier") {
                    perform {
                        try await store.watcherClient.configure(.init(provider: provider, model: model, base_url: endpoint, api_key_env: keyName))
                    }
                }
                .disabled(busy || provider.isEmpty || model.isEmpty || endpoint.isEmpty)
                Text("Use a dedicated cheap model with a compatible structured-output API. Keys stay on your Hermes host; enter only the variable name here. Errors retain events and never call the main model.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section("Watchers") {
                if let snapshot, snapshot.watchers.isEmpty {
                    Text("Ask Alice in chat to watch an email, feed or GitHub repository, or to create a birthday, departure or follow-up reminder.")
                }
                ForEach(snapshot?.watchers ?? []) { watcher in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(watcher.name).font(.headline)
                        Text("\(watcher.status)\(watcher.reason.map { " (\($0))" } ?? "") · \(watcher.pending) pending")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(watcher.status == "active" ? "Pause" : "Activate") {
                                perform { _ = try await store.watcherClient.action(watcher.status == "active" ? "pause" : "activate", id: watcher.id) }
                            }
                            .disabled(busy || (watcher.status != "active" && snapshot?.setup_required != false))
                            Button("Dry run") {
                                perform { dryRun = try await store.watcherClient.action("dry_run", id: watcher.id) }
                            }.disabled(busy || snapshot?.setup_required != false)
                        }
                        if watcher.pending > 0 {
                            HStack {
                                Button("Retry pending") {
                                    perform { _ = try await store.watcherClient.action("retry", id: watcher.id) }
                                }.disabled(busy || snapshot?.setup_required != false)
                                Button("Discard pending", role: .destructive) { discardID = watcher.id }
                                    .disabled(busy)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Text("Checks run on your Hermes. An empty check costs no main-model call. New events are batched for one minute. Delivery while Alice is closed requires the existing Mac/Bark notifier.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let dryRun {
                Section("Dry run — no messages sent") { Text(dryRun.isEmpty ? "No recent source items." : dryRun).textSelection(.enabled) }
            }
            Section("Feedback") {
                Picker("Filter", selection: $feedbackKind) {
                    Text("Mute sender").tag("muted_senders")
                    Text("Mute topic").tag("muted_topics")
                    Text("Less of category").tag("less_categories")
                }
                TextField("Sender address, exact topic or category", text: $feedbackValue)
                Button("Add filter") {
                    perform {
                        try await store.watcherClient.feedback(feedbackKind, value: feedbackValue)
                        feedbackValue = ""
                    }
                }.disabled(busy || feedbackValue.trimmingCharacters(in: .whitespaces).isEmpty)
                ForEach(["muted_senders", "muted_topics", "less_categories"], id: \.self) { kind in
                    ForEach(snapshot?.feedback[kind] ?? [], id: \.self) { value in
                        HStack {
                            Text(value)
                            Spacer()
                            Button("Remove") { perform { try await store.watcherClient.feedback(kind, value: value, remove: true) } }
                                .disabled(busy)
                        }
                    }
                }
            }
            if let snapshot, !snapshot.notices.isEmpty {
                Section("Needs attention") {
                    ForEach(snapshot.notices) { notice in Text(notice.message) }
                }
            }
        }
        .navigationTitle("Watchers")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("Discard pending events for \(snapshot?.watchers.first { $0.id == discardID }?.name ?? "this watcher")? They will not be retried.", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } })) {
            Button("Discard pending events", role: .destructive) {
                if let id = discardID { perform { _ = try await store.watcherClient.action("discard", id: id) } }
                discardID = nil
            }
        }
    }

    @MainActor private func refresh() async {
        do {
            let loaded = try await store.watcherClient.load()
            snapshot = loaded
            if let route = loaded.route {
                provider = route.provider; model = route.model
                endpoint = route.base_url; keyName = route.api_key_env
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await operation(); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
}
