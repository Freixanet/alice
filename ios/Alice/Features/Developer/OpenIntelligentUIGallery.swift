import SwiftUI

struct OpenIntelligentUIGallery: View {
    @Environment(AppStore.self) private var store
    @State private var sandbox: AppStore?
    @State private var nativeSamples: [NativeCalculator] = []
    @State private var samples: [InteractiveArtifact] = []
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Ejemplos locales con el mismo renderer que usan las respuestas de Hermes. Los controles no gastan cuota. Las consultas de esta galería están desconectadas de Hermes.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Controles nativos").font(.title3.weight(.semibold))
                ForEach(nativeSamples, id: \.self) { calculator in
                    NativeCalculatorView(calculator: calculator, language: .spanish)
                }
                Text("Interfaces libres").font(.title3.weight(.semibold))
                if let sandbox {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, artifact in
                        InteractiveArtifactView(artifact: artifact)
                    }
                    .environment(sandbox)
                }
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }.padding(16)
        }
        .navigationTitle("OpenIntelligentUI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard sandbox == nil else { return }
            sandbox = GalleryFixtures.sandbox(like: store)
            do {
                guard let nativeURL = Bundle.main.url(forResource: "native-calculator-demos", withExtension: "json"),
                      let nativeValues = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeURL)) as? [[String: Any]] else { throw CocoaError(.fileNoSuchFile) }
                nativeSamples = try nativeValues.map { value in
                    guard let calculator = NativeCalculator(json: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
                    return calculator
                }
                guard let url = Bundle.main.url(forResource: "openintelligentui-demos", withExtension: "json"),
                      let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { throw CocoaError(.fileNoSuchFile) }
                samples = try values.map { value in
                    try InteractiveArtifact(json: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
                }
            } catch { problem = "No se pudieron cargar los ejemplos." }
        }
    }
}
