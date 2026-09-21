import Foundation

/// A living tool in Library, as opposed to a file an agent handed over.
enum LibraryTool: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mac

    /// The home-pin kind. Distinct from a file, an image, or a link.
    static let shortcutKind = "tool"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mac: "Mac"
        }
    }

    var symbol: String {
        switch self {
        case .mac: "gauge.with.dots.needle.67percent"
        }
    }

    var summary: String {
        switch self {
        case .mac: "Live CPU and memory on this Mac."
        }
    }
}
