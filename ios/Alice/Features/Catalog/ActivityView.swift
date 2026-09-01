import SwiftUI

/// Jobs and Insights. Both need capabilities a given Hermes may not serve, so
/// the screen states the requirement instead of showing an empty list.
struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    List {
                Section("Jobs") {
                    if store.supports("cron") {
                        Text("Scheduled jobs from your Hermes.")
                    } else {
                        Text("This Hermes does not advertise scheduled jobs.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Insights") {
                    if store.supports("insights") || store.supports("analytics") {
                        Text("Usage reported by your Hermes.")
                    } else {
                        Text("This Hermes does not expose analytics yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                    }
                } else {
                    ContentUnavailableView(
                        "Connect your Hermes",
                        systemImage: "link",
                        description: Text("Activity comes from your agent.")
                    )
                }
            }
            .navigationTitle("Activity")
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))

        }
    }
}
