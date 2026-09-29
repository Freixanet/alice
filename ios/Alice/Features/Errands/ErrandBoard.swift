import SwiftUI

/// The person's errands, as the plugin keeps them (`hermes-plugin/errands.py`): one list for the
/// chat's cards and the Errands page, refreshed while any of them is on screen, and the answers
/// the person gives — approving a checkout (after Face ID), answering a question, stopping one.
@MainActor
@Observable
final class ErrandBoard {
    private(set) var errands: [Errand] = []
    private(set) var loaded = false
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

    func attach(_ store: AppStore) { self.store = store }

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
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// «Permitir» pays, so it asks for Face ID first; «Denegar» does not.
    func decide(_ errand: Errand, allow: Bool) async {
        guard let store, let checkout = errand.checkout, checkout.status == .pending else { return }
        if allow {
            let language = errand.language
            let merchant = checkout.merchant.nonEmpty(or: checkout.site)
            let reason = language.pick("Pay \(checkout.total) at \(merchant)", "Pagar \(checkout.total) en \(merchant)")
            guard await Biometrics.authenticate(reason: reason) else { return }
        }
        await answer(errand) {
            try await store.decideCheckout(errand.id, checkoutID: checkout.id, allow: allow)
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
            await refresh()
        } catch {
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
    let errand: Errand
    var snapshot: ErrandBrowserCard.Snapshot = .live
    /// Whose logo the cards show: the errand's from the plugin, or `logo` in the walkthrough.
    var logoID: String? = nil
    var logo: URL? = nil
    var sending = false
    var problem: String? = nil
    let onOpenBrowser: () -> Void
    let onDecide: (Bool) -> Void
    let onAnswer: ([String: String]) -> Void
    let onConfirm: (Bool) -> Void

    private var checkoutPhase: CheckoutApprovalCard.Phase? {
        guard let checkout = errand.checkout, errand.receipt == nil else { return nil }
        switch checkout.status {
        case .pending: return errand.status == .needsApproval ? (sending ? .sending : .pending) : nil
        case .approved: return .approved
        case .denied: return .denied
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if errand.status.isOpen || errand.status == .done {
                ErrandBrowserCard(errand: errand, snapshot: errand.status == .done ? .none : snapshot,
                                  onOpen: onOpenBrowser)
            }
            ErrandProgressCard(errand: errand, logoID: logoID, logo: logo)
            if errand.status == .needsInput, !errand.questions.isEmpty {
                ErrandQuestionsCard(errand: errand, sending: sending, onAnswer: onAnswer)
            }
            if let approval = errand.approval, errand.status == .needsApproval, errand.checkout?.status != .pending {
                ErrandConfirmCard(approval: approval, language: errand.language, sending: sending,
                                  onAllow: { onConfirm(true) }, onDeny: { onConfirm(false) })
            }
            if let checkout = errand.checkout, let phase = checkoutPhase {
                CheckoutApprovalCard(checkout: checkout, logoID: logoID, logo: logo,
                                     language: errand.language, phase: phase, error: problem,
                                     onOpenPage: phase == .pending ? onOpenBrowser : nil,
                                     onAllow: { onDecide(true) }, onDeny: { onDecide(false) })
            }
            if let receipt = errand.receipt {
                ErrandReceiptCard(receipt: receipt, logoID: logoID, logo: logo, language: errand.language)
            }
            if let problem, checkoutPhase == nil {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
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
                    sending: board.sending.contains(errand.id), problem: board.problems[errand.id],
                    onOpenBrowser: { browsing = true },
                    onDecide: { allow in Task { await board.decide(errand, allow: allow) } },
                    onAnswer: { answers in Task { await board.answerQuestions(errand, answers) } },
                    onConfirm: { allow in Task { await board.confirm(errand, allow: allow) } })
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
