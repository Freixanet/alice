import Foundation

/// What the phone says about errands when Alice is woken in the background or comes back to the
/// foreground: an errand that now needs the person, or one that ended.
///
/// Hermes has no push channel to the phone, so this is opportunistic (`AliceApp.handleRefresh`
/// runs when iOS decides). Each errand's state is reduced to a signature and compared with the one
/// seen last; the first reading only records, so an installation's existing errands are not
/// announced as news. When the Mac's notifier relays through Bark it already says these, and the
/// phone stays quiet to avoid saying them twice.
enum ErrandAlerts {
    /// The parts of an errand whose change is worth a word to the person.
    static func signature(_ errand: Errand) -> String {
        [errand.status.rawValue, errand.checkout?.id ?? "", errand.checkout?.status.rawValue ?? "",
         errand.receipt?.outcome ?? "", errand.questions.map(\.id).joined(separator: ","),
         errand.access?.requestID ?? "", errand.approval?.requestID ?? ""].joined(separator: "|")
    }

    struct Result: Equatable {
        var events: [AliceEvent]
        var seen: [String: String]
    }

    static func digest(previous: [String: String]?, current: [Errand], installation: String?) -> Result {
        var seen: [String: String] = [:]
        var events: [AliceEvent] = []
        for errand in current {
            let mark = signature(errand)
            seen[errand.id] = mark
            guard let previous, previous[errand.id] != mark,
                  let alert = Self.event(for: errand, mark: mark, installation: installation)
            else { continue }
            events.append(alert)
        }
        return Result(events: events, seen: seen)
    }

    /// How many errands are waiting for the person: the app icon's badge.
    static func waiting(_ errands: [Errand]) -> Int { errands.filter { $0.status.needsPerson }.count }

    /// Alice's own words, never the agent's or the shop's beyond the errand's title.
    static func event(for errand: Errand, mark: String, installation: String?) -> AliceEvent? {
        let language = errand.language
        let title = errand.title
        let summary: String
        let kind: AliceEvent.Kind
        let severity: AliceEvent.Severity
        switch errand.status {
        case .needsApproval:
            kind = .needsInput; severity = .needsAttention
            summary = errand.checkout?.status == .pending
                ? language.pick("The checkout is ready: approve the total to pay.", "El pago está listo: aprueba el total para pagar.")
                : language.pick("It needs your confirmation.", "Necesita tu confirmación.")
        case .needsInput:
            kind = .needsInput; severity = .needsAttention
            summary = language.pick("It has a question for you.", "Tiene una pregunta para ti.")
        case .needsCard:
            kind = .needsInput; severity = .needsAttention
            summary = language.pick("It needs a card to pay with.", "Necesita una tarjeta para pagar.")
        case .needsLogin:
            kind = .needsInput; severity = .needsAttention
            summary = errand.access?.isCode == true
                ? language.pick("The shop sent a verification code.", "La tienda ha enviado un código de verificación.")
                : language.pick("It needs you to sign in to the shop.", "Necesita que inicies sesión en la tienda.")
        case .done:
            kind = .finished; severity = .informational
            switch errand.receipt?.outcome {
            case "paid": summary = language.pick("Order placed.", "Pedido hecho.")
            case "declined": summary = language.pick("The payment was declined. Nothing was charged.", "El pago se ha rechazado. No se ha cobrado nada.")
            case "not_charged": summary = language.pick("The order did not go through. Nothing was charged.", "El pedido no se ha completado. No se ha cobrado nada.")
            default: summary = language.pick("Done.", "Hecho.")
            }
        case .stuck:
            kind = .needsInput; severity = .failure
            summary = errand.paymentUnconfirmed || errand.receipt?.outcome == "unknown"
                ? language.pick("Stopped: whether the payment went through is not confirmed. Check before paying again.",
                                "Parado: no está confirmado si el pago se hizo. Compruébalo antes de volver a pagar.")
                : language.pick("Stopped: it needs you.", "Parado: te necesita.")
        case .working, .stopped, .denied:
            return nil
        }
        var reference = AliceEvent.Reference()
        reference.installation = installation
        reference.profile = errand.profile
        reference.sessionID = errand.originSession.isEmpty ? nil : errand.originSession
        return AliceEvent(id: "errand:\(errand.id):\(stableHash(mark))", kind: kind, severity: severity,
                          profile: errand.profile, title: title, summary: summary, detail: nil,
                          occurred: errand.updatedAt, reference: reference)
    }

    /// FNV-1a: stable across launches (Swift's `hashValue` is not), so one change is one notification.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
