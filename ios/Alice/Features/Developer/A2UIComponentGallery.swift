import SwiftUI
import A2UISwiftCore
import A2UISwiftUI

/// Local SDK surfaces. No transport, credentials or application store is attached.
struct A2UIComponentGallery: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Controles reales de a2ui-swift. Puedes tocarlos: los cambios se quedan en esta pantalla y se reinician al salir.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(A2UIGallerySample.allCases) { sample in
                    A2UIGalleryCard(sample: sample)
                }
            }
            .padding(20)
        }
        .navigationTitle("a2ui-swift")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct A2UIGalleryCard: View {
    let sample: A2UIGallerySample
    @State private var model: SurfaceViewModel?
    @State private var error: String?
    @State private var lastAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sample.title).font(.headline)
            Text(sample.detail).font(.caption).foregroundStyle(.secondary)
            if let model {
                A2UISurfaceView(viewModel: model, scrolls: false) { action in
                    let name = action.name
                    Task { @MainActor in lastAction = "Acción local: \(name)" }
                }
                .a2uiImageResolver { _ in Image(systemName: "sun.max.fill") }
            } else if let error {
                Text("No se pudo cargar este ejemplo: \(error)").foregroundStyle(.red)
            } else {
                ProgressView()
            }
            if let lastAction {
                Text(lastAction).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("a2ui.localAction")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            guard model == nil, error == nil else { return }
            do { model = try sample.makeModel() }
            catch { self.error = error.localizedDescription }
        }
    }
}
