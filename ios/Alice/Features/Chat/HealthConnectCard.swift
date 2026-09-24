import SwiftUI

/// `[Conectar Salud](alice://connect/health)`: an agent that needs the
/// person's sleep, activity or recovery offers the Health app here. One tap
/// shows iOS's own permission sheet; after it, the last 60 days go to the
/// person's own Hermes as one summary per day.
struct HealthConnectCard: View {
    var language: ChatLanguage = .english

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    @State private var connected = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if connected {
            Label(language.pick("Health connected", "Salud conectada"), systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.success(scheme))
        } else if !superseded {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 42, height: 42)
                    .background(Color.pink.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.pick("Connect Health", "Conecta Salud")).font(.headline)
                    Text(language.pick("Sleep, activity, resting heart rate and HRV — also from your WHOOP or Apple Watch — so Alice tells you what stands out.",
                                       "Sueño, actividad, pulso en reposo y HRV —también de tu WHOOP o Apple Watch— para que Alice te diga lo que destaca."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Task { await connect() }
            } label: {
                Group {
                    if working { ProgressView() } else { Label(language.pick("Connect", "Conectar"), systemImage: "heart.text.square") }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.pink)
            .disabled(working)
            Label(language.pick("One summary per day goes only to your own Hermes. Alice never writes to Health.",
                                "Solo va un resumen por día a tu propio Hermes. Alice nunca escribe en Salud."), systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .task { connected = store.healthConnected }
    }

    private func connect() async {
        working = true
        defer { working = false }
        problem = await store.connectHealth()
        if problem == nil {
            withAnimation(.snappy) { connected = true }
            store.sendAppNote("The person connected Health. Carry on with the task.")
        }
    }
}

/// Settings › Connections › Health.
struct HealthConnectionRow: View {
    @Environment(AppStore.self) private var store
    @State private var connected = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Health", systemImage: "heart.fill")
                Spacer()
                if working {
                    ProgressView()
                } else if connected {
                    Button("Disconnect", role: .destructive) {
                        Task {
                            await store.disconnectHealth()
                            connected = false
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Connect") {
                        Task {
                            working = true
                            problem = await store.connectHealth()
                            connected = problem == nil
                            working = false
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        }
        .task { connected = store.healthConnected }
    }
}
