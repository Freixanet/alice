import LinkPresentation
import SwiftUI
import UIKit

/// The picture a web page chooses for itself — the one Messages and Safari
/// show when the link is shared — for a card whose agent linked the page but
/// had no image address. Real, from the source, never guessed.
@MainActor
enum LinkPreviewImages {
    private static var cache: [URL: UIImage] = [:]
    private static var missing: Set<URL> = []
    private static var loading: [URL: Task<UIImage?, Never>] = [:]

    static func cached(_ url: URL) -> UIImage? { cache[url] }

    static func image(for url: URL) async -> UIImage? {
        if let image = cache[url] { return image }
        if missing.contains(url) { return nil }
        if let task = loading[url] { return await task.value }
        let task = Task { @MainActor () -> UIImage? in
            let provider = LPMetadataProvider()
            provider.timeout = 12
            guard let metadata = try? await provider.startFetchingMetadata(for: url),
                  let item = metadata.imageProvider
            else { return nil }
            return await withCheckedContinuation { continuation in
                _ = item.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image {
            if cache.count > 60 { cache.removeAll() }
            cache[url] = image
        } else {
            missing.insert(url)
        }
        return image
    }
}

/// `RemoteImage`, falling back to the linked page's own picture.
struct CardImage: View {
    @Environment(\.colorScheme) private var scheme
    let image: URL?
    let page: URL?
    var symbol = "photo"

    @State private var preview: UIImage?
    @State private var looked = false

    var body: some View {
        if image != nil || page == nil {
            RemoteImage(url: image, symbol: symbol)
        } else {
            // An overlay, so the filled picture cannot size the view; see `RemoteImage`.
            Palette.muted(scheme)
                .overlay {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFill().transition(.opacity)
                    } else if looked {
                        Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
                    }
                }
                .clipped()
            .task(id: page) {
                guard let page else { return }
                if let cached = LinkPreviewImages.cached(page) {
                    preview = cached
                    return
                }
                let found = await LinkPreviewImages.image(for: page)
                withAnimation(.easeOut(duration: 0.25)) {
                    preview = found
                    looked = true
                }
            }
        }
    }
}
