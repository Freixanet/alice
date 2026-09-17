import SwiftUI
import UIKit

/// Images full screen, to look at closely.
///
/// Pinch to zoom and double tap to zoom in or back out, as Photos does; with
/// more than one, swipe sideways between them. Each image starts whole: the
/// zoom is not carried from one to the next, nor from last time.
struct ImageViewer: View {
    let images: [UIImage]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [UIImage], startingAt start: Int = 0) {
        self.images = images
        _index = State(initialValue: min(max(start, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(images.indices, id: \.self) { position in
                    ZoomableImage(image: images[position])
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            // Below the bar, not under it: Close and Share keep their own room.
            .padding(.top, 8)
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(images.count > 1 ? "\(index + 1) of \(images.count)" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    let image = images[index]
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Image", image: Image(uiImage: image))
                    )
                }
            }
            // On black the bar is a dark one, whatever the phone is set to:
            // light-mode glyphs on it were grey on black and all but invisible.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

extension View {
    /// Opens `images` full screen at `index`, zoomable, when tapped.
    func opensImageViewer(_ images: [UIImage], at index: Int = 0) -> some View {
        modifier(OpensImageViewer(images: images, index: index))
    }

    func opensImageViewer(_ image: UIImage) -> some View {
        opensImageViewer([image])
    }
}

private struct OpensImageViewer: ViewModifier {
    let images: [UIImage]
    let index: Int
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture { open = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the image full screen")
            .fullScreenCover(isPresented: $open) { ImageViewer(images: images, startingAt: index) }
    }
}

/// `UIScrollView` zooming: pinch, double tap, and the image kept centred.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = view

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        private let feedback = UIImpactFeedbackGenerator(style: .light)

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            feedback.impactOccurred()
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height
                ), animated: true)
            }
        }
    }
}

extension View {
    /// Pull to refresh with a tap felt when it triggers: the finger is over
    /// the spinner at that moment, so the screen alone does not say it took.
    func refreshableWithFeedback(_ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        refreshable {
            await MainActor.run { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            await action()
        }
    }
}
