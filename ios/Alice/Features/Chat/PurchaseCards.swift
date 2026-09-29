import SwiftUI

// The purchase, as the cards of a checkout: big rounded surfaces with no outline, an inner grey group
// for the rows, dotted dividers, and two tall capsule buttons.

private struct DottedDivider: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [1.5, 3.5]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return path
        }
    }
}

/// A tall capsule, the grey one for refusing and the accent one for going on.
struct PurchaseCapsuleButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let title: String
    var prominent = false
    var disabled = false
    /// An SF Symbol before the title, such as Face ID on the button that pays.
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let symbol { Image(systemName: symbol) } }
                .font(.headline)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(prominent ? store.accent.control(scheme) : Palette.muted(scheme), in: .capsule)
                .opacity(disabled ? 0.5 : 1)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// The checkout: what is bought, where it goes, who is told, with which card, the total, and the answer.
struct PurchaseCheckoutCard: View {
    @Environment(\.colorScheme) private var scheme

    let title: String
    let detail: String?
    let image: URL?
    let delivery: String
    var contact: String? = nil
    let cardLabel: String
    var cardVia: String? = nil
    let site: String
    let total: String
    var language: ChatLanguage = .english
    var disabled = false
    var onOpenProduct: (() -> Void)? = nil
    let onPay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.pick("Checkout", "Pago")).font(.title3.weight(.medium))
                Spacer()
                Text(site).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                Button { onOpenProduct?() } label: {
                    PurchaseThumbRow(image: image, title: title, detail: detail)
                        .padding(14)
                }
                .buttonStyle(.plain)
                .disabled(onOpenProduct == nil)
                DottedDivider().padding(.horizontal, 14)
                row(symbol: "shippingbox", text: delivery)
                if let contact {
                    DottedDivider().padding(.horizontal, 14)
                    row(symbol: "envelope", text: contact)
                }
            }
            .background(Palette.background(scheme), in: .rect(cornerRadius: 22))

            HStack(spacing: 12) {
                CardBrandBadge(label: cardLabel)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cardLabel).font(.body)
                    if let cardVia { Text(cardVia).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                chevron
            }
            .padding(14)
            .background(Palette.background(scheme), in: .rect(cornerRadius: 22))

            HStack {
                Text(language.pick("Estimated total", "Total estimado")).font(.body)
                Spacer()
                Text(total.pricesKeptTogether).font(.body.monospacedDigit())
            }
            .padding(.horizontal, 8)

            HStack(spacing: 10) {
                PurchaseCapsuleButton(title: language.pick("Cancel", "Cancelar"), disabled: disabled, action: onCancel)
                PurchaseCapsuleButton(title: language.pick("Pay", "Pagar"), prominent: true,
                                      disabled: disabled, symbol: Biometrics.symbol, action: onPay)
            }

            Text(language.pick("By continuing you accept \(site)'s terms, privacy policy and returns policy.",
                               "Al continuar aceptas las condiciones, la privacidad y las devoluciones de \(site)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 30)
            Text(text).font(.body)
            Spacer()
            chevron
        }
        .padding(14)
    }
}

/// A thumbnail, a name and a line under it: the item in a checkout or a list.
struct PurchaseThumbRow: View {
    let image: URL?
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 14) {
            CardImage(image: image, page: nil, symbol: "bag", fits: true)
                .background(Color.white)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The products found, one under another in a grey rounded group.
struct PurchaseProductList: View {
    @Environment(\.colorScheme) private var scheme

    struct Item: Identifiable {
        let id = UUID()
        let image: URL?
        let title: String
        let subtitle: String
        let price: String
    }

    let items: [Item]
    var onOpen: (Item) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button { onOpen(item) } label: {
                    HStack(spacing: 14) {
                        CardImage(image: item.image, page: nil, symbol: "bag", fits: true)
                            .background(Color.white)
                            .frame(width: 60, height: 60)
                            .clipShape(.rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            Text(item.price.pricesKeptTogether).font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Palette.muted(scheme), in: .rect(cornerRadius: 24))
    }
}

/// "Visa ···4242" as a small brand mark, so the card reads at a glance.
struct CardBrandBadge: View {
    let label: String

    var body: some View {
        Text((label.split(separator: " ").first.map(String.init) ?? label).uppercased())
            .font(.system(size: 11, weight: .heavy).italic())
            .foregroundStyle(Color(red: 0.10, green: 0.12, blue: 0.45))
            .frame(width: 42, height: 28)
            .background(Color.white, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.08), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

/// While the order goes through, and then that it did.
struct PurchaseProgressCard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let title: String
    let site: String
    let done: Bool
    let doneText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(site).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.title3)
                        .foregroundStyle(store.accent.control(scheme))
                } else {
                    ProgressView()
                }
                Text(done ? doneText : "…").font(.body)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }
}

/// The receipt: lines, what was paid, with which card and that it went through.
struct PurchaseReceiptCard: View {
    @Environment(\.colorScheme) private var scheme
    let site: String
    let order: String
    let lines: [(String, String)]
    let paid: String
    let paidLabel: String
    let cardLabel: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site).font(.title3.weight(.medium))
                Text(order).font(.subheadline).foregroundStyle(.secondary)
            }
            DottedDivider()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack {
                    Text(line.0).font(.body)
                    Spacer()
                    Text(line.1.pricesKeptTogether).font(.body.monospacedDigit())
                }
            }
            DottedDivider()
            HStack {
                Text(paidLabel).font(.body.weight(.semibold))
                Spacer()
                Text(paid.pricesKeptTogether).font(.body.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 8) {
                Image(systemName: "creditcard").foregroundStyle(.secondary)
                Text(cardLabel).font(.subheadline)
                Spacer()
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }
}

/// The item on its own: a big photo, who sells it, the price with the old one struck through, an
/// option to choose, and the two ways on: buy it here, or go to the shop.
struct PurchaseProductSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let image: URL?
    let seller: String
    let title: String
    let price: String
    let oldPrice: String?
    var language: ChatLanguage = .english
    var options: [String] = []
    let onBuy: () -> Void

    @State private var chosen = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CardImage(image: image, page: nil, symbol: "bag", fits: true)
                    .background(Color.white)
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 28))
                    .overlay(alignment: .topTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .padding(12)
                        .accessibilityLabel(language.pick("Close", "Cerrar"))
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.pick("From \(seller)", "De \(seller)")).font(.body).foregroundStyle(.secondary)
                    Text(title).font(.title2.weight(.medium))
                    HStack(spacing: 8) {
                        Text(price.pricesKeptTogether).font(.title3.monospacedDigit())
                        if let oldPrice {
                            Text(oldPrice.pricesKeptTogether).font(.body.monospacedDigit())
                                .strikethrough().foregroundStyle(.secondary)
                        }
                    }
                    if !options.isEmpty { optionPicker.padding(.top, 10) }
                    PurchaseCapsuleButton(title: language.pick("Buy with Alice", "Comprar con Alice"), prominent: true) {
                        dismiss()
                        onBuy()
                    }
                    .padding(.top, 10)
                    PurchaseCapsuleButton(title: language.pick("Visit website", "Visitar la web")) { dismiss() }
                }
                .padding(.top, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Palette.card(scheme))
        .presentationDetents([.large])
        .presentationCornerRadius(32)
    }

    /// The options in a grey track with the chosen one lifted on a white pill.
    private var optionPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, name in
                Button { withAnimation(.snappy) { chosen = index } } label: {
                    Text(name).font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if chosen == index { Capsule().fill(Palette.card(scheme)) }
                        }
                        .foregroundStyle(chosen == index ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Palette.muted(scheme), in: .capsule)
    }
}

/// What the browser is doing, above the checkout: the agent is waiting for the person's answer.
struct PurchaseBrowserRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe").font(.title3)
                .frame(width: 44, height: 44)
                .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.muted(scheme), in: .rect(cornerRadius: 22))
    }
}
