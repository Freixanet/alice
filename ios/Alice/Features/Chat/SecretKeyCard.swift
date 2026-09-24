import SwiftUI

/// A key an agent needs — an API key, a token — given in a secure field, never
/// in the chat. The agent ends its reply with `[Dar clave](alice://connect/secret/NAME)`
/// (or `alice://connect/search` for search's own key); this card takes the value
/// and the Alice plugin writes `NAME=…` to Hermes' `.env` on the Mac. The value
/// is never shown again, logged or kept on the phone.
struct SecretKeyCard: View {
    let name: String
    var language: ChatLanguage = .english

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    @State private var value = ""
    @State private var working = false
    @State private var saved = false
    @State private var alreadySet = false
    @State private var problem: String?

    /// `search` is search's own key (Exa's free tier); `secret/NAME` names it.
    nonisolated static func keyName(for service: String) -> String? {
        if service == "search" { return "EXA_API_KEY" }
        guard service.hasPrefix("secret/") else { return nil }
        let name = String(service.dropFirst("secret/".count))
        guard name.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil,
              !name.hasPrefix("HERMES_"), !name.hasPrefix("API_SERVER_") else { return nil }
        return name
    }

    private var isSearch: Bool { name == "EXA_API_KEY" }

    var body: some View {
        if saved || alreadySet {
            Label(language.pick("\(name) saved on your Mac", "\(name) guardada en tu Mac"),
                  systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.success(scheme))
        } else if !superseded {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isSearch ? "magnifyingglass" : "key.fill")
                    .foregroundStyle(store.accent.primary(scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSearch ? language.pick("Turn on search", "Activar la búsqueda")
                                  : language.pick("Give a key", "Dar una clave"))
                        .font(.headline)
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if isSearch {
                Link(language.pick("Get a free key at exa.ai", "Consigue una clave gratis en exa.ai"),
                     destination: URL(string: "https://dashboard.exa.ai/api-keys")!)
                    .font(.subheadline)
            }
            HStack(spacing: 8) {
                SecureField(language.pick("Paste the key", "Pega la clave"), text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Palette.muted(scheme), in: .rect(cornerRadius: 10))
                Button {
                    Task { await save() }
                } label: {
                    if working { ProgressView() } else { Text(language.pick("Save", "Guardar")) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            Text(language.pick("Saved in Hermes on your Mac. It never goes through the chat.",
                               "Se guarda en Hermes, en tu Mac. Nunca pasa por el chat."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
        }
        .padding(14)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border(scheme).opacity(0.5), lineWidth: 0.5) }
        .task { alreadySet = (try? await store.secretIsSet(name)) == true }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await store.saveSecret(name, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
            value = ""
            withAnimation(.snappy) { saved = true }
            store.sendAppNote("The person saved \(name). Carry on with the task.")
        } catch {
            problem = PlainWords.describe(error, doing: "save the key")
        }
    }
}
