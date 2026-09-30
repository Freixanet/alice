import SwiftUI

/// The person's errands, as the plugin keeps them (`hermes-plugin/errands.py`): one list for the
/// chat's cards and the Errands page, refreshed while any of them is on screen, and the answers
/// the person gives — approving a checkout (after Face ID), answering a question, stopping one.
@MainActor
@Observable
final class ErrandBoard {
    private(set) var errands: [Errand] = []
    private(set) var loaded = false
    /// True once the list came from the Mac in this launch. Before that, what is shown is the last
    /// list saved on the phone (`LaunchCache`): drawn at once, but nothing is decided from it.
    private(set) var fresh = false
    private(set) var failure: String?
    /// Errands with an answer on its way, so their buttons wait.
    private(set) var sending: Set<String> = []
    /// What went wrong with the last answer to an errand, by errand.
    private(set) var problems: [String: String] = [:]
    /// The shop's logo, by errand; an errand looked up and without one is left out for good.
    private(set) var logos: [String: UIImage] = [:]
    @ObservationIgnored private var lookedUp: Set<String> = []

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    func attach(_ store: AppStore) {
        self.store = store
        // The chat's cards open on the last errands seen instead of on a spinner each.
        if errands.isEmpty, let saved = store.cachedLaunchList(.errands, as: [Errand].self) {
            errands = saved
        }
    }

    var needingPerson: [Errand] { errands.filter { $0.status.needsPerson } }

    func errand(id: String) -> Errand? { errands.first { $0.id == id } }

    /// While a card or the page is on screen: every few seconds while one is open, less often otherwise.
    func watch() {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let busy = self.errands.contains { $0.status == .working }
                try? await Task.sleep(for: .seconds(busy ? 3 : 10))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func loadLogo(_ errandID: String) async {
        guard let store, !lookedUp.contains(errandID) else { return }
        lookedUp.insert(errandID)
        if let data = try? await store.errandIcon(errandID), let image = UIImage(data: data) {
            logos[errandID] = image
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            errands = try await store.listErrands()
            fresh = true
            failure = nil
            store.rememberLaunchList(.errands, errands)
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// «Permitir» pays, so it asks for Face ID first; «Denegar» does not.
    func decide(_ errand: Errand, allow: Bool, card: String = "") async {
        guard let store, let checkout = errand.checkout, checkout.status == .pending else { return }
        if allow {
            let language = errand.language
            let merchant = checkout.merchant.nonEmpty(or: checkout.site)
            let reason = language.pick("Pay \(checkout.total) at \(merchant)", "Pagar \(checkout.total) en \(merchant)")
            guard await Biometrics.authenticate(reason: reason) else { return }
        }
        await answer(errand) {
            try await store.decideCheckout(errand.id, checkoutID: checkout.id, allow: allow, card: card)
        }
    }

    func answerQuestions(_ errand: Errand, _ answers: [String: String]) async {
        guard let store else { return }
        await answer(errand) { try await store.answerErrand(errand.id, answers: answers) }
    }

    func confirm(_ errand: Errand, allow: Bool) async {
        guard let store, let approval = errand.approval else { return }
        await answer(errand) { try await store.approveInErrand(errand.id, requestID: approval.requestID, allow: allow) }
    }

    func cardReady(_ errand: Errand, label: String) async {
        guard let store else { return }
        await answer(errand) { try await store.errandCardReady(errand.id, label: label) }
    }

    func refreshCheckout(_ errand: Errand) async {
        guard let store else { return }
        await answer(errand) { try await store.refreshCheckout(errand.id) }
    }

    func stop(_ errand: Errand) async {
        guard let store else { return }
        await answer(errand) { try await store.stopErrand(errand.id) }
    }

    private func answer(_ errand: Errand, _ work: () async throws -> Errand?) async {
        guard !sending.contains(errand.id) else { return }
        sending.insert(errand.id)
        problems[errand.id] = nil
        defer { sending.remove(errand.id) }
        do {
            if let updated = try await work() { replace(updated) }
            // The Mac took the answer: approved, denied, answered, stopped.
            Haptic.success.play()
            await refresh()
        } catch {
            Haptic.error.play()
            problems[errand.id] = error.localizedDescription
            await refresh()
        }
    }

    private func replace(_ updated: Errand) {
        if let index = errands.firstIndex(where: { $0.id == updated.id }) {
            errands[index] = updated
        } else {
            errands.insert(updated, at: 0)
        }
    }
}

/// An errand's cards, one under another: the browser, the progress, and whatever it needs from the
/// person — the checkout, a question, a confirmation — or its receipt. The same stack for the
/// chat, the Errands page and the walkthrough; what the buttons do is given.
struct ErrandStack: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let errand: Errand
    var snapshot: ErrandBrowserCard.Snapshot = .live
    /// Whose logo the cards show: the errand's from the plugin, or `logo` in the walkthrough.
    var logoID: String? = nil
    var logo: URL? = nil
    var sending = false
    var problem: String? = nil
    let onOpenBrowser: () -> Void
    /// Allowed or not, and with which card.
    let onDecide: (Bool, String) -> Void
    let onAnswer: ([String: String]) -> Void
    let onConfirm: (Bool) -> Void
    var onCardReady: (String) -> Void = { _ in }
    var onRefreshCheckout: () -> Void = {}
    var onStop: () -> Void = {}
    /// The walkthrough's own cards, instead of the vault's.
    var demoCards: [SavedCard]? = nil

    @State private var cards: [SavedCard] = []
    @State private var chosen: SavedCard?
    @State private var addingCard = false

    private var checkoutPhase: CheckoutApprovalCard.Phase? {
        guard let checkout = errand.checkout, errand.receipt == nil else { return nil }
        switch checkout.status {
        case .pending: return errand.status == .needsApproval ? (sending ? .sending : .pending) : nil
        case .approved: return .approved
        case .denied: return .denied
        case .expired: return errand.status.isOpen ? .expired : nil
        case .replaced: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The browser only while it is being used: not before it starts, and gone once the
            // errand waits for the person or ends (a still page left there read as broken).
            if errand.status == .working && !errand.steps.isEmpty {
                ErrandBrowserCard(errand: errand, snapshot: snapshot, onOpen: onOpenBrowser)
            }
            ErrandProgressCard(errand: errand, logoID: logoID, logo: logo)
            if errand.status == .needsCard, !errand.cardOrigin.isEmpty {
                PaymentCardOfferCard(offer: PaymentCardOffer(origin: errand.cardOrigin, profile: "default"),
                                     language: errand.language,
                                     onReady: { card in onCardReady(card.label) })
            }
            if errand.status == .needsInput, !errand.questions.isEmpty {
                ErrandQuestionsCard(errand: errand, sending: sending, onAnswer: onAnswer)
            }
            if let approval = errand.approval, errand.status == .needsApproval, errand.checkout?.status != .pending {
                ErrandConfirmCard(approval: approval, language: errand.language, sending: sending,
                                  onAllow: { onConfirm(true) }, onDeny: { onConfirm(false) })
            }
            if let checkout = errand.checkout, let phase = checkoutPhase {
                if phase == .pending || phase == .sending {
                    RichMessageView(content: PurchaseSummaryText.summary(checkout, card: chosen?.label ?? checkout.cardLabel,
                                                                        language: errand.language))
                }
                CheckoutApprovalCard(checkout: checkout, logoID: logoID, logo: logo,
                                     language: errand.language, phase: phase, compact: true, error: problem,
                                     onOpenPage: phase == .pending ? onOpenBrowser : nil,
                                     cards: cards, chosenCard: chosen,
                                     onChooseCard: { chosen = $0 }, onAddCard: { addingCard = true },
                                     paid: errand.status == .done && errand.receipt?.paid != false,
                                     paying: errand.status.isOpen,
                                     busy: sending,
                                     onRefresh: onRefreshCheckout,
                                     onAllow: { onDecide(true, chosen?.label ?? checkout.cardLabel) },
                                     onDeny: { phase == .expired ? onStop() : onDecide(false, "") })
                    .task(id: checkout.id) { await loadCards(for: checkout) }
                    .sheet(isPresented: $addingCard) {
                        PaymentCardSheet(offer: PaymentCardOffer(origin: "https://" + checkout.site, profile: "default"),
                                         language: errand.language, demo: demoCards != nil) { card in
                            cards.append(card)
                            chosen = card
                        }
                    }
            }
            if let receipt = errand.receipt {
                RichMessageView(content: PurchaseSummaryText.result(receipt, language: errand.language))
            } else if let stopped = PurchaseSummaryText.stopped(errand, language: errand.language) {
                RichMessageView(content: stopped)
            }
            if let problem, checkoutPhase == nil {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
        }
    }
}

extension ErrandStack {
    /// The saved cards; the one the agent named, or the only one, is chosen to start with.
    fileprivate func loadCards(for checkout: Errand.Checkout) async {
        let found: [SavedCard]
        if let demoCards {
            found = demoCards
        } else {
            let all = (try? await store.savedCards(profile: "default")) ?? []
            // The same card saved for several sites is one choice.
            var seen = Set<String>()
            found = all.filter { seen.insert($0.card).inserted }
        }
        cards = found
        if chosen == nil {
            chosen = found.first { $0.card == checkout.cardLabel || $0.label == checkout.cardLabel }
                ?? (found.count == 1 ? found.first : nil)
        }
    }
}

/// The errand a reply started (`errand_start`), live from the board, in the chat.
struct ErrandChatBlock: View {
    let ref: ErrandRef

    @Environment(AppStore.self) private var store
    @State private var browsing = false

    private var board: ErrandBoard { store.errandBoard }

    var body: some View {
        Group {
            if let errand = ref.find(in: board.errands) {
                ErrandStack(
                    errand: errand, logoID: errand.id,
                    // A saved errand's buttons wait for the Mac's own word on it.
                    sending: board.sending.contains(errand.id) || !board.fresh, problem: board.problems[errand.id],
                    onOpenBrowser: { browsing = true },
                    onDecide: { allow, card in Task { await board.decide(errand, allow: allow, card: card) } },
                    onAnswer: { answers in Task { await board.answerQuestions(errand, answers) } },
                    onConfirm: { allow in Task { await board.confirm(errand, allow: allow) } },
                    onCardReady: { label in Task { await board.cardReady(errand, label: label) } },
                    onRefreshCheckout: { Task { await board.refreshCheckout(errand) } },
                    onStop: { Task { await board.stop(errand) } })
                // Felt as it turns, and only from the Mac's own word (a saved card changing on
                // launch is not news): it needs the person now, or the order went through.
                .haptic(.warning, trigger: errand.status) { old, new in
                    board.fresh && !old.needsPerson && new.needsPerson
                }
                .haptic(.success, trigger: errand.receipt?.paid == true) { old, new in
                    board.fresh && !old && new
                }
                .fullScreenCover(isPresented: $browsing) {
                    LiveBrowserScreen(agentWorking: errand.status == .working, caption: errand.lastStep?.text)
                }
            } else if !board.loaded {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(ref.title).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .onAppear { board.watch() }
        .onDisappear { board.unwatch() }
    }
}
