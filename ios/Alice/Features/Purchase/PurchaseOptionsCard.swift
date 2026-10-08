import SwiftUI

/// Step 5 of buying: the options Alice found and verified, as product cards of their own in the
/// chat — picture, name, shop, price — with her recommendation marked. Step 6: a tap opens the
/// product and «Comprar con Alice» sends the choice; the plugin starts that option's errand. Up to
/// here nothing about paying has been touched.
///
/// Drawn from the plugin's verified list (`PurchaseOptionSet`), fetched by the key of the call's
/// arguments; `preview` is the gallery's and the walkthrough's own list.
struct PurchaseOptionsCard: View {
    /// The `purchase_options` call's detail (its arguments as JSON).
    let detail: String?
    var language: ChatLanguage = .spanish
    var preview: PurchaseOptionSet? = nil
    var session: String? = nil
    var replyProfile: String? = nil
    /// The walkthrough answers here instead of sending a message.
    var onChoose: ((PurchaseOption) -> Void)? = nil
    var onChooseQuantity: ((PurchaseOption, Int) -> Void)? = nil
    /// The set to draw when there is no call to read it from (a stopped purchase's «Ver otras opciones»).
    var key: String? = nil
    /// Offered again after the chosen option could not be bought: that one is left out and the
    /// others can be chosen, whatever was chosen before.
    var reopenExcluding: String? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loaded: PurchaseOptionSet?
    @State private var state = LoadState.loading
    @State private var open: PurchaseOption?
    @State private var submitted: String?
    @State private var page = 0

    private enum LoadState: Equatable { case loading, shown, gone, failed(String) }

    private var set: PurchaseOptionSet? { preview ?? loaded }
    private var cardWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 320 : 176 }

    var body: some View {
        Group {
            if let set, !set.options.isEmpty {
                cards(set)
            } else {
                switch state {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(language.pick("Checking the options…", "Comprobando las opciones…"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                case .gone:
                    Text(language.pick("These options are no longer available. Ask Alice to look again.",
                                       "Estas opciones ya no están disponibles. Pídele a Alice que vuelva a buscar."))
                        .font(.subheadline).foregroundStyle(.secondary)
                case let .failed(reason):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                        Button(language.pick("Try again", "Reintentar")) { Task { await load() } }
                            .font(.subheadline.weight(.medium))
                    }
                case .shown:
                    EmptyView()
                }
            }
        }
        .onChange(of: store.isSending) { was, sending in
            if was && !sending && submitted != nil {
                Task {
                    await load()
                    if loaded?.chosen == nil { submitted = nil }
                }
            }
        }
        .task(id: (detail ?? key ?? "") + (session ?? "")) { if preview == nil { await load() } }
        .sheet(item: $open) { option in
            PurchaseProductSheet(image: option.image, seller: option.merchant, title: option.title,
                                 price: option.price, oldPrice: nil, language: language,
                                 options: option.variant.isEmpty ? [] : [option.variant], onBuy: {}, onBuyQuantity: { quantity in
                open = nil
                if let onChooseQuantity { onChooseQuantity(option, quantity) } else if let onChoose { onChoose(option) } else {
                    guard store.isConnected, !store.isSending, submitted == nil else { return }
                    submitted = option.id
                    store.sendQuickReply(option.choice + " [cantidad:\(quantity)]", replyProfile: replyProfile, followsLatestAgent: false)
                }
            }, shipping: option.shipping, condition: option.condition, initialQuantity: option.qty, productURL: option.url)
        }
    }

    private func load() async {
        guard let session, !session.isEmpty, let key = key ?? PurchaseOptionSet.key(fromDetail: detail) else { state = .gone; return }
        do {
            loaded = try await store.purchaseOptions(key, session: session)
            state = loaded == nil ? .gone : .shown
        } catch {
            state = .failed(PlainWords.describe(error, doing: language.pick("load the options", "cargar las opciones")))
        }
    }

    private func cards(_ set: PurchaseOptionSet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(set.options.filter { $0.id != reopenExcluding }.dropFirst(page * 6).prefix(6))) { option in
                        card(option, chosen: reopenExcluding == nil ? (set.chosen ?? submitted) : submitted)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            if set.options.count > 6 {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        previousPage
                        Spacer()
                        pageNumber(set)
                        Spacer()
                        nextPage(set)
                    }
                    VStack(spacing: 8) {
                        pageNumber(set)
                        previousPage
                        nextPage(set)
                    }
                }
            }
            if set.chosen == nil, submitted == nil, let best = set.options.first(where: \.recommended), !best.why.isEmpty {
                Label(best.why, systemImage: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(language.pick("Options to buy", "Opciones para comprar")))
    }

    private var previousPage: some View {
        Button(language.pick("Previous", "Anterior")) { page -= 1 }.disabled(page == 0)
            .fixedSize(horizontal: true, vertical: true)
    }

    private func nextPage(_ set: PurchaseOptionSet) -> some View {
        Button(language.pick("Next", "Siguiente")) { page += 1 }.disabled((page + 1) * 6 >= set.options.count)
            .fixedSize(horizontal: true, vertical: true)
    }

    private func pageNumber(_ set: PurchaseOptionSet) -> some View {
        Text("\(page + 1) / \((set.options.count + 5) / 6)").font(.caption)
            .fixedSize(horizontal: true, vertical: true)
    }

    private func card(_ option: PurchaseOption, chosen: String?) -> some View {
        let picked = chosen == option.id
        let decided = chosen != nil
        return Button { open = option } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    CardImage(image: option.image, page: option.url, symbol: "bag", fits: true)
                        .background(Color.white)
                        .frame(width: cardWidth, height: 150)
                        .clipped()
                    if picked {
                        ComponentPill(text: language.pick("Chosen", "Elegida"), tint: Palette.success(scheme)).padding(8)
                    } else if option.recommended, !decided {
                        ComponentPill(text: language.pick("Recommended", "Recomendada"), tint: store.accent.primary(scheme))
                            .padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title).font(.subheadline.weight(.medium)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text([option.merchant, option.variant, option.qty > 1 ? "× \(option.qty)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(option.price.pricesKeptTogether).font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.top, 2)
                }
                .padding(12)
                .frame(width: cardWidth, alignment: .leading)
            }
            .background(Palette.card(scheme))
            .clipShape(.rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(picked ? Palette.success(scheme) : Palette.border(scheme).opacity(0.5),
                                  lineWidth: picked ? 1.5 : 0.5)
            }
            .contentShape(.rect(cornerRadius: 20))
            .opacity(decided && !picked ? 0.5 : 1)
        }
        .buttonStyle(PressableCardStyle())
        .disabled(decided || (onChoose == nil && onChooseQuantity == nil && (!store.isConnected || store.isSending)))
        .accessibilityLabel(Text("\(option.title), \(option.merchant), \(option.price)"))
        .accessibilityHint(decided ? "" : language.pick("Opens the product to buy it with Alice.",
                                                         "Abre el producto para comprarlo con Alice."))
    }
}
