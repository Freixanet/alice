import SwiftUI

/// Alice's editorial feed: posts she wrote from the person's brief, newest first.
///
/// Pull to refresh asks the Mac for new posts and returns at once; while the run goes on the
/// feed watches it and the posts appear when it ends. Offline, what was already read stays.
struct FeedScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var onOpenedChat: () -> Void = {}

    @State private var editingBrief = false
    @State private var explaining: FeedPost?
    @State private var undoable: FeedPost?
    @State private var undoTask: Task<Void, Never>?

    private var feed: FeedStore { store.feed }

    var body: some View {
        List {
            generationRow
                .animation(.snappy(duration: 0.25), value: feed.generation.state)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(feed.posts) { post in
                FeedPostCard(
                    post: post,
                    onLove: { Task { await feed.toggleLove(post) } },
                    onDiscuss: { discuss(post) },
                    onWhy: { explaining = post },
                    onDelete: { delete(post) },
                    onExpand: { feed.markRead(post) }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { delete(post) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            // Nothing yet and nothing being made: say what this is and how to get the first posts,
            // instead of a blank page.
            if feed.posts.isEmpty, feed.generation.state == .idle, feed.offlineReason == nil {
                ContentUnavailableView {
                    Label("No posts yet", systemImage: "newspaper")
                } description: {
                    Text("Your Mac writes posts here about what interests you. Ask for the first ones now, or wait for the next round.")
                } actions: {
                    Button("Get posts now") { Task { await feed.requestGeneration() } }
                        .buttonStyle(.borderedProminent).onAccentLabel()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if let reason = feed.offlineReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingBrief = true } label: { Image(systemName: "text.page") }
                    .accessibilityLabel("Coverage brief")
                    .accessibilityHint("What the feed covers, its tone and what it leaves out")
            }
        }
        .refreshable {
            await feed.requestGeneration()
            await feed.sync()
            feed.watch()
        }
        .task {
            await feed.sync()
            feed.watch()
        }
        .onDisappear { feed.stopWatching() }
        .onChange(of: feed.generation.isActive) { _, active in
            if active { feed.watch() }
        }
        .overlay(alignment: .bottom) { undoBar }
        .sheet(isPresented: $editingBrief) {
            FeedBriefEditor(initial: feed.brief, running: feed.generation.state == .running) { text in
                let saved = await feed.saveBrief(text)
                (saved ? Haptic.success : Haptic.error).play()
                if saved { feed.watch() }
                return saved
            }
            .preferredColorScheme(store.theme.colorScheme)
        }
        .sheet(item: $explaining) { post in
            FeedWhyThisSheet(post: post)
                .presentationDetents([.medium])
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    /// What the Mac is doing with the feed, in one quiet line; nothing while it rests.
    @ViewBuilder
    private var generationRow: some View {
        switch feed.generation.state {
        case .queued, .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing new posts…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(spacing: 6) {
                Text("Couldn’t write new posts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Haptic.tap.play()
                    Task {
                        await feed.requestGeneration()
                        feed.watch()
                    }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityHint("Asks your Mac to write new posts again")
            }
            .frame(maxWidth: .infinity)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var undoBar: some View {
        if let post = undoable {
            HStack(spacing: 12) {
                Text("Post deleted")
                    .font(.subheadline)
                Spacer(minLength: 0)
                Button("Undo") {
                    Haptic.success.play()
                    undoTask?.cancel()
                    undoable = nil
                    Task { await feed.undoDelete(post) }
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("Brings the post back")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func delete(_ post: FeedPost) {
        Haptic.warning.play()
        withMotion(.snappy) { undoable = post }
        Task { await feed.delete(post) }
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withMotion(.snappy) { undoable = nil }
        }
    }

    private func discuss(_ post: FeedPost) {
        store.discuss(post)
        onOpenedChat()
    }
}

/// Why a post is in the feed, as Alice put it.
private struct FeedWhyThisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let post: FeedPost

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(post.headline)
                    .font(.headline)
                Text(post.whyThis ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Why this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
