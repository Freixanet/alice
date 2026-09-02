import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns what the pickers hand back into something a message can carry.
enum AttachmentLoader {
    /// The longest edge an image is reduced to before it is sent.
    ///
    /// A photo off a modern phone is around 4000px and a few megabytes; as a
    /// base64 data URL that is a request most providers refuse outright. 1024
    /// is comfortably more than any vision model reads at.
    private static let maxEdge: CGFloat = 1024

    static func image(from item: PhotosPickerItem) async -> Attachment? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let source = UIImage(data: data)
        else { return nil }
        let shrunk = downscale(source)
        guard let jpeg = shrunk.jpegData(compressionQuality: 0.7) else { return nil }
        return Attachment(
            id: UUID().uuidString,
            name: item.itemIdentifier.map { "Photo \($0.prefix(6))" } ?? "Photo",
            mime: "image/jpeg",
            kind: .image,
            data: jpeg
        )
    }

    /// An image already in memory — what the camera hands back.
    static func photo(_ image: UIImage, name: String = "Photo") -> Attachment? {
        guard let jpeg = downscale(image).jpegData(compressionQuality: 0.7) else {
            return nil
        }
        return Attachment(
            id: UUID().uuidString, name: name,
            mime: "image/jpeg", kind: .image, data: jpeg
        )
    }

    static func file(at url: URL) -> Attachment? {
        // A file handed over by the document picker lives outside the app's
        // sandbox; without this the read fails with a permission error.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"

        if type?.conforms(to: .image) == true, let source = UIImage(data: data),
           let jpeg = downscale(source).jpegData(compressionQuality: 0.7) {
            return Attachment(
                id: UUID().uuidString, name: url.lastPathComponent,
                mime: "image/jpeg", kind: .image, data: jpeg
            )
        }
        return Attachment(
            id: UUID().uuidString, name: url.lastPathComponent,
            mime: mime, kind: .file, data: data
        )
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let edge = max(image.size.width, image.size.height)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        let size = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The system camera, handed back as an attachment.
///
/// `PhotosPicker` covers the library but cannot take a picture, and there is
/// still no SwiftUI camera, so this is the UIKit controller in a wrapper.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Attachment) -> Void
    @Environment(\.dismiss) private var dismiss

    /// False in the Simulator and on any device without one, where offering
    /// the option would open a controller that cannot do anything.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onCapture: (Attachment) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (Attachment) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let attachment = AttachmentLoader.photo(image) {
                onCapture(attachment)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

/// The row of things waiting to go out with the next message.
///
/// One square per attachment, whatever it is. An image is shown and nothing
/// else — a thumbnail beside its own filename is the filename twice — and a
/// file takes the same square so the row keeps one rhythm instead of
/// alternating between pictures and name-shaped pills.
struct AttachmentChips: View {
    @Environment(\.colorScheme) private var scheme
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    private let tile: CGFloat = 100

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    preview(attachment)
                        .frame(width: tile, height: tile)
                        .clipShape(.rect(cornerRadius: 18))
                        .overlay(alignment: .topTrailing) {
                            remove(attachment).padding(5)
                        }
                }
            }
            .padding(.trailing, 4)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // The composer insets its contents by 16 across and 12 down, which
        // left the squares 20pt from its left edge and 12 from its top — a
        // corner that read as lopsided. Pulling back against those insets sets
        // both to 8. The text stays where it is; only this row moves.
        .padding(.leading, -8)
        .padding(.top, -4)
    }

    @ViewBuilder
    private func preview(_ attachment: Attachment) -> some View {
        if attachment.kind == .image, let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 30, weight: .light))
                Text(attachment.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Full strength, and edged. At 0.8 over the composer's glass this
            // fill landed three levels from the background: the same 68pt
            // square as a photo, measured, but with its corners fading out it
            // read as the smaller of the two.
            .background(Palette.muted(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.border(scheme).opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private func remove(_ attachment: Attachment) -> some View {
        Button {
            onRemove(attachment)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                // A material rather than a fixed colour: sitting on top of an
                // arbitrary photo, a flat circle is legible over some pictures
                // and invisible over others.
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(attachment.name)")
    }
}
