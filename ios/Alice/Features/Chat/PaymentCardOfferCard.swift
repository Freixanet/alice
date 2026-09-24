import SwiftUI

/// The card for a payment page that needs a card Hermes does not have yet. It
/// opens a native form (iOS offers the cards saved in the phone's AutoFill),
/// or lets a card already saved for another site be used here too. The card
/// goes straight to Hermes' vault on the Mac, bound to this page's site; the
/// chat only hears that it is saved.
struct PaymentCardOfferCard: View {
    let offer: PaymentCardOffer
    var language: ChatLanguage = .english

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    @State private var showingForm = false
    @State private var saved: SavedCard?
    /// A card already saved for another site, offered here with one tap.
    @State private var known: SavedCard?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if let saved {
            Label(language.pick("\(saved.label) ready for \(offer.host)", "\(saved.label) lista para \(offer.host)"),
                  systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.success(scheme))
        } else if !superseded {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(store.accent.primary(scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.pick("Add a card", "Añadir tarjeta"))
                        .font(.headline)
                    Text(language.pick("To pay on \(offer.host)", "Para pagar en \(offer.host)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if known == nil {
                    Button(language.pick("Add", "Añadir")) { showingForm = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let known {
                HStack(spacing: 8) {
                    Button {
                        Task { await use(known) }
                    } label: {
                        if working { ProgressView() } else { Text(language.pick("Use \(known.label)", "Usar \(known.label)")) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    Button(language.pick("Another card", "Otra tarjeta")) { showingForm = true }
                        .buttonStyle(.bordered)
                        .disabled(working)
                }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
            Text(language.pick("Kept encrypted in Hermes on your Mac. It never goes through the chat, and Alice asks before using it.",
                               "Se guarda cifrada en Hermes, en tu Mac. Nunca pasa por el chat, y Alice te pregunta antes de usarla."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border(scheme).opacity(0.5), lineWidth: 0.5) }
        .sheet(isPresented: $showingForm) {
            PaymentCardSheet(offer: offer, language: language) { card in finish(card) }
        }
        .task {
            let cards = (try? await store.savedCards(profile: offer.profile)) ?? []
            known = cards.first { $0.origin != offer.origin }
        }
    }

    private func use(_ card: SavedCard) async {
        working = true
        problem = nil
        defer { working = false }
        do {
            finish(try await store.saveCard(nil, handle: card.handle, origin: offer.origin, profile: offer.profile))
        } catch {
            problem = PlainWords.describe(error, doing: "use the card")
        }
    }

    private func finish(_ card: SavedCard) {
        withAnimation(.snappy) { saved = card }
        store.sendAppNote("The person saved \(card.label) for \(card.origin ?? offer.origin). Carry on with the task.")
    }
}

/// The card form. Nothing typed here is kept after it closes.
struct PaymentCardSheet: View {
    let offer: PaymentCardOffer
    let language: ChatLanguage
    let onSaved: (SavedCard) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var fields = PaymentCardFields()
    @State private var others: [SavedCard] = []
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case number, expiry, cvc, name }

    var body: some View {
        NavigationStack {
            Form {
                if !others.isEmpty {
                    Section(language.pick("Saved cards", "Tarjetas guardadas")) {
                        ForEach(others) { card in
                            Button {
                                Task { await save(handle: card.handle) }
                            } label: {
                                LabeledContent {
                                    Text(language.pick("Use here", "Usar aquí"))
                                } label: {
                                    Label(card.label, systemImage: "creditcard")
                                }
                            }
                            .disabled(working)
                        }
                    }
                }
                Section {
                    TextField(language.pick("Card number", "Número de tarjeta"), text: $fields.number)
                        .textContentType(.creditCardNumber)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .number)
                        .onChange(of: fields.number) { _, new in
                            let grouped = PaymentCardFields.grouped(new)
                            if grouped != new { fields.number = grouped }
                        }
                    HStack {
                        TextField(language.pick("MM/YY", "MM/AA"), text: $fields.expiry)
                            .textContentType(.creditCardExpiration)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .expiry)
                            .onChange(of: fields.expiry) { _, new in
                                let formatted = PaymentCardFields.expiryFormatted(new)
                                if formatted != new { fields.expiry = formatted }
                            }
                        Divider()
                        SecureField("CVC", text: $fields.cvc)
                            .textContentType(.creditCardSecurityCode)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .cvc)
                    }
                    TextField(language.pick("Name on card (optional)", "Titular (opcional)"), text: $fields.name)
                        .textContentType(.creditCardName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .name)
                } header: {
                    if !others.isEmpty { Text(language.pick("New card", "Tarjeta nueva")) }
                } footer: {
                    Text(language.pick("Saved encrypted in Hermes on your Mac, for \(offer.host) only. Alice fills it in without seeing it, after you confirm, and it never appears in the chat.",
                                       "Se guarda cifrada en Hermes, en tu Mac, solo para \(offer.host). Alice la rellena sin verla, después de que lo confirmes, y nunca aparece en el chat."))
                }
                if let problem = problem ?? fields.problem(spanish: language == .spanish) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle(offer.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.pick("Cancel", "Cancelar")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(language.pick("Save", "Guardar")) { Task { await save(handle: nil) } }
                            .disabled(!fields.isValid())
                    }
                }
            }
            .task {
                focus = .number
                let all = (try? await store.savedCards(profile: offer.profile)) ?? []
                others = all.filter { $0.origin != offer.origin }
                    .reduce(into: [SavedCard]()) { list, card in
                        if !list.contains(where: { $0.label == card.label }) { list.append(card) }
                    }
            }
            .onDisappear { fields = PaymentCardFields() }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.large])
    }

    private func save(handle: String?) async {
        working = true
        problem = nil
        defer { working = false }
        do {
            let card = try await store.saveCard(handle == nil ? fields : nil, handle: handle,
                                                origin: offer.origin, profile: offer.profile)
            fields = PaymentCardFields()
            onSaved(card)
            dismiss()
        } catch {
            problem = PlainWords.describe(error, doing: "save the card")
        }
    }
}
