import SwiftUI
import UIKit

/// The app's one vocabulary of touch. Each kind means the same thing wherever it is felt, so a
/// success never feels like a warning and a page opening never feels like a payment.
///
/// Discreet by design: actions and outcomes that matter, never while a reply is being written.
/// iOS already silences all of it when the system Haptics switch is off.
enum Haptic: CaseIterable, Sendable {
    /// Something was set off: sent, retried, jumped to the latest message, opened.
    case tap
    /// A page or the drawer moving in or out.
    case soft
    /// One option chosen among several.
    case selection
    /// It worked: copied, approved, saved, restored.
    case success
    /// It needs the person, or it cannot be undone.
    case warning
    /// It failed.
    case error
    /// A deliberate, weighty action: stop, refresh.
    case heavy

    /// What each kind is played with, for tests and for the declarative `.haptic` form.
    enum Kind: Equatable, Sendable {
        case impact(UIImpactFeedbackGenerator.FeedbackStyle)
        case notification(UINotificationFeedbackGenerator.FeedbackType)
        case selection
    }

    var kind: Kind {
        switch self {
        case .tap: .impact(.light)
        case .soft: .impact(.soft)
        case .selection: .selection
        case .success: .notification(.success)
        case .warning: .notification(.warning)
        case .error: .notification(.error)
        case .heavy: .impact(.medium)
        }
    }

    var sensory: SensoryFeedback {
        switch self {
        case .tap: .impact(weight: .light)
        case .soft: .impact(flexibility: .soft)
        case .selection: .selection
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .heavy: .impact(weight: .medium)
        }
    }

    @MainActor
    func play() {
        HapticEngine.shared.play(self)
    }
}

/// Generators made once and kept, so a touch lands on time instead of after a warm-up.
@MainActor
private final class HapticEngine {
    static let shared = HapticEngine()

    private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private lazy var notification = UINotificationFeedbackGenerator()
    private lazy var selection = UISelectionFeedbackGenerator()

    func play(_ haptic: Haptic) {
        switch haptic.kind {
        case let .impact(style):
            let generator = impacts[style] ?? UIImpactFeedbackGenerator(style: style)
            impacts[style] = generator
            generator.impactOccurred()
            generator.prepare()
        case let .notification(type):
            notification.notificationOccurred(type)
            notification.prepare()
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes.
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T) -> some View {
        sensoryFeedback(haptic.sensory, trigger: trigger)
    }

    /// Plays `haptic` when `trigger` changes and `condition` says this change deserves it.
    func haptic<T: Equatable>(
        _ haptic: Haptic, trigger: T, when condition: @escaping (_ old: T, _ new: T) -> Bool
    ) -> some View {
        sensoryFeedback(haptic.sensory, trigger: trigger, condition: condition)
    }
}
