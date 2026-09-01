import SwiftUI

/// The composer every model client has converged on: the text on its own line,
/// and the controls underneath — attach on the left, send on the right.
///
/// It sits on Liquid Glass so the transcript stays visible behind it, and the
/// field and the button share one `GlassEffectContainer` so they read as a
/// single surface rather than two stacked shapes.
struct Composer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var focused: FocusState<Bool>.Binding
    @Namespace private var glass

    var body: some View {
        @Bindable var store = store

        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 10) {
                TextField("Talk to Alice…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...7)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(focused)
                    .padding(.horizontal, 4)

                HStack(spacing: 10) {
                    Button {
                        // Attachments arrive with the multimodal work; the
                        // control is here so the layout does not shift later.
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(true)

                    Spacer()

                    actionButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .glassEffectID("composer", in: glass)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// One button holds the trailing slot: send when idle, stop while a reply is
    /// streaming, and back to send as soon as there is something new to say.
    @ViewBuilder
    private var actionButton: some View {
        let sending = store.isSending
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stopping = sending && !hasDraft

        Button {
            if stopping { store.stop() } else { store.send() }
        } label: {
            Image(systemName: stopping ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .glassEffectID("send", in: glass)
        .disabled(!sending && (!hasDraft || !store.isConnected))
        .accessibilityLabel(stopping ? "Stop" : "Send")
    }
}
