#if DEBUG
import SwiftUI

/// The QA journey (`-qaDashboard <url>`): the Errands page, connected to the purchase simulator's
/// dashboard (hermes-plugin/qa/serve.py) instead of a person's Hermes. PurchaseJourneyTests drives
/// it on a CI simulator; nothing here exists in a release build.
struct QAJourneyScreen: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ErrandsScreen()
        }
        .task { await store.connectForQA() }
    }
}
#endif
