import MapKit
import SwiftUI

/// Places to choose from, side by side: a photo when the agent found one,
/// the name, a line about it, and Maps a tap away.
struct PlacesCarousel: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    let places: [UIComponent.Place]
    var language: ChatLanguage = .english

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(places) { place in
                    Button {
                        if let url = place.url ?? MapsLink.url(for: place) { openURL(url) }
                    } label: {
                        card(place)
                    }
                    .buttonStyle(PressableCardStyle())
                    .contextMenu {
                        if let url = MapsLink.url(for: place) {
                            Button(language.pick("Open in Maps", "Abrir en Mapas"), systemImage: "map") { openURL(url) }
                        }
                        if let url = MapsLink.directions(to: place) {
                            Button(language.pick("Directions", "Cómo llegar"), systemImage: "arrow.triangle.turn.up.right.diamond") { openURL(url) }
                        }
                        if let url = place.url {
                            Button(language.pick("Open website", "Abrir web"), systemImage: "safari") { openURL(url) }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }

    private func card(_ place: UIComponent.Place) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardImage(image: place.image, page: place.url, symbol: "mappin.and.ellipse")
                .frame(width: 236, height: 150)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = place.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .padding(12)
            .frame(width: 236, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .background(Palette.card(scheme))
        .clipShape(.rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5) }
    }
}

/// Places on a map. Still, so it never fights the chat's scrolling; a tap
/// opens Maps, where moving around belongs.
struct PlacesMapCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    let title: String?
    let places: [UIComponent.Place]
    var language: ChatLanguage = .english

    @State private var pins: [Pin] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var located = false

    struct Pin: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(position: $position, interactionModes: []) {
                ForEach(pins) { pin in
                    Marker(pin.title, coordinate: pin.coordinate)
                        .tint(pinColor)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 200)
            .overlay {
                if !located {
                    ProgressView()
                }
            }
            .contentShape(.rect)
            .onTapGesture { open(places.first) }

            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title)
                        .font(.headline)
                        .padding(.bottom, 6)
                }
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 { Divider() }
                    Button { open(place) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(pinColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.title).font(.subheadline.weight(.semibold))
                                if let subtitle = place.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 9)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Palette.card(scheme))
        .clipShape(.rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .task(id: places) { await locate() }
        .accessibilityElement(children: .contain)
    }

    /// Maps pins the same muted blue as links: a place is somewhere to go.
    private var pinColor: Color { Palette.link(scheme) }

    private func open(_ place: UIComponent.Place?) {
        guard let place, let url = MapsLink.url(for: place) else { return }
        openURL(url)
    }

    /// Coordinates the agent gave are used as they are; the rest are looked
    /// up by name with Apple's own search, never guessed.
    private func locate() async {
        var found: [Pin] = []
        for place in places.prefix(8) {
            if let lat = place.latitude, let lon = place.longitude {
                found.append(Pin(id: place.id, title: place.title, coordinate: .init(latitude: lat, longitude: lon)))
                continue
            }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = place.query ?? place.title
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                found.append(Pin(id: place.id, title: place.title, coordinate: item.location.coordinate))
            }
        }
        pins = found
        located = true
        if let only = found.first, found.count == 1 {
            position = .region(MKCoordinateRegion(center: only.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        } else {
            position = .automatic
        }
    }
}

/// Something that answers the finger the instant it lands, as the system's
/// own controls do: a small give on touch-down (ease-out, a tenth of a
/// second), a critically damped spring back on release. Under Reduce Motion
/// the give becomes a dim, with no movement.
struct PressableCardStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale)
    }

    private struct PressBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let scale: CGFloat

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .scaleEffect(pressed && !reduceMotion ? scale : 1)
                .opacity(pressed ? (reduceMotion ? 0.6 : 0.85) : 1)
                .animation(
                    pressed ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 1),
                    value: pressed
                )
        }
    }
}

/// The same answer for a small control — a row, a chip, an icon: dims and
/// gives a touch more, since there is less of it to see move.
extension ButtonStyle where Self == PressableCardStyle {
    static var pressable: PressableCardStyle { PressableCardStyle(scale: 0.95) }
}
