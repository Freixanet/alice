import SwiftUI

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

/// A round Liquid Glass button, the same 44pt disc the header's own controls
/// use, that opens the section list in a menu instead of spelling all five
/// out in a bar. It sits to the composer's left in the same row, so the two
/// read as one control rather than a bar stacked over another.
struct ExperimentalHomeMenu: View {
    enum Section: String, CaseIterable {
        case chat, today, goals, feed, library

        var symbol: String {
            switch self {
            case .chat: "bubble.left"
            case .today: "sun.max"
            case .goals: "scope"
            case .feed: "rectangle.stack"
            case .library: "photo.on.rectangle"
            }
        }

        var title: String {
            switch self {
            case .chat: String(localized: "Chat")
            case .today: String(localized: "Today")
            case .goals: String(localized: "Goals")
            case .feed: String(localized: "Feed")
            case .library: String(localized: "Library")
            }
        }
    }

    @Binding var selected: Section
    let onSelect: (Section) -> Void

    var body: some View {
        Menu {
            ForEach(Section.allCases, id: \.self) { section in
                Button {
                    onSelect(section)
                } label: {
                    if section == selected {
                        Label(section.title, systemImage: "checkmark")
                    } else {
                        Text(section.title)
                    }
                }
            }
        } label: {
            // The current section's own glyph, not a generic menu mark: the
            // button says where you are, the way the bar's segments used to.
            Image(systemName: selected.symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .menuOrder(.fixed)
        .accessibilityIdentifier("home.experimentalMenu")
        .accessibilityLabel(String(localized: "Sections"))
        .accessibilityValue(selected.title)
    }
}
