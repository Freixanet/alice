import CoreLocation
import MapKit
import OSLog

/// Watches the places agents were asked about ("when I get to the
/// supermarket…") and tells Hermes when the person arrives or leaves.
///
/// iOS region monitoring (`CLMonitor`) does the watching: it costs no
/// battery beyond what the phone already does, and it relaunches Alice in
/// the background when a boundary is crossed. Only the fact — this trigger,
/// arrived or left — goes to the Mac; never a location. A place given in
/// words is found once with Maps near where the person is, and its
/// coordinates are kept on the trigger so it is not looked up again.
@MainActor
final class PlaceWatcher: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceWatcher()

    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var listening: Task<Void, Never>?
    private weak var store: AppStore?
    private let log = Logger(subsystem: "com.freixanet.alice", category: "places")

    override private init() {
        super.init()
        manager.delegate = self
    }

    /// At launch, including a background relaunch for a crossed boundary:
    /// the events have to be read before anything else.
    func start(store: AppStore) {
        self.store = store
        // CLMonitor asserts (and took the app down at launch) when created
        // before the person has allowed location; until then there is
        // nothing to watch anyway.
        guard listening == nil,
              [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
        else { return }
        listening = Task { [weak self] in
            let monitor = await CLMonitor("AlicePlaces")
            self?.monitor = monitor
            Task { await self?.sync() }
            do {
                for try await event in await monitor.events {
                    await self?.handle(event)
                }
            } catch {
                self?.log.error("Place monitor stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Brings the watched places in line with the agents' triggers. Asks
    /// for location permission only once a trigger exists.
    func sync() async {
        guard let store, let triggers = try? await store.placeTriggers() else { return }
        if triggers.isEmpty {
            await replace(with: [])
            return
        }
        askPermissionIfNeeded()
        var ready: [PlaceTrigger] = []
        for var trigger in triggers {
            if !trigger.isResolved, let found = await find(trigger.place) {
                trigger.latitude = found.coordinate.latitude
                trigger.longitude = found.coordinate.longitude
                try? await store.placeResolved(trigger, latitude: found.coordinate.latitude,
                                               longitude: found.coordinate.longitude, label: found.label)
            }
            if trigger.isResolved { ready.append(trigger) }
        }
        await replace(with: ready)
    }

    // MARK: Monitoring

    private func replace(with triggers: [PlaceTrigger]) async {
        guard let monitor else { return }
        let wanted = Dictionary(uniqueKeysWithValues: triggers.map { ($0.monitorKey, $0) })
        for key in await monitor.identifiers where wanted[key] == nil {
            await monitor.remove(key)
        }
        let present = Set(await monitor.identifiers)
        for (key, trigger) in wanted where !present.contains(key) {
            guard let latitude = trigger.latitude, let longitude = trigger.longitude else { continue }
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                radius: trigger.radius
            )
            // Assumed to be in the opposite state of what the trigger waits
            // for: set while already at the place, "when I arrive" waits for
            // the next arrival instead of firing at once.
            await monitor.add(condition, identifier: key,
                              assuming: trigger.when == .arrive ? .satisfied : .unsatisfied)
        }
    }

    private func handle(_ event: CLMonitor.Event) async {
        guard let (profile, id) = PlaceTrigger.parse(key: event.identifier) else { return }
        let moved: String
        switch event.state {
        case .satisfied: moved = "arrive"
        case .unsatisfied: moved = "leave"
        default: return
        }
        guard let store else { return }
        do {
            try await store.placeEvent(id: id, profile: profile, event: moved)
        } catch {
            log.error("Place event could not reach Hermes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Finding a place

    private struct Found { let coordinate: CLLocationCoordinate2D; let label: String }

    private func find(_ place: String) async -> Found? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        if let here = manager.location?.coordinate {
            request.region = MKCoordinateRegion(center: here, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        let label = [item.name, item.addressRepresentations?.cityName].compactMap { $0 }.joined(separator: " · ")
        return Found(coordinate: coordinate, label: label.isEmpty ? place : label)
    }

    // MARK: Permission

    private func askPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // "While using" first, then iOS offers "Always" — the one that
            // lets a place be noticed with the app closed.
            if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
            if let store = self.store, [.authorizedAlways, .authorizedWhenInUse].contains(status) {
                self.start(store: store)
                await self.sync()
            }
        }
    }
}
