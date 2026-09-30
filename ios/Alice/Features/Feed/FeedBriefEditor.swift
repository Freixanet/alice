import SwiftUI

/// The coverage brief: what the feed covers, its tone and what it leaves out, in the person's
/// own words. Saving a real change asks the Mac for one fresh run.
struct FeedBriefEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let initial: String
    /// A run is already under way: the new brief applies to the next one.
    let running: Bool
    let onSave: (String) async -> Bool

    @State private var text = ""
    @State private var saving = false
    @State private var failed = false
    @State private var confirmingDiscard = false
    @FocusState private var focused: Bool

    private var changed: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Topics to follow, the tone you like, and anything to leave out. Alice writes the next posts from this.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .disabled(saving)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
                    .accessibilityLabel("Coverage brief")
                if running, changed {
                    Label("Alice is writing posts now. The new brief applies to the next run.", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if failed {
                    Text("The brief couldn’t be saved. Check that your Mac is reachable and try again.")
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            .padding(16)
            .background(Palette.background(scheme))
            .navigationTitle("Coverage brief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if changed { confirmingDiscard = true }
                        else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            saving = true
                            Task {
                                let saved = await onSave(text)
                                saving = false
                                failed = !saved
                                if saved { dismiss() }
                            }
                        }
                        .disabled(!changed)
                        .accessibilityHint("Saves the brief and asks Alice for new posts")
                    }
                }
            }
            .onAppear {
                text = initial
                focused = true
            }
            .confirmationDialog("Discard changes to the coverage brief?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(changed || saving)
    }
}
