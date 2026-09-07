import SwiftUI
import UIKit

/// Machine-global Hermes webhook administration.
/// Route secrets are intentionally write-only: Hermes reveals a generated or
/// supplied secret only in the create response, and Alice keeps that value
/// only in the creation sheet long enough for the user to copy it.
struct WebhooksScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var snapshot: WebhooksSnapshot?
    @State private var loading = false
    @State private var failure: String?
    @State private var query = ""
    @State private var showCreate = false
    @State private var deleting: WebhookSubscription?
    @State private var toggling: Set<String> = []
    @State private var enabling = false
    @State private var restartNeeded = false
    @State private var restartFailure: String?
    @State private var restartAction: HermesActionStart?
    @State private var restartStatus: HermesActionStatus?
    @State private var confirmRestart = false

    var body: some View {
        List {
            statusSection
            subscriptionsSection

            if let restartStatus {
                restartSection(restartStatus)
            }

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
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .searchable(text: $query, prompt: "Search webhooks")
        .task { await load() }
        .task(id: restartAction?.name) { await pollRestart() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("New webhook", systemImage: "plus") }
                    .disabled(snapshot?.enabled != true || !store.dashboardReady)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateWebhookSheet {
                Task { await load() }
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .confirmationDialog(
            "Delete webhook?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let sub = deleting else { return }
                deleting = nil
                Task { await remove(sub) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "“\($0.name)” and its HMAC secret will be permanently removed." } ?? "")
        }
        .confirmationDialog(
            "Restart Hermes gateway?",
            isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart") { Task { await restartGateway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active chat and channel connections may disconnect briefly while the webhook receiver comes online.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Receiver") {
            if loading && snapshot == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading webhooks…").foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))
            } else if let snapshot {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: snapshot.enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(snapshot.enabled ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.enabled ? "Webhook receiver enabled" : "Webhook receiver disabled")
                            .font(.subheadline.weight(.semibold))
                        Text(snapshot.enabled
                             ? "Subscriptions hot-reload without restarting the gateway."
                             : "Enable the webhook platform before creating subscriptions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !snapshot.baseURL.isEmpty {
                            Text(snapshot.baseURL)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 6)
                }
                .listRowBackground(Palette.card(scheme))

                if !snapshot.enabled {
                    Button {
                        Task { await enableReceiver() }
                    } label: {
                        if enabling { ProgressView() }
                        else { Label("Enable webhooks", systemImage: "link") }
                    }
                    .disabled(enabling)
                    .listRowBackground(Palette.card(scheme))
                }

                if restartNeeded {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(
                            restartFailure ?? "The webhook platform is saved but the gateway still needs a restart.",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        Button { confirmRestart = true } label: {
                            Label("Restart gateway", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } else {
                stateRow(
                    "Webhooks unavailable",
                    detail: failure ?? "Connect the Hermes dashboard to manage webhooks.",
                    systemImage: "link"
                )
            }
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section("Subscriptions · \(filtered.count)") {
            if snapshot?.enabled == false {
                Text("Enable the receiver to create subscriptions. Existing subscriptions remain stored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            }

            if loading && snapshot?.subscriptions.isEmpty != false {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading subscriptions…").foregroundStyle(.secondary)
                }
                .listRowBackground(Palette.card(scheme))
            } else if filtered.isEmpty {
                stateRow(
                    query.isEmpty ? "No webhook subscriptions" : "No matches",
                    detail: query.isEmpty
                        ? "Create a subscription to receive signed HTTP events."
                        : "Try a different search.",
                    systemImage: query.isEmpty ? "tray" : "magnifyingglass"
                )
            } else {
                ForEach(filtered) { sub in
                    subscriptionRow(sub)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
    }

    @ViewBuilder
    private func subscriptionRow(_ sub: WebhookSubscription) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sub.enabled ? "link" : "link")
                    .foregroundStyle(sub.enabled ? .green : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(sub.name).font(.subheadline.weight(.semibold))
                        badge(sub.deliver.uppercased(), tint: .secondary)
                        if sub.deliverOnly { badge("DIRECT", tint: .orange) }
                        if !sub.enabled { badge("OFF", tint: .secondary) }
                    }
                    if !sub.detail.isEmpty {
                        Text(sub.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if toggling.contains(sub.name) {
                    ProgressView().frame(width: 51)
                } else {
                    Toggle(
                        sub.name,
                        isOn: Binding(
                            get: { current(sub.name)?.enabled ?? sub.enabled },
                            set: { setEnabled(sub, enabled: $0) }
                        )
                    )
                    .labelsHidden()
                }
            }

            HStack(spacing: 7) {
                Text(sub.events.isEmpty ? "All events" : sub.events.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if sub.secretSet {
                    Label("Signed", systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(sub.url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button { copy(sub.url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy webhook URL")
            }

            if !sub.prompt.isEmpty || !sub.script.isEmpty || !sub.skills.isEmpty || sub.createdAt != nil {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 7) {
                        if let created = sub.createdAt, !created.isEmpty {
                            LabeledContent("Created", value: created)
                        }
                        if !sub.skills.isEmpty {
                            LabeledContent("Skills", value: sub.skills.joined(separator: ", "))
                        }
                        if !sub.prompt.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.deliverOnly ? "Direct message" : "Agent prompt")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(sub.prompt).font(.caption).textSelection(.enabled)
                            }
                        }
                        if !sub.script.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pre-processing script")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(sub.script).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                Button(role: .destructive) { deleting = sub } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(sub.enabled ? 1 : 0.62)
    }

    @ViewBuilder
    private func restartSection(_ status: HermesActionStatus) -> some View {
        Section("Gateway restart") {
            HStack {
                Label(status.name, systemImage: "arrow.clockwise.circle")
                Spacer()
                Text(status.running ? "RUNNING" : (status.exitCode == 0 ? "DONE" : "EXIT \(status.exitCode.map(String.init) ?? "?")"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(status.running ? .orange : (status.exitCode == 0 ? .green : .red))
            }
            .listRowBackground(Palette.card(scheme))
            if let last = status.lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Text(last)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var filtered: [WebhookSubscription] {
        let rows = snapshot?.subscriptions ?? []
        guard !query.isEmpty else { return rows }
        let needle = query.lowercased()
        return rows.filter {
            "\($0.name) \($0.detail) \($0.deliver) \($0.events.joined(separator: " ")) \($0.skills.joined(separator: " "))"
                .lowercased().contains(needle)
        }
    }

    private func current(_ name: String) -> WebhookSubscription? {
        snapshot?.subscriptions.first { $0.name == name }
    }

    private func load() async {
        guard store.dashboardReady else {
            snapshot = nil
            failure = "Connect the Hermes dashboard to manage webhooks."
            return
        }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await store.webhooks()
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func enableReceiver() async {
        enabling = true
        defer { enabling = false }
        do {
            let result = try await store.enableWebhooks()
            restartNeeded = result.needsRestart
            restartFailure = result.restartError
            await load()
            if result.restartStarted {
                restartAction = HermesActionStart(
                    ok: true,
                    pid: result.restartPID,
                    name: result.restartAction ?? "gateway-restart",
                    archive: nil
                )
                restartNeeded = false
            }
        } catch {
            failure = reason(error)
        }
    }

    private func setEnabled(_ sub: WebhookSubscription, enabled: Bool) {
        guard !toggling.contains(sub.name) else { return }
        toggling.insert(sub.name)
        Task {
            defer { toggling.remove(sub.name) }
            do {
                try await store.setWebhookEnabled(sub.name, enabled: enabled)
                if let index = snapshot?.subscriptions.firstIndex(where: { $0.name == sub.name }) {
                    snapshot?.subscriptions[index].enabled = enabled
                }
            } catch {
                failure = reason(error)
            }
        }
    }

    private func remove(_ sub: WebhookSubscription) async {
        do {
            try await store.deleteWebhook(sub.name)
            await load()
        } catch {
            failure = reason(error)
        }
    }

    private func restartGateway() async {
        do {
            restartAction = try await store.hermesGatewayAction("restart", profile: "default")
            restartNeeded = false
            restartFailure = nil
        } catch {
            restartNeeded = true
            restartFailure = reason(error)
        }
    }

    private func pollRestart() async {
        guard let name = restartAction?.name else { return }
        while !Task.isCancelled {
            do {
                let status = try await store.hermesActionStatus(name, lines: 30)
                guard !Task.isCancelled, restartAction?.name == name else { return }
                restartStatus = status
                if !status.running {
                    if status.exitCode == 0 {
                        restartNeeded = false
                        restartFailure = nil
                        try? await Task.sleep(for: .milliseconds(700))
                        await load()
                    } else {
                        restartNeeded = true
                        restartFailure = "Gateway restart failed with exit \(status.exitCode.map(String.init) ?? "?")."
                    }
                    return
                }
            } catch {
                // The dashboard can be momentarily unreachable while the
                // gateway restarts. Keep polling instead of turning that gap
                // into a false restart failure.
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.11), in: Capsule())
    }

    private func stateRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }
}

private struct CreateWebhookSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let onCreated: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var events = ""
    @State private var deliver = "log"
    @State private var customDeliver = ""
    @State private var deliverOnly = false
    @State private var deliverChatID = ""
    @State private var prompt = ""
    @State private var script = ""
    @State private var skills = ""
    @State private var secret = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var created: WebhookCreation?
    @State private var copiedSecret = false

    private let commonTargets = ["log", "telegram", "discord", "slack", "email", "github_comment", "custom"]

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    createdSections(created)
                } else {
                    formSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle(created == nil ? "New Webhook" : "Webhook Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Done") { dismiss() }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }.disabled(saving)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Subscription") {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Description (optional)", text: $description)
        }
        .listRowBackground(Palette.card(scheme))

        Section("Events") {
            TextField("push, issue.opened, deployment", text: $events, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Comma or newline separated. Leave blank to accept every event type.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Palette.card(scheme))

        Section("Delivery") {
            Picker("Deliver to", selection: $deliver) {
                ForEach(commonTargets, id: \.self) { target in
                    Text(target == "github_comment" ? "GitHub comment" : target.capitalized).tag(target)
                }
            }
            if deliver == "custom" {
                TextField("Custom delivery target", text: $customDeliver)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("Deliver only — skip the agent", isOn: $deliverOnly)
            if effectiveDeliver != "log" {
                TextField("Chat / target ID (optional)", text: $deliverChatID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Text(deliverOnly
                 ? "Direct delivery sends the payload without invoking the agent, so it has no LLM cost."
                 : "Hermes can run the agent first, then deliver its result to the selected target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Palette.card(scheme))

        Section(deliverOnly ? "Direct message" : "Agent prompt") {
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 95)
            Text(deliverOnly
                 ? "Optional text/instructions used for the direct delivery."
                 : "Optional instructions Hermes adds when this webhook invokes the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Palette.card(scheme))

        Section("Advanced") {
            TextField("Skills, comma-separated", text: $skills, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Pre-processing script (optional)", text: $script)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("A script is executed by Hermes on the host when this route fires. Only configure scripts you trust.")
                .font(.caption)
                .foregroundStyle(.orange)
            SecureField("Custom HMAC secret (optional)", text: $secret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Leave the secret blank and Hermes will generate a strong one. It is shown exactly once after creation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Palette.card(scheme))

        if let failure {
            Section { Text(failure).font(.footnote).foregroundStyle(.red) }
                .listRowBackground(Palette.card(scheme))
        }
    }

    @ViewBuilder
    private func createdSections(_ result: WebhookCreation) -> some View {
        Section {
            Label("Subscription created", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .listRowBackground(Palette.card(scheme))
            Text("Copy the HMAC secret now. Hermes will not return it again from list calls.")
                .font(.footnote)
                .foregroundStyle(.orange)
                .listRowBackground(Palette.card(scheme))
        }

        Section("Webhook URL") {
            Text(result.subscription.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .listRowBackground(Palette.card(scheme))
            Button { UIPasteboard.general.string = result.subscription.url } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            .listRowBackground(Palette.card(scheme))
        }

        Section("HMAC secret · shown once") {
            Text(result.secret)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .privacySensitive()
                .listRowBackground(Palette.card(scheme))
            Button {
                UIPasteboard.general.string = result.secret
                copiedSecret = true
            } label: {
                Label(copiedSecret ? "Copied" : "Copy secret", systemImage: copiedSecret ? "checkmark" : "doc.on.doc")
            }
            .listRowBackground(Palette.card(scheme))
        }

        Section("Signing") {
            Text("Send HMAC-SHA256 in the `X-Hub-Signature-256` header as `sha256=<hex digest>` using this secret.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .listRowBackground(Palette.card(scheme))
        }
    }

    private var effectiveDeliver: String {
        if deliver != "custom" { return deliver }
        return customDeliver.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() async {
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !normalizedName.isEmpty else { failure = "Name required."; return }
        guard normalizedName.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
            failure = "Use lowercase letters, numbers, hyphens or underscores; the name must start with a letter or number."
            return
        }
        let target = effectiveDeliver
        guard !target.isEmpty else { failure = "Delivery target required."; return }
        if deliverOnly && target == "log" {
            failure = "Direct delivery requires a real target, not Log."
            return
        }

        saving = true
        defer { saving = false }
        failure = nil
        do {
            let result = try await store.createWebhook(
                name: normalizedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                events: splitList(events),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                script: script.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: splitList(skills),
                deliver: target,
                deliverOnly: deliverOnly,
                deliverChatID: deliverChatID.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: secret.isEmpty ? nil : secret
            )
            created = result
            // Do not retain a second copy of the secret in editable form.
            secret = ""
            onCreated()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
