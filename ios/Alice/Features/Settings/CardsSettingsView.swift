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

    var body: some View {
        Form {
            if loaded && cards.isEmpty && problem == nil {
                ContentUnavailableView("No Cards", systemImage: "creditcard",
                                       description: Text("A card you add when Alice pays is kept here."))
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
