import Foundation

/// The purchase's words in the chat, written from the errand's own data — never a figure the model
/// wrote: the final summary before approving (step 9), the result (step 12), and, when it stops,
/// what happened and how to go on. Drawn as a reply's text, with reply buttons for the next step.
enum PurchaseSummaryText {
    /// Step 9: product, variant, quantity, price, delivery, exact total, address, email and card.
    static func summary(_ checkout: Errand.Checkout, card: String, language: ChatLanguage) -> String {
        let shop = escaped(checkout.merchant.nonEmpty(or: checkout.site))
        var lines = [language.pick("Ready to pay at **\(shop)**:", "Listo para pagar en **\(shop)**:"), ""]
        for item in checkout.items {
            let parts = [escaped(item.name), item.variant.isEmpty ? nil : escaped(item.variant),
                         "× \(item.qty)", item.price.isEmpty ? nil : escaped(item.price.pricesKeptTogether)]
            lines.append("- " + parts.compactMap { $0 }.joined(separator: " · "))
        }
        if !checkout.delivery.isEmpty {
            lines.append("- " + language.pick("Delivery: ", "Envío: ") + escaped(checkout.delivery))
        }
        lines.append("- **" + language.pick("Total: ", "Total: ") + escaped(checkout.total.pricesKeptTogether) + "**")
        if !checkout.address.isEmpty {
            lines.append("- " + language.pick("To: ", "Dirección: ") + escaped(checkout.address))
        }
        if !checkout.email.isEmpty {
            lines.append("- Email: " + escaped(checkout.email))
        }
        lines.append("- " + language.pick("Pay with: ", "Pago: ")
                     + (card.isEmpty ? language.pick("choose a card below", "elige una tarjeta abajo") : escaped(card)))
        lines += ["", language.pick("Nothing is paid until you approve this total below.",
                                    "No se paga nada hasta que apruebes este total abajo.")]
        return lines.joined(separator: "\n")
    }

    /// Step 12: the order, its number, what was paid and what to expect of the delivery.
    static func result(_ receipt: Errand.Receipt, language: ChatLanguage) -> String {
        let shop = escaped(receipt.merchant.nonEmpty(or: receipt.site))
        let total = escaped(receipt.total.pricesKeptTogether)
        switch receipt.outcome {
        case "paid":
            var text = language.pick("Order placed at **\(shop)**", "Pedido hecho en **\(shop)**")
            if !receipt.order.isEmpty {
                text += language.pick(", number **\(escaped(receipt.order))**", ", número **\(escaped(receipt.order))**")
            }
            text += ": \(total)" + (receipt.cardLabel.isEmpty ? "" : language.pick(" with ", " con ") + escaped(receipt.cardLabel)) + "."
            text += "\n\n" + (receipt.delivery.isEmpty
                ? language.pick("The shop will email the delivery details.", "La tienda te enviará por email los datos del envío.")
                : escaped(receipt.delivery) + ".")
            if let approved = receipt.approvedTotal, !approved.isEmpty, approved != receipt.total {
                text += "\n\n> [!WARNING]\n> " + language.pick(
                    "You approved \(escaped(approved.pricesKeptTogether)); the shop charged \(total). Check the order.",
                    "Aprobaste \(escaped(approved.pricesKeptTogether)) y la tienda ha cobrado \(total). Revisa el pedido.")
            }
            return text
        case "declined":
            return language.pick("The payment at **\(shop)** was declined. Nothing was charged.",
                                 "El pago en **\(shop)** se ha rechazado. No se ha cobrado nada.")
                + "\n" + buttons([(language.pick("Try another card", "Probar otra tarjeta"),
                                   language.pick("Try again with another card", "Inténtalo con otra tarjeta"))])
        case "not_charged":
            return language.pick("The order at **\(shop)** did not go through. Nothing was charged.",
                                 "El pedido en **\(shop)** no se ha completado. No se ha cobrado nada.")
        default:
            return language.pick(
                "It is not clear yet whether the payment at **\(shop)** went through. Alice is checking the confirmation and will not pay again meanwhile.",
                "Aún no está claro si el pago en **\(shop)** se hizo. Alice está comprobando la confirmación y no volverá a pagar mientras tanto.")
        }
    }

    /// Stopped before paying: what happened, and the ways on.
    static func stopped(_ errand: Errand, language: ChatLanguage) -> String? {
        if errand.checkout?.status == .approved {
            guard errand.status == .stuck || errand.status == .stopped else { return nil }
            return language.pick(
                "The purchase stopped after approval. The payment outcome has not been confirmed; check the order before trying again.",
                "La compra se ha detenido después de aprobarla. El resultado del pago no está confirmado; comprueba el pedido antes de reintentar.")
        }
        switch errand.status {
        case .stuck:
            let why = errand.reason.isEmpty ? language.pick("it could not go on.", "no ha podido seguir.") : escaped(errand.reason)
            return language.pick("I stopped the purchase: ", "He parado la compra: ") + why + " "
                + language.pick("Nothing was paid.", "No se ha pagado nada.") + "\n"
                + buttons([
                    (language.pick("Choose another option", "Elegir otra opción"),
                     language.pick("Show me other options", "Enséñame otras opciones")),
                    (language.pick("Try again", "Reintentar"),
                     language.pick("Try the same purchase again", "Vuelve a intentar la misma compra")),
                ])
        case .denied:
            return language.pick("Understood: nothing was paid.", "Entendido: no se ha pagado nada.") + "\n"
                + buttons([(language.pick("Choose another option", "Elegir otra opción"),
                            language.pick("Show me other options", "Enséñame otras opciones"))])
        case .stopped:
            return language.pick("Purchase stopped. Nothing was paid.", "Compra detenida. No se ha pagado nada.")
        default:
            return nil
        }
    }

    private static func buttons(_ items: [(title: String, reply: String)]) -> String {
        items.map { item in
            let text = item.reply.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? item.reply
            return "[\(item.title)](alice://reply?text=\(text)&style=dotted)"
        }.joined(separator: "\n")
    }

    /// A shop's words are data: Markdown in them is shown, not followed.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*_[]`()".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return allowed
    }()
}
