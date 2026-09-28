import SwiftUI

/// Source-linked internet posts. Agent activity remains in Activity.
struct FeedScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    var onOpenedChat: () -> Void = {}
    @State private var feed = NewsFeedStore.shared
    @State private var mode = 0
    @State private var showPreferences = false
    @State private var resetConfirmation = false
    @State private var explanation: NewsPost?

    private var posts: [NewsPost] {
        switch mode {
        case 1: feed.timeline.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        case 2: feed.saved
        default: feed.timeline
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Picker("Orden del Feed", selection: $mode) {
                    Text("Para ti").tag(0)
                    Text("Recientes").tag(1)
                    Text("Guardados").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(16)
                if feed.archive.interests.isEmpty {
                    Button { showPreferences = true } label: {
                        Label("Elige tus intereses para empezar", systemImage: "slider.horizontal.3")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
                if feed.storageFailure {
                    Text("No se pudieron leer tus preferencias guardadas. Se han conservado sin sobrescribirlas.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
                if let failure = feed.failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                        Button("Reintentar") { Task { await feed.refresh(force: true) } }
                    }.padding()
                }
                if posts.isEmpty {
                    if feed.loading {
                        ProgressView("Buscando publicaciones…").padding(40)
                    } else {
                        ContentUnavailableView(
                            mode == 2 ? "Aún no has guardado publicaciones" : "No hay publicaciones disponibles",
                            systemImage: mode == 2 ? "bookmark" : "newspaper",
                            description: Text(mode == 2 ? "Guarda lo que quieras leer más tarde." : "Elige tus fuentes o desliza hacia abajo para actualizar.")
                        )
                    }
                }
                ForEach(posts) { post in
                    postRow(post)
                    Divider().padding(.leading, 68)
                }
                if !posts.isEmpty {
                    Text("Estás al día con las publicaciones disponibles.")
                        .font(.footnote).foregroundStyle(.secondary).padding(24)
                }
            }
        }
        .background(Palette.background(scheme))
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showPreferences = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Intereses y fuentes")
            }
        }
        .refreshable { await feed.refresh(force: true) }
        .task { await feed.refresh() }
        .sheet(isPresented: $showPreferences) { preferences }
        .alert("Por qué aparece", isPresented: Binding(get: { explanation != nil }, set: { if !$0 { explanation = nil } })) {
            Button("Entendido", role: .cancel) { explanation = nil }
        } message: {
            if let post = explanation {
                Text("Publicado por \(post.source), sobre \(post.topic). El orden combina actualidad, tus temas elegidos y tus acciones de abrir, guardar, más y menos como esto. También introduce variedad. Puedes cambiarlo en Intereses y fuentes.")
            }
        }
    }

    private func postRow(_ post: NewsPost) -> some View {
        let feedback = feed.archive.feedback[post.id]
        return HStack(alignment: .top, spacing: 12) {
            Text(String(post.source.prefix(1)))
                .font(.headline).frame(width: 36, height: 36)
                .background(.quaternary, in: .circle).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(post.source).font(.subheadline.weight(.semibold))
                    if let published = post.published {
                        Text(published, style: .relative).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Por qué aparece", systemImage: "info.circle") { explanation = post }
                        Button("Menos como esto", systemImage: "hand.thumbsdown") { feed.respond(post, vote: -1) }
                        Button("Ocultar esta fuente", systemImage: "eye.slash") { feed.source(post.sourceID, enabled: false) }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .accessibilityLabel("Opciones de la publicación")
                }
                Button {
                    feed.respond(post, opened: true)
                    openURL(post.url)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(post.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        if !post.excerpt.isEmpty {
                            Text(post.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                        }
                        if let image = post.image {
                            AsyncImage(url: image) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill().frame(height: 180).clipped()
                                        .clipShape(.rect(cornerRadius: 14))
                                }
                            }.accessibilityHidden(true)
                        }
                        Label(post.url.host ?? post.source, systemImage: "arrow.up.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }.buttonStyle(.plain)
                HStack(spacing: 24) {
                    Button { feed.respond(post, vote: 1) } label: {
                        Image(systemName: feedback?.vote == 1 ? "heart.fill" : "heart")
                            .foregroundStyle(feedback?.vote == 1 ? Color.pink : Color.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(feedback?.vote == 1 ? "Quitar más como esto" : "Más como esto")
                    Button { feed.respond(post, save: feedback?.saved != true) } label: {
                        Image(systemName: feedback?.saved == true ? "bookmark.fill" : "bookmark")
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(feedback?.saved == true ? "Quitar de guardados" : "Guardar publicación")
                    ShareLink(item: post.url) {
                        Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Compartir enlace")
                    Spacer(minLength: 0)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var preferences: some View {
        NavigationStack {
            Form {
                Section("Tus temas") {
                    ForEach(NewsSource.topics, id: \.self) { topic in
                        Toggle(topic, isOn: Binding(get: { feed.archive.interests.contains(topic) }, set: { feed.interest(topic, enabled: $0) }))
                    }
                }
                Section("Fuentes") {
                    ForEach(NewsSource.catalogue) { source in
                        Toggle("\(source.name) · \(source.topic)", isOn: Binding(
                            get: { !feed.archive.mutedSources.contains(source.id) },
                            set: { feed.source(source.id, enabled: $0) }
                        ))
                    }
                }
                Section {
                    Text("Tus preferencias se guardan en este iPhone. Guardar y dar «más como esto» pesa más que abrir una noticia. No usamos el tiempo de pantalla. Las fuentes reciben las solicitudes de sus noticias e imágenes. Los artículos se abren en su web y pueden requerir suscripción.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Reiniciar aprendizaje", role: .destructive) { resetConfirmation = true }
                }
            }
            .disabled(feed.storageFailure)
            .navigationTitle("Intereses y fuentes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") {
                showPreferences = false
                Task { await feed.refresh(force: true) }
            } } }
            .confirmationDialog("¿Reiniciar los intereses aprendidos? Tus publicaciones guardadas se conservan.", isPresented: $resetConfirmation) {
                Button("Reiniciar aprendizaje", role: .destructive) { feed.resetLearning() }
            }
        }
    }
}
