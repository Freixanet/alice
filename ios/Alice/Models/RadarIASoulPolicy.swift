import Foundation

extension RadarIA {
    /// Hermes seeds a new profile with this generic SOUL. For Radar IA that is
    /// bootstrap content, not user-authored instructions, so it is safe to
    /// replace with Radar IA's editorial SOUL.
    static let genericHermesSoulLead = "You are Hermes Agent, built by Nous Research."

    static func isGenericHermesSoul(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: genericHermesSoulLead,
            options: [.caseInsensitive, .anchored]
        ) != nil
    }
}
