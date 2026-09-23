import SwiftUI

/// An agent asking for a key it needs, in the chat, without the key ever
/// being part of the chat.
///
/// An agent that needs a key for a command ends its reply with
/// `[Dar clave](alice://connect/secret/EXA_API_KEY)` (the plugin's
/// `alice.claves` instructions; failed web search offers
/// `alice://connect/search`, the same card for Exa). The key goes into a
/// secure field and straight to the Alice plugin, which writes it to Hermes'
/// `.env` files as the terminal would have. It is never a message, a
/// transcript line or a log entry; the agent is only told that it is there.
struct SecretRequestCard: View {
    /// What the person is asked for: the variable, and how to say it.
    struct Request: Equatable {
        let name: String
        let title: (english: String, spanish: String)
        let detail: (english: String, spanish: String)
        let keysPage: URL?

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.name == rhs.name }

        static let search = Request(
            name: "EXA_API_KEY",
            title: ("Turn web search back on", "Vuelve a activar la búsqueda web"),
            detail: ("Your agents search with Exa. Its free key is enough: create one and paste it here.",
                     "Tus agentes buscan con Exa. Basta con su clave gratuita: créala y pégala aquí."),
            keysPage: URL(string: "https://dashboard.exa.ai/api-keys")
        )

        static func named(_ name: String) -> Request {
            if name == search.name { return search }
            return Request(
                name: name,
                title: ("Your agent needs a key", "Tu agente necesita una clave"),
                detail: ("It will be saved to your Hermes as \(name), for your agents' commands.",
                         "Se guardará en tu Hermes como \(name), para los comandos de tus agentes."),
                keysPage: nil
            )
        }
    }

    /// `secret/NAME` as the link carries it: capitals, digits, underscores.
    nonisolated static func name(fromService service: String) -> String? {
        guard service.hasPrefix("secret/") else { return nil }
        let name = String(service.dropFirst("secret/".count))
        guard name.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    let request: Request
    var language: ChatLanguage = .english

    @State private var key = ""
    @State private var working = false
    @State private var problem: String?
    /// Hermes has not answered yet whether the key is there: nothing is
    /// shown rather than a field that may be about to close.
    @State private var checked = false
    /// A saved key the person wants to change (a wrong one, say).
    @State private var replacing = false

    /// From the store, not the card: the row is rebuilt while the agent
    /// answers, and a card's own flag would forget and ask again.
    private var saved: Bool { store.savedSecrets.contains(request.name) }

    var body: some View {
        // Once answered (the person wrote after it) the card closes, saved
        // or not; before that, a saved key shows as done, never as a field.
        if !superseded, checked || saved {
            offer
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else if !superseded {
            Color.clear.frame(height: 0)
                .task { await check() }
        }
    }

    private func check() async {
        _ = try? await store.aliceSecretIsSet(name: request.name)
        checked = true
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request == .search ? "magnifyingglass" : "key")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.pick(request.title.english, request.title.spanish))
                        .font(.headline)
                    Text(language.pick(request.detail.english, request.detail.spanish))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if saved && !replacing {
                HStack {
                    Label(language.pick("Saved", "Guardada"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.success(scheme))
                    Spacer(minLength: 8)
                    Button(language.pick("Change", "Cambiar")) { replacing = true }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
            } else {
                if let page = request.keysPage {
                    Link(destination: page) {
                        Label(language.pick("Get a free key", "Conseguir una clave gratis"), systemImage: "arrow.up.right")
                            .font(.subheadline)
                    }
                    .tint(Palette.link(scheme))
                }

                SecureField(request.name, text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.muted(scheme), in: .rect(cornerRadius: 12))
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if working {
                            ProgressView()
                        } else {
                            Label(language.pick("Save", "Guardar"), systemImage: "lock")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .disabled(working || trimmed.isEmpty || store.isSending)

                Label(language.pick("The key goes only to your own Hermes, never into the chat.", "La clave va solo a tu propio Hermes, nunca al chat."), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .animation(.snappy(duration: 0.25), value: saved)
        .accessibilityElement(children: .contain)
    }

    private var accent: Color { store.accent.primary(scheme) }
    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() async {
        let value = trimmed
        guard !value.isEmpty, !working else { return }
        working = true
        defer { working = false }
        problem = nil
        do {
            try await store.saveAliceSecret(name: request.name, value: value)
            key = ""
            replacing = false
            // The agent carries on; this message names the key, never its value.
            store.sendQuickReply(language.pick(
                "Done, \(request.name) is saved. Carry on.",
                "Listo, ya he guardado \(request.name). Sigue."
            ))
        } catch {
            problem = diagnosticMessage(error)
        }
    }
}
