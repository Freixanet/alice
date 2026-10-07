import SwiftUI

/// Products Alice compared, from her `product_list` call (`product_list.py`): picture, name,
/// brand · shop, price with the price before an offer struck through, her pick marked. Nothing to
/// buy here; a tap opens the product page.
struct ProductList: Hashable, Sendable {
    struct Product: Hashable, Sendable, Identifiable {
        var title: String
        var brand: String
        var merchant: String
        var price: String
        var originalPrice: String
        var url: URL
        var image: URL?
        var recommended: Bool

        var id: String { url.absoluteString + title }

        /// "Sony · elcorteingles.es": who makes it and where the price is from.
        var byline: String {
            let shop = merchant.isEmpty ? (url.host() ?? "").replacingOccurrences(of: "www.", with: "") : merchant
            return [brand, shop].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    static let toolName = "product_list"
    static func isTool(_ name: String) -> Bool { name == toolName }

    var products: [Product]

    /// The call's arguments; nil when they name nothing that can be drawn.
    static func parse(_ detail: String?) -> ProductList? {
        guard let data = detail?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["products"] as? [[String: Any]]
        else { return nil }
        let products = items.compactMap { item -> Product? in
            func text(_ key: String) -> String { (item[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !text("title").isEmpty, !text("price").isEmpty,
                  let url = URL(string: text("url")), url.scheme == "https" else { return nil }
            let image = URL(string: text("image")).flatMap { $0.scheme == "https" ? $0 : nil }
            return Product(title: text("title"), brand: text("brand"), merchant: text("merchant"),
                           price: text("price"), originalPrice: text("original_price"), url: url,
                           image: image, recommended: item["recommended"] as? Bool ?? false)
        }
        return products.isEmpty ? nil : ProductList(products: products)
    }
}

struct ProductListCard: View {
    let list: ProductList
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(list.products.enumerated()), id: \.element.id) { index, product in
                if index > 0 { Divider().padding(.leading, 96) }
                Button {
                    Haptic.tap.play()
                    openURL(product.url)
                } label: {
                    row(product)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the product page")
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func row(_ product: ProductList.Product) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProductListThumb(image: product.image, page: product.url)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(product.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !product.byline.isEmpty {
                    Text(product.byline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(product.price)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if !product.originalPrice.isEmpty, product.originalPrice != product.price {
                        Text(product.originalPrice)
                            .font(.footnote)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Before \(product.originalPrice)")
                    }
                }
                if product.recommended {
                    Text("My pick")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

/// The product's picture: the one Alice gave, or else the page's own; the white around it trimmed.
private struct ProductListThumb: View {
    let image: URL?
    let page: URL
    @State private var picture: UIImage?
    @State private var looked = false

    var body: some View {
        Color.white
            .overlay {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFit().padding(6)
                } else if looked {
                    Image(systemName: "bag").font(.title2).foregroundStyle(.gray)
                } else {
                    ProgressView()
                }
            }
            .task(id: page) {
                let loaded = await CardImages.load(image: image, page: page)
                let trimmed = await Task.detached(priority: .userInitiated) {
                    loaded.flatMap(ProductThumb.trimmingWhite)
                }.value
                picture = trimmed ?? loaded
                looked = true
            }
    }
}
