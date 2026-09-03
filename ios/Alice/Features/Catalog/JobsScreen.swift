import SwiftUI
import UIKit

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
    @State private var reading: JobRow?

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
                        .foregroundStyle(.secondary)
                }

                // What came back can be a stack trace or a page of JSON. Set
                // in red at full length it took over the screen and told a
                // reader who is not a programmer nothing they could act on.
                // One line says it failed and why; the rest is a tap away for
                // whoever actually wants it.
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
        .sheet(item: $reading) { job in
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
    }

    /// The one line of a failure worth putting on a row.
    ///
    /// Tracebacks say what went wrong on their last line, not their first, so
    /// that is the one taken; anything else gives up its first real line. The
    /// language's own decoration — the `Error:` and `Exception:` a reader
    /// already knows from the colour — comes off.
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

    /// Paused, failing, or fine — the one thing worth seeing at a glance.
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
