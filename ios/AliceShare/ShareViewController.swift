import UIKit
import UniformTypeIdentifiers

/// Forwards shared text or a link into Alice as a composer draft.
///
/// The extension cannot talk to Hermes. It only opens `alice://compose`, which
/// Alice already understands, so a paragraph from Safari lands in the chat
/// the person is looking at. Long text is trimmed: a URL has a finite size.
final class ShareViewController: UIViewController {
    private static let limit = 1_500

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await forward() }
    }

    private func forward() async {
        let text = await sharedText()
        var parts = URLComponents()
        parts.scheme = "alice"
        parts.host = "compose"
        if !text.isEmpty {
            parts.queryItems = [URLQueryItem(name: "text", value: String(text.prefix(Self.limit)))]
        }
        if let url = parts.url {
            _ = openURL(url)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func sharedText() async -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return "" }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    return url.absoluteString
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return ""
    }

    /// Share extensions do not get `UIApplication.shared`. Walk the responder
    /// chain for the same `openURL` the system uses to hand a link to Alice.
    @discardableResult
    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }
}
