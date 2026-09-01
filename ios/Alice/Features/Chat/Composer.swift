import SwiftUI

/// The composer floats on its own glass over the transcript.
///
/// `GlassEffectContainer` lets the field and the send button share one glass
/// system, so when the button changes shape the two blend rather than fighting
/// each other — the effect Apple built the container for.
struct Composer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var focused: FocusState<Bool>.Binding
    @Namespace private var glass

    var body: some View {
        @Bindable var store = store

        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Talk to Alice…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .glassEffectID("field", in: glass)

                actionButton
            }
        }
    }

    /// One button holds the trailing slot, exactly as on the web: send when
    /// idle, stop while a reply is streaming, and back to send as soon as there
    /// is something new to say.
    @ViewBuilder
    private var actionButton: some View {
        let sending = store.isSending
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Button {
            if sending && !hasDraft {
                store.stop()
            } else {
                store.send()
            }
        } label: {
            Image(systemName: sending && !hasDraft ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .glassEffectID("action", in: glass)
        .disabled(!sending && (!hasDraft || !store.isConnected))
        .accessibilityLabel(sending && !hasDraft ? "Stop" : "Send")
    }
}
