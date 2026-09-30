import SwiftUI

/// A purchase that stopped before paying, as a card with its ways on — never as loose text.
///
/// The shop charging another price is the person's call: «Comprar a 34,99 €» takes the same option
/// on to the checkout, where that exact total is approved as always; «Ver otras opciones» opens the
/// options that were shown, without the one that failed. Anything else can be tried again.
struct ErrandStoppedCard: View {
    let errand: Errand
    var session: String? = nil
    var sending = false
    let onAcceptPrice: () -> Void
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var showingOptions = false

    private var language: ChatLanguage { errand.language }
    private var setKey: String? { errand.optionID.flatMap { $0.split(separator: "-").first.map(String.init) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ComponentPill(text: pill, tint: errand.status == .stuck ? Palette.warning(scheme) : nil)
                Spacer(minLength: 0)
            }
            Text(headline).font(.body).fixedSize(horizontal: false, vertical: true)
            Text(language.pick("Nothing was paid.", "No se ha pagado nada."))
                .font(.subheadline).foregroundStyle(.secondary)

            if errand.status == .stuck, let price = errand.blockedPrice {
                PurchaseCapsuleButton(title: language.pick("Buy it at \(price.pricesKeptTogether)",
                                                           "Comprarla a \(price.pricesKeptTogether)"),
                                      prominent: true, disabled: sending, busy: sending, tint: .approve,
                                      action: onAcceptPrice)
            } else if errand.status == .stuck {
                PurchaseCapsuleButton(title: language.pick("Try again", "Reintentar"), prominent: true,
                                      disabled: sending, busy: sending, tint: .approve, action: onRetry)
            }
            if setKey != nil, errand.status != .stopped {
                PurchaseCapsuleButton(title: showingOptions ? language.pick("Hide the options", "Ocultar las opciones")
                                                            : language.pick("See the other options", "Ver otras opciones"),
                                      disabled: sending) {
                    withAnimation(.snappy) { showingOptions.toggle() }
                }
            }
            if showingOptions, let setKey {
                PurchaseOptionsCard(detail: nil, language: language, session: session ?? errand.originSession,
                                    key: setKey, reopenExcluding: errand.optionID)
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
    }

    private var pill: String {
        switch errand.status {
        case .denied: language.pick("Cancelled", "Cancelada")
        case .stopped: language.pick("Stopped", "Detenida")
        default: errand.blockedPrice != nil ? language.pick("Price changed", "Precio distinto")
                                             : language.pick("Stopped", "Parada")
        }
    }

    private var headline: String {
        switch errand.status {
        case .denied: return language.pick("You cancelled this purchase.", "Has cancelado esta compra.")
        case .stopped: return language.pick("This purchase was stopped.", "Esta compra se ha detenido.")
        default:
            if let price = errand.blockedPrice {
                let was = errand.offerPrice.map { language.pick(", not \($0.pricesKeptTogether)", ", no \($0.pricesKeptTogether)") } ?? ""
                return language.pick("At \(errand.site.nonEmpty(or: "the shop")) it costs \(price.pricesKeptTogether) in the basket\(was).",
                                     "En \(errand.site.nonEmpty(or: "la tienda")) cuesta \(price.pricesKeptTogether) en la cesta\(was).")
            }
            return errand.reason.isEmpty ? language.pick("It could not go on.", "No ha podido seguir.") : errand.reason
        }
    }
}
