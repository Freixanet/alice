import SwiftUI

/// Developer › Purchase walkthrough: a scripted purchase in Alice's own components, to judge how it
/// feels. The cards are the real ones (offer, card form, the payment confirmation, the product
/// card), but nothing is read from or written to Hermes and nothing is charged.
struct PurchaseDemoScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private enum Step: Int, Comparable {
        case asked, proposed, card, cardReady, checkout, paying, done, cancelled
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    @State private var step: Step = .asked
    @State private var hasCard = false
    @State private var language = ChatLanguage.spanish
    @State private var thinking = false
    @State private var run = 0
    @State private var showingProduct = false

    private let offer = PaymentCardOffer(origin: "https://tienda.example", profile: "default")
    private let photo = URL(string: "https://placehold.co/600x600/ffffff/9a9a9a/png?text=Sony+WH-1000XM5")

    private func said(_ spanish: String, _ english: String) -> String { language.pick(english, spanish) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    userBubble(said("Cómprame unos auriculares Sony WH-1000XM5, hasta 280 €",
                                    "Buy me Sony WH-1000XM5 headphones, up to €280"))

                    if thinking && step == .asked {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    if step >= .proposed {
                        aliceBubble(proposalText)
                        // With a card already saved, the product goes in the checkout card below.
                        if !hasCard {
                            PurchaseProductList(items: [.init(image: photo, title: "Sony WH-1000XM5",
                                                              subtitle: said("Auriculares con cancelación de ruido", "Noise-cancelling headphones"),
                                                              price: "249 €")]) { _ in showingProduct = true }
                        }
                    }
                    if step >= .card && step < .cardReady {
                        PaymentCardOfferCard(
                            offer: offer, language: language,
                            demo: .init(hasCard: hasCard) { _ in advance(to: .cardReady) })
                            .id("offer\(run)\(hasCard)")
                    }
                    if step >= .cardReady && !hasCard {
                        aliceBubble(said("Ya tengo tu tarjeta para tienda.example. Te dejo el pago para que lo revises.",
                                         "I have your card for tienda.example. Here's the payment to review."))
                    }
                    if step == .checkout {
                        PurchaseBrowserRow(title: said("Navegador", "Browser"),
                                           status: said("Esperando tu confirmación", "Waiting for your confirmation"))
                    }
                    if step >= .checkout && step < .done {
                        PurchaseCheckoutCard(
                            title: "Sony WH-1000XM5", detail: said("Cantidad: 1 · Negro", "Qty: 1 · Black"),
                            image: photo,
                            delivery: said("Envío gratis, llega el jueves", "Free delivery, arrives Thursday"),
                            contact: "nombre@email.com",
                            cardLabel: "Visa ···4242", cardVia: said("Pagar con Alice", "Pay with Alice"), site: "tienda.example", total: "249 €",
                            language: language, disabled: step != .checkout,
                            onOpenProduct: { showingProduct = true },
                            onPay: { pay() }, onCancel: { advance(to: .cancelled) })
                    }
                    if step == .paying {
                        PurchaseProgressCard(title: said("Comprando unos auriculares", "Buying headphones"),
                                             site: "tienda.example", done: false, doneText: "")
                    }
                    if step == .done {
                        PurchaseProgressCard(title: said("Comprando unos auriculares", "Buying headphones"),
                                             site: "tienda.example", done: true,
                                             doneText: said("Pedido realizado", "Order placed"))
                        aliceBubble(said("Hecho. El pedido 88-4271 llega el jueves.",
                                         "Done. Order 88-4271 arrives Thursday."))
                        PurchaseReceiptCard(
                            site: "tienda.example",
                            order: said("Pedido 88-4271", "Order 88-4271"),
                            lines: [("Sony WH-1000XM5", "259 €"), (said("Código AURI10", "Code AURI10"), "-10 €"),
                                    (said("Envío", "Shipping"), said("Gratis", "Free"))],
                            paid: "249 €", paidLabel: said("Pagado", "Paid"), cardLabel: "Visa ···4242",
                            status: said("Aprobado", "Approved"))
                    }
                    if step == .cancelled {
                        aliceBubble(said("Vale, no he pagado nada. El carrito sigue listo.",
                                         "Okay, I haven't paid anything. The cart is still ready."))
                    }

                    Text(said("Simulación: nada se guarda ni se cobra. Las tarjetas son de la app.",
                              "Simulation: nothing is saved or charged. The cards are the app's."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .id("end")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: step) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Palette.background(scheme))
        .navigationTitle(said("Compra de prueba", "Purchase walkthrough"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(said("Reiniciar", "Restart")) { restart() }
            }
        }
        .task(id: run) { await start() }
        // A tap when the payment is approved, and another when the order goes through.
        .sensoryFeedback(.success, trigger: step) { _, new in new == .paying || new == .done }
        .sheet(isPresented: $showingProduct) {
            PurchaseProductSheet(image: photo, seller: "tienda.example", title: "Sony WH-1000XM5",
                                 price: "249 €", oldPrice: "329 €", language: language,
                                 options: [said("Negro", "Black"), said("Plata", "Silver"), said("Azul", "Blue")]) { pay() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Language", selection: $language) {
                Text("Español").tag(ChatLanguage.spanish)
                Text("English").tag(ChatLanguage.english)
            }
            .pickerStyle(.segmented)
            Toggle(said("Ya tengo una tarjeta guardada", "I already have a saved card"), isOn: $hasCard)
                .onChange(of: hasCard) { _, _ in restart() }
        }
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(store.accent.control(scheme).opacity(0.18), in: .rect(cornerRadius: 24))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
    }

    private var productBlock: String {
        "```alice-ui\n{\"type\":\"products\",\"items\":[{\"brand\":\"Sony\",\"title\":\"WH-1000XM5\",\"price\":\"249 €\",\"image\":\"https://placehold.co/600x600/ffffff/9a9a9a/png?text=Sony+WH-1000XM5\"}]}\n```"
    }

    private var proposalText: String {
        said(
            "Los mejores en tienda.example: **259 €** con envío gratis, llegan el jueves. El código AURI10 ahorra 10 €, así que el total es **249 €**. Tengo el carrito listo.",
            "The best at tienda.example: **€259** with free shipping, arriving Thursday. Code AURI10 saves €10, so the total is **€249**. The cart is ready.")
    }

    private func aliceBubble(_ text: String) -> some View {
        RichMessageView(content: text)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
    }

    private func start() async {
        thinking = true
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled else { return }
        thinking = false
        advance(to: .proposed)
        try? await Task.sleep(for: .milliseconds(1400))
        guard !Task.isCancelled, step == .proposed else { return }
        advance(to: hasCard ? .checkout : .card)
    }

    private func advance(to next: Step) {
        withAnimation(.snappy) { step = next }
        if next == .cardReady {
            Task {
                try? await Task.sleep(for: .milliseconds(1000))
                if step == .cardReady { advance(to: .checkout) }
            }
        }
    }

    /// Paying asks for Face ID first, as the real payment does.
    private func pay() {
        Task {
            guard await Biometrics.authenticate(
                reason: said("Confirma el pago en tienda.example", "Confirm the payment on tienda.example")
            ) else { return }
            advance(to: .paying)
            try? await Task.sleep(for: .milliseconds(1800))
            if step == .paying {
                advance(to: .done)
            }
        }
    }

    private func restart() {
        step = .asked
        run += 1
    }
}
