import SwiftUI

/// What the agent is scheduled to do without being asked.
///
/// Read-only for now: Hermes serves the list from the gateway, but creating
/// and editing jobs lives on the dashboard, which a gateway-only install does
/// not run. A screen that offered an edit it cannot deliver would be worse
/// than one that is honest about being a window.
struct JobsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var jobs: [JobRow] = []
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        Group {
            if loading && jobs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    "Jobs unavailable",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text(failure)
                )
            } else if jobs.isEmpty {
                ContentUnavailableView(
                    "No scheduled jobs",
                    systemImage: "clock",
                    description: Text("Nothing is set to run on its own.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        List(jobs) { job in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(colour(for: job))
                        .frame(width: 7, height: 7)
                    Text(job.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !job.schedule.isEmpty {
                        Text(job.schedule)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if !job.prompt.isEmpty {
                    Text(job.prompt)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let line = status(of: job) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(job.lastStatus == "error" ? .red : .secondary)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Palette.card(scheme))
        }
    }

    /// Paused, failing, or fine — the one thing worth seeing at a glance.
    private func colour(for job: JobRow) -> Color {
        if !job.enabled { return .secondary.opacity(0.5) }
        if job.lastStatus == "error" { return .red }
        return .green
    }

    private func status(of job: JobRow) -> String? {
        var parts: [String] = []
        if !job.enabled { parts.append("Paused") }
        if let error = job.lastError {
            parts.append("Last run failed — \(error)")
        } else if let last = job.lastRun {
            parts.append("Last ran \(last.formatted(.relative(presentation: .named)))")
        }
        if job.enabled, let next = job.nextRun {
            parts.append("next \(next.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            jobs = try await store.jobs()
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Hermes did not answer."
        }
    }
}
