import SwiftUI
import UIKit

/// Products side by side: the photo on white, the brand, the name and the
/// price as the agent found them. A tap opens the shop; Alice never pays.
struct ProductsCarousel: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    let products: [UIComponent.Product]
    var language: ChatLanguage = .english

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(products) { product in
                    Button {
                        if let url = product.url { openURL(url) }
                    } label: {
                        card(product)
                    }
                    .buttonStyle(PressableCardStyle())
                    .disabled(product.url == nil)
                    .accessibilityHint(product.url == nil ? "" : language.pick("Opens the shop", "Abre la tienda"))
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }

    private func card(_ product: UIComponent.Product) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.white
                if product.image == nil, product.url != nil {
                    CardImage(image: nil, page: product.url, symbol: "bag")
                        .padding(14)
                } else if let image = product.image {
                    AsyncImage(url: image, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                        if case let .success(picture) = phase {
                            picture.resizable().scaledToFit().padding(14).transition(.opacity)
                        } else if case .failure = phase {
                            Image(systemName: "bag").font(.title2).foregroundStyle(.gray.opacity(0.5))
                        }
                    }
                } else {
                    Image(systemName: "bag").font(.title2).foregroundStyle(.gray.opacity(0.5))
                }
            }
            .frame(width: 176, height: 176)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                if let brand = product.brand {
                    Text(brand.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(product.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                if let price = product.price {
                    Text(price)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(width: 176, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .background(Palette.card(scheme))
        .clipShape(.rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5) }
    }
}

/// Phrases in another language, each with its translation, a note on when
/// to use it, and a button to hear it said by a native voice.
struct PhrasesCard: View {
    @Environment(ReadAloud.self) private var speech
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let languageCode: String?
    let phrases: [UIComponent.Phrase]
    var language: ChatLanguage = .english

    var body: some View {
        VStack(spacing: 10) {
            ForEach(phrases) { phrase in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phrase.text)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        if let translation = phrase.translation {
                            Text(translation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let note = phrase.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 8)
                    let id = "phrase:" + phrase.text
                    Button {
                        speech.toggle(phrase.text, id: id, language: languageCode)
                    } label: {
                        Image(systemName: speech.isSpeaking(id) ? "stop.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(accent)
                            .frame(width: 40, height: 40)
                            .background(accent.opacity(0.13), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.pick("Listen", "Escuchar"))
                }
                .componentCard(scheme, padding: 14, radius: 18)
            }
        }
    }

    private var accent: Color { store.accent.primary(scheme) }
}

/// An email the agent drafted, to read, touch up and send from Mail. Alice
/// does not send it herself: the person does, with one tap in Mail.
struct EmailDraftCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let draft: UIComponent.Email
    var language: ChatLanguage = .english

    @State private var to = ""
    @State private var subject = ""
    @State private var text = ""
    @State private var copied = false
    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field(language.pick("To", "Para"), text: $to, keyboard: .emailAddress)
            Divider()
            field(language.pick("Subject", "Asunto"), text: $subject, keyboard: .default)
            Divider()
            TextField("", text: $text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(4...14)
                .padding(.vertical, 12)

            HStack(spacing: 10) {
                Button {
                    if let url = mailURL { openURL(url) }
                } label: {
                    Label(language.pick("Open in Mail", "Abrir en Mail"), systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(store.accent.primary(scheme))

                Button {
                    UIPasteboard.general.string = subject.isEmpty ? text : "\(subject)\n\n\(text)"
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? language.pick("Copied", "Copiado") : language.pick("Copy", "Copiar"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
            }
            .padding(.top, 4)
        }
        .componentCard(scheme)
        .onAppear {
            guard !filled else { return }
            filled = true
            to = draft.to ?? ""
            subject = draft.subject ?? ""
            text = draft.body
        }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            TextField("", text: text)
                .font(.subheadline.weight(label == language.pick("Subject", "Asunto") ? .semibold : .regular))
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .emailAddress)
        }
        .padding(.vertical, 11)
    }

    /// `mailto:` with every part escaped strictly, so an ampersand or a plus
    /// in the text arrives as written.
    private var mailURL: URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let recipient = to.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return URL(string: "mailto:\(recipient)?subject=\(escape(subject))&body=\(escape(text))")
    }
}

/// A short read: a hero image, a title, and sections — the first two shown,
/// the rest a tap away.
struct ArticleCard: View {
    @Environment(\.colorScheme) private var scheme
    let article: UIComponent.Article
    var language: ChatLanguage = .english

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if article.image != nil {
                RemoteImage(url: article.image)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(article.title)
                    .font(.aliceTitle(.title))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(shownSections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        if let heading = section.heading {
                            Text(heading).font(.headline)
                        }
                        Text(Self.inline(section.text))
                            .font(.subheadline)
                            .foregroundStyle(.primary.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if article.sections.count > 2 {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? language.pick("Show less", "Ver menos") : language.pick("Keep reading", "Seguir leyendo"),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Palette.card(scheme))
        .clipShape(.rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(Palette.border(scheme), lineWidth: 0.5) }
    }

    private var shownSections: [UIComponent.Article.Section] {
        expanded ? article.sections : Array(article.sections.prefix(2))
    }

    /// Bold, italics and links inside a section; anything else as written.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
