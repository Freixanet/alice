import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Controls for work Alice can keep doing after a conversation ends.
struct AgentWorkScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink { PageWatchesScreen() } label: {
                    Label("Page watches", systemImage: "eye")
                }
                NavigationLink { SharedBrowserScreen() } label: {
                    Label("Shared browser", systemImage: "globe")
                }
                NavigationLink { AgentDocumentsScreen() } label: {
                    Label("Documents for agents", systemImage: "doc")
                }
            } footer: {
                Text("These tools use the Hermes dashboard on your Mac. Page watches notify you when a page changes; the shared browser lets you see and control the page your agents use.")
            }
        }
        .navigationTitle("Agent work")
    }
}

private struct PageWatchesScreen: View {
    @Environment(AppStore.self) private var store
    @State private var service: PageWatchService?
    @State private var watches: [PageWatch] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var adding = false
    @State private var removing: PageWatch?

    var body: some View {
        List {
            if let service, !service.installed {
                Section {
                    Button {
                        Task { await setUp() }
                    } label: {
                        Label(service.installing ? "Setting up…" : "Set up page watches", systemImage: "arrow.down.circle")
                    }
                    .disabled(service.installing || loading)
                    if let failed = service.failed {
                        Text(failed).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Alice installs the page watcher on your Mac when you ask. Setup can take a few minutes.")
                }
            }

            if service?.installed == true {
                Section {
                    if watches.isEmpty {
                        Text("No pages watched yet.").foregroundStyle(.secondary)
                    }
                    ForEach(watches) { watch in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(watch.label).font(.headline)
                            Text(watch.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let detail = detail(watch) {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let error = watch.error {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .swipeActions {
                            Button("Stop watching", role: .destructive) { removing = watch }
                        }
                    }
                } header: {
                    Text("Watching")
                } footer: {
                    Text("Swipe a page to stop watching it. Pull down to refresh prices and status.")
                }
            }

            if let failure {
                Section("Last error") { Text(failure).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Page watches")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .disabled(service?.installed != true)
                    .accessibilityLabel("Watch a page")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { NewPageWatchSheet { Task { await load() } } }
        }
        .confirmationDialog("Stop watching \(removing?.label ?? "this page")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Stop watching", role: .destructive) {
                guard let watch = removing else { return }
                removing = nil
                Task { await remove(watch) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay { if loading && service == nil { ProgressView() } }
    }

    private func detail(_ watch: PageWatch) -> String? {
        if let price = watch.price {
            return "\(price.formatted(.number.precision(.fractionLength(2)))) \(watch.currency ?? "")"
        }
        if let inStock = watch.inStock { return inStock ? "In stock" : "Out of stock" }
        if let date = watch.lastChecked { return "Checked \(date.formatted(date: .abbreviated, time: .shortened))" }
        return nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await store.pageWatches()
            service = result.service
            watches = result.watches
            failure = nil
        } catch {
            failure = PlainWords.describe(error, doing: "load page watches")
        }
    }

    private func setUp() async {
        loading = true
        defer { loading = false }
        do {
            service = try await store.setUpPageWatches()
            failure = nil
            for _ in 0..<90 where service?.installed != true && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let result = try await store.pageWatches()
                service = result.service
                watches = result.watches
                if service?.failed != nil { break }
            }
        } catch {
            failure = PlainWords.describe(error, doing: "set up page watches")
        }
    }

    private func remove(_ watch: PageWatch) async {
        do {
            try await store.deletePageWatch(watch.id)
            await load()
        } catch {
            failure = PlainWords.describe(error, doing: "stop watching the page")
        }
    }
}

private struct NewPageWatchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var url = ""
    @State private var label = ""
    @State private var kind: PageWatch.Kind = .change
    @State private var below = ""
    @State private var wantedText = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Page") {
                TextField("https://example.com/page", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Name (optional)", text: $label)
            }
            Section("Tell me when") {
                Picker("Change", selection: $kind) {
                    Text("Anything changes").tag(PageWatch.Kind.change)
                    Text("Price drops").tag(PageWatch.Kind.price)
                    Text("Stock returns").tag(PageWatch.Kind.stock)
                    Text("Text appears").tag(PageWatch.Kind.text)
                }
                if kind == .price {
                    TextField("Price limit (optional)", text: $below).keyboardType(.decimalPad)
                }
                if kind == .text {
                    TextField("Words to look for", text: $wantedText)
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("Watch a page")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(saving || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (kind == .text && wantedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .disabled(saving)
    }

    private func save() async {
        let amount = below.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = amount.isEmpty ? nil : Double(amount.replacingOccurrences(of: ",", with: "."))
        if kind == .price && !amount.isEmpty && number == nil {
            failure = "Enter a valid price."
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await store.createPageWatch(url: url, kind: kind, label: label,
                                            below: kind == .price ? number : nil, text: wantedText)
            onSaved()
            dismiss()
        } catch {
            failure = PlainWords.describe(error, doing: "watch the page")
        }
    }
}

private struct SharedBrowserScreen: View {
    @Environment(AppStore.self) private var store
    @State private var state: SharedBrowserState?
    @State private var frame: SharedBrowserFrame?
    @State private var address = ""
    @State private var typing = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var showEnable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let state {
                    if state.watchable {
                        if let frame, let data = frame.jpeg, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .overlay {
                                    GeometryReader { geometry in
                                        Color.clear.contentShape(Rectangle())
                                            .gesture(SpatialTapGesture().onEnded { tap in
                                                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                                                let x = Double(tap.location.x / geometry.size.width)
                                                let y = Double(tap.location.y / geometry.size.height)
                                                Task { await input(.tap(x: x, y: y)) }
                                            })
                                    }
                                }
                                .accessibilityLabel("Browser page. Tap to interact.")
                        } else {
                            ContentUnavailableView("Waiting for the page", systemImage: "globe")
                        }
                        Text(frame?.title.isEmpty == false ? frame!.title : (state.pageTitle ?? "Shared browser"))
                            .font(.headline)
                        HStack {
                            Button { Task { await input(.back) } } label: { Image(systemName: "chevron.left") }
                            Button { Task { await input(.forward) } } label: { Image(systemName: "chevron.right") }
                            Button { Task { await input(.reload) } } label: { Image(systemName: "arrow.clockwise") }
                            Button("Scroll up") { Task { await input(.scroll(x: 0.5, y: 0.5, dy: -0.7)) } }
                            Button("Scroll down") { Task { await input(.scroll(x: 0.5, y: 0.5, dy: 0.7)) } }
                        }
                        .buttonStyle(.bordered)
                        HStack {
                            TextField("Web address", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Go") { Task { await input(.navigate(address)) } }.disabled(address.isEmpty)
                        }
                        HStack {
                            TextField("Type into selected field", text: $typing)
                            Button("Type") {
                                let text = typing
                                typing = ""
                                Task { await input(.text(text)) }
                            }
                            .disabled(typing.isEmpty)
                        }
                        Text("Tap a field in the page before typing. Agents can see and use this same browser.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("Browser unavailable", systemImage: "globe",
                                               description: Text(state.configured && !state.local
                                                                 ? "Hermes is using a browser on another machine."
                                                                 : "Start a shared browser on your Mac to watch your agents work."))
                    }
                    if state.managed {
                        Button("Stop shared browser", role: .destructive) { Task { await switchBrowser(false) } }
                    } else if state.available {
                        Button("Start shared browser") { showEnable = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("Install Chrome or another Chromium browser on your Mac to use this.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
                if let failure { Text(failure).foregroundStyle(.red).font(.footnote) }
            }
            .padding()
        }
        .navigationTitle("Shared browser")
        .disabled(busy)
        .confirmationDialog("Use Alice’s shared browser?", isPresented: $showEnable) {
            Button("Use shared browser") { Task { await switchBrowser(true) } }
        } message: {
            Text("This switches your agents to one browser on this Mac. Turning it off restores their previous browser settings.")
        }
        .task { await refresh() }
        .task(id: state?.watchable == true) {
            guard state?.watchable == true else { return }
            var sequence = 0
            while !Task.isCancelled {
                do {
                    let shot = try await store.sharedBrowserFrame(after: sequence, target: frame?.target)
                    if shot.jpeg != nil {
                        sequence = shot.seq
                        frame = shot
                    }
                    try await Task.sleep(for: .milliseconds(350))
                } catch is CancellationError {
                    return
                } catch {
                    failure = PlainWords.describe(error, doing: "watch the shared browser")
                    return
                }
            }
        }
    }

    private func refresh() async {
        do { state = try await store.sharedBrowser(); failure = nil }
        catch { failure = PlainWords.describe(error, doing: "load the shared browser") }
    }

    private func switchBrowser(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do {
            state = try await store.setSharedBrowser(on: on)
            frame = nil
            failure = nil
        } catch { failure = PlainWords.describe(error, doing: on ? "start the shared browser" : "stop the shared browser") }
    }

    private func input(_ action: SharedBrowserAction) async {
        do { try await store.sharedBrowserInput(action, target: frame?.target); failure = nil }
        catch { failure = PlainWords.describe(error, doing: "control the shared browser") }
    }
}

private struct AgentDocumentsScreen: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var busy = false
    @State private var remotePath: String?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Button { importing = true } label: {
                    Label("Choose a document", systemImage: "square.and.arrow.up")
                }
                .disabled(busy)
                if busy { ProgressView("Uploading…") }
            } footer: {
                Text("PDF forms and bank statement CSV files can be read by your agents. The file is copied to your Hermes Mac only when you choose it here.")
            }
            if let remotePath {
                Section {
                    Text(remotePath).font(.footnote).textSelection(.enabled)
                    Button("Copy file reference") { UIPasteboard.general.string = remotePath }
                } header: {
                    Text("Ready for Alice")
                } footer: {
                    Text("Paste this reference into a chat and tell Alice what you want done with the file.")
                }
            }
            if let failure { Section("Last error") { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle("Documents")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await upload(url) }
        }
    }

    private func upload(_ url: URL) async {
        busy = true
        defer { busy = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 25 * 1024 * 1024 else {
                failure = "Choose a file smaller than 25 MB."
                return
            }
            remotePath = try await store.uploadAgentDocument(name: url.lastPathComponent, data: data)
            failure = nil
        } catch {
            failure = PlainWords.describe(error, doing: "upload the document")
        }
    }
}
