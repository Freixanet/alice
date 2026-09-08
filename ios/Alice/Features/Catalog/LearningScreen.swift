import SwiftUI

struct LearningScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles: [(id: String, label: String)] = [("default", "Alice")]
    @State private var profile = "default"
    @State private var graph: HermesLearningGraph?
    @State private var selected: HermesLearningNode?
    @State private var search = ""
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        List {
            Section("Profile") {
                Picker("Learning belongs to", selection: $profile) {
                    ForEach(profiles, id: \.id) { Text($0.label).tag($0.id) }
                }
            }

            if let graph {
                Section("Overview") {
                    LabeledContent("Nodes", value: "\(graph.nodes.count)")
                    LabeledContent("Connections", value: "\(graph.edgeCount)")
                    LabeledContent("Memory chunks", value: "\(graph.memoryCount)")
                    if !graph.clusters.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(graph.clusters) { cluster in
                                    Text("\(cluster.category) · \(cluster.count)")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.secondary.opacity(0.10), in: .capsule)
                                }
                            }
                        }
                    }
                }
            }

            Section("Learned nodes") {
                if loading && graph == nil {
                    ProgressView("Loading learning graph…")
                } else if filtered.isEmpty {
                    Text(search.isEmpty ? "No learned nodes for this profile." : "No matching nodes.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { node in
                        Button { selected = node } label: { nodeRow(node) }
                            .buttonStyle(.plain)
                    }
                }
            }

            if let failure {
                Section("Last error") {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Learning")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search learned skills & memory")
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await loadProfiles(); await load() }
        .onChange(of: profile) { _, _ in graph = nil; Task { await load() } }
        .refreshable { await load() }
        .sheet(item: $selected) { node in
            LearningNodeSheet(node: node, profile: profile) { await load() }
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    private var filtered: [HermesLearningNode] {
        guard let graph else { return [] }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return graph.nodes }
        return graph.nodes.filter {
            $0.label.lowercased().contains(q)
                || ($0.category?.lowercased().contains(q) ?? false)
                || $0.kind.lowercased().contains(q)
        }
    }

    private func nodeRow(_ node: HermesLearningNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind == "skill" ? "sparkles" : "brain").frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.label).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 5) {
                    Text(node.kind)
                    if let category = node.category { Text("·"); Text(category) }
                    if node.useCount > 0 { Text("· used \(node.useCount)×") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if node.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func loadProfiles() async {
        do { profiles = try await store.routineProfiles().map { ($0.id, $0.label) } }
        catch { profiles = [("default", "Alice")] }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { graph = try await store.learningGraph(profile: profile); failure = nil }
        catch { failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not return the learning graph." }
    }
}

private struct LearningNodeSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let node: HermesLearningNode
    let profile: String
    let changed: () async -> Void

    @State private var detail: HermesLearningNodeDetail?
    @State private var draft = ""
    @State private var editing = false
    @State private var busy = false
    @State private var failure: String?
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            Group {
                if detail == nil && failure == nil {
                    ProgressView("Loading node…")
                } else {
                    Form {
                        if let detail {
                            Section("Node") {
                                LabeledContent("Type", value: detail.kind)
                                LabeledContent("ID", value: detail.id)
                                Text(detail.label).font(.headline)
                            }
                            Section("Content") {
                                if editing {
                                    TextEditor(text: $draft)
                                        .font(.system(.footnote, design: .monospaced))
                                        .frame(minHeight: 300)
                                } else {
                                    ScrollView(.horizontal) {
                                        Text(detail.content)
                                            .font(.system(.footnote, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(minWidth: 500, alignment: .leading)
                                    }
                                }
                            }
                            Section {
                                Button(editing ? "Cancel editing" : "Edit content") {
                                    if editing { draft = detail.content }
                                    editing.toggle()
                                }
                                Button(detail.kind == "skill" ? "Archive learned skill" : "Delete memory chunk", role: .destructive) {
                                    deleting = true
                                }
                            }
                        }
                        if let failure { Section { Text(failure).foregroundStyle(.red) } }
                    }
                }
            }
            .navigationTitle(node.label)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if editing {
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else { Button("Save") { Task { await save() } }.disabled(draft == detail?.content) }
                    }
                }
            }
            .task { await load() }
            .confirmationDialog(
                node.kind == "skill" ? "Archive this learned skill?" : "Delete this memory chunk?",
                isPresented: $deleting,
                titleVisibility: .visible
            ) {
                Button(node.kind == "skill" ? "Archive" : "Delete", role: .destructive) { Task { await remove() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(node.kind == "skill" ? "Hermes archives learned skills so they can be restored later." : "This removes the memory chunk from the selected profile.")
            }
        }
    }

    private func load() async {
        do {
            let value = try await store.learningNode(node.id, profile: profile)
            detail = value; draft = value.content; failure = nil
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "Could not load node." }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await store.saveLearningNode(node.id, content: draft, profile: profile)
            await load(); editing = false; await changed()
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "Could not save node." }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do { try await store.deleteLearningNode(node.id, profile: profile); await changed(); dismiss() }
        catch { failure = (error as? LocalizedError)?.errorDescription ?? "Could not delete node." }
    }
}
