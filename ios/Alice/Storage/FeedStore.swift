import Foundation
import SwiftUI
import UIKit
import Observation
import os

/// Alice's editorial feed on this phone.
///
/// The Mac writes the posts (`feed.py`); this keeps what it wrote readable offline, carries
/// what the person does with each post back to it (an outbox of events, each with its own id so
/// a retry is applied once), and follows a run while the feed is on screen. Nothing here
/// generates, ranks or notifies.
@MainActor
@Observable
final class FeedStore {
    private(set) var cache = FeedCache()
    /// Why the last sync could not reach the Mac; the cached posts stay on screen meanwhile.
    private(set) var offlineReason: String?
    private(set) var syncing = false
    private(set) var requestingGeneration = false

    @ObservationIgnored private let client: DashboardClient
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pollingID: UUID?
    @ObservationIgnored private let log = Logger(subsystem: "alice", category: "feed")

    init(client: DashboardClient, file: URL? = FeedStore.standardFile) {
        self.client = client
        self.file = file
        load()
    }

    nonisolated static var standardFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Feed", directoryHint: .isDirectory)
            .appending(path: "feed.json", directoryHint: .notDirectory)
    }

    // MARK: Reading

    /// Newest first; the intro posts after the real ones, and hidden once enough real ones exist.
    var posts: [FeedPost] {
        let shown = cache.posts.filter { !$0.deleted }
        let real = shown.filter { !$0.isSeeded }
        if real.count >= FeedSeed.retireAfter { return real }
        return real + shown.filter(\.isSeeded)
    }

    var generation: FeedGeneration { cache.generation }
    var brief: String { cache.brief }

    // MARK: Syncing

    /// Sends what is waiting, then reads the feed: the server is the baseline and anything still
    /// waiting is replayed on top. Offline, the cache is left exactly as it was.
    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        await flushOutbox()
        do {
            let payload = try await client.feed()
            apply(payload)
            offlineReason = nil
        } catch {
            offlineReason = PlainWords.describe(error, doing: "reach your Mac")
            log.info("feed: sync failed, keeping \(self.cache.posts.count) cached posts")
        }
    }

    private func apply(_ payload: FeedPayload) {
        let before = Set(cache.posts.map(\.id))
        if payload.revision != cache.lastRevision || !cache.outbox.isEmpty {
            let seeded = cache.posts.filter(\.isSeeded)
            let merged = FeedMerge.merge(
                server: payload.feedPosts, local: cache.posts.filter { !$0.isSeeded }, outbox: cache.outbox
            )
            // New posts slide in and gone ones fold away, rather than the list jumping.
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { cache.posts = merged + seeded }
            if let text = payload.brief?.text { cache.brief = text }
        }
        cache.generation = payload.feedGeneration
        cache.lastRevision = payload.revision
        cache.syncedAt = Date()
        retireSeedsIfDue()
        save()
        let fresh = cache.posts.filter { !before.contains($0.id) && !$0.isSeeded }.count
        log.info("feed: \(fresh) new posts (revision \(payload.revision), \(self.cache.generation.state.rawValue))")
    }

    private func flushOutbox() async {
        for event in cache.outbox {
            let outcome = await client.postFeedEvent(event)
            switch outcome {
            case .accepted, .expired:
                cache.outbox.removeAll { $0.id == event.id }
            case .invalid(let reason):
                log.error("feed: event \(event.id.uuidString) refused: \(reason)")
                cache.outbox.removeAll { $0.id == event.id }
            case .retry:
                // Order matters for love and delete: later events wait behind this one.
                save()
                return
            }
        }
        // Acknowledged deletes are settled: those posts are gone for good.
        let waiting = Set(cache.outbox.filter { $0.kind == .delete }.map(\.postID))
        cache.posts.removeAll { $0.deleted && !$0.isSeeded && !waiting.contains($0.id) }
        save()
    }

    // MARK: Asking for posts

    /// Pull-to-refresh: asks the Mac for a run and returns at once; the posts arrive while the
    /// feed is watched (`watch`).
    func requestGeneration() async {
        guard !requestingGeneration, !cache.generation.isActive else { return }
        requestingGeneration = true
        defer { requestingGeneration = false }
        do {
            try await client.generateFeed()
            cache.generation.state = cache.generation.state == .running ? .running : .queued
            cache.generation.error = nil
            offlineReason = nil
            save()
        } catch {
            offlineReason = PlainWords.describe(error, doing: "ask your Mac for new posts")
        }
    }

    /// Saves the brief when it changed; the Mac starts one run for it (or the next one, when one
    /// is under way). Returns false when it could not be saved.
    func saveBrief(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != cache.brief else { return true }
        do {
            try await client.saveFeedBrief(text)
            cache.brief = text
            if !cache.generation.isActive { cache.generation.state = .queued }
            save()
            return true
        } catch {
            offlineReason = PlainWords.describe(error, doing: "save the brief")
            return false
        }
    }

    /// While the feed is on screen and a run is going, its status is checked every few seconds
    /// (the small route, never the whole feed); the feed is read once when it ends.
    func watch() {
        guard polling == nil else { return }
        let id = UUID()
        pollingID = id
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.cache.generation.isActive else { break }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                guard let status = try? await self.client.feedStatus() else { continue }
                guard !Task.isCancelled, self.pollingID == id else { break }
                let next = status.feedGeneration
                if next.isActive {
                    self.cache.generation = next
                } else {
                    await self.sync()
                    guard !Task.isCancelled, self.pollingID == id else { break }
                    self.cache.generation = next
                    self.save()
                    break
                }
            }
            if self?.pollingID == id {
                self?.polling = nil
                self?.pollingID = nil
            }
        }
    }

    func stopWatching() {
        polling?.cancel()
        polling = nil
        pollingID = nil
    }

    // MARK: What the person does

    func toggleLove(_ post: FeedPost) async {
        await record(post, kind: .love, on: !post.loved)
    }

    func delete(_ post: FeedPost) async {
        await record(post, kind: .delete, on: true)
    }

    /// Brings a deleted post back; the post travels with the undo, since an acknowledged delete
    /// has already let go of it here.
    func undoDelete(_ post: FeedPost) async {
        if !cache.posts.contains(where: { $0.id == post.id }) {
            var restored = post
            restored.deleted = true
            cache.posts.append(restored)
            cache.posts.sort { $0.createdAt > $1.createdAt }
        }
        await record(post, kind: .delete, on: false)
    }

    func discussed(_ post: FeedPost) async {
        await record(post, kind: .discuss, on: nil)
    }

    func markRead(_ post: FeedPost) {
        guard let index = cache.posts.firstIndex(where: { $0.id == post.id }), cache.posts[index].readAt == nil
        else { return }
        cache.posts[index].readAt = Date()
        save()
    }

    /// Applied here at once; sent to the Mac now or on the next sync. The intro posts are the
    /// app's own and never reach the Mac.
    private func record(_ post: FeedPost, kind: FeedEvent.Kind, on: Bool?) async {
        let event = FeedEvent(id: UUID(), postID: post.id, kind: kind, on: on, createdAt: Date())
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { cache.posts = FeedMerge.replay([event], on: cache.posts) }
        guard !post.isSeeded else {
            if kind == .delete, on == true { cache.posts.removeAll { $0.id == post.id && $0.deleted } }
            save()
            return
        }
        cache.outbox.append(event)
        save()
        await flushOutbox()
    }

    // MARK: Seeds

    private func seedIfNew() {
        guard !cache.seeded else { return }
        cache.seeded = true
        cache.posts += FeedSeed.posts()
        save()
    }

    private func retireSeedsIfDue() {
        let real = cache.posts.filter { !$0.isSeeded && !$0.deleted }.count
        if real >= FeedSeed.retireAfter { cache.posts.removeAll(where: \.isSeeded) }
    }

    // MARK: Storage

    private func load() {
        defer { seedIfNew() }
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            cache = try Self.decoder.decode(FeedCache.self, from: data)
        } catch {
            log.error("feed: cache unreadable, starting empty")
        }
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(cache)
            // Written whole, then moved into place: a crash never leaves half a feed.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("feed: cache not saved")
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
