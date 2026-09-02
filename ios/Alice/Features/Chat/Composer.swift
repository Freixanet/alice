import SwiftUI

/// The composer every model client has converged on: the text on its own line,
/// and the controls underneath — attach and model on the left, send on the
/// right.
///
/// It sits on Liquid Glass so the transcript stays visible behind it, and the
/// field and the button share one `GlassEffectContainer` so they read as a
/// single surface rather than two stacked shapes.
struct Composer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var focused: FocusState<Bool>.Binding
    @Namespace private var glass
    @State private var showModels = false
    @State private var dictation = Dictation()

    /// One height for every control on the bottom row, so the send button and
    /// the model chip line up instead of each taking the size its own padding
    /// happens to produce.
    private let controlHeight: CGFloat = 34

    var body: some View {
        @Bindable var store = store

        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 18) {
                TextField("Talk to Alice…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...7)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(focused)
                    .padding(.horizontal, 4)
                    // The field only claims the height of its own text, so a
                    // tap anywhere on the upper half of the composer used to
                    // land on inert glass. Give it a real target.
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    .contentShape(.rect)
                    .onTapGesture { focused.wrappedValue = true }

                HStack(spacing: 8) {
                    attachButton
                    modelChip
                    Spacer(minLength: 4)
                    micButton
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
        // Flicking the composer down puts the keyboard away, which is quicker
        // than reaching for the transcript to tap it.
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 40 { focused.wrappedValue = false }
                }
        )
        .sheet(isPresented: $showModels) { ModelPicker() }
    }

    private var attachButton: some View {
        Button {
            // Attachments arrive with the multimodal work; the control is here
            // so the layout does not shift later.
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(true)
        .accessibilityLabel("Attach")
    }

    /// The model belongs next to the message it will answer, not buried in a
    /// settings screen — it is the single choice that most changes the reply.
    private var modelChip: some View {
        Button {
            showModels = true
        } label: {
            HStack(spacing: 4) {
                Text(currentModel)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: controlHeight)
            .background(Palette.muted(scheme).opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!store.isConnected)
        .accessibilityLabel("Model: \(currentModel)")
    }

    private var currentModel: String {
        store.models.first { $0.id == store.selectedModel }?.label
            ?? (store.isConnected ? "Model" : "Not connected")
    }

    /// Dictation writes into the draft rather than sending, so a misheard word
    /// can be fixed before the agent ever sees it.
    @ViewBuilder
    private var micButton: some View {
        let listening = dictation.isListening
        Button {
            dictation.prime(with: store.draft)
            dictation.toggle { store.draft = $0 }
        } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.system(size: 16, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor, isActive: listening)
        }
        .buttonStyle(.plain)
        .foregroundStyle(listening ? Color.accentColor : .secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
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
                .frame(width: controlHeight, height: controlHeight)
                .contentTransition(.symbolEffect(.replace))
        }
        // `.glassProminent` sizes itself, adding about 10pt of its own padding
        // around the label — measured at 44pt tall next to a 34pt chip. Applying
        // the material to an exact frame instead keeps the row one height.
        .buttonStyle(.plain)
        .foregroundStyle(store.isConnected ? Color.primary : Color.secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("send", in: glass)
        .disabled(!sending && (!hasDraft || !store.isConnected))
        .accessibilityLabel(stopping ? "Stop" : "Send")
    }
}
