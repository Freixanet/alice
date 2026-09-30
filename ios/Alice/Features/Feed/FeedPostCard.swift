import SwiftUI

/// One post: kicker, headline, the body with its citations, and what can be done with it.
struct FeedPostCard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let post: FeedPost
    let onLove: () -> Void
    let onDiscuss: () -> Void
    let onWhy: () -> Void
    let onDelete: () -> Void
    let onExpand: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kicker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Spacer(minLength: 0)
                Text(post.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(post.headline)
                .font(.aliceTitle(.title2))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            FeedBodyText(post: post, collapsed: !expanded)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded.toggle() }
                if expanded { onExpand() }
            } label: {
                Text(expanded ? String(localized: "Less") : String(localized: "More"))
                    .frame(minHeight: 44)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityLabel(expanded ? "Show less" : "Show the whole post")

            if !post.sourceLinks.isEmpty {
                sources
            }
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
    }

    private var kicker: String {
        [post.kicker, post.category].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The sources in citation order, each a chip that opens it.
    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(post.sourceLinks.enumerated()), id: \.offset) { index, source in
                    Link(destination: source.url) {
                        Text("\(index + 1) \(source.host)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Palette.muted(scheme), in: .capsule)
                    }
                    .accessibilityLabel("Source \(index + 1): \(source.title.isEmpty ? source.host : source.title)")
                    .accessibilityHint("Opens it in the browser")
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: onLove) {
                Image(systemName: post.loved ? "heart.fill" : "heart")
                    .foregroundStyle(post.loved ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(post.loved ? "Unlove" : "Love")
            .haptic(.selection, trigger: post.loved)

            Button {
                Haptic.tap.play()
                onDiscuss()
            } label: {
                Label("Discuss", systemImage: "bubble.left.and.text.bubble.right")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Discuss with Alice")

            if post.whyThis != nil {
                Button(action: onWhy) {
                    Label("Why this", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Why this post")
            }

            Spacer(minLength: 0)

            Menu {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("More options")
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
        .font(.system(size: 17, weight: .medium))
    }
}

/// A post's body with each `[n]` as a tappable link to its source. Plain inline markdown in a
/// `Text`, so it folds to a few lines; blocks (lists, headings) are not used in posts.
struct FeedBodyText: View {
    @Environment(\.colorScheme) private var scheme
    let post: FeedPost
    var collapsed: Bool

    var body: some View {
        Text(Self.attributed(post))
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(collapsed ? 4 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Palette.link(scheme))
    }

    nonisolated static func attributed(_ post: FeedPost) -> AttributedString {
        let linked = citationLinks(post.body, sources: post.sourceLinks)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(post.body)
    }

    /// `[2]` → a markdown link to the second source, drawn as a small superscript-like marker.
    /// A marker with no source stays as written.
    nonisolated static func citationLinks(_ body: String, sources: [FeedSource]) -> String {
        guard !sources.isEmpty else { return body }
        var result = ""
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "]"),
               let number = Int(after[..<close]), (1...sources.count).contains(number),
               // Not already a markdown link text: "[1](…)".
               after[after.index(after: close)...].first != "(" {
                result += "[\u{2009}\(number)\u{2009}](\(sources[number - 1].url.absoluteString))"
                rest = after[after.index(after: close)...]
            } else {
                result += "["
                rest = after
            }
        }
        return result + rest
    }
}
