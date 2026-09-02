import SwiftUI

/// The agent's other selves.
///
/// A bot in Hermes is not a separate kind of thing — it is a profile with its
/// own standing instructions, model, skills and sessions. Everything the
/// desktop client shows under Bot Mode is that, which is why it can be shown
/// here from the same three endpoints.
struct BotsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [BotRow] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var creating = false
    @State private var newName = ""
    @State private var newDetail = ""

    var body: some View {
        Group {
            if loading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    "Bots", systemImage: "person.2", description: Text(failure)
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No bots", systemImage: "person.2",
                    description: Text("Every Hermes has at least a default profile.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New bot")
            }
        }
        .sheet(isPresented: $creating) { createSheet }
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        List {
            ForEach(rows) { bot in
                NavigationLink {
                    BotDetail(bot: bot, onChange: { Task { await load() } })
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(bot.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if bot.active {
                                Text("Active")
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(
                                        store.accent.primary(scheme).opacity(0.18),
                                        in: .capsule
                                    )
                            }
                            if bot.gatewayRunning {
                                Circle().fill(.green).frame(width: 6, height: 6)
                            }
                        }
                        if !bot.detail.isEmpty {
                            Text(bot.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(subtitle(bot))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private func subtitle(_ bot: BotRow) -> String {
        var parts: [String] = []
        if let model = bot.model { parts.append(model) }
        parts.append(bot.skills == 1 ? "1 skill" : "\(bot.skills) skills")
        if bot.isDefault { parts.append("default") }
        return parts.joined(separator: " · ")
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("What it is for", text: $newDetail, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("A new profile with its own memory, sessions and standing instructions.")
                }
            }
            .navigationTitle("New bot")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { creating = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await store.createBot(
                                    name: newName.trimmingCharacters(in: .whitespaces),
                                    description: newDetail
                                )
                                newName = ""; newDetail = ""
                                creating = false
                                await load()
                            } catch {
                                failure = describe(error)
                                creating = false
                            }
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { rows = try await store.bots(); failure = nil }
        catch { failure = describe(error) }
    }
}

/// One bot: what it is told to be, and what it is running on.
private struct BotDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bot: BotRow
    let onChange: () -> Void

    @State private var soul = ""
    @State private var soulExists = false
    @State private var editing = false
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Standing instructions") {
                if editing {
                    TextEditor(text: $soul)
                        .frame(minHeight: 220)
                        .font(.callout)
                        .listRowBackground(Palette.card(scheme))
                } else if soul.isEmpty {
                    Text(soulExists ? "Empty." : "This bot has no SOUL yet.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                } else {
                    Text(soul)
                        .font(.callout)
                        .listRowBackground(Palette.card(scheme))
                }
            }

            Section {
                LabeledContent("Model", value: bot.model ?? "—")
                    .listRowBackground(Palette.card(scheme))
                if let provider = bot.provider {
                    LabeledContent("Provider", value: provider)
                        .listRowBackground(Palette.card(scheme))
                }
                LabeledContent("Skills", value: "\(bot.skills)")
                    .listRowBackground(Palette.card(scheme))
            }

            Section {
                if !bot.active {
                    Button("Make this the active bot") {
                        act { try await store.activateBot(bot.name) }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
                if !bot.isDefault {
                    Button("Delete this bot", role: .destructive) {
                        act {
                            try await store.deleteBot(bot.name)
                        } then: {
                            dismiss()
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(bot.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if busy {
                    ProgressView()
                } else if editing {
                    Button("Save") {
                        act { try await store.setSoul(bot.name, soul) } then: {
                            editing = false
                        }
                    }
                } else {
                    Button("Edit") { editing = true }
                }
            }
        }
        .task {
            do {
                let result = try await store.soul(bot.name)
                soul = result.text
                soulExists = result.exists
            } catch {
                failure = describe(error)
            }
        }
    }

    private func act(
        _ work: @escaping () async throws -> Void,
        then finish: @escaping () -> Void = {}
    ) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                failure = nil
                onChange()
                finish()
            } catch {
                failure = describe(error)
            }
        }
    }
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "The dashboard did not answer."
}
