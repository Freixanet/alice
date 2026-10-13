import Foundation

/// Read-only status vocabulary for a future Alice-authenticated ASR feed.
/// Never initialize a confirmed status from Hermes errand data or an LLM answer.
/// There is intentionally no payment or approval action in this model.
enum SecureRunnerDisplayStatus: String, Sendable, CaseIterable {
    case unverified, researching, cartReady, pending, approved, rejected, unknown, confirmed, handoff

    var allowsCheckout: Bool { false }

    func title(_ language: ChatLanguage) -> String {
        switch self {
        case .unverified: language.pick("Secure Runner · not verified", "Secure Runner · sin verificar")
        case .researching: language.pick("Fictional proposal in progress", "Propuesta ficticia en preparación")
        case .cartReady: language.pick("Fictional cart prepared", "Carrito ficticio preparado")
        case .pending: language.pick("Authorization pending", "Autorización pendiente")
        case .approved: language.pick("Fictional checkout approved", "Pedido ficticio aprobado")
        case .rejected: language.pick("Fictional shopping stopped", "Compra ficticia detenida")
        case .unknown: language.pick("Payment outcome unknown", "Resultado del pago desconocido")
        case .confirmed: language.pick("Order confirmed", "Pedido confirmado")
        case .handoff: language.pick("Manual handoff", "Entrega de control manual")
        }
    }

    func explanation(_ language: ChatLanguage) -> String {
        switch self {
        case .unverified:
            language.pick("No trusted Alice Secure Runner status is connected. A Hermes checkout or Face ID prompt is not ASR payment authorization. Payments are disabled here.",
                          "No hay un estado verificado de Alice Secure Runner. Un checkout de Hermes o Face ID no autoriza pagos de ASR. Aquí no se puede pagar.")
        case .researching:
            language.pick("Alice is reviewing fictional products. No checkout or payment has been authorized.",
                          "Alice está revisando productos ficticios. No se ha autorizado ningún pedido ni pago.")
        case .cartReady:
            language.pick("The exact fictional cart is ready to review. No payment has been authorized.",
                          "El carrito ficticio exacto está listo para revisar. No se ha autorizado ningún pago.")
        case .pending:
            language.pick("Waiting for trusted authorization. Do not submit a payment from this screen.",
                          "Esperando autorización de confianza. No envíes un pago desde esta pantalla.")
        case .approved:
            language.pick("The exact fictional checkout was approved, but a merchant receipt has not been verified. Do not submit it again.",
                          "Se aprobó el pedido ficticio exacto, pero no hay un recibo verificado. No lo vuelvas a enviar.")
        case .rejected:
            language.pick("This fictional shopping job was stopped before merchant dispatch. An uncertain merchant effect can never be called cancelled.",
                          "Esta compra ficticia se detuvo antes del envío al comercio. Un efecto comercial incierto nunca se considera cancelado.")
        case .unknown:
            language.pick("The merchant may have received the payment. Do not retry: check an independent receipt first.",
                          "El comercio podría haber recibido el pago. No reintentes: comprueba antes un recibo independiente.")
        case .confirmed:
            language.pick("An independent receipt has confirmed the order. This screen cannot submit it again.",
                          "Un recibo independiente ha confirmado el pedido. Esta pantalla no puede volver a enviarlo.")
        case .handoff:
            language.pick("The agent must be stopped and its browser closed before a separate human session can continue.",
                          "El agente debe estar detenido y su navegador cerrado antes de continuar en una sesión humana separada.")
        }
    }
}
