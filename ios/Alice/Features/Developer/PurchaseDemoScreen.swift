import SwiftUI

/// The walkthrough uses its own store as well as synthetic errands: reply buttons cannot reach Hermes.
struct PurchaseDemoScreen: View {
    @Environment(AppStore.self) private var store
    @State private var sandbox: AppStore?

    var body: some View {
        Group {
            if let sandbox { PurchaseWalkthrough().environment(sandbox) } else { ProgressView() }
        }
        .onAppear { if sandbox == nil { sandbox = GalleryFixtures.sandbox(like: store) } }
    }
}

private struct PurchaseWalkthrough: View {
    @Environment(\.colorScheme) private var scheme
    private enum Step: Int, Comparable {
        case clarify = 1, context, search, verify, options, chosen, prepare, card, summary, approve, pay, result
        case denied, stuck
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }
    @State private var step = Step.clarify
    @State private var language = ChatLanguage.spanish
    @State private var automatic = true
    @State private var run = 0
    @State private var selected: PurchaseOption?
    @State private var showingErrands = false
    @State private var showingBrowser = false
    @State private var outcome = "paid"
    @State private var started = Date()

    private func said(_ es: String, _ en: String) -> String { language.pick(en, es) }
    private var active: Bool { step >= .chosen }
    private var progress: String { "\(min(step.rawValue, 12))/12" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Language", selection: $language) {
                        Text("Español").tag(ChatLanguage.spanish)
                        Text("English").tag(ChatLanguage.english)
                    }.pickerStyle(.segmented)
                    Toggle(said("Avanzar solo", "Play automatically"), isOn: $automatic)
                    Text(progress + " · " + caption).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    userBubble(said("Compra creatina Creapure", "Buy Creapure creatine"))
                    RichMessageView(content: said("¿Qué cantidad y sabor quieres?", "What quantity and flavour do you want?"))
                    if step == .clarify {
                        Button(said("500 g · sin sabor", "500 g · unflavoured")) { advance(.context) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    } else {
                        userBubble(said("500 g · sin sabor", "500 g · unflavoured"))
                    }
                    if step >= .context {
                        RichMessageView(content: said("Envío a España y precios en euros. Miraré HSN y el catálogo Shop.",
                                                     "Delivery to Spain and prices in euros. I'll check HSN and the Shop catalog."))
                    }
                    if step == .search || step == .verify {
                        Label(step == .search ? said("Buscando en el catálogo y la tienda…", "Searching the catalog and shop…")
                                              : said("Comprobando página, stock y moneda…", "Checking the page, stock and currency…"),
                              systemImage: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if step >= .options {
                        PurchaseOptionsCard(detail: nil, language: language,
                            preview: GalleryFixtures.purchaseOptions(language, chosen: selected?.id),
                            onChoose: { option in selected = option; started = Date(); advance(.chosen) })
                    }
                    if let selected, active {
                        userBubble(PurchaseChoice.display(selected.choice))
                        ErrandStack(errand: errand, snapshot: .still(GalleryFixtures.pageURL),
                            onOpenBrowser: { showingBrowser = true },
                            onDecide: { allow, _ in decide(allow) }, onAnswer: { _ in }, onConfirm: { _ in },
                            onRefreshCheckout: { advance(.prepare) }, onStop: { advance(.denied) },
                            demoCards: [SavedCard.demo(origin: nil)])
                    }
                    if step == .summary {
                        RichMessageView(content: PurchaseSummaryText.summary(errand.checkout ?? GalleryFixtures.checkout(language),
                                                                            card: "Visa ···4242", language: language))
                    }
                    if step == .card {
                        Label(said("Tarjeta guardada comprobada: Visa ···4242", "Saved card checked: Visa ···4242"),
                              systemImage: "creditcard").font(.subheadline)
                    }
                    if active {
                        Button(said("Simular falta de stock", "Simulate out of stock")) { advance(.stuck) }
                            .buttonStyle(.bordered).disabled(step >= .pay)
                        Button(said("Ver en Recados", "See in Errands")) { showingErrands = true }.buttonStyle(.bordered)
                    }
                    Picker(said("Resultado simulado", "Simulated outcome"), selection: $outcome) {
                        Text(said("Pedido hecho", "Order placed")).tag("paid")
                        Text(said("Rechazado", "Declined")).tag("declined")
                        Text(said("Sin confirmar", "Unconfirmed")).tag("unknown")
                    }
                    if canAdvance && !automatic {
                        Button(said("Siguiente paso", "Next step")) { next() }.buttonStyle(.borderedProminent)
                    }
                    Text(said("Simulación aislada: nada llega a Hermes, se guarda o se cobra. Se detiene para tu elección y aprobación.",
                              "Isolated simulation: nothing reaches Hermes, is saved or charged. It waits for your choice and approval."))
                        .font(.footnote).foregroundStyle(.secondary).id("end")
                }.padding(20)
            }
            .onChange(of: step) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Palette.background(scheme))
        .navigationTitle(said("Compra en 12 pasos", "12-step purchase"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(said("Reiniciar", "Restart")) { restart() } } }
        .task(id: "\(run)-\(step.rawValue)-\(automatic)") {
            guard automatic, canAdvance else { return }
            do { try await Task.sleep(for: .seconds(1.5)); try Task.checkCancellation(); next() } catch { }
        }
        .sheet(isPresented: $showingErrands) {
            NavigationStack { ErrandsScreen(onClose: { showingErrands = false }, preview: [errand]) }
        }
        .sheet(isPresented: $showingBrowser) {
            VStack(spacing: 16) {
                CardImage(image: GalleryFixtures.pageURL, page: nil, symbol: "globe").frame(height: 320)
                Text(said("En la compra real puedes ver el navegador y tomar el control.",
                          "In a real purchase you can watch the browser and take over.")).font(.subheadline)
            }.padding(20).presentationDetents([.medium, .large])
        }
    }

    private var canAdvance: Bool {
        step != .clarify && step != .options && step != .approve && step != .result && step != .denied && step != .stuck
    }
    private func next() { if let next = Step(rawValue: step.rawValue + 1), next <= .result { advance(next) } }
    private func advance(_ next: Step) { withAnimation(.snappy) { step = next } }
    private func restart() { selected = nil; step = .clarify; run += 1; started = Date() }
    private func decide(_ allow: Bool) {
        guard step == .approve else { return }
        if !allow { advance(.denied); return }
        let generation = run
        Task {
            guard await Biometrics.authenticate(reason: said("Pagar 27,98 € en HSN (simulación)",
                                                             "Pay €27.98 at HSN (simulation)")),
                  generation == run, step == .approve else { return }
            advance(.pay)
        }
    }

    private var errand: Errand {
        let status: Errand.Status = switch step {
        case .approve: .needsApproval
        case .result: .done
        case .denied: .denied
        case .stuck: .stuck
        default: .working
        }
        var checkout = GalleryFixtures.checkout(language)
        checkout.total = selected?.price ?? checkout.total
        if let selected {
            checkout.merchant = selected.merchant
            checkout.items = [Errand.Item(name: selected.title, variant: selected.variant, qty: selected.qty,
                                         price: selected.price, image: selected.image)]
        }
        checkout.status = step == .pay || step == .result ? .approved : step == .denied ? .denied : .pending
        var receipt = GalleryFixtures.receipt(language)
        receipt.outcome = outcome
        receipt.total = checkout.total
        receipt.merchant = checkout.merchant
        receipt.items = checkout.items
        var errand = GalleryFixtures.errand(language, status: status,
            checkout: step >= .summary && step != .stuck ? checkout : nil,
            receipt: step == .result ? receipt : nil,
            reason: step == .stuck ? said("La variante elegida ya no está disponible.", "The selected variant is no longer available.") : "")
        errand.startedAt = started
        if step < .prepare { errand.steps = [] }
        return errand
    }

    private var caption: String {
        switch step {
        case .clarify: said("Aclarar", "Clarify")
        case .context: said("Contexto", "Context")
        case .search: said("Buscar", "Search")
        case .verify: said("Verificar", "Verify")
        case .options: said("Opciones", "Options")
        case .chosen: said("Tu elección", "Your choice")
        case .prepare: said("Preparar", "Prepare")
        case .card: said("Método de pago", "Payment method")
        case .summary: said("Resumen", "Summary")
        case .approve: said("Aprobación", "Approval")
        case .pay: said("Pago", "Payment")
        case .result: said("Resultado", "Result")
        case .denied: said("Cancelado", "Cancelled")
        case .stuck: said("Sin stock", "Out of stock")
        }
    }
    private func userBubble(_ text: String) -> some View {
        Text(text).padding(.horizontal, 16).padding(.vertical, 10)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
