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
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Chats")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newChat()
                    } label: {
                        // `square.and.pencil` hangs its pencil off the top-right,
                        // so the glyph reads low and left inside a round button.
                        // Nudge it back to the optical centre.
                        Image(systemName: "square.and.pencil")
                            .offset(x: 1, y: -1)
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
                    .padding(.top, 8)
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
