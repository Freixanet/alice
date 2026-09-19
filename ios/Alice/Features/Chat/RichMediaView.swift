import SwiftUI
import UIKit
import AVKit
import AVFoundation

// MARK: - State

/// One media card's state: where its bytes are, and the player once it has
/// them. Held per card so the chat can redraw the row without losing the
/// playhead, and torn down when the row leaves the screen.
@MainActor
@Observable
final class RichMediaModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(URL)
        case failed(String)
    }

    let media: RichMedia
    private(set) var phase: Phase
    private(set) var player: AVPlayer?
    private(set) var image: UIImage?
    private(set) var bytes: Int64?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    private var fetching: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    init(media: RichMedia) {
        self.media = media
        if let cached = RichMediaLoader.cached(media) {
            phase = .ready(cached.file)
            bytes = Self.size(of: cached.file)
            if media.kind == .image { image = UIImage(contentsOfFile: cached.file.path) }
        } else {
            phase = .idle
        }
    }

    var file: URL? {
        if case let .ready(url) = phase { return url }
        return nil
    }

    /// Fetches the bytes if they are not on the phone yet. `then` runs once
    /// they are, on this actor, so a tap on the poster can start playback.
    func fetch(with fetchers: RichMediaLoader.Fetchers, then: (@MainActor (URL) -> Void)? = nil) {
        if let file {
            then?(file)
            return
        }
        guard fetching == nil else { return }
        phase = .loading
        fetching = Task { [weak self] in
            guard let self else { return }
            defer { fetching = nil }
            do {
                let loaded = try await RichMediaLoader.load(media, with: fetchers)
                guard !Task.isCancelled else { return }
                bytes = Self.size(of: loaded.file)
                if media.kind == .image {
                    image = UIImage(contentsOfFile: loaded.file.path)
                    if image == nil {
                        phase = .failed("This image can’t be shown.")
                        return
                    }
                }
                phase = .ready(loaded.file)
                then?(loaded.file)
            } catch is CancellationError {
                phase = .idle
            } catch let failure as RichMediaLoader.Failure {
                phase = .failed(failure.localizedDescription)
            } catch {
                phase = .failed(PlainWords.describe(error, doing: "fetch this file"))
            }
        }
    }

    func retry(with fetchers: RichMediaLoader.Fetchers, then: (@MainActor (URL) -> Void)? = nil) {
        // A download already under way is the retry: say so, do not restart it.
        if fetching != nil {
            phase = .loading
            return
        }
        dropPlayer()
        phase = .idle
        fetch(with: fetchers, then: then)
    }

    // MARK: Playback

    /// Makes the player on first use and starts it. Sound comes through even
    /// with the ringer switch off: a video someone asked for is not a ping.
    func play(_ file: URL) {
        if player == nil {
            let item = AVPlayerItem(url: file)
            let fresh = AVPlayer(playerItem: item)
            fresh.actionAtItemEnd = .pause
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let reason = item.error?.localizedDescription
                Task { @MainActor [weak self] in self?.itemStatusChanged(status, reason: reason) }
            }
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObserver = fresh.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                let seconds = time.seconds
                MainActor.assumeIsolated { self?.tick(seconds) }
            }
            player = fresh
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Playing at the current session settings beats silence.
        }
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayback(with fetchers: RichMediaLoader.Fetchers) {
        if isPlaying {
            pause()
        } else {
            fetch(with: fetchers) { [weak self] file in self?.play(file) }
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
    }

    /// Stops playing and lets the player go. The bytes stay cached, so the
    /// card comes back in a tap, without another download.
    func tearDown() {
        fetching?.cancel()
        fetching = nil
        dropPlayer()
        if case .loading = phase { phase = .idle }
    }

    /// Lets the player go and hands the speaker back to whatever was playing
    /// before, so music paused for a clip comes back when the clip is done.
    private func dropPlayer() {
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        player?.pause()
        let hadPlayer = player != nil
        player = nil
        isPlaying = false
        elapsed = 0
        if hadPlayer {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// A file the phone cannot play: the player goes, so the card can say why
    /// instead of sitting as a black box.
    private func itemStatusChanged(_ status: AVPlayerItem.Status, reason: String?) {
        guard status == .failed else { return }
        dropPlayer()
        let plain = reason.flatMap { PlainWords.looksTechnical($0) ? nil : $0 }
        phase = .failed(plain ?? "This file can’t be played on this phone. It may be damaged or in a format iOS doesn’t support.")
    }

    private func tick(_ seconds: Double) {
        guard let player else { return }
        if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 {
            duration = total
        }
        elapsed = max(0, min(seconds, duration > 0 ? duration : seconds))
        let playing = player.timeControlStatus == .playing
            || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isPlaying != playing { isPlaying = playing }
        // At the end the player pauses on its own; the next tap starts over,
        // and other apps get their sound back meanwhile.
        if duration > 0, seconds >= duration - 0.05, !playing {
            elapsed = 0
            player.seek(to: .zero)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func size(of file: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }
}

// MARK: - Card

/// Media from a reply, drawn as what it is: video plays in the chat with a
/// full-screen option, audio gets a player, images preview inline with a
/// tap-to-zoom viewer, other files a save button. The address never shows.
struct RichMediaView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let media: RichMedia
    @State private var model: RichMediaModel
    @State private var fullscreen = false
    @State private var shareItem: MediaShareItem?

    init(media: RichMedia) {
        self.media = media
        _model = State(initialValue: RichMediaModel(media: media))
    }

    private var fetchers: RichMediaLoader.Fetchers { RichMediaLoader.fetchers(store) }

    private var isLoading: Bool {
        if case .loading = model.phase { return true }
        return false
    }

    var body: some View {
        Group {
            switch media.kind {
            case .video: videoCard
            case .audio: audioCard
            case .image: imageCard
            case .file: fileCard
            }
        }
        // Presenting the full-screen player is not leaving the chat: the
        // player must survive it.
        .onDisappear { if !fullscreen { model.tearDown() } }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $fullscreen) {
            if let player = model.player {
                FullscreenVideo(player: player, title: media.title)
            }
        }
    }

    // MARK: Video

    private var videoCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player = model.player {
                    NativeVideoPlayer(player: player)
                } else {
                    switch model.phase {
                    case .ready, .idle:
                        poster(symbol: "play.circle.fill", caption: nil)
                            .onTapGesture { model.fetch(with: fetchers) { model.play($0) } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Play \(media.title)")
                    case .loading:
                        poster(symbol: nil, caption: loadingCaption)
                    case let .failed(reason):
                        failure(reason)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .transaction { $0.animation = nil }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(detail(kind: "Video"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.player != nil {
                    Button {
                        fullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Full screen")
                }
                actionsMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func poster(symbol: String?, caption: String?) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 48, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                } else {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .contentShape(.rect)
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
            Text(reason)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .padding(.horizontal, 16)
            HStack(spacing: 8) {
                Button("Try again") {
                    model.retry(with: fetchers) { file in
                        if media.kind == .video || media.kind == .audio { model.play(file) }
                    }
                }
                if let web = media.webURL {
                    Link("Open link", destination: web)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.1))
    }

    // MARK: Audio

    private var audioCard: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlayback(with: fetchers)
            } label: {
                ZStack {
                    Circle()
                        .fill(store.accent.primary(scheme))
                        .frame(width: 44, height: 44)
                    if case .loading = model.phase {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .offset(x: model.isPlaying ? 0 : 1)
                    }
                }
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(model.isPlaying ? "Pause \(media.title)" : "Play \(media.title)")

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if case let .failed(reason) = model.phase {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if model.player != nil {
                    AudioScrubber(
                        elapsed: model.elapsed, duration: model.duration,
                        tint: store.accent.primary(scheme)
                    ) { model.seek(to: $0) }
                    Text(Self.clock(model.elapsed) + (model.duration > 0 ? " / " + Self.clock(model.duration) : ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(loadingOrDetail(kind: "Audio"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            actionsMenu
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Image

    private var imageCard: some View {
        Group {
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Palette.border(scheme), lineWidth: 0.5)
                    }
                    .opensImageViewer(image)
                    .contextMenu { menuItems }
                    .accessibilityLabel(media.title)
            } else if case let .failed(reason) = model.phase {
                compactFailure(reason)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
                    .accessibilityLabel("Loading \(media.title)")
            }
        }
        .onAppear { model.fetch(with: fetchers) }
    }

    // MARK: File

    private var fileCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if case let .failed(reason) = model.phase {
                    Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(loadingOrDetail(kind: "File")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 7))
            .controlSize(.small)
            .tint(.primary)
            .disabled(isLoading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
    }

    private func compactFailure(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title).font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Try again") { model.retry(with: fetchers) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
    }

    // MARK: Shared

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.footnote.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            save()
        } label: {
            Label("Save to Files", systemImage: "square.and.arrow.down")
        }
        if let web = media.webURL {
            Button {
                UIPasteboard.general.url = web
            } label: {
                Label("Copy link", systemImage: "link")
            }
            Link(destination: web) {
                Label("Open link", systemImage: "safari")
            }
        }
        if media.hermesPath != nil {
            Button {
                UIPasteboard.general.string = media.hermesPath
            } label: {
                Label("Copy path on Hermes", systemImage: "folder")
            }
        }
    }

    /// Hands the local file to the share sheet, fetching it first if needed.
    private func save() {
        model.fetch(with: fetchers) { file in
            shareItem = MediaShareItem(url: file)
        }
    }

    private var loadingCaption: String {
        media.hermesPath != nil ? "Fetching from Hermes…" : "Fetching…"
    }

    private func loadingOrDetail(kind: String) -> String {
        if case .loading = model.phase { return loadingCaption }
        return detail(kind: kind)
    }

    private func detail(kind: String) -> String {
        var parts = [kind]
        if let bytes = model.bytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else if media.hermesPath != nil {
            parts.append("On Hermes")
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600, minutes = (whole % 3600) / 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - Pieces

/// The system player, inline: scrubber, volume, AirPlay and its own
/// full-screen toggle, the way every other video on the phone behaves.
private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

/// The same player, over the whole screen, with a way back.
private struct FullscreenVideo: View {
    @Environment(\.dismiss) private var dismiss
    let player: AVPlayer
    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            NativeVideoPlayer(player: player)
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: .circle)
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .accessibilityLabel(title)
    }
}

/// A thin progress bar the finger can drag along.
private struct AudioScrubber: View {
    let elapsed: Double
    let duration: Double
    let tint: Color
    let onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = duration > 0 ? min(max((dragging ?? elapsed) / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(tint).frame(width: width * fraction)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragging = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let target = min(max(value.location.x / width, 0), 1) * duration
                        dragging = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(RichMediaView.clock(elapsed))
    }
}

struct MediaShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
