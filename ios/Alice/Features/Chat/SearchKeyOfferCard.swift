import SwiftUI

/// An agent's offer to switch web search back on, in the chat where it failed.
///
/// Exa's keyless endpoint is rate-limited, so search needs the person's own
/// (free) Exa key. When a search fails for want of one, the plugin tells the
/// agent to end its reply with `[Conectar búsqueda](alice://connect/search)`,
/// and never to ask for the key in the chat. The link becomes this card: the
/// key goes into a secure field and straight to Hermes' `.env` through the
/// dashboard, so it is never part of a message, a transcript or a log.
struct SearchKeyOfferCard: View {
    static let keyName = "EXA_API_KEY"
    static let keysPage = URL(string: "https://dashboard.exa.ai/api-keys")!

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    var language: ChatLanguage = .english

    @State private var key = ""
    @State private var working = false
    @State private var saved = false
    @State private var problem: String?

    var body: some View {
        if saved || !superseded {
            offer
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.pick("Turn web search back on", "Vuelve a activar la búsqueda web"))
                        .font(.headline)
                    Text(language.pick("Your agents search with Exa. Its free key is enough: create one and paste it here.", "Tus agentes buscan con Exa. Basta con su clave gratuita: créala y pégala aquí."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if saved {
                Label(language.pick("Search is on", "Búsqueda activada"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.success(scheme))
            } else {
                Link(destination: Self.keysPage) {
                    Label(language.pick("Get a free key", "Conseguir una clave gratis"), systemImage: "arrow.up.right")
                        .font(.subheadline)
                }
                .tint(Palette.link(scheme))

                SecureField(language.pick("Paste your Exa key", "Pega tu clave de Exa"), text: $key)
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
            // The main profile's .env: the web provider reads it for every agent.
            try await store.saveProviderCredential(profile: "default", key: Self.keyName, value: value)
            key = ""
            saved = true
            // The agent carries on with what it was asked; the key is not in this message.
            store.sendQuickReply(language.pick("Done, search is on. Try again.", "Listo, ya está la búsqueda. Vuelve a intentarlo."))
        } catch {
            problem = diagnosticMessage(error)
        }
    }
}
