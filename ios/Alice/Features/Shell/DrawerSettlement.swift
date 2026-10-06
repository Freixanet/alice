import Foundation

/// Keeps the existing distance/flick thresholds while honoring a return toward origin.
enum DrawerSettlement {
    static func isOpen(
        wasOpen: Bool, translation: CGFloat, predicted: CGFloat, width: CGFloat
    ) -> Bool {
        let direction: CGFloat = wasOpen ? -1 : 1
        let travelled = translation * direction
        let projected = predicted * direction
        // A reversed flick must not commit because its magnitude is large.
        let commits = projected > 0 && (travelled > width * 0.3 || projected > 120)
        return commits ? !wasOpen : wasOpen
    }
}
