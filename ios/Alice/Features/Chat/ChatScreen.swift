import SwiftUI

struct ChatScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let onOpenDrawer: () -> Void

    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                transcript
                    // A plain tap anywhere off the composer dismisses the
                    // keyboard; `simultaneousGesture` leaves scrolling and text
                    // selection working underneath it.
                    .simultaneousGesture(
                        TapGesture().onEnded { composerFocused = false }
                    )
                Composer(focused: $composerFocused)
            }
            .background(Palette.background(scheme))
            .contentShape(.rect)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenDrawer) {
                        // Two bars, not three, matched to the `plus` opposite
                        // it. Both are math symbols, so the pairing is a real
                        // one — but not at the same settings: `equal` at 18pt
                        // medium draws the plus's 1.88pt stroke on bars 2pt
                        // too short, and going up a size to fix the width
                        // thickens it past the plus. 20pt regular lands on
                        // both: 1.88pt bars, 14.75pt wide against the plus's
                        // 15.0. (`line.3.horizontal`, the usual menu glyph,
                        // is a different family entirely and drew at 1.25pt,
                        // reading thin beside it.)
                        Image(systemName: "equal")
                            .font(.system(size: 20, weight: .regular))
                    }
                    .accessibilityLabel("Chats")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newChat()
                    } label: {
                        // `square.and.pencil` cannot sit straight in a round
                        // button: its square holds the visual mass low-left
                        // while the pencil runs a thin diagonal past the
                        // top-right, so centring the ink's bounding box —
                        // which measures as centred — still reads as tilted.
                        // A symmetric glyph has no such argument with itself.
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear.frame(height: 120).id(bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation.messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        } else {
            EmptyChatView()
        }
    }

    private var bottomAnchor: String { "bottom" }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("What are we working on?")
                .font(.aliceTitle(.title))
                .multilineTextAlignment(.center)
            Text("You talk to Alice. One thing at a time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
