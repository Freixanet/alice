import SwiftUI
import UIKit

/// Sample content for Developer › Components, drawn by the app's own views.
///
/// Everything here runs against a sandbox store (`sandbox(like:)`): its own settings suite, no
/// Hermes address and a still browser page, so a card in the gallery can be tapped without
/// sending a message, answering an approval, saving a key or paying — the calls have nowhere to
/// go. Pictures are drawn here, so the page needs no network either.
@MainActor
enum GalleryFixtures {
    // MARK: The sandbox

    static let sandboxSuite = "alice.gallery.sandbox"

    /// A store with nothing behind it, looking like `store`.
    static func sandbox(like store: AppStore) -> AppStore {
        UserDefaults().removePersistentDomain(forName: sandboxSuite)
        let sandbox = AppStore(defaults: UserDefaults(suiteName: sandboxSuite) ?? UserDefaults())
        sandbox.accent = store.accent
        sandbox.liveBrowser.showPreview(page, title: "Creatina Excell 500 g · HSN", url: "https://www.hsnstore.com/creatina")
        return sandbox
    }

    // MARK: Pictures

    /// A shop's product page, as the browser would show it.
    static let page: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 520)).image { context in
        let ink = UIColor(red: 0.12, green: 0.23, blue: 0.45, alpha: 1)
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 390, height: 520))
        UIColor(white: 0.95, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 390, height: 56))
        draw("hsnstore.com", at: CGPoint(x: 20, y: 18), size: 17, weight: .semibold, color: ink)
        UIColor(white: 0.93, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: 95, y: 80, width: 200, height: 200), cornerRadius: 16).fill()
        ink.setFill()
        UIBezierPath(roundedRect: CGRect(x: 160, y: 120, width: 70, height: 120), cornerRadius: 12).fill()
        draw("Creatina Excell 500 g", at: CGPoint(x: 20, y: 300), size: 22, weight: .bold, color: .black)
        draw("Creapure® · Sin sabor", at: CGPoint(x: 20, y: 334), size: 16, weight: .regular, color: .darkGray)
        draw("27,98 €", at: CGPoint(x: 20, y: 368), size: 24, weight: .bold, color: ink)
        UIColor(red: 0.0, green: 0.48, blue: 1, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: 20, y: 430, width: 350, height: 52), cornerRadius: 26).fill()
        draw("Añadir a la cesta", at: CGPoint(x: 128, y: 445), size: 18, weight: .semibold, color: .white)
    }

    /// A small photo, for an attachment.
    static let photo: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).image { context in
        UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
        UIColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: -40, y: 110, width: 320, height: 160)).fill()
        UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: 170, y: 24, width: 40, height: 40)).fill()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }

    /// The page as a file URL, for views that take a picture's address.
    static let pageURL: URL? = {
        let file = FileManager.default.temporaryDirectory.appending(path: "alice-gallery-page.png")
        guard let data = page.pngData(), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }()

    // MARK: Messages

    static let now = Date()

    static func reply(_ id: String, _ content: String, pending: Bool = false, tools: [Message.ToolCall] = [],
                      error: String? = nil, errorLimit: ModelLimit? = nil, approval: Message.Approval? = nil) -> Message {
        var message = Message(id: "gallery-\(id)", role: .assistant, content: content,
                              createdAt: now.addingTimeInterval(-90), pending: pending, tools: tools,
                              error: error, errorLimit: errorLimit, approval: approval)
        message.thoughtSeconds = pending ? nil : 14
        return message
    }

    static func said(_ id: String, _ content: String, attachments: [Attachment] = []) -> Message {
        Message(id: "gallery-\(id)", role: .user, content: content, createdAt: now.addingTimeInterval(-120),
                attachments: attachments)
    }

    static func tool(_ id: String, _ name: String, _ detail: String?, done: Bool = true) -> Message.ToolCall {
        Message.ToolCall(id: id, name: name, status: done ? .done : .start, detail: detail)
    }

    // MARK: Errands

    static let shopLogo: URL? = nil

    static func purchaseOptions(_ language: ChatLanguage, chosen: String? = nil) -> PurchaseOptionSet {
        PurchaseOptionSet(key: "a1b2c3d4", options: [
            PurchaseOption(id: "a1b2c3d4-1", title: "Creatina Excell 500 g (Creapure®)", merchant: "HSN",
                           variant: language.pick("Unflavoured", "Sin sabor"), qty: 1, price: "27,98 €",
                           image: pageURL, url: nil, recommended: true,
                           why: language.pick("Your usual one, with free delivery.", "La de siempre, con envío gratis.")),
            PurchaseOption(id: "a1b2c3d4-2", title: "Creapure 500 g", merchant: "Otra tienda",
                           variant: language.pick("Unflavoured", "Sin sabor"), qty: 1, price: "31,90 €",
                           image: pageURL, url: nil, recommended: false, why: ""),
        ], chosen: chosen)
    }

    static func item(_ language: ChatLanguage) -> Errand.Item {
        Errand.Item(name: "Creatina Excell 500 g (Creapure®)", variant: language.pick("Unflavoured", "Sin sabor"),
                    qty: 1, price: "27,98 €", image: pageURL)
    }

    static func checkout(_ language: ChatLanguage, status: Errand.Checkout.Status = .pending) -> Errand.Checkout {
        Errand.Checkout(id: "gallery-checkout", status: status, merchant: "HSN", site: "hsnstore.com",
                        items: [item(language)],
                        delivery: language.pick("Free delivery · arrives Friday, Oct 2", "Envío gratis · llega el viernes 2 oct"),
                        address: "Calle Mayor 1, 28013 Madrid", email: "nombre@email.com",
                        cardLabel: "Visa ···4242", total: "27,98 €", currency: "EUR")
    }

    static func receipt(_ language: ChatLanguage) -> Errand.Receipt {
        Errand.Receipt(outcome: "paid", order: "100123456", total: "27,98 €", merchant: "HSN", site: "hsnstore.com",
                       items: [item(language)], cardLabel: "Visa ···4242",
                       delivery: language.pick("Arrives Friday, Oct 2", "Llega el viernes 2 oct"))
    }

    static func errand(_ language: ChatLanguage, status: Errand.Status, id: String = "gallery-errand",
                       checkout: Errand.Checkout? = nil, receipt: Errand.Receipt? = nil,
                       questions: [Errand.Question] = [], approval: Errand.Approval? = nil,
                       reason: String = "") -> Errand {
        let steps = [
            language.pick("Open HSN and search for Creapure", "Abrir HSN y buscar Creapure"),
            language.pick("Add to basket", "Añadir al carrito"),
            language.pick("Choose free standard delivery", "Elegir envío estándar gratis"),
        ].map { Errand.Step(text: $0, url: "https://www.hsnstore.com", at: now.addingTimeInterval(-60)) }
        return Errand(
            id: id, title: language.pick("Buy Creapure at HSN", "Comprar Creapure en HSN"),
            request: language.pick("Buy the Creapure creatine from HSN", "Compra la creatina Creapure de HSN"),
            site: "hsnstore.com", status: status, checkout: checkout, receipt: receipt,
            questionsTitle: questions.isEmpty ? "" : language.pick("Before buying", "Antes de comprar"),
            questions: questions, approval: approval, reason: reason,
            summary: language.pick("At the payment step.", "En el paso de pago."),
            steps: steps, startedAt: now.addingTimeInterval(-240), updatedAt: now)
    }

    static func errandQuestions(_ language: ChatLanguage) -> [Errand.Question] {
        [Errand.Question(id: "sabor", question: language.pick("Which flavour?", "¿Qué sabor?"),
                         choices: [language.pick("Unflavoured", "Sin sabor"), language.pick("Lemon", "Limón"),
                                   language.pick("Orange", "Naranja")])]
    }

    static func errandList(_ language: ChatLanguage) -> [Errand] {
        [
            errand(language, status: .working),
            errand(language, status: .needsApproval, id: "gallery-errand-2", checkout: checkout(language)),
            errand(language, status: .done, id: "gallery-errand-3", receipt: receipt(language)),
            errand(language, status: .stuck, id: "gallery-errand-4",
                   reason: language.pick("Out of stock in this size.", "Sin stock en esta talla.")),
        ]
    }
}
