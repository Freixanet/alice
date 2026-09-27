import SwiftUI
import UIKit

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

struct ExperimentalHomeMenu: View {
    private enum Section: String, CaseIterable {
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

    @State private var selected: Section = .chat
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        GeometryReader { geometry in
            NativeSegmentedPicker(selected: selected) { section in
                selected = section
                switch section {
                case .chat, .today: onOpenToday()
                case .goals: onOpenDestination(.goals)
                case .feed: onOpenDestination(.feed)
                case .library: onOpenDestination(.library)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .onAppear { selected = .chat }
    }

    /// The system control supplies the Liquid Glass thumb and its drag behavior.
    /// Per-segment actions also let Chat open Today when Chat is already selected.
    private struct NativeSegmentedPicker: UIViewRepresentable {
        let selected: Section
        let onSelect: (Section) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

        func makeUIView(context: Context) -> UISegmentedControl {
            let actions = Section.allCases.map { section in
                UIAction(title: section.title, image: UIImage(systemName: section.symbol)) {
                    [weak coordinator = context.coordinator] _ in
                    coordinator?.onSelect(section)
                }
            }
            let control = UISegmentedControl(frame: .zero, actions: actions)
            control.selectedSegmentIndex = 0
            control.accessibilityIdentifier = "home.experimentalMenu"
            return control
        }

        func updateUIView(_ control: UISegmentedControl, context: Context) {
            context.coordinator.onSelect = onSelect
            let index = Section.allCases.firstIndex(of: selected) ?? 0
            if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UISegmentedControl,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: width, height: proposal.height ?? 56)
        }

        final class Coordinator {
            var onSelect: (Section) -> Void

            init(onSelect: @escaping (Section) -> Void) {
                self.onSelect = onSelect
            }
        }
    }
}
