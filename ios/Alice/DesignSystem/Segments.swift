import SwiftUI

extension View {
    /// Every segmented control in Alice at one height: the large one, easier to hit and read than
    /// the compact default. Used wherever `.segments()` would be.
    func segments() -> some View {
        pickerStyle(.segmented).controlSize(.large)
    }
}
