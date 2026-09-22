import CryptoKit
import ImageIO
import LinkPresentation
import SwiftUI
import UIKit

/// Pictures for the cards: the image an agent named, or else the one the
/// linked page chooses for itself — its `og:image`, the picture Messages and
/// Safari show when the link is shared. Real, from the source, never guessed.
///
/// Built for a row of cards arriving at once. The first version handed every
/// page to LinkPresentation, which loads and runs the whole page, one after
/// another: heavy pages took many seconds or gave up, and nothing was kept,
/// so the same card started again from nothing. Now the page's head is read
/// only as far as its picture tag, all cards fetch side by side, the picture
/// is shrunk to card size as it is decoded, and the result is kept in memory
/// and on disk. LinkPresentation remains the fallback for a page with no tag.
enum CardImages {
    /// Largest side of a decoded picture, in pixels: a card is at most 236pt wide.
    nonisolated static let maxPixels: CGFloat = 900
    nonisolated static let pageTimeout: TimeInterval = 6
    nonisolated static let imageTimeout: TimeInterval = 10
    /// How much of a page is read looking for its picture tag.
    nonisolated static let headLimit = 300_000

    @MainActor private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    @MainActor private static var loading: [URL: Task<UIImage?, Never>] = [:]
    /// Pages found to have no picture, and when: tried again after a while,
    /// not never — a page that timed out once may answer next time.
    @MainActor private static var missing: [URL: Date] = [:]

    /// Already decoded, for drawing on the first frame without a flash.
    @MainActor static func cached(image: URL?, page: URL?) -> UIImage? {
        guard let key = image ?? page else { return nil }
        return memory.object(forKey: key as NSURL)
    }

    @MainActor static func load(image: URL?, page: URL?) async -> UIImage? {
        guard let key = image ?? page else { return nil }
        if let hit = memory.object(forKey: key as NSURL) { return hit }
        if let when = missing[key], Date().timeIntervalSince(when) < 600 { return nil }
        if let task = loading[key] { return await task.value }
        let task = Task<UIImage?, Never> {
            let stored = await Task.detached(priority: .userInitiated) { Self.fromDisk(key) }.value
            if let stored { return stored }
            var picture: UIImage?
            if let image {
                picture = await Task.detached(priority: .userInitiated) { await Self.download(image) }.value
            }
            if picture == nil, let page {
                picture = await Task.detached(priority: .userInitiated) { () async -> UIImage? in
                    guard let found = await Self.pictureAddress(of: page) else { return nil }
                    return await Self.download(found)
                }.value
                if picture == nil { picture = await Self.linkPresentation(page) }
            }
            if let picture {
                let copy = picture
                Task.detached(priority: .utility) { Self.toDisk(copy, key: key) }
            }
            return picture
        }
        loading[key] = task
        let picture = await task.value
        loading[key] = nil
        if let picture {
            memory.setObject(picture, forKey: key as NSURL)
        } else {
            missing[key] = Date()
        }
        return picture
    }

    // MARK: - Finding the page's picture

    /// The page's own picture: `og:image`, `twitter:image` or `image_src`,
    /// read from its head without loading the rest.
    nonisolated static func pictureAddress(of page: URL) async -> URL? {
        var request = URLRequest(url: page, timeoutInterval: pageTimeout)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true
        else { return nil }
        var data = Data()
        data.reserveCapacity(64_000)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= headLimit { break }
                // The tags live in the head; stop as soon as it closes.
                if byte == UInt8(ascii: ">"), data.count > 512,
                   data.suffix(7) == Data("</head>".utf8) { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = String(decoding: data, as: UTF8.self)
        return metaImage(in: html, base: response.url ?? page)
    }

    /// The picture named in a page's head, as an absolute web address.
    nonisolated static func metaImage(in html: String, base: URL) -> URL? {
        let tags = html.matches(of: /<(?:meta|link)\b[^>]*>/.ignoresCase())
        let wanted = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src", "image_src"]
        var found: [String: String] = [:]
        for match in tags {
            let tag = String(match.output)
            guard let key = attribute(in: tag, named: ["property", "name", "rel", "itemprop"])?.lowercased(),
                  wanted.contains(key) || key == "image",
                  let value = attribute(in: tag, named: ["content", "href"]), !value.isEmpty,
                  found[key] == nil
            else { continue }
            found[key] = value
        }
        for key in wanted + ["image"] {
            guard let raw = found[key] else { continue }
            let value = raw.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { continue }
            return url
        }
        return nil
    }

    nonisolated private static func attribute(in tag: String, named names: [String]) -> String? {
        for name in names {
            let pattern = try? Regex("\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))").ignoresCase()
            guard let pattern, let match = tag.firstMatch(of: pattern) else { continue }
            for index in 2...4 {
                if let value = match.output[index].substring { return String(value) }
            }
        }
        return nil
    }

    // MARK: - Downloading and decoding

    /// Downloaded and shrunk to card size while decoding: a 4000px photo
    /// never sits whole in memory for a 236pt card.
    nonisolated static func download(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: imageTimeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true
        else { return nil }
        return downsample(data)
    }

    nonisolated static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // A tracking pixel or a 1×1 spacer is not a picture.
        guard image.width >= 80, image.height >= 80 else { return nil }
        return UIImage(cgImage: image)
    }

    /// The system's link preview, for a page whose head names no picture.
    @MainActor private static func linkPresentation(_ page: URL) async -> UIImage? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let metadata = try? await provider.startFetchingMetadata(for: page),
              let item = metadata.imageProvider
        else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            _ = item.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return image }
        return downsample(data) ?? image
    }

    // MARK: - Disk

    nonisolated private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("card-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated private static func file(for key: URL) -> URL? {
        let digest = SHA256.hash(data: Data(key.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest + ".jpg")
    }

    nonisolated private static func fromDisk(_ key: URL) -> UIImage? {
        guard let file = file(for: key), let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    nonisolated private static func toDisk(_ image: UIImage, key: URL) {
        guard let file = file(for: key), let data = image.jpegData(compressionQuality: 0.82) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// A card's picture: the image the agent named, else the linked page's own,
/// with a quiet placeholder while it arrives and a symbol if there is none.
struct CardImage: View {
    @Environment(\.colorScheme) private var scheme
    let image: URL?
    let page: URL?
    var symbol = "photo"
    /// Whole, on its own background — a product shot — rather than filling the frame.
    var fits = false

    @State private var picture: UIImage?
    @State private var looked = false

    var body: some View {
        // An overlay on a plain surface, so the filled picture cannot size
        // the view and spill over the text below.
        Palette.muted(scheme)
            .overlay {
                if let picture {
                    Image(uiImage: picture).resizable()
                        .aspectRatio(contentMode: fits ? .fit : .fill)
                        .padding(fits ? 14 : 0)
                        .transition(.opacity)
                } else if looked || (image == nil && page == nil) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
                } else {
                    ShimmerPlaceholder()
                }
            }
            .clipped()
            .task(id: (image?.absoluteString ?? "") + "|" + (page?.absoluteString ?? "")) {
                if let cached = CardImages.cached(image: image, page: page) {
                    picture = cached
                    return
                }
                guard image != nil || page != nil else { return }
                let found = await CardImages.load(image: image, page: page)
                withAnimation(.easeOut(duration: 0.25)) {
                    picture = found
                    looked = true
                }
            }
    }
}

/// A soft band of light crossing the placeholder while a picture loads, so
/// an empty card reads as arriving, not as broken.
private struct ShimmerPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                GeometryReader { box in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * 0.6)
                        .offset(x: (box.size.width * 1.6) * phase - box.size.width * 0.6)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
