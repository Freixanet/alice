import SwiftUI

/// The time zone Alice and every agent live in, as Hermes has it.
///
/// A profile without a zone of its own falls back to the Mac's clock. On a
/// Mac set to New York, thirteen agents believed it was six hours earlier
/// than it was for the person, and Alice asked the terminal what day it was
/// — twice — to answer "I have the hairdresser on Wednesday". One choice here
/// sets the same zone on Alice and on every agent.
struct HermesTimezones: Equatable, Sendable {
    struct Profile: Equatable, Sendable {
        let name: String
        let timezone: String
    }

    /// Alice's own (the main profile's).
    var timezone: String
    /// The Mac's, which any profile without one uses.
    var server: String
    var profiles: [Profile]

    static func parse(_ object: [String: Any]) -> HermesTimezones {
        HermesTimezones(
            timezone: object["timezone"] as? String ?? "",
            server: object["server"] as? String ?? "",
            profiles: (object["profiles"] as? [[String: Any]] ?? []).compactMap { row in
                guard let name = row["name"] as? String else { return nil }
                return Profile(name: name, timezone: row["timezone"] as? String ?? "")
            }
        )
    }

    /// Agents that do not share Alice's zone — on the Mac's clock, or another.
    var outOfStep: [Profile] {
        profiles.filter { ($0.timezone.isEmpty ? server : $0.timezone) != effective }
    }

    /// What Alice actually runs on.
    var effective: String { timezone.isEmpty ? server : timezone }
}

/// Settings › General › Time zone.
struct TimeZoneRow: View {
    @Environment(AppStore.self) private var store
    @State private var zones: HermesTimezones?

    var body: some View {
        NavigationLink {
            TimeZoneScreen(zones: $zones)
        } label: {
            HStack {
                Label("Time zone", systemImage: "clock")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(zones.map { TimeZoneScreen.label($0.effective) } ?? "…")
                        .foregroundStyle(.secondary)
                    if let zones, !zones.outOfStep.isEmpty {
                        Text("\(zones.outOfStep.count) agents on another clock")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .task { zones = try? await store.hermesTimezones() }
    }
}

struct TimeZoneScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var zones: HermesTimezones?
    @State private var query = ""
    @State private var saving = false
    @State private var failure: String?

    private var phone: String { TimeZone.current.identifier }

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.localizedCaseInsensitiveContains(needle)
                || Self.label($0).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        List {
            if let zones {
                Section {
                    LabeledContent("Alice and your agents", value: Self.label(zones.effective))
                    if !zones.outOfStep.isEmpty {
                        Text("\(zones.outOfStep.count) agents have no zone of their own and use this Mac’s clock (\(Self.label(zones.server))): \(zones.outOfStep.prefix(4).map(\.name).joined(separator: ", "))\(zones.outOfStep.count > 4 ? "…" : ""). Choosing a zone below sets it for all of them.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Routines run, and your agents tell the date, in this zone. Your agents’ chats follow at once; routines and messaging apps after Hermes next restarts.")
                }
            }

            if query.isEmpty {
                Section("This iPhone") {
                    zoneButton(phone)
                }
            }

            Section(query.isEmpty ? "All time zones" : "Matches") {
                ForEach(matches, id: \.self) { zoneButton($0) }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
        }
        .searchable(text: $query, prompt: "City or region")
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .overlay { if saving { ProgressView() } }
    }

    private func zoneButton(_ identifier: String) -> some View {
        Button {
            Task { await choose(identifier) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(identifier)).foregroundStyle(.primary)
                    Text(identifier).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if zones?.effective == identifier, zones?.outOfStep.isEmpty == true {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func choose(_ identifier: String) async {
        saving = true
        defer { saving = false }
        failure = nil
        do {
            zones = try await store.setHermesTimezone(identifier)
            dismiss()
        } catch {
            failure = PlainWords.describe(error, doing: "set the time zone")
        }
    }

    /// "Madrid (GMT+2)" rather than "Europe/Madrid".
    static func label(_ identifier: String) -> String {
        guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else { return identifier }
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? identifier
        let offset = zone.secondsFromGMT() / 3600
        let minutes = abs(zone.secondsFromGMT() % 3600) / 60
        let sign = offset >= 0 ? "+" : "−"
        let hours = minutes == 0 ? "\(abs(offset))" : "\(abs(offset)):\(String(format: "%02d", minutes))"
        return "\(city) (GMT\(sign)\(hours))"
    }
}
