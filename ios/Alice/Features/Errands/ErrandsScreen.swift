import SwiftUI

/// Every errand Alice is running or ran for the person: those waiting for them first, then those
/// under way, then the finished ones. Opening one shows its cards and lets the person stop it.
struct ErrandsScreen: View {
    var onClose: () -> Void = {}
    /// The walkthrough's own errands, instead of the plugin's.
    var preview: [Errand]? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var opened: String?

    private var board: ErrandBoard { store.errandBoard }
    private var errands: [Errand] { preview ?? board.errands }
    private var waiting: [Errand] { errands.filter { $0.status.needsPerson } }
    private var working: [Errand] { errands.filter { $0.status == .working } }
    private var finished: [Errand] { errands.filter { !$0.status.isOpen } }

    var body: some View {
        List {
            Text("Errands")
                .font(.aliceTitle(.largeTitle))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)

            if (preview != nil || board.loaded) && errands.isEmpty {
                ContentUnavailableView {
                    Label("No errands yet", systemImage: "bag")
                } description: {
                    Text("Ask Alice to buy, order or book something. She does it in the background and asks you before paying.")
                }
                .listRowBackground(Color.clear)
            }

            section("Needs you", waiting)
            section("Under way", working)
            section("Finished", finished)

            if preview == nil, let failure = board.failure {
                Text(failure).font(.footnote).foregroundStyle(Palette.danger(scheme))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Errands")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("errands.back")
            }
        }
        .refreshable { if preview == nil { await board.refresh() } }
        .onAppear {
            if preview == nil { board.watch() }
            openRequested()
        }
        .onDisappear { if preview == nil { board.unwatch() } }
        .onChange(of: store.requestedErrand) { _, _ in openRequested() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, preview == nil { Task { await board.refresh() } }
        }
        .sheet(item: Binding(get: { opened.map(OpenedErrand.init) }, set: { opened = $0?.id })) { item in
            NavigationStack {
                ErrandDetailScreen(errandID: item.id, preview: preview)
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func openRequested() {
        guard let id = store.requestedErrand else { return }
        store.requestedErrand = nil
        opened = id
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [Errand]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { errand in
                    Button { opened = errand.id } label: { ErrandRow(errand: errand) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text(title).font(.headline).foregroundStyle(.primary).textCase(nil)
            }
            .listRowBackground(Palette.card(scheme))
        }
    }
}

private struct OpenedErrand: Identifiable { let id: String }

/// One errand in the list: the shop's mark, what it is, its state and how long.
struct ErrandRow: View {
    @Environment(\.colorScheme) private var scheme
    let errand: Errand

    var body: some View {
        HStack(spacing: 12) {
            MerchantMark(name: (errand.checkout?.merchant ?? "").nonEmpty(or: errand.site.nonEmpty(or: errand.title)),
                         size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(errand.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    ComponentPill(text: errand.status.label(errand.language), tint: errand.status.tint(scheme))
                    if let total = errand.receipt?.total ?? errand.checkout?.total, !total.isEmpty {
                        Text(total.pricesKeptTogether).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(errand.elapsed.errandElapsed).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// One errand: its cards, and stopping it while it runs.
struct ErrandDetailScreen: View {
    let errandID: String
    var preview: [Errand]? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var browsing = false
    @State private var confirmingStop = false

    private var board: ErrandBoard { store.errandBoard }
    private var errand: Errand? { (preview ?? board.errands).first { $0.id == errandID } }

    var body: some View {
        ScrollView {
            if let errand {
                VStack(alignment: .leading, spacing: 12) {
                    Text(errand.request)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    ErrandStack(
                        errand: errand, snapshot: preview == nil ? .live : .none,
                        sending: board.sending.contains(errand.id), problem: board.problems[errand.id],
                        onOpenBrowser: { if preview == nil { browsing = true } },
                        onDecide: { allow in if preview == nil { Task { await board.decide(errand, allow: allow) } } },
                        onAnswer: { answers in if preview == nil { Task { await board.answerQuestions(errand, answers) } } },
                        onConfirm: { allow in if preview == nil { Task { await board.confirm(errand, allow: allow) } } })
                    if errand.status.isOpen, preview == nil {
                        Button(role: .destructive) { confirmingStop = true } label: {
                            Text(errand.language.pick("Stop this errand", "Parar este recado"))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .confirmationDialog(
                            errand.language.pick("Stop «\(errand.title)»?", "¿Parar «\(errand.title)»?"),
                            isPresented: $confirmingStop, titleVisibility: .visible
                        ) {
                            Button(errand.language.pick("Stop it", "Pararlo"), role: .destructive) {
                                Task { await board.stop(errand) }
                            }
                        } message: {
                            Text(errand.language.pick("Nothing that was not paid will be paid.",
                                                      "No se pagará nada que no se haya pagado ya."))
                        }
                    }
                }
                .padding(16)
                .fullScreenCover(isPresented: $browsing) {
                    LiveBrowserScreen(agentWorking: errand.status == .working, caption: errand.lastStep?.text)
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .background(Palette.background(scheme).ignoresSafeArea())
        .navigationTitle(errand?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
        .onAppear { if preview == nil { board.watch() } }
        .onDisappear { if preview == nil { board.unwatch() } }
    }
}
