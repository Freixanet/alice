import Foundation

/// A pin on the empty home: a place, note, folder, agent, artifact, or chat
/// worth reaching without walking the drawer.
///
/// Kept on this phone, like bot channels. Hermes has no equivalent list.
struct HomeShortcut: Codable, Equatable, Identifiable, Sendable {
    /// Where the pin goes. Associated values are ids, never a second live object:
    /// a deleted note should still sit on the shelf until it is taken off, not
    /// vanish because the store no longer has it.
    enum Target: Codable, Equatable, Hashable, Sendable {
        case destination(String)
        case note(String)
        case noteFolder(String)
        case bot(String)
        case artifact(kind: String, value: String)
        case conversation(String)

        private enum CodingKeys: String, CodingKey {
            case kind, value, artifactKind
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try box.decodeIfPresent(String.self, forKey: .kind) ?? ""
            let value = try box.decodeIfPresent(String.self, forKey: .value) ?? ""
            switch kind {
            case "destination":
                self = .destination(value)
            case "note":
                self = .note(value)
            case "noteFolder":
                self = .noteFolder(value)
            case "bot":
                self = .bot(value)
            case "artifact":
                let artifactKind = try box.decodeIfPresent(String.self, forKey: .artifactKind) ?? "file"
                self = .artifact(kind: artifactKind, value: value)
            case "conversation":
                self = .conversation(value)
            default:
                self = .destination(value)
            }
        }

        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .destination(value):
                try box.encode("destination", forKey: .kind)
                try box.encode(value, forKey: .value)
            case let .note(value):
                try box.encode("note", forKey: .kind)
                try box.encode(value, forKey: .value)
            case let .noteFolder(value):
                try box.encode("noteFolder", forKey: .kind)
                try box.encode(value, forKey: .value)
            case let .bot(value):
                try box.encode("bot", forKey: .kind)
                try box.encode(value, forKey: .value)
            case let .artifact(kind, value):
                try box.encode("artifact", forKey: .kind)
                try box.encode(value, forKey: .value)
                try box.encode(kind, forKey: .artifactKind)
            case let .conversation(value):
                try box.encode("conversation", forKey: .kind)
                try box.encode(value, forKey: .value)
            }
        }

        static func place(_ target: AliceDestination.Target) -> Target {
            .destination(target.rawValue)
        }
    }

    let id: String
    var label: String
    var symbol: String
    var target: Target

    init(
        id: String = UUID().uuidString,
        label: String,
        symbol: String,
        target: Target
    ) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try box.decodeIfPresent(String.self, forKey: .label) ?? ""
        symbol = try box.decodeIfPresent(String.self, forKey: .symbol) ?? "square"
        target = try box.decodeIfPresent(Target.self, forKey: .target) ?? .destination("")
    }

    /// The name to show: the live title when that thing still exists, otherwise
    /// the words saved on the pin so a deleted note does not go blank.
    func displayedLabel(
        note: Note? = nil,
        folderName: String? = nil,
        botName: String? = nil,
        conversationTitle: String? = nil
    ) -> String {
        func kept(_ fallback: String) -> String {
            label.isEmpty ? fallback : label
        }
        switch target {
        case .note:
            let title = note.map(NotesFeed.title(of:)) ?? ""
            return title.isEmpty ? kept("Note") : title
        case .noteFolder:
            let name = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? kept("Folder") : name
        case .bot:
            let name = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? kept("Agent") : name
        case .conversation:
            let title = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? kept("Chat") : title
        case let .destination(raw):
            return AliceDestination.all.first { $0.target.rawValue == raw }?.title ?? kept(raw)
        case let .artifact(kind, value):
            if kind == LibraryTool.shortcutKind, let tool = LibraryTool(rawValue: value) {
                return kept(tool.title)
            }
            return kept("File")
        }
    }

    /// A pin for a named place in the app, labelled as Search would label it.
    static func place(_ target: AliceDestination.Target) -> HomeShortcut {
        let named = AliceDestination.all.first { $0.target == target }
        return HomeShortcut(
            label: named?.title ?? target.rawValue,
            symbol: named?.systemImage ?? "square",
            target: .place(target)
        )
    }
}
