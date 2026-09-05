import SwiftUI

/// Native iOS counterpart of Alice's Radar IA setup assistant.
///
/// This screen deliberately prepares a chat request instead of writing a cron
/// job itself. Hermes has to inspect the installed scheduler, effective time
/// zone and delivery path before it can truthfully say Radar IA is active.
struct RadarIASetupScreen: View {
    @Environment(\.colorScheme) private var scheme

    let onConfigure: (String) -> Void

    @State private var time = RadarIA.dateForDefaultTime()
    @State private var zone = RadarIA.defaultZone

    private var timeText: String { RadarIA.timeString(from: time) }
    private var valid: Bool { RadarIA.validSchedule(time: timeText, zone: zone) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                scheduleCard
                setupCard
                configureButton
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background(scheme))
        .navigationTitle("Radar IA")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                Text("Daily AI briefing")
                    .font(.headline)
            }
            Text(
                "A daily AI briefing in Spanish: important models, tools and advances, with verified sources and practical relevance."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule")
                .font(.subheadline.weight(.semibold))

            DatePicker(
                "Daily start time",
                selection: $time,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Time zone")
                    .font(.subheadline)
                TextField("Europe/Madrid", text: $zone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Time zone")

                Text(
                    "Europe/Madrid is Barcelona time, including daylight-saving changes. Use a named zone such as Europe/London or America/New_York."
                )
                .font(.caption)
                .foregroundStyle(valid || zone.isEmpty ? Color.secondary : Color.red)
            }
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border(scheme), lineWidth: 0.75)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What happens next", systemImage: "message")
                .font(.subheadline.weight(.semibold))
            Text(
                "Alice prepares a request in a new chat to create or update Radar IA. You can edit it before sending. Hermes then verifies the schedule, web access, persistence and delivery."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(
                "This screen does not activate or save a schedule. The selected time starts research; delivery follows when the report is finished."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.border(scheme), lineWidth: 0.75)
        }
    }

    private var configureButton: some View {
        Button {
            guard let prompt = RadarIA.setupPrompt(time: timeText, zone: zone) else { return }
            onConfigure(prompt)
        } label: {
            Label("Configure with Hermes", systemImage: "arrow.up.message")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!valid)
        .accessibilityHint("Opens an editable Radar IA setup request in a new chat")
    }
}
