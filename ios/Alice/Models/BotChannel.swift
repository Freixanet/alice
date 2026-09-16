import Foundation

/// A channel on the Bots page: a folder of bots and teams, kept on this phone.
///
/// Not a conversation. It holds bots — loose, or grouped into the channel's
/// own sections — and teams, the shared chats with several of its bots. A bot
/// put into a channel leaves the page's general list and shows only in the
/// channels it is in; the same bot can be in several. An empty channel is
/// simply empty: there is nobody in it to talk to.
struct BotChannel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    /// Profile names, in the order they were added.
    var bots: [String] = []
    /// This channel's sections, in order.
    var sections: [String] = []
    /// The section a bot is in inside this channel. Absent means loose.
    var botSections: [String: String] = [:]
    /// Folded shut on the Bots page, until the person opens it again.
    var collapsed = false
    /// This channel's sections that are folded shut.
    var collapsedSections: [String] = []

    init(id: String = UUID().uuidString, name: String, bots: [String] = []) {
        self.id = id
        self.name = name
        self.bots = []
        for bot in bots { add(bot) }
    }

    /// Every key a later build adds is optional here, so a new field never
    /// turns the saved channels into a decode failure.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? "Channel"
        bots = try box.decodeIfPresent([String].self, forKey: .bots) ?? []
        sections = try box.decodeIfPresent([String].self, forKey: .sections) ?? []
        botSections = try box.decodeIfPresent([String: String].self, forKey: .botSections) ?? [:]
        collapsed = try box.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        collapsedSections = try box.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
    }
}

extension BotChannel {
    /// Bots that live in a channel, and so not in the general list.
    static func members(of channels: [BotChannel]) -> Set<String> {
        Set(channels.flatMap(\.bots))
    }

    func section(for bot: String) -> String? {
        guard let section = botSections[bot], sections.contains(section) else { return nil }
        return section
    }

    mutating func add(_ bot: String) {
        guard !bot.isEmpty, !bots.contains(bot) else { return }
        bots.append(bot)
    }

    mutating func remove(_ bot: String) {
        bots.removeAll { $0 == bot }
        botSections.removeValue(forKey: bot)
    }

    /// Sets exactly which bots are in the channel. Bots that stay keep their
    /// section; bots that leave take nothing of theirs with them.
    mutating func setBots(_ names: [String]) {
        let kept = Set(names)
        bots = []
        for name in names { add(name) }
        botSections = botSections.filter { kept.contains($0.key) }
    }

    mutating func rename(bot old: String, to new: String) {
        guard old != new, let index = bots.firstIndex(of: old) else { return }
        if bots.contains(new) {
            bots.remove(at: index)
        } else {
            bots[index] = new
        }
        if let section = botSections.removeValue(forKey: old) { botSections[new] = section }
    }

    /// False when the name is empty or already a section here.
    @discardableResult
    mutating func addSection(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sections.contains(trimmed) else { return false }
        sections.append(trimmed)
        return true
    }

    /// False when the name is empty, already a section here, or not found.
    @discardableResult
    mutating func renameSection(from old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old,
              let index = sections.firstIndex(of: old),
              !sections.contains(trimmed)
        else { return false }
        sections[index] = trimmed
        for (bot, section) in botSections where section == old {
            botSections[bot] = trimmed
        }
        if let folded = collapsedSections.firstIndex(of: old) {
            collapsedSections[folded] = trimmed
        }
        return true
    }

    /// The section goes; its bots stay in the channel, loose.
    mutating func deleteSection(_ name: String) {
        sections.removeAll { $0 == name }
        botSections = botSections.filter { $0.value != name }
        collapsedSections.removeAll { $0 == name }
    }

    mutating func setSection(_ section: String?, for bot: String) {
        guard bots.contains(bot) else { return }
        if let section, sections.contains(section) {
            botSections[bot] = section
        } else {
            botSections.removeValue(forKey: bot)
        }
    }

    /// Moves a section to where `target` is, the way a drag lands: before it
    /// when moving up, after it when moving down.
    mutating func moveSection(_ source: String, to target: String) {
        guard source != target,
              let from = sections.firstIndex(of: source),
              let to = sections.firstIndex(of: target)
        else { return }
        let item = sections.remove(at: from)
        sections.insert(item, at: to)
    }

    mutating func toggleSection(_ name: String) {
        if collapsedSections.contains(name) {
            collapsedSections.removeAll { $0 == name }
        } else if sections.contains(name) {
            collapsedSections.append(name)
        }
    }

    /// Channels in a new order, the way a drag lands: the dragged one takes the
    /// target's place, before it when moving up and after it when moving down.
    static func moving(_ channels: [BotChannel], _ source: String, to target: String) -> [BotChannel] {
        guard source != target,
              let from = channels.firstIndex(where: { $0.id == source }),
              let to = channels.firstIndex(where: { $0.id == target })
        else { return channels }
        var result = channels
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// Channels with each agent put where Hermes says it belongs
    /// (`AlicePlacement`): in the channel of that name, whatever its case,
    /// made if there is none, and in its section, made if missing. Agents
    /// arrive in their placement order.
    ///
    /// A placement that carries the channel's section layout applies it once
    /// every agent is in place (`applyLayout`).
    ///
    /// Each placement revision is applied once and remembered in `applied`, by
    /// profile. After that the person owns the agent's place: moving it out or
    /// deleting the channel is not undone the next time the roster loads.
    static func applyingPlacements(
        _ bots: [BotRow], to channels: [BotChannel], applied: [String: Int]
    ) -> (channels: [BotChannel], applied: [String: Int]) {
        var channels = channels
        var applied = applied
        var layouts: [Int: [String]] = [:]
        let pending = bots
            .compactMap { bot -> (name: String, placement: AlicePlacement)? in
                guard let placement = bot.placement,
                      applied[bot.name].map({ $0 < placement.revision }) ?? true
                else { return nil }
                return (bot.name, placement)
            }
            .sorted {
                ($0.placement.order ?? .max, $0.name) < ($1.placement.order ?? .max, $1.name)
            }

        for (bot, placement) in pending {
            let name = placement.channel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let index: Int
            if let found = channels.firstIndex(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
            }) {
                index = found
            } else {
                channels.append(BotChannel(name: name))
                index = channels.count - 1
            }
            var channel = channels[index]
            channel.add(bot)
            if let wanted = placement.section?.trimmingCharacters(in: .whitespacesAndNewlines),
               !wanted.isEmpty {
                let section = channel.sections.first {
                    $0.caseInsensitiveCompare(wanted) == .orderedSame
                } ?? wanted
                channel.addSection(section)
                channel.setSection(section, for: bot)
            } else {
                channel.setSection(nil, for: bot)
            }
            channels[index] = channel
            applied[bot] = placement.revision
            if let layout = placement.sections { layouts[index] = layout }
        }
        for (index, layout) in layouts {
            channels[index].applyLayout(layout)
        }
        return (channels, applied)
    }

    /// The sections in `layout`'s order, made if missing and matched whatever
    /// their case; after them, any other section that still holds an agent.
    /// An empty section the layout leaves out goes: nobody loses their place.
    mutating func applyLayout(_ layout: [String]) {
        var ordered: [String] = []
        for wanted in layout {
            let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let existing = sections.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            if !ordered.contains(where: { $0.caseInsensitiveCompare(existing) == .orderedSame }) {
                ordered.append(existing)
            }
        }
        let used = Set(bots.compactMap { section(for: $0) })
        for other in sections where !ordered.contains(other) && used.contains(other) {
            ordered.append(other)
        }
        let removed = Set(sections).subtracting(ordered)
        sections = ordered
        collapsedSections.removeAll { removed.contains($0) }
        botSections = botSections.filter { ordered.contains($0.value) }
    }

    /// Channels made before a channel was a folder were conversations flagged
    /// `isChannel` with no channel of their own. Each becomes a channel of the
    /// same name. One nobody wrote in is only a name, so the conversation goes;
    /// one with a history keeps it as the new channel's team, with its bots in
    /// the channel. Running it again changes nothing.
    static func migratingLegacyChannels(
        _ conversations: [Conversation], into channels: [BotChannel]
    ) -> (conversations: [Conversation], channels: [BotChannel]) {
        var channels = channels
        var kept: [Conversation] = []
        for conversation in conversations {
            guard conversation.isChannel == true, conversation.teamChannelID == nil else {
                kept.append(conversation)
                continue
            }
            let title = conversation.title.drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bots = conversation.channelBots ?? []
            var channel = BotChannel(name: title.isEmpty ? "Channel" : title, bots: bots)
            let spoken = conversation.messages.contains { $0.role == .user }
            if spoken {
                var team = conversation
                team.teamChannelID = channel.id
                team.title = channel.name
                kept.append(team)
            } else {
                channel.setBots([])
            }
            channels.append(channel)
        }
        return (kept, channels)
    }
}
