import Foundation

/// "When I arrive at / leave this place, do this", as an agent set it
/// (hermes-plugin/places.py). The iPhone finds the place and watches it.
struct PlaceTrigger: Identifiable, Hashable, Sendable {
    enum When: String, Sendable { case arrive, leave }

    let id: String
    let profile: String
    let place: String
    let when: When
    let radius: Double
    var latitude: Double?
    var longitude: Double?

    var isResolved: Bool { latitude != nil && longitude != nil }
    /// The monitor's condition name: which trigger, in which profile.
    var monitorKey: String { "\(profile)|\(id)" }

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let place = object["place"] as? String,
              let when = (object["when"] as? String).flatMap(When.init(rawValue:))
        else { return nil }
        self.id = id
        self.profile = object["profile"] as? String ?? "default"
        self.place = place
        self.when = when
        self.radius = (object["radius"] as? NSNumber)?.doubleValue ?? 150
        latitude = (object["lat"] as? NSNumber)?.doubleValue
        longitude = (object["lon"] as? NSNumber)?.doubleValue
    }

    /// The trigger a monitor condition name belongs to.
    nonisolated static func parse(key: String) -> (profile: String, id: String)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
