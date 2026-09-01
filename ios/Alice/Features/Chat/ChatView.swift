import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ZStack(alignment: .bottom) {
                transcript
                Composer(focused: $composerFocused)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .background(Palette.background(scheme))
            // Content runs under the floating bars; the soft edge keeps text
            // legible where it passes beneath them.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(store.activeConversation?.title ?? "Alice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { HistoryView() } label: {
                        Label("Chats", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newChat()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        // Room for the composer and the floating tab bar.
                        Color.clear.frame(height: 140).id(bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
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
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
