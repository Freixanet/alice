import SwiftUI

struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List {
            ForEach(store.conversations) { conversation in
                Button {
                    store.activeID = conversation.id
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).foregroundStyle(.primary)
                        Text(conversation.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        store.delete(conversation.id)
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}
