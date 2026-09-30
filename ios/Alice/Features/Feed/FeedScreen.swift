import SwiftUI

/// Alice's editorial feed: posts she wrote from the person's brief, newest first.
///
/// Pull to refresh asks the Mac for new posts and returns at once; while the run goes on the
/// feed watches it and the posts appear when it ends. Offline, what was already read stays.
struct FeedScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var onOpenedChat: () -> Void = {}

    @State private var editingBrief = false
    @State private var explaining: FeedPost?
    @State private var undoable: FeedPost?
    @State private var undoTask: Task<Void, Never>?

    private var feed: FeedStore { store.feed }

    var body: some View {
        List {
            generationRow
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: feed.generation.state)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if feed.posts.isEmpty {
                emptyState
                    .listRowInsets(EdgeInsets(top: 28, leading: 24, bottom: 28, trailing: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
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
            if !Task.isCancelled, scenePhase == .active { feed.watch() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                feed.stopWatching()
                return
            }
            await feed.sync()
            guard !Task.isCancelled else { return }
            feed.watch()
        }
        .onDisappear { feed.stopWatching() }
        .onChange(of: feed.generation.isActive) { _, active in
            if active, scenePhase == .active { feed.watch() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { undoBar }
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

    /// An empty feed still says what is happening and offers one useful next step.
    private var emptyState: some View {
        VStack(spacing: 12) {
            if feed.syncing || feed.requestingGeneration || feed.generation.isActive {
                if !feed.generation.isActive { ProgressView() }
                Text(feed.generation.isActive ? String(localized: "Your first posts are on their way") : String(localized: "Checking for posts…"))
                    .font(.headline)
            } else {
                Text("No posts yet")
                    .font(.aliceTitle(.title2))
                    .accessibilityAddTraits(.isHeader)
                Text(feed.offlineReason == nil
                     ? String(localized: "Choose what Alice covers, then ask your Mac for new posts.")
                     : String(localized: "Your saved posts will appear here when your Mac is reachable."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if feed.offlineReason != nil {
                    Button("Retry") { Task { await feed.sync(); feed.watch() } }
                        .buttonStyle(.bordered)
                        .disabled(feed.syncing)
                } else if feed.generation.state != .failed {
                    Button("Coverage brief") { editingBrief = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("feed.empty")
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
            VStack(spacing: 8) {
                Text("Couldn’t write new posts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let error = feed.generation.error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Haptic.tap.play()
                    Task {
                        await feed.requestGeneration()
                        feed.watch()
                    }
                } label: {
                    Text("Retry").frame(minHeight: 44)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(feed.requestingGeneration)
                .accessibilityHint("Asks your Mac to write new posts again")
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
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
                Button {
                    Haptic.tap.play()
                    undoTask?.cancel()
                    undoable = nil
                    Task { await feed.undoDelete(post) }
                } label: {
                    Text("Undo").frame(minHeight: 44)
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("Brings the post back")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func delete(_ post: FeedPost) {
        Haptic.warning.play()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { undoable = post }
        Task { await feed.delete(post) }
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { undoable = nil }
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
    @Environment(\.colorScheme) private var scheme
    let post: FeedPost

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(post.headline)
                        .font(.headline)
                    Text(post.whyThis ?? "")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.background(scheme))
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
