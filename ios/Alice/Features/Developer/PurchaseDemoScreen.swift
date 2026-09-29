import SwiftUI

/// Developer › Purchase walkthrough: a scripted errand in Alice's own components, to judge how it
/// feels end to end — the request, the errand working in the background, the notification that it
/// needs approval, the checkout with Face ID, the order going through, the receipt and the list of
/// errands. The cards are the real ones; nothing is read from or written to Hermes and nothing is
/// charged.
struct PurchaseDemoScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private enum Step: Int, Comparable {
        case asked, started, browsing, checkout, approving, paying, done, denied
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    @State private var step: Step = .asked
    @State private var language = ChatLanguage.spanish
    @State private var fromProduct = false
    @State private var automatic = true
    @State private var run = 0
    @State private var started = Date()
    @State private var showingProduct = false
    @State private var showingErrands = false
    @State private var showingBrowser = false
    @State private var banner = false

    private let photo = URL(string: "https://placehold.co/600x600/ffffff/1f3b73/png?text=Creapure+500+g")
    private let page = URL(string: "https://placehold.co/820x520/f3f4f6/1f2937/png?text=hsnstore.com+Checkout")

    private func said(_ spanish: String, _ english: String) -> String { language.pick(english, spanish) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    if fromProduct {
                        aliceBubble(said("Esta es la de siempre en HSN:", "This is your usual one at HSN:"))
                        Button { showingProduct = true } label: { productRow }
                            .buttonStyle(.plain)
                    }
                    if step >= .started || !fromProduct {
                        userBubble(said("Compra la creatina Creapure de HSN", "Buy the Creapure creatine from HSN"))
                    }
                    if step >= .started {
                        aliceBubble(said("Lo pongo en marcha. Te aviso antes de pagar.",
                                         "I'm on it. I'll check with you before paying."))
                        ErrandStack(
                            errand: errand, snapshot: .still(page), sending: step == .approving,
                            onOpenBrowser: { showingBrowser = true },
                            onDecide: { allow in if allow { approve() } else { advance(to: .denied) } },
                            onAnswer: { _ in }, onConfirm: { _ in })
                    }
                    if step == .done {
                        aliceBubble(said("Hecho. Pedido 100123456: llega el viernes.",
                                         "Done. Order 100123456 arrives on Friday."))
                    }
                    if step == .denied {
                        aliceBubble(said("Vale, no he pagado nada. El carrito sigue listo en HSN.",
                                         "Okay, I haven't paid anything. The basket is still ready at HSN."))
                    }
                    if !automatic, step >= .started, step < .checkout {
                        Button(said("Siguiente paso", "Next step")) { next() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                    if step >= .started {
                        Button { showingErrands = true } label: {
                            Label(said("Ver en Recados", "See in Errands"), systemImage: "bag")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }

                    Text(said("Simulación: nada se guarda ni se cobra. Las tarjetas son las de la app.",
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
        .overlay(alignment: .top) {
            if banner { notification.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .background(Palette.background(scheme))
        .navigationTitle(said("Compra de prueba", "Purchase walkthrough"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(said("Reiniciar", "Restart")) { restart() }
            }
        }
        .task(id: run) { await play() }
        .sensoryFeedback(.success, trigger: step) { _, new in new == .paying || new == .done }
        .sensoryFeedback(.warning, trigger: banner) { _, shown in shown }
        .sheet(isPresented: $showingProduct) {
            PurchaseProductSheet(image: photo, seller: "HSN", title: "Creatina Excell 500 g (Creapure®)",
                                 price: "27,98 €", oldPrice: "34,90 €", language: language,
                                 options: [said("Sin sabor", "Unflavoured"), said("Limón", "Lemon"),
                                           said("Naranja", "Orange")]) {
                advance(to: .started)
            }
        }
        .sheet(isPresented: $showingErrands) {
            NavigationStack {
                ErrandsScreen(onClose: { showingErrands = false }, preview: previewList)
            }
        }
        .sheet(isPresented: $showingBrowser) {
            VStack(spacing: 16) {
                CardImage(image: page, page: nil, symbol: "globe")
                    .frame(height: 320)
                    .clipShape(.rect(cornerRadius: 22))
                Text(said("En la app real se abre el navegador en vivo: ves lo que hace Alice y puedes tomar el control.",
                          "In the real app the live browser opens: you watch Alice and can take over."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: The script

    /// The errand as the plugin would report it at this step.
    private var errand: Errand {
        let steps = [
            said("Abrir HSN y buscar Creapure", "Open HSN and search for Creapure"),
            said("Elegir Creatina Excell 500 g, sin sabor", "Choose Creatine Excell 500 g, unflavoured"),
            said("Añadir al carrito", "Add to basket"),
            said("Iniciar sesión con la cuenta guardada", "Sign in with the saved account"),
            said("Elegir envío estándar gratis", "Choose free standard delivery"),
            said("Ir al paso de pago", "Go to the payment step"),
        ]
        let shown: Int = switch step {
        case .asked, .started: 1
        case .browsing: 4
        default: steps.count
        }
        var list = steps.prefix(shown).map { Errand.Step(text: $0, url: "https://www.hsnstore.com", at: started) }
        if step == .paying || step == .done {
            list.append(Errand.Step(text: said("Pagar con la tarjeta guardada", "Pay with the saved card"),
                                    url: "https://www.hsnstore.com", at: started))
        }
        let status: Errand.Status = switch step {
        case .checkout, .approving: .needsApproval
        case .done: .done
        case .denied: .denied
        default: .working
        }
        let checkoutStatus: Errand.Checkout.Status = switch step {
        case .paying, .done: .approved
        case .denied: .denied
        default: .pending
        }
        return Errand(
            id: "demo01", title: said("Comprar Creapure en HSN", "Buy Creapure at HSN"),
            request: said("Compra la creatina Creapure de HSN", "Buy the Creapure creatine from HSN"),
            site: "hsnstore.com", status: status,
            checkout: step >= .checkout ? checkout(checkoutStatus) : nil,
            receipt: step == .done ? receipt : nil,
            questionsTitle: "", questions: [], approval: nil, reason: "",
            summary: said("Pedido 100123456 realizado.", "Order 100123456 placed."),
            steps: list, startedAt: started, updatedAt: Date())
    }

    private var item: Errand.Item {
        Errand.Item(name: "Creatina Excell 500 g (Creapure®)", variant: said("Sin sabor", "Unflavoured"), qty: 1,
                    price: "27,98 €", image: photo)
    }

    private func checkout(_ status: Errand.Checkout.Status) -> Errand.Checkout {
        Errand.Checkout(id: "c1", status: status, merchant: "HSN", site: "hsnstore.com", items: [item],
                        delivery: said("Envío gratis · llega el viernes 2 oct", "Free delivery · arrives Friday, Oct 2"),
                        address: "Calle Mayor 1, 28013 Madrid", email: "nombre@email.com",
                        cardLabel: "Visa ···4242", total: "27,98 €", currency: "EUR")
    }

    private var receipt: Errand.Receipt {
        Errand.Receipt(outcome: "paid", order: "100123456", total: "27,98 €", merchant: "HSN", site: "hsnstore.com",
                       items: [item], cardLabel: "Visa ···4242",
                       delivery: said("Llega el viernes 2 oct", "Arrives Friday, Oct 2"))
    }

    /// The list of errands, with two older ones so the finished states show too.
    private var previewList: [Errand] {
        let stuck = Errand(
            id: "demo02", title: said("Reservar la ITV en Madrid", "Book an MOT in Madrid"),
            request: said("Resérvame la ITV", "Book my MOT"), site: "itv.example", status: .stuck,
            checkout: nil, receipt: nil, questionsTitle: "", questions: [], approval: nil,
            reason: said("No hay citas hasta noviembre", "No slots until November"), summary: "", steps: [],
            startedAt: Date().addingTimeInterval(-7200), updatedAt: Date().addingTimeInterval(-6000))
        let food = Errand(
            id: "demo03", title: said("Pienso Purina 14 kg", "Purina dog food 14 kg"),
            request: said("Pide el pienso de siempre", "Order the usual dog food"), site: "piensosraposo.es",
            status: .done, checkout: nil,
            receipt: Errand.Receipt(outcome: "paid", order: "88-4271", total: "64,40 €", merchant: "Piensos Raposo",
                                    site: "piensosraposo.es", items: [], cardLabel: "Visa ···4242", delivery: ""),
            questionsTitle: "", questions: [], approval: nil, reason: "", summary: "", steps: [],
            startedAt: Date().addingTimeInterval(-86_400), updatedAt: Date().addingTimeInterval(-80_000))
        return [errand, stuck, food]
    }

    private func play() async {
        started = Date()
        // From the product card, its «Comprar con Alice» starts it.
        guard !fromProduct else { return }
        await pause(700)
        guard !Task.isCancelled else { return }
        advance(to: .started)
    }

    /// Automatic: the errand works on its own until it needs the person.
    private func runErrand() async {
        guard automatic else { return }
        await pause(1800)
        guard step == .started else { return }
        advance(to: .browsing)
        await pause(2200)
        guard step == .browsing else { return }
        advance(to: .checkout)
    }

    private func next() {
        switch step {
        case .started: advance(to: .browsing)
        case .browsing: advance(to: .checkout)
        default: break
        }
    }

    private func advance(to next: Step) {
        withAnimation(.snappy) { step = next }
        switch next {
        case .started:
            started = Date()
            Task { await runErrand() }
        case .checkout:
            // What the Mac's notifier sends through Bark: who and what for, never what it is.
            withAnimation(.snappy) { banner = true }
            Task {
                await pause(3200)
                withAnimation(.snappy) { banner = false }
            }
        default:
            break
        }
    }

    /// «Permitir» asks for Face ID, as the real one does.
    private func approve() {
        Task {
            guard await Biometrics.authenticate(reason: said("Pagar 27,98 € en HSN", "Pay €27.98 at HSN")) else { return }
            advance(to: .approving)
            await pause(700)
            advance(to: .paying)
            await pause(2000)
            if step == .paying { advance(to: .done) }
        }
    }

    private func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func restart() {
        step = .asked
        banner = false
        run += 1
    }

    // MARK: Pieces

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Language", selection: $language) {
                Text("Español").tag(ChatLanguage.spanish)
                Text("English").tag(ChatLanguage.english)
            }
            .pickerStyle(.segmented)
            Toggle(said("Empezar desde la ficha del producto", "Start from the product card"), isOn: $fromProduct)
                .onChange(of: fromProduct) { _, _ in restart() }
            Toggle(said("Avanzar solo", "Play automatically"), isOn: $automatic)
                .onChange(of: automatic) { _, _ in restart() }
        }
    }

    private var productRow: some View {
        HStack(spacing: 14) {
            CardImage(image: photo, page: nil, symbol: "bag", fits: true)
                .background(Color.white)
                .frame(width: 60, height: 60)
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Creatina Excell 500 g (Creapure®)").font(.body.weight(.medium)).lineLimit(2)
                Text("HSN · 27,98 €").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
    }

    private var notification: some View {
        HStack(spacing: 12) {
            Image(systemName: "bag.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(store.accent.control(scheme), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("Alice").font(.subheadline.weight(.semibold))
                Text(said("Un recado necesita tu aprobación", "An errand needs your approval")).font(.subheadline)
            }
            Spacer(minLength: 0)
            Text(said("ahora", "now")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .onTapGesture { withAnimation(.snappy) { banner = false } }
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

    private func aliceBubble(_ text: String) -> some View {
        RichMessageView(content: text)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
    }
}
