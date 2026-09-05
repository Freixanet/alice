import SwiftUI
import UIKit

/// What the agent is scheduled to do without being asked.
///
/// Existing jobs stay read-only here. Radar IA is an assisted setup entry: it
/// prepares a request for Hermes rather than pretending this gateway-only view
/// can safely create a scheduler job by itself.
struct JobsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var jobs: [JobRow] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var reading: JobRow?

    var body: some View {
        list
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $reading) { job in
                errorSheet(for: job)
            }
    }

    private var list: some View {
        List {
            Section {
                NavigationLink {
                    RadarIASetupScreen(onConfigure: prepareRadar)
                } label: {
                    radarRow
                }
                .listRowBackground(Palette.card(scheme))
            }

            Section("Scheduled") {
                if loading && jobs.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading jobs…")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                } else if let failure {
                    stateRow(
                        title: "Jobs unavailable",
                        detail: failure,
                        systemImage: "clock.badge.exclamationmark"
                    )
                } else if jobs.isEmpty {
                    stateRow(
                        title: "No scheduled jobs",
                        detail: "Nothing is set to run on its own yet.",
                        systemImage: "clock"
                    )
                } else {
                    ForEach(jobs) { job in
                        jobRow(job)
                    }
                }
            }
        }
    }

    private var radarRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                Text("Radar IA")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("10:00 · Europe/Madrid")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(
                "Daily AI news in Spanish, researched from current sources and prepared around what matters to you."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Set up or update with Hermes")
                .font(.caption.weight(.medium))
                .foregroundStyle(store.accent.primary(scheme))
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Radar IA setup")
    }

    @ViewBuilder
    private func jobRow(_ job: JobRow) -> some View {
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
                    .foregroundStyle(.secondary)
            }

            if let error = job.lastError, !error.isEmpty {
                Button {
                    reading = job
                } label: {
                    HStack(spacing: 4) {
                        Text("Failed — \(Self.reason(from: error))")
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.red)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the full error")
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.card(scheme))
    }

    private func stateRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }

    private func errorSheet(for job: JobRow) -> some View {
        NavigationStack {
            ScrollView {
                Text(job.lastError ?? "")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(job.name)
            .navigationBarTitleDisplayMode(.inline)
            .background(Palette.background(scheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { reading = nil }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = job.lastError
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Opens an editable setup request in Alice instead of claiming this view
    /// configured the scheduler itself. Dismissing Jobs reveals the new chat;
    /// the drawer remains available exactly as it was before opening Jobs.
    private func prepareRadar(_ prompt: String) {
        store.newChat()
        store.draft = prompt
        dismiss()
    }

    /// The one line of a failure worth putting on a row.
    static func reason(from error: String) -> String {
        let lines = error
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first else { return "no reason given" }
        if let last = lines.last, lines.count > 1,
           line.hasPrefix("Traceback") || line.hasPrefix("  File ") {
            line = last
        }
        for prefix in ["Error:", "Exception:", "error:", "ERROR:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }

    private func colour(for job: JobRow) -> Color {
        if !job.enabled { return .secondary.opacity(0.5) }
        if job.lastStatus == "error" { return .red }
        return .green
    }

    private func status(of job: JobRow) -> String? {
        var parts: [String] = []
        if !job.enabled { parts.append("Paused") }
        if let last = job.lastRun {
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
