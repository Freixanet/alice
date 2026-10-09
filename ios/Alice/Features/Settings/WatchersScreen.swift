import SwiftUI
import UIKit

struct WatchersScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var snapshot: WatcherSnapshot?
    @State private var failure: String?
    @State private var loading = false
    @State private var selected: WatcherSnapshot.Watcher?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("Alice checks for updates and tells you when something needs your attention.")
                Text("To create a watch, tell Alice in chat what to follow and when to notify you.")
                    .foregroundStyle(.secondary)
                Text("For example: “Watch emails from my insurer and tell me when a new one arrives.”")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = String(localized: "Watch emails from [sender]. Notify me when a new one arrives. Do not take any action on the emails.")
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Request copied — paste it in chat") : String(localized: "Copy an example request"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            if let snapshot {
                if snapshot.setup_required {
                    Section {
                        Label("One-time setup needed", systemImage: "exclamationmark.circle")
                        Text("Choose how Alice checks your watches in Notification setup before starting one.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let morning = snapshot.morning {
                    WatcherMorningSettings(settings: morning) { await refresh() }
                }
                if let usage = snapshot.usage {
                    Section {
                        LabeledContent("Watch updates", value: "\(usage.today.proactive)")
                        LabeledContent("Morning briefing", value: "\(usage.today.briefing)")
                        LabeledContent("Total today", value: "\(usage.today.total)")
                        Text(usage.timezone).font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup("Last seven days") {
                            ForEach(usage.days) { day in
                                LabeledContent(day.date, value: "\(day.total)")
                            }
                        }
                    } header: {
                        Text("Daily model calls")
                    } footer: {
                        if !usage.available { Text("Model call counting is unavailable on this Hermes version.") }
                        Text("Calls for watch messages and briefings share your model quota. Failed attempts and retries count too. This is not your remaining Plus quota. Classifier calls are separate.")
                    }
                }
                Section("Your watches") {
                    if snapshot.watchers.isEmpty {
                        Text("No watches yet. Create your first one in chat.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.watchers) { watcher in
                        Button { selected = watcher } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(watcher.name).font(.headline).foregroundStyle(.primary)
                                    Text(WatcherWords.status(watcher.status, reason: watcher.reason, incomplete: watcher.needsEmailFilter))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        WatcherSetupScreen(snapshot: snapshot) { await refresh() }
                    } label: {
                        Label("Notification setup", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Your Hermes must stay on to check for updates. Alerts while Alice is closed use your configured phone notifications.")
                }
            }
            if let failure {
                Section {
                    Text(failure).foregroundStyle(Palette.danger(scheme))
                    Button("Try again") { Task { await refresh() } }
                }
            }
        }
        .navigationTitle("Watches")
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
        .overlay { if loading && snapshot == nil { ProgressView("Loading watches…") } }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { watcher in
            NavigationStack { WatcherDetailScreen(watcher: watcher, setupRequired: snapshot?.setup_required != false) }
        }
    }

    @MainActor private func refresh() async {
        loading = true
        defer { loading = false }
        do { snapshot = try await store.watcherClient.load(); failure = nil }
        catch { failure = WatcherWords.failure(error) }
    }
}

private struct WatcherMorningSettings: View {
    @Environment(AppStore.self) private var store
    let settings: WatcherSnapshot.Morning
    let saved: () async -> Void
    @State private var enabled = true
    @State private var time = Date()
    @State private var confirmation = false
    @State private var busy = false
    @State private var failure: String?

    private var zone: TimeZone { TimeZone(identifier: settings.timezone) ?? TimeZone(identifier: "Europe/Madrid")! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        return value
    }

    var body: some View {
        Section {
            Toggle("Send a morning briefing", isOn: $enabled)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, zone)
                .disabled(!enabled)
            Text(settings.timezone).font(.footnote).foregroundStyle(.secondary)
            Button("Save briefing time") {
                Task { await save() }
            }
            if confirmation { Text("Briefing time saved.").foregroundStyle(.secondary) }
            if let failure { Text(failure).foregroundStyle(.red) }
        } header: {
            Text("Morning briefing")
        } footer: {
            Text("Once a day: tasks waiting for your review and updates caught by your watches. Nothing to report means no message and no model call.")
        }
        .disabled(busy)
        .onChange(of: time) { confirmation = false }
        .onChange(of: enabled) { confirmation = false }
        .onAppear {
            enabled = settings.enabled
            let parts = settings.time.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                time = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) ?? Date()
            }
        }
    }

    @MainActor private func save() async {
        busy = true
        defer { busy = false }
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let value = String(format: "%02d:%02d", parts.hour ?? 8, parts.minute ?? 0)
        do {
            try await store.watcherClient.morning(.init(enabled: enabled, time: value, timezone: settings.timezone))
            failure = nil
            await saved()
            confirmation = true
        } catch { failure = WatcherWords.failure(error) }
    }
}

private struct WatcherDetailScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State var watcher: WatcherSnapshot.Watcher
    let setupRequired: Bool
    @State private var busy = false
    @State private var failure: String?
    @State private var preview: String?
    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                Label(WatcherWords.status(watcher.status, reason: watcher.reason, incomplete: watcher.needsEmailFilter),
                      systemImage: watcher.status == "active" ? "eye" : "pause.circle")
                if watcher.needsEmailFilter {
                    Text(WatcherWords.missingFilter).foregroundStyle(.secondary)
                } else {
                    Text(watcher.source == "email" ? String(localized: "Alice checks your matching emails and follows the alert rule you agreed in chat.") : String(localized: "Alice checks this source and follows the alert rule you agreed in chat."))
                        .foregroundStyle(.secondary)
                }
                if watcher.status == "failed" || (watcher.status == "paused" && watcher.reason != "user") {
                    Text("Alice stopped this watch because it couldn’t process updates or reached an alert limit. Ask her in chat to review it before restarting.")
                        .foregroundStyle(.secondary)
                }
                if setupRequired {
                    Text("Choose how Alice checks your watches in Notification setup before starting one.")
                }
                Button(watcher.status == "active" ? String(localized: "Pause watch") : String(localized: "Start watch")) {
                    perform(watcher.status == "active" ? "pause" : "activate")
                }
                .disabled(busy || (watcher.status != "active" && (setupRequired || watcher.needsEmailFilter)))
            }
            if !watcher.needsEmailFilter {
                Section {
                    Button("Test alerts") { perform("dry_run") }
                        .disabled(busy || setupRequired)
                    if let preview { Text(preview).foregroundStyle(.secondary) }
                } footer: {
                    Text("Checks recent matching items without sending messages or changing them.")
                }
            }
            if watcher.pending > 0 {
                Section("Waiting to be checked") {
                    Text("Items waiting: \(watcher.pending). They have not been successfully processed yet.")
                    if watcher.needsEmailFilter {
                        Text("These items were collected before this watch had a filter. They may not belong to the sender you requested.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Check again") { perform("retry") }
                        .disabled(busy || setupRequired || watcher.needsEmailFilter)
                    Button("Ignore these items", role: .destructive) { confirmingDiscard = true }
                        .disabled(busy)
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(Palette.danger(scheme)) } }
            Section {
                DisclosureGroup("Technical details") {
                    if let query = watcher.config?.query { LabeledContent("Email filter", value: query) }
                    Text(watcher.id).font(.caption).textSelection(.enabled)
                }
            }
            Section {
                Button("Delete watch", role: .destructive) { confirmingDelete = true }
                    .disabled(busy)
            }
        }
        .navigationTitle(watcher.name)
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Ignore the waiting items for this watch?", isPresented: $confirmingDiscard) {
            Button("Ignore these items", role: .destructive) { perform("discard") }
        } message: {
            Text("They will not be checked again. Your emails will not be deleted.")
        }
        .confirmationDialog("Delete “\(watcher.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete watch", role: .destructive) { perform("delete") }
        } message: {
            Text("Stops checks and ignores waiting items. Your emails and existing chat messages will not be deleted.")
        }
    }

    @MainActor private func perform(_ action: String) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                let result = try await store.watcherClient.action(action, id: watcher.id)
                if action == "delete" { dismiss(); return }
                if action == "dry_run" { preview = result }
                let loaded = try await store.watcherClient.load()
                if let updated = loaded.watchers.first(where: { $0.id == watcher.id }) { watcher = updated }
            } catch { failure = WatcherWords.failure(error) }
        }
    }
}

private struct WatcherSetupScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let snapshot: WatcherSnapshot
    let onSaved: @MainActor () async -> Void
    @State private var provider = ""
    @State private var model = ""
    @State private var endpoint = ""
    @State private var keyName = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var saved = false
    @State private var feedbackKind = "muted_senders"
    @State private var feedbackValue = ""
    @State private var filters: [String: [String]] = [:]

    var body: some View {
        Form {
            Section {
                Label(saved || !snapshot.setup_required ? String(localized: "Ready to check your watches") : String(localized: "Setup needed"), systemImage: saved || !snapshot.setup_required ? "checkmark.circle" : "exclamationmark.circle")
                Text("Alice uses a separate model to decide which updates deserve an alert. Your model is already configured if this says Ready.")
                    .foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced model settings") {
                    TextField("Provider", text: $provider)
                    TextField("Model", text: $model)
                    TextField("Server address", text: $endpoint).keyboardType(.URL)
                    TextField("Key variable on Hermes (optional)", text: $keyName)
                    Text("For a ChatGPT connection already set up in Hermes, no API key is needed. Other providers use the name of a key stored on Hermes, never the key itself.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save settings") {
                        perform {
                            try await store.watcherClient.configure(.init(provider: provider, model: model, base_url: endpoint, api_key_env: keyName))
                            saved = true
                        }
                    }
                    .disabled(busy || provider.isEmpty || model.isEmpty || endpoint.isEmpty)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            Section {
                DisclosureGroup("Reduce alerts") {
                    Picker("Ignore", selection: $feedbackKind) {
                        Text("Sender").tag("muted_senders")
                        Text("Exact subject").tag("muted_topics")
                        Text("Fewer alerts in category").tag("less_categories")
                    }
                    TextField("Address, subject or category", text: $feedbackValue)
                    Button("Add preference") {
                        perform {
                            try await store.watcherClient.feedback(feedbackKind, value: feedbackValue)
                            feedbackValue = ""
                        }
                    }.disabled(busy || feedbackValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(["muted_senders", "muted_topics", "less_categories"], id: \.self) { kind in
                        ForEach(filters[kind] ?? [], id: \.self) { value in
                            HStack {
                                Text(value)
                                Spacer()
                                Button("Remove") { perform { try await store.watcherClient.feedback(kind, value: value, remove: true) } }
                                    .disabled(busy)
                            }
                        }
                    }
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(Palette.danger(scheme)) } }
        }
        .navigationTitle("Notification setup")
        .navigationBarTitleDisplayMode(.inline)
        .aliceFormPaper(scheme)
        .onAppear {
            if let route = snapshot.route {
                provider = route.provider; model = route.model; endpoint = route.base_url; keyName = route.api_key_env
            }
            filters = snapshot.feedback
        }
    }

    @MainActor private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await operation()
                filters = try await store.watcherClient.load().feedback
                await onSaved()
            } catch { failure = WatcherWords.failure(error) }
        }
    }
}
