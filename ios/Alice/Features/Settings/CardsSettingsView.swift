import SwiftUI

/// Cards saved in Hermes' vault on the Mac: an alias to tell them apart, and
/// removal. The numbers never come to the phone; only "Visa ···4242".
struct CardsSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var profile = "default"

    @State private var cards: [SavedCard] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var renaming: SavedCard?
    @State private var alias = ""
    @State private var removing: SavedCard?
    @State private var adding = false

    var body: some View {
        Form {
            if loaded && cards.isEmpty && problem == nil {
                ContentUnavailableView("No Cards", systemImage: "creditcard",
                                       description: Text("Add a card, or Alice will ask for one when she has to pay."))
            }
            if !cards.isEmpty {
                Section {
                    ForEach(SavedCard.distinct(cards)) { card in
                        Button {
                            alias = card.alias
                            renaming = card
                        } label: {
                            LabeledContent {
                                Text(sites(of: card))
                            } label: {
                                Label {
                                    Text(card.alias.isEmpty ? card.card : card.alias)
                                    if !card.alias.isEmpty { Text(card.card) }
                                } icon: {
                                    Image(systemName: "creditcard")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = card }
                        }
                    }
                } footer: {
                    Text("Tap a card to give it an alias.")
                }
            }
            if let problem {
                Text(problem).foregroundStyle(Palette.danger(scheme))
            }
        }
        .aliceFormPaper(scheme)
        .navigationTitle("Cards")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a card")
            }
        }
        .sheet(isPresented: $adding) {
            PaymentCardSheet(offer: nil, profile: profile, language: Locale.current.language.languageCode == .spanish ? .spanish : .english) { _ in
                Task { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Alias", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Personal, Work…", text: $alias)
            Button("Save") {
                if let card = renaming { Task { await rename(card) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let card = renaming { Text(card.card) }
        }
        .confirmationDialog(
            "Remove \(removing.map { $0.alias.isEmpty ? $0.card : "\($0.alias) (\($0.card))" } ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from Hermes", role: .destructive) {
                if let card = removing { Task { await remove(card) } }
            }
        } message: {
            Text("Alice won't be able to pay with it until you add it again.")
        }
    }

    private func sites(of card: SavedCard) -> String {
        let hosts = Set(cards.filter { $0.card == card.card }.compactMap { card -> String? in
            guard let origin = card.origin else { return nil }
            return URL(string: origin)?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "")
        })
        if hosts.isEmpty { return String(localized: "Not used yet") }
        return hosts.count == 1 ? hosts.first! : String(localized: "\(hosts.count) sites")
    }

    private func load() async {
        do {
            cards = try await store.savedCards(profile: profile)
            problem = nil
        } catch {
            problem = PlainWords.describe(error, doing: "load your cards")
        }
        loaded = true
    }

    private func rename(_ card: SavedCard) async {
        do {
            _ = try await store.renameCard(handle: card.handle, alias: alias, profile: profile)
            await load()
        } catch {
            problem = PlainWords.describe(error, doing: "rename the card")
        }
    }

    private func remove(_ card: SavedCard) async {
        // Every site it is saved for: removing one copy removes it and its www twin.
        for copy in cards where copy.card == card.card {
            try? await store.removeCard(handle: copy.handle, profile: profile)
        }
        await load()
        if cards.contains(where: { $0.card == card.card }) {
            problem = String(localized: "Some copies of the card could not be removed. Pull down to try again.")
        }
    }
}

/// What Alice fills in a checkout or a sign-up: kept on the Mac by the plugin,
/// given once — here or in a question card — and never asked for again.
struct DeliveryDetailsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var profile = "default"

    private static let fields: [(key: String, label: String, keyboard: UIKeyboardType, content: UITextContentType?)] = [
        ("name", "Name", .default, .givenName),
        ("surname", "Surname", .default, .familyName),
        ("id", "ID (NIF/NIE)", .asciiCapable, nil),
        ("address", "Address", .default, .fullStreetAddress),
        ("postcode", "Postcode", .numberPad, .postalCode),
        ("city", "City", .default, .addressCity),
        ("province", "Province", .default, .addressState),
        ("phone", "Phone", .phonePad, .telephoneNumber),
        ("email", "Email", .emailAddress, .emailAddress),
    ]

    @State private var values: [String: String] = [:]
    @State private var saved: [String: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.fields, id: \.key) { field in
                    TextField(field.label, text: Binding(
                        get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }))
                        .keyboardType(field.keyboard)
                        .textContentType(field.content)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("Alice uses these to fill in checkouts and sign-ups, so she does not have to ask. They stay on your Mac.")
            }
            if let problem {
                Text(problem).foregroundStyle(Palette.danger(scheme))
            }
        }
        .aliceFormPaper(scheme)
        .navigationTitle("Delivery details")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!loaded || saving || cleaned(values) == saved)
            }
        }
        .disabled(!loaded)
        .task { await load() }
    }

    private func cleaned(_ values: [String: String]) -> [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
    }

    private func load() async {
        do {
            saved = try await store.deliveryDetails(profile: profile)
            values = saved
            problem = nil
        } catch {
            problem = "Couldn't read them from your Mac."
        }
        loaded = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            saved = try await store.saveDeliveryDetails(cleaned(values), profile: profile)
            values = saved
            problem = nil
        } catch {
            problem = "Couldn't save them on your Mac."
        }
    }
}
