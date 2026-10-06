import SwiftUI
import UIKit

/// One native segmented control size throughout Alice, including forms and sheets.
struct AppSegmentedPicker<Value: Hashable>: UIViewRepresentable {
    struct Option {
        var value: Value
        var title: String
        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = String(localized: String.LocalizationValue(title))
        }
    }
    let label: String
    @Binding var selection: Value
    var options: [Option]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44

    init(_ label: String, selection: Binding<Value>, options: [Option]) {
        self.label = label
        self._selection = selection
        self.options = options
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if control.numberOfSegments != titles.count
            || titles.enumerated().contains(where: { control.titleForSegment(at: $0.offset) != $0.element }) {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() { control.insertSegment(withTitle: title, at: index, animated: false) }
        }
        control.selectedSegmentIndex = options.firstIndex { $0.value == selection } ?? UISegmentedControl.noSegment
        control.accessibilityLabel = String(localized: String.LocalizationValue(label))
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        control.setTitleTextAttributes([.font: font], for: .normal)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(44, height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: AppSegmentedPicker
        init(_ parent: AppSegmentedPicker) { self.parent = parent }
        @objc func changed(_ control: UISegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = parent.options[control.selectedSegmentIndex].value
        }
    }
}

enum PageLayout {
    /// Matches the breathing room below the back button in Settings.
    static let navigationGap: CGFloat = 20
}

extension View {
    func pageNavigationSpacing() -> some View {
        contentMargins(.top, PageLayout.navigationGap, for: .scrollContent)
    }
}
