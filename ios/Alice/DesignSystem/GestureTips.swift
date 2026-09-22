import SwiftUI
import TipKit

/// Hints for gestures that nothing on screen gives away. Each shows once, and
/// goes for good the first time the gesture is used — whether or not the hint
/// was ever seen.

struct SwipeNavigationTip: Tip {
    var title: Text { Text("Swipe to move around") }
    var message: Text? { Text("Swipe right for your chats, left for your agents.") }
    var image: Image? { Image(systemName: "hand.draw") }
}

struct MessageActionsTip: Tip {
    var title: Text { Text("Tap or hold your message") }
    var message: Text? { Text("Copy it, edit it, select part of it or share it.") }
    var image: Image? { Image(systemName: "hand.tap") }
}

struct ReactionTip: Tip {
    var title: Text { Text("Answer with a thumb") }
    var message: Text? { Text("Tap a reply, then 👍 for yes or 👎 for no. A 👍 to a calendar card also adds or moves the event.") }
    var image: Image? { Image(systemName: "hand.thumbsup") }
}

struct NoteActionsTip: Tip {
    var title: Text { Text("Hold or swipe a note") }
    var message: Text? { Text("Hold for more options, or swipe left to delete it.") }
    var image: Image? { Image(systemName: "hand.point.up.left") }
}

enum GestureTips {
    private static let resetKey = "alice.tips.resetOnLaunch"

    static func configure() {
        // TipKit only forgets what has been shown before it is configured.
        if UserDefaults.standard.bool(forKey: resetKey) {
            try? Tips.resetDatastore()
            UserDefaults.standard.removeObject(forKey: resetKey)
        }
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    /// Shows every hint again, from the next launch.
    static func showAgainNextLaunch() {
        UserDefaults.standard.set(true, forKey: resetKey)
    }
}
