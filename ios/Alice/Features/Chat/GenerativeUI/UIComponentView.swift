import MapKit
import SwiftUI

/// Draws a `UIComponent` in a reply.
struct UIComponentView: View {
    let component: UIComponent
    var language: ChatLanguage = .english

    var body: some View {
        switch component {
        case let .places(places):
            PlacesCarousel(places: places, language: language)
        case let .map(title, places):
            PlacesMapCard(title: title, places: places, language: language)
        case let .events(events):
            EventsCard(events: events, language: language)
        case let .timeline(steps):
            TimelineCard(steps: steps)
        case let .products(products):
            ProductsCarousel(products: products, language: language)
        case let .phrases(code, items):
            PhrasesCard(languageCode: code, phrases: items, language: language)
        case let .email(email):
            EmailDraftCard(draft: email, language: language)
        case let .calendar(month):
            MonthCard(month: month, language: language)
        case let .article(article):
            ArticleCard(article: article, language: language)
        case let .spending(spending):
            SpendingCard(spending: spending)
        }
    }
}

private struct SpendingCard: View {
    @Environment(\.colorScheme) private var scheme
    let spending: UIComponent.Spending

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Spending", systemImage: "chart.bar.xaxis")
                .font(.headline)
            if let from = spending.from, let to = spending.to {
                Text("\(from) – \(to)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                amount("Income", spending.income)
                amount("Spent", spending.spent)
                amount("Net", spending.net)
            }
            if !spending.categories.isEmpty {
                Divider()
                ForEach(spending.categories.prefix(5)) { category in
                    HStack {
                        Text(category.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(category.amount)).monospacedDigit()
                    }
                    .font(.footnote)
                }
            }
        }
        .componentCard(scheme)
    }

    private func amount(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(money(value)).font(.subheadline.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: spending.currency))
    }
}

// MARK: - Shared pieces

extension View {
    /// The surface every component sits on: the paper of a card, a hairline,
    /// and a generous radius — the same as the calendar cards.
    func componentCard(_ scheme: ColorScheme, padding: CGFloat = 16, radius: CGFloat = 22) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius).stroke(Palette.border(scheme), lineWidth: 0.5)
            }
    }
}

/// An image from the web, filled into its frame: `CardImage` with no page,
/// so it shares its cache, its card-size decoding and its placeholder.
struct RemoteImage: View {
    let url: URL?
    var symbol = "photo"

    var body: some View {
        CardImage(image: url, page: nil, symbol: symbol)
    }
}

/// A small pill of text: a time, a tag, a size.
struct ComponentPill: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint ?? .secondary)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.13), in: .capsule)
    }
}

/// Opening a place in Maps: by its coordinates when the agent gave them,
/// otherwise by name, which Maps searches for.
enum MapsLink {
    static func url(for place: UIComponent.Place) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        if let lat = place.latitude, let lon = place.longitude {
            parts?.queryItems = [
                URLQueryItem(name: "ll", value: "\(lat),\(lon)"),
                URLQueryItem(name: "q", value: place.title),
            ]
        } else {
            parts?.queryItems = [URLQueryItem(name: "q", value: place.query ?? place.title)]
        }
        return parts?.url
    }

    /// Directions to it, for the "how do I get there" a place invites.
    static func directions(to place: UIComponent.Place) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        let destination = place.latitude.flatMap { lat in place.longitude.map { "\(lat),\($0)" } }
        parts?.queryItems = [URLQueryItem(name: "daddr", value: destination ?? place.query ?? place.title)]
        return parts?.url
    }
}
