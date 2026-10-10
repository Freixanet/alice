import SwiftUI
import WebKit

/// Generated code has no host capabilities. Only native confirmation can send a turn.
struct InteractiveArtifactView: View {
    @Environment(AppStore.self) private var store
    let artifact: InteractiveArtifact
    var replyProfile: String? = nil
    @State private var height: CGFloat = 300
    @State private var proposedDraft: String?
    @State private var reviewing = false
    @State private var ready = false
    @State private var problem: String?
    private var language: ChatLanguage { ChatLanguage.of(artifact.summary) }
    @State private var originChat: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(artifact.title).font(.headline)
            Text(artifact.summary).font(.callout).foregroundStyle(.secondary)
            if !ready && problem == nil {
                HStack { ProgressView(); Text(artifact.placeholderMessages.first ?? "Preparando…").font(.caption) }
            }
            InteractiveWebSurface(artifact: artifact) { event, value in
                switch event {
                case "ready": ready = true
                case "height": if let number = value as? Double, number.isFinite { height = min(900, max(180, number)) }
                case "draft": if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 4000 { proposedDraft = text }
                case "error": problem = language.pick("The interactive part could not load. The summary is still available.", "La parte interactiva no se ha podido cargar. El resumen sigue disponible.")
                default: break
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if proposedDraft != nil {
                Button(language.pick("Review question for Alice", "Revisar consulta a Alice")) { reviewing = true }
                    .buttonStyle(.bordered)
                    .disabled(originChat != store.activeID)
            }
        }
        .padding(12)
        .onAppear { originChat = store.activeID; height = CGFloat(artifact.initialHeight) }
        .task(id: artifact.html + artifact.jsFunctions + artifact.jsExpressions) {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if !ready && problem == nil {
                problem = language.pick("The interactive part did not finish loading. You can still read the summary.", "La parte interactiva no terminó de cargar. Puedes leer el resumen.")
            }
        }
        .sheet(isPresented: $reviewing) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text(language.pick("This sends a message in this chat using its configured model.", "Se enviará un mensaje en este chat y usará el modelo configurado.")).font(.callout)
                    TextEditor(text: Binding(get: { proposedDraft ?? "" }, set: { proposedDraft = $0 }))
                        .accessibilityLabel("Consulta para Alice")
                    Button(language.pick("Send question", "Enviar consulta")) {
                        guard originChat == store.activeID, store.isConnected, !store.isSending,
                              let draft = proposedDraft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        reviewing = false
                        proposedDraft = nil
                        store.sendQuickReply(draft, replyProfile: replyProfile, followsLatestAgent: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(originChat != store.activeID || !store.isConnected || store.isSending || (proposedDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                .navigationTitle(language.pick("Review question", "Revisar consulta"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.pick("Cancel", "Cancelar")) { reviewing = false } } }
            }
        }
    }
}

struct InteractiveWebSurface: UIViewRepresentable {
    let artifact: InteractiveArtifact
    var receive: @MainActor (String, Any) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(receive: receive) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(context.coordinator, name: "interactiveUI")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.receive = receive
        guard context.coordinator.artifact != artifact else { return }
        context.coordinator.artifact = artifact
        do { view.loadHTMLString(try InteractiveDocument.make(artifact), baseURL: nil) }
        catch { receive("error", true) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "interactiveUI")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var artifact: InteractiveArtifact?
        var receive: @MainActor (String, Any) -> Void
        init(receive: @escaping @MainActor (String, Any) -> Void) { self.receive = receive }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
                  let type = data["type"] as? String, let value = data["value"] else { return }
            receive(type, value)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // No external navigation, file URLs, custom app links, popups or downloads.
            let url = navigationAction.request.url
            decisionHandler(url?.scheme == "about" && navigationAction.navigationType == .other ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { receive("error", true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { receive("error", true) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { receive("error", true) }
    }
}
