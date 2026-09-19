import SwiftUI

struct CronBlueprintsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var profiles: [(id: String, label: String)] = [("default", "Alice")]
    @State private var profile = "default"
    @State private var rows: [CronBlueprint] = []
    @State private var selected: CronBlueprint?
    @State private var failure: String?
    @State private var loading = false
    @State private var search = ""

    var body: some View {
        List {
            Section("Target") {
                Picker("Create for", selection: $profile) { ForEach(profiles, id: \.id) { Text($0.label).tag($0.id) } }
            }
            Section("Blueprints") {
                if loading && rows.isEmpty { ProgressView("Loading templates…") }
                else if filtered.isEmpty { Text(search.isEmpty ? "No blueprints reported by Hermes." : "No matching blueprints.").foregroundStyle(.secondary) }
                else { ForEach(filtered) { row in
                    Button { selected = row } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(row.title).foregroundStyle(.primary); Spacer(); Text(row.category.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                            Text(row.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            if let human = row.scheduleHuman { Text(human).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                        }.padding(.vertical, 3)
                    }.buttonStyle(.plain)
                } }
            }
            if let failure { Section("Last error") { Text(failure).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Routine Blueprints")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search blueprints")
        .scrollContentBackground(.hidden).background(Palette.background(scheme))
        .task { await loadProfiles(); await load() }.refreshableWithFeedback { await load() }
        .sheet(item: $selected) { row in BlueprintForm(blueprint: row, profile: profile) { selected = nil }.environment(store).preferredColorScheme(store.theme.colorScheme) }
    }
    private var filtered: [CronBlueprint] { let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard !q.isEmpty else { return rows }; return rows.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.tags.contains(where: { $0.lowercased().contains(q) }) } }
    private func loadProfiles() async { do { profiles = try await store.routineProfiles().map { ($0.id, $0.label) } } catch { profiles = [("default", "Alice")] } }
    private func load() async { loading = true; defer { loading = false }; do { rows = try await store.cronBlueprints(); failure = nil } catch { failure = PlainWords.describe(error) } }
}

private struct BlueprintForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let blueprint: CronBlueprint
    let profile: String
    let onCreated: () -> Void
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(blueprint.detail).font(.footnote).foregroundStyle(.secondary) }
                Section("Options") { ForEach(blueprint.fields) { field in fieldView(field) } }
                Section("Result") {
                    if let human = blueprint.scheduleHuman { LabeledContent("Typical schedule", value: human) }
                    Text(blueprint.command).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(blueprint.title).navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { if busy { ProgressView() } else { Button("Create") { Task { await create() } }.disabled(!valid) } }
            }
            .task { if values.isEmpty { values = Dictionary(uniqueKeysWithValues: blueprint.fields.compactMap { field in field.defaultValue.map { (field.name, $0) } }) } }
        }
    }
    @ViewBuilder private func fieldView(_ field: CronBlueprintField) -> some View {
        if !field.options.isEmpty && field.strict {
            Picker(field.label, selection: Binding(get: { values[field.name] ?? field.defaultValue ?? field.options.first ?? "" }, set: { values[field.name] = $0 })) { ForEach(field.options, id: \.self) { Text($0).tag($0) } }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(field.label).font(.caption).foregroundStyle(.secondary)
                TextField(field.defaultValue ?? "", text: Binding(get: { values[field.name] ?? field.defaultValue ?? "" }, set: { values[field.name] = $0 }))
                    .textInputAutocapitalization(field.type == "time" ? .never : .sentences).autocorrectionDisabled(field.type == "time")
                if !field.help.isEmpty { Text(field.help).font(.caption2).foregroundStyle(.tertiary) }
                if !field.options.isEmpty && !field.strict { Text("Suggestions: \(field.options.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
    private var valid: Bool { blueprint.fields.allSatisfy { $0.optional || !(values[$0.name] ?? $0.defaultValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    private func create() async { busy = true; defer { busy = false }; var filled: [String:String] = [:]; for field in blueprint.fields { let value = values[field.name] ?? field.defaultValue ?? ""; if !value.isEmpty { filled[field.name] = value } }; do { try await store.instantiateCronBlueprint(blueprint.key, values: filled, profile: profile); onCreated(); dismiss() } catch { failure = PlainWords.describe(error, doing: "create the routine") } }
}
