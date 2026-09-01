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
                Composer(focused: $composerFocused)
            }
            .background(Palette.background(scheme))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenDrawer) {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Chats")
                }
                // The model belongs in the title: it is what the reply depends
                // on, and it changes far more often than anything else here.
                ToolbarItem(placement: .principal) {
                    ModelMenu()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
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

private struct ModelMenu: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            if store.models.isEmpty {
                Text("Connect your Hermes")
            } else {
                ForEach(store.models) { model in
                    Button {
                        store.selectedModel = model.id
                    } label: {
                        if model.id == store.selectedModel {
                            Label(model.label, systemImage: "checkmark")
                        } else {
                            Text(model.label)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current).font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var current: String {
        store.models.first { $0.id == store.selectedModel }?.label ?? "Alice"
    }
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
