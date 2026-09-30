import SwiftUI

// An errand, as the cards of a checkout the person can follow: the browser working, the order
// under way, the checkout to approve, the receipt. Big rounded surfaces with no outline, inner
// grey groups for the rows, dotted dividers, and tall capsule buttons — the language of the
// purchase flows Alice is measured against. The cards are pure views: the chat and the list feed
// them from `ErrandBoard`, the developer walkthrough from a script.

struct DottedDivider: View {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    let title: String
    var prominent = false
    var disabled = false
    var busy = false
    /// An SF Symbol before the title, such as Face ID on the button that pays.
    var symbol: String? = nil
    /// A colour of its own for the prominent one, such as blue on «Permitir».
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(prominent ? .white : .primary)
                } else {
                    Label { Text(title) } icon: { if let symbol { Image(systemName: symbol) } }
                }
            }
            .font(.headline)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(prominent ? (tint ?? store.accent.control(scheme)) : Palette.muted(scheme), in: .capsule)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(.capsule)
            // Label ⇄ spinner as the answer goes out and comes back.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: busy)
        }
        // Pay, Deny, Cancel: the buttons that matter most give under the finger.
        .buttonStyle(PressableCardStyle())
        .disabled(disabled || busy)
        .accessibilityLabel(title)
    }
}

/// The card's own brand mark, drawn as the networks draw it — Mastercard's two circles, Visa's
/// blue italic wordmark, Amex's blue box — on a white card-shaped tile.
struct CardBrandBadge: View {
    let label: String

    private var brand: String { label.lowercased() }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.white)
            mark
        }
        .frame(width: 46, height: 30)
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.08), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        if brand.contains("master") {
            HStack(spacing: -7) {
                Circle().fill(Color(red: 0.92, green: 0.0, blue: 0.11))
                Circle().fill(Color(red: 0.97, green: 0.62, blue: 0.11)).opacity(0.9)
            }
            .frame(height: 18)
        } else if brand.contains("visa") {
            Text("VISA")
                .font(.system(size: 13, weight: .black).italic())
                .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.47))
        } else if brand.contains("amex") || brand.contains("american") {
            Text("AMEX")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Color(red: 0.0, green: 0.44, blue: 0.81), in: .rect(cornerRadius: 3))
        } else {
            Image(systemName: "creditcard.fill").foregroundStyle(.gray)
        }
    }
}

/// Who the errand is with: the shop's own logo, found on its site by the plugin, or else
/// Alice herself, who is doing it.
struct ShopLogo: View {
    /// The errand whose shop it is; nil in the walkthrough, which gives its own `image`.
    var errandID: String?
    var image: URL? = nil
    var size: CGFloat = 44

    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let errandID, let logo = store.errandBoard.logos[errandID] {
                // Filling the circle, on the logo's own edge colour: a square icon fitted inside
                // with a margin left white corners around it.
                Image(uiImage: logo).resizable().scaledToFill()
                    .background(Color(uiColor: logo.edgeColor))
            } else if let image {
                CardImage(image: image, page: nil, symbol: "bag", fits: true).padding(size * 0.1)
                    .background(Color.white)
            } else {
                Image("AliceAvatar").resizable().renderingMode(.original).scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay { Circle().stroke(.black.opacity(0.08), lineWidth: 0.5) }
        .task(id: errandID) { if let errandID { await store.errandBoard.loadLogo(errandID) } }
        .accessibilityHidden(true)
    }
}

/// How an errand's state reads, in the conversation's language.
extension Errand.Status {
    func label(_ language: ChatLanguage) -> String {
        switch self {
        case .working: language.pick("Working", "Trabajando")
        case .needsApproval: language.pick("Needs approval", "Necesita tu aprobación")
        case .needsInput: language.pick("Waiting for your answer", "Espera tu respuesta")
        case .needsCard: language.pick("Needs a card", "Necesita una tarjeta")
        case .done: language.pick("Completed", "Completado")
        case .stuck: language.pick("Stuck", "Atascado")
        case .stopped: language.pick("Stopped", "Parado")
        case .denied: language.pick("Cancelled", "Cancelado")
        }
    }

    func tint(_ scheme: ColorScheme) -> Color? {
        switch self {
        case .needsApproval, .needsInput, .needsCard: Palette.warning(scheme)
        case .done: Palette.success(scheme)
        case .stuck: Palette.danger(scheme)
        case .working, .stopped, .denied: nil
        }
    }
}

extension TimeInterval {
    /// "42 s", "3 min", "1 h 5 min".
    var errandElapsed: String {
        let seconds = Int(self)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(minutes) min"
    }
}

/// The blue of a payment approval: it has to read as the one button that pays, on any accent.
extension Color {
    static let approve = Color(red: 0.23, green: 0.42, blue: 0.96)
}

extension String {
    /// This string, or `fallback` when it is empty.
    func nonEmpty(or fallback: @autoclosure () -> String) -> String { isEmpty ? fallback() : self }
}

// MARK: - The browser

/// The browser at work on the errand: its state and title over the page, live while it works,
/// with the way in to watch or take over.
struct ErrandBrowserCard: View {
    enum Snapshot { case live, still(URL?), none }

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let errand: Errand
    var snapshot: Snapshot = .live
    let onOpen: () -> Void

    @State private var still: UIImage?

    private var language: ChatLanguage { errand.language }
    private var live: LiveBrowser { store.liveBrowser }
    /// Live only while the agent is at work: waiting for the person, the page stays as it was
    /// instead of following whatever the browser shows next.
    private var following: Bool {
        if case .live = snapshot { return errand.status == .working }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: errand.status == .done ? "checkmark.circle" : "globe")
                    .font(.title3)
                    .foregroundStyle(errand.status == .done ? Palette.success(scheme) : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Palette.muted(scheme), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.pick("Browser", "Navegador")).font(.body.weight(.medium))
                    Text("\(errand.status.label(language)) · \(errand.title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if errand.status == .working { LivePulse(color: Palette.success(scheme)) }
            }

            if showsPage {
                page
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Palette.border(scheme).opacity(0.5), lineWidth: 0.5)
                    }
                PurchaseCapsuleButton(title: language.pick("Open browser", "Abrir navegador"), action: onOpen)
            }
        }
        .padding(14)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .onAppear { if following { live.watch() } }
        .onDisappear { if following { live.unwatch() } }
        .onChange(of: following) { was, now in
            if was && !now { still = live.image; live.unwatch() }
            if now && !was { still = nil; live.watch() }
        }
    }

    private var showsPage: Bool {
        if case .none = snapshot { return false }
        return errand.status != .denied && errand.status != .stopped
    }

    @ViewBuilder private var page: some View {
        switch snapshot {
        case .live:
            ZStack {
                Palette.muted(scheme)
                if let image = following ? live.image : (still ?? live.image) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                } else {
                    Image(systemName: "globe").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
        case .still(let url):
            CardImage(image: url, page: nil, symbol: "globe")
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Progress

/// The order under way, and then that it went through: what, where, how long, the steps.
struct ErrandProgressCard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    let errand: Errand
    /// nil in the walkthrough, which shows `logo` instead.
    var logoID: String?
    var logo: URL? = nil
    @State private var expanded = false

    private var language: ChatLanguage { errand.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(reduceMotion ? nil : .snappy) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    ShopLogo(errandID: logoID, image: logo)
                    VStack(alignment: .leading, spacing: 1) {
                        // How long, on the title's first line: centred on the whole block it floated
                        // between the title and the site (29-09).
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(errand.title).font(.body.weight(.medium)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(errand.elapsed.errandElapsed)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize()
                            if !errand.steps.isEmpty {
                                Image(systemName: "chevron.down")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                        }
                        if !errand.site.isEmpty {
                            Text(errand.site).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(errand.steps.isEmpty)
            .accessibilityHint(language.pick("Shows the steps", "Muestra los pasos"))

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    let stages = errand.milestones
                    ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: index == stages.count - 1 && errand.status == .working
                                  ? "circle.dotted" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(stage).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.opacity)
            }

            HStack(spacing: 10) {
                statusMark
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                Text(statusLine).font(.body)
                    .lineLimit(errand.status == .stuck ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            // Working → waiting for you → done reads as one card changing, not a new one.
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: errand.status)
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: statusLine)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }

    @ViewBuilder private var statusMark: some View {
        switch errand.status {
        case .working:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(store.accent.control(scheme))
        case .needsApproval, .needsInput, .needsCard:
            Image(systemName: "hourglass").font(.title3).foregroundStyle(Palette.warning(scheme))
        case .stuck:
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(Palette.danger(scheme))
        case .stopped, .denied:
            Image(systemName: "xmark.circle").font(.title3).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch errand.status {
        case .working:
            if errand.checkout?.status == .approved {
                return language.pick("Completing the payment…", "Completando el pago…")
            }
            if errand.checkout?.status == .replaced {
                return language.pick("Preparing the checkout again…", "Preparando el checkout de nuevo…")
            }
            return errand.milestones.last ?? language.pick("Getting started…", "Empezando…")
        case .done:
            return errand.receipt?.paid == true ? language.pick("Order placed", "Pedido realizado")
                                                : errand.summary.nonEmpty(or: language.pick("Done", "Hecho"))
        case .needsApproval: return language.pick("Waiting for your approval", "Esperando tu aprobación")
        case .needsInput: return language.pick("Waiting for your answer", "Esperando tu respuesta")
        case .needsCard: return language.pick("Waiting for a card to pay with", "Esperando una tarjeta para pagar")
        case .stuck: return errand.reason.nonEmpty(or: language.pick("It got stuck", "Se ha atascado"))
        case .stopped: return language.pick("The errand was stopped", "El recado se ha detenido")
        case .denied: return language.pick("You denied the purchase. Nothing was paid.",
                                           "Denegaste la compra. No se ha pagado nada.")
        }
    }
}

// MARK: - Checkout

/// The checkout to approve: what is bought, where it goes, who is told, with which card, the
/// total, and «Denegar» / «Permitir». The one who shows it asks for Face ID before answering.
struct CheckoutApprovalCard: View {
    enum Phase: Equatable { case pending, sending, approved, denied, expired }

    @Environment(\.colorScheme) private var scheme
    let checkout: Errand.Checkout
    var logoID: String? = nil
    var logo: URL? = nil
    var language: ChatLanguage = .spanish
    var phase: Phase = .pending
    var error: String? = nil
    var onOpenPage: (() -> Void)? = nil
    /// The person's saved cards, the one chosen to pay, and how to add another.
    var cards: [SavedCard] = []
    var chosenCard: SavedCard? = nil
    var onChooseCard: (SavedCard) -> Void = { _ in }
    var onAddCard: (() -> Void)? = nil
    /// The order went through: the approved line says it was paid, not that it is being paid.
    var paid = false
    /// Still going after the approval: it is paying now. Stopped before: it never paid.
    var paying = true
    /// A stale checkout: prepared again, or the purchase given up.
    var onRefresh: () -> Void = {}
    let onAllow: () -> Void
    let onDeny: () -> Void

    private var shop: String { checkout.merchant.nonEmpty(or: checkout.site) }
    private var payingWith: String { chosenCard?.label ?? checkout.cardLabel }
    private var deciding: Bool { phase == .pending || phase == .sending }

    var body: some View {
        switch phase {
        case .approved: approvedLine
        case .expired: expiredCard
        default: fullCard
        }
    }

    /// Approved: one line, so the checkout no longer reads as something still to answer.
    private var approvedLine: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(Palette.success(scheme))
            VStack(alignment: .leading, spacing: 1) {
                Text(language.pick("Approved · \(checkout.total.pricesKeptTogether)",
                                   "Aprobado · \(checkout.total.pricesKeptTogether)"))
                    .font(.body.weight(.medium))
                Text(payingWith.isEmpty ? shop
                     : paid ? language.pick("Paid with \(payingWith)", "Pagado con \(payingWith)")
                     : paying ? language.pick("Paying with \(payingWith)", "Pagando con \(payingWith)")
                     : language.pick("Not paid · \(payingWith)", "No se llegó a pagar · \(payingWith)"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !payingWith.isEmpty { CardBrandBadge(label: payingWith) }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }

    /// Waited too long: shops close their checkout, and prices and delivery move. Not payable;
    /// prepared again for a fresh approval, or the purchase given up.
    private var expiredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComponentPill(text: language.pick("Expired", "Caducado"), tint: Palette.warning(scheme))
            Text(language.pick("This checkout waited too long and \(shop) no longer holds it. Nothing was paid.",
                               "Este checkout ha esperado demasiado y \(shop) ya no lo guarda. No se ha pagado nada."))
                .font(.body)
            Text(language.pick("Alice can prepare it again and ask you with the price as it is now.",
                               "Alice puede prepararlo de nuevo y preguntarte con el precio de ahora."))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                PurchaseCapsuleButton(title: language.pick("Cancel purchase", "Cancelar compra"), action: onDeny)
                PurchaseCapsuleButton(title: language.pick("Prepare it again", "Prepararlo de nuevo"), prominent: true,
                                      tint: .approve, action: onRefresh)
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Checkout").font(.title3.weight(.semibold))
                    Text(language.pick("Alice wants to place an order at \(checkout.site)",
                                       "Alice quiere hacer un pedido en \(checkout.site)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ShopLogo(errandID: logoID, image: logo, size: 40)
            }
            .padding(.horizontal, 4)

            badge.padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(checkout.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { DottedDivider().padding(.horizontal, 14) }
                    itemRow(item).padding(14)
                }
                if !checkout.delivery.isEmpty {
                    DottedDivider().padding(.horizontal, 14)
                    row(symbol: "shippingbox", text: checkout.delivery)
                }
                if !checkout.address.isEmpty {
                    DottedDivider().padding(.horizontal, 14)
                    row(symbol: "mappin.and.ellipse", text: checkout.address)
                }
                if !checkout.email.isEmpty {
                    DottedDivider().padding(.horizontal, 14)
                    row(symbol: "envelope", text: checkout.email)
                }
            }
            .background(Palette.background(scheme), in: .rect(cornerRadius: 22))

            paymentRow

            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.title3.weight(.semibold))
                Spacer()
                Text(checkout.total.pricesKeptTogether).font(.title3.weight(.semibold).monospacedDigit())
            }
            .padding(.horizontal, 6)

            if phase == .pending || phase == .sending {
                Text(language.pick("Check the order and the shop's terms before approving.",
                                   "Revisa el pedido y las condiciones de la tienda antes de aprobar."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                if let onOpenPage {
                    Button(action: onOpenPage) {
                        Label(language.pick("Review it in the browser", "Revisarlo en el navegador"),
                              systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.link(scheme))
                    .padding(.horizontal, 6)
                }
                HStack(spacing: 10) {
                    PurchaseCapsuleButton(title: language.pick("Deny", "Denegar"), disabled: phase == .sending, action: onDeny)
                    PurchaseCapsuleButton(title: language.pick("Allow", "Permitir"), prominent: true,
                                          disabled: payingWith.isEmpty, busy: phase == .sending,
                                          symbol: Biometrics.symbol, tint: .approve, action: onAllow)
                }
                if payingWith.isEmpty {
                    Text(language.pick("Choose the card to pay with.", "Elige la tarjeta con la que pagar."))
                        .font(.footnote).foregroundStyle(Palette.warning(scheme)).padding(.horizontal, 6)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Palette.danger(scheme)).padding(.horizontal, 6)
                }
                Text(language.pick("By continuing you accept \(shop)'s terms, privacy and returns policies.",
                                   "Al continuar aceptas las condiciones, la privacidad y las devoluciones de \(shop)."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }

    /// With which card: the one chosen, and a menu of the others and «Añadir tarjeta» while deciding.
    @ViewBuilder private var paymentRow: some View {
        let row = HStack(spacing: 12) {
            if payingWith.isEmpty {
                Image(systemName: "creditcard").font(.title3).frame(width: 46, height: 30)
            } else {
                CardBrandBadge(label: payingWith)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(payingWith.nonEmpty(or: language.pick("Choose a card", "Elegir tarjeta"))).font(.body)
                Text(language.pick("Saved in Alice · she fills it in", "Guardada en Alice · la rellena ella"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if deciding {
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Palette.background(scheme), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))

        if deciding {
            Menu {
                ForEach(cards) { card in
                    Button {
                        onChooseCard(card)
                    } label: {
                        if card.id == chosenCard?.id { Label(card.label, systemImage: "checkmark") } else { Text(card.label) }
                    }
                }
                if let onAddCard {
                    Button(action: onAddCard) {
                        Label(language.pick("Add a card…", "Añadir tarjeta…"), systemImage: "plus")
                    }
                }
            } label: { row }
            .buttonStyle(.plain)
        } else if !payingWith.isEmpty {
            row
        }
    }

    @ViewBuilder private var badge: some View {
        switch phase {
        case .pending, .sending:
            ComponentPill(text: language.pick("Needs approval", "Necesita tu aprobación"), tint: Palette.warning(scheme))
        case .approved:
            ComponentPill(text: language.pick("Approved", "Aprobado"), tint: Palette.success(scheme))
        case .denied:
            ComponentPill(text: language.pick("Denied", "Denegado"), tint: nil)
        case .expired:
            ComponentPill(text: language.pick("Expired", "Caducado"), tint: Palette.warning(scheme))
        }
    }

    private func itemRow(_ item: Errand.Item) -> some View {
        HStack(spacing: 14) {
            // Filled and cropped to the middle: shops' pictures are often wide banners with the
            // product small in the centre, and fitted whole (with a margin) it became a speck.
            ProductThumb(url: item.image)
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                Text(detail(item)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.price.isEmpty {
                Text(item.price.pricesKeptTogether).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ item: Errand.Item) -> String {
        let qty = language.pick("Qty: \(item.qty)", "Cant.: \(item.qty)")
        return item.variant.isEmpty ? qty : "\(qty) · \(item.variant)"
    }

    private func row(symbol: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 30)
            Text(text).font(.body)
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

/// A product's picture as a thumbnail: the white around it trimmed off, so a shop's wide banner
/// with the product small in the middle (Apple's) shows the product, not a speck on white.
struct ProductThumb: View {
    let url: URL?
    @State private var picture: UIImage?
    @State private var looked = false

    var body: some View {
        Color.white
            .overlay {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFit().padding(6)
                } else if looked || url == nil {
                    Image(systemName: "bag").font(.title2).foregroundStyle(.gray)
                } else {
                    ProgressView()
                }
            }
            .task(id: url) {
                guard let url else { return }
                let loaded = await CardImages.load(image: url, page: nil)
                let trimmed = await Task.detached(priority: .userInitiated) { loaded.flatMap(Self.trimmingWhite) }.value
                picture = trimmed ?? loaded
                looked = true
            }
    }

    /// The picture cropped to what is not (near) white around it; nil when there is nothing to crop.
    nonisolated static func trimmingWhite(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard width > 8, height > 8,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let i = row + x * 4
                let alpha = pixels[i + 3]
                let blank = alpha < 16 || (pixels[i] > 240 && pixels[i + 1] > 240 && pixels[i + 2] > 240)
                if !blank {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        // Nothing worth cropping: the picture already fills itself.
        guard box.width * box.height < CGFloat(width * height) * 0.85,
              let cropped = context.makeImage()?.cropping(to: box) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

// MARK: - Receipt

/// The receipt: the shop and order number, the lines, what was paid, with which card, approved.
struct ErrandReceiptCard: View {
    @Environment(\.colorScheme) private var scheme
    let receipt: Errand.Receipt
    var logoID: String? = nil
    var logo: URL? = nil
    var language: ChatLanguage = .spanish

    private var shop: String { receipt.merchant.nonEmpty(or: receipt.site) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ShopLogo(errandID: logoID, image: logo, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop).font(.title3.weight(.semibold))
                    if !receipt.order.isEmpty {
                        Text(language.pick("Order #\(receipt.order)", "Pedido #\(receipt.order)"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            DottedDivider()
            ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.qty > 1 ? "\(item.qty) × \(item.name)" : item.name).font(.body).lineLimit(2)
                    Spacer()
                    Text(item.price.pricesKeptTogether).font(.body.monospacedDigit())
                }
            }
            if !receipt.delivery.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text(receipt.delivery).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            DottedDivider()
            HStack {
                Text(receipt.paid ? language.pick("Paid", "Pagado") : "Total").font(.title3.weight(.semibold))
                Spacer()
                Text(receipt.total.pricesKeptTogether).font(.title3.weight(.semibold).monospacedDigit())
            }
            if !receipt.cardLabel.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard").foregroundStyle(.secondary)
                    Text(receipt.cardLabel).font(.subheadline)
                    Spacer()
                    Text(outcome).font(.subheadline)
                        .foregroundStyle(receipt.paid ? Palette.success(scheme) : Color.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    private var outcome: String {
        switch receipt.outcome {
        case "paid": language.pick("Approved", "Aprobado")
        case "declined": language.pick("Declined", "Rechazado")
        case "not_charged": language.pick("Not charged", "Sin cargo")
        default: language.pick("Unconfirmed", "Sin confirmar")
        }
    }
}

// MARK: - Questions and confirmations

/// Questions the errand asked (size, colour, an alternative), answered here one at a time: a
/// tap on a choice moves on, and the last one sends them all.
struct ErrandQuestionsCard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let errand: Errand
    var sending = false
    let onAnswer: ([String: String]) -> Void

    @State private var answers: [String: String] = [:]
    @State private var index = 0

    private var language: ChatLanguage { errand.language }
    private var questions: [Errand.Question] { errand.questions }
    private var current: Errand.Question? { questions.indices.contains(index) ? questions[index] : questions.last }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(errand.questionsTitle.nonEmpty(or: language.pick("A question", "Una pregunta")))
                    .font(.title3.weight(.semibold))
                Spacer()
                if questions.count > 1 {
                    Text("\(min(index, questions.count - 1) + 1) / \(questions.count)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let question = current {
                Text(question.question).font(.body)
                if question.choices.isEmpty {
                    TextField(language.pick("Your answer", "Tu respuesta"), text: binding(question.id))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Palette.background(scheme), in: .rect(cornerRadius: 14))
                        .submitLabel(isLast ? .send : .next)
                        .onSubmit { advance() }
                    PurchaseCapsuleButton(title: isLast ? language.pick("Send", "Enviar") : language.pick("Next", "Siguiente"),
                                          prominent: true,
                                          disabled: (answers[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                                          busy: sending) { advance() }
                } else {
                    ForEach(question.choices, id: \.self) { choice in
                        choiceButton(question, choice)
                    }
                }
                if index > 0 {
                    Button { withAnimation(reduceMotion ? nil : .snappy) { index -= 1 } } label: {
                        Label(language.pick("Back", "Atrás"), systemImage: "chevron.left").font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(sending)
                }
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .animation(reduceMotion ? nil : .snappy, value: index)
    }

    private func advance() {
        guard let question = current, !(answers[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        if isLast { onAnswer(answers) } else { index += 1 }
    }

    private func choiceButton(_ question: Errand.Question, _ choice: String) -> some View {
        let chosen = answers[question.id] == choice
        return Button {
            answers[question.id] = choice
            advance()
        } label: {
            HStack {
                Text(choice).font(.body)
                Spacer()
                if chosen { Image(systemName: "checkmark.circle.fill") }
            }
            .padding(14)
            .background(Palette.background(scheme), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: chosen ? [] : [4, 3]))
                    .foregroundStyle(chosen ? Color.primary : Color.secondary.opacity(0.5))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}

/// Another confirmation Hermes asked inside the errand, such as signing in when the person wanted
/// to be asked first.
struct ErrandConfirmCard: View {
    @Environment(\.colorScheme) private var scheme
    let approval: Errand.Approval
    var language: ChatLanguage = .spanish
    var sending = false
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ComponentPill(text: language.pick("Needs approval", "Necesita tu aprobación"), tint: Palette.warning(scheme))
            Text(approval.title).font(.body)
            HStack(spacing: 10) {
                PurchaseCapsuleButton(title: language.pick("Deny", "Denegar"), disabled: sending, action: onDeny)
                PurchaseCapsuleButton(title: language.pick("Allow", "Permitir"), prominent: true, busy: sending,
                                      action: onAllow)
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
    }
}

// MARK: - The product

/// The item on its own: a big photo, who sells it, the price with the old one struck through, an
/// option to choose, and the two ways on: buy it with Alice, or go to the shop.
struct PurchaseProductSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Button { withAnimation(reduceMotion ? nil : .snappy) { chosen = index } } label: {
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

extension UIImage {
    /// The colour at the picture's top-left corner: what surrounds a logo drawn on a square.
    var edgeColor: UIColor {
        guard let cg = cgImage,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let corner = cg.cropping(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        else { return .white }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return .white }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        if pixel[3] < 20 { return .white }
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
