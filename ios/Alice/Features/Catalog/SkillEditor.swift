import SwiftUI

/// A skill, as the agent actually keeps it.
///
/// Hermes stores each one as a `SKILL.md` — a YAML preamble naming it and
/// saying what it is for, then the instructions in Markdown — and hands the
/// whole file over and takes the whole file back. So that is what is edited
/// here. Splitting it into fields would mean this app deciding what a skill
/// is allowed to say, and it is not the app's decision to make.
struct SkillEditor: View {
    enum Subject: Identifiable, Hashable {
        case new
        case existing(String, label: String)

        var id: String {
            switch self {
            case .new: "new"
            case let .existing(name, _): name
            }
        }

        var title: String {
            switch self {
            case .new: "New Skill"
            case let .existing(_, label): label
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let subject: Subject
    var onChange: () -> Void

    @State private var name = ""
    @State private var text = ""
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editor
                }
            }
            .background(Palette.background(scheme))
            .navigationTitle(subject.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .alert(
                "Couldn’t save",
                isPresented: Binding(
                    get: { failure != nil },
                    set: { if !$0 { failure = nil } }
                )
            ) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
        .task { await load() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .new = subject {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(Palette.card(scheme))
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("Lower case, words joined by hyphens — the agent calls it by this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            // Monospaced, because the preamble is YAML and its indentation is
            // load-bearing. Proportional type hides a misaligned key.
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
    }

    private var canSave: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if case .new = subject {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func load() async {
        guard case let .existing(name, _) = subject else {
            // Enough of a file to be a skill, and nothing the writer then has
            // to delete: the two keys Hermes reads, and a heading to start on.
            text = """
                ---
                name: 
                description: 
                ---

                # 

                """
            return
        }
        loading = true
        defer { loading = false }
        do { text = try await store.skillContent(name) }
        catch { failure = message(error) }
    }

    private func save() {
        let identifier: String
        let isNew: Bool
        switch subject {
        case .new:
            identifier = name.trimmingCharacters(in: .whitespacesAndNewlines)
            isNew = true
        case let .existing(existing, _):
            identifier = existing
            isNew = false
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.saveSkill(
                    name: identifier, content: text, isNew: isNew
                )
                onChange()
                dismiss()
            } catch {
                failure = message(error)
            }
        }
    }
}
