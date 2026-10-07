import SwiftUI

/// A purchase that stopped before paying, as a card with its ways on — never as loose text.
///
/// The shop charging another price is the person's call: «Comprar a 34,99 €» takes the same option
/// on to the checkout, where that exact total is approved as always; «Ver otras opciones» opens the
/// options that were shown, without the one that failed. «Cancelar» ends it. A stop that was not
/// about the price can be tried again from where the shop is.
struct ErrandStoppedCard: View {
    let errand: Errand
    var session: String? = nil
    var sending = false
    let onAcceptPrice: () -> Void
    let onRetry: () -> Void
    var onCancel: () -> Void = {}
    var onOpenBrowser: () -> Void = {}

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
            } else if errand.status == .stuck, errand.accessBlocked {
                PurchaseCapsuleButton(title: language.pick("Open shop to sign in", "Abrir tienda para iniciar sesión"),
                                      prominent: true, disabled: sending, action: onOpenBrowser)
                PurchaseCapsuleButton(title: language.pick("Check sign-in and retry", "Comprobar sesión y reintentar"),
                                      disabled: sending, busy: sending, action: onRetry)
            } else if errand.status == .stuck {
                PurchaseCapsuleButton(title: language.pick("Retry purchase", "Reintentar compra"), prominent: true,
                                      disabled: sending, busy: sending, tint: .approve, action: onRetry)
            }
            if setKey != nil, errand.status != .stopped, !errand.accessBlocked {
                PurchaseCapsuleButton(title: showingOptions ? language.pick("Hide the options", "Ocultar las opciones")
                                                            : language.pick("Choose another product", "Elegir otro producto"),
                                      disabled: sending) {
                    withMotion(.snappy) { showingOptions.toggle() }
                }
            }
            if errand.status == .stuck {
                PurchaseCapsuleButton(title: language.pick("Cancel", "Cancelar"), disabled: sending, action: onCancel)
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
            if errand.accessBlocked {
                return language.pick("Alice couldn’t complete sign-in at this shop. Open the browser to see what it asks for.",
                                     "Alice no ha podido completar el inicio de sesión en esta tienda. Abre el navegador para ver qué te pide.")
            }
            if let price = errand.blockedPrice {
                let was = errand.offerPrice.map { language.pick(", not \($0.pricesKeptTogether)", ", no \($0.pricesKeptTogether)") } ?? ""
                return language.pick("At \(errand.site.nonEmpty(or: "the shop")) it costs \(price.pricesKeptTogether) in the basket\(was).",
                                     "En \(errand.site.nonEmpty(or: "la tienda")) cuesta \(price.pricesKeptTogether) en la cesta\(was).")
            }
            return errand.reason.isEmpty ? language.pick("It could not go on.", "No ha podido seguir.") : errand.reason
        }
    }
}
