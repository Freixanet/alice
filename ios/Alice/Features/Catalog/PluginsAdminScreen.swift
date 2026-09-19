import SwiftUI

struct PluginsAdminScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var hub: HermesPluginHub?
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    @State private var installing = false
    @State private var pendingMutation: PluginMutation?
    @State private var busyName: String?
    @State private var message: String?

    var body: some View {
        List {
            if let hub, !hub.contextOptions.isEmpty {
                Section("Context engine") {
                    Picker("Engine", selection: Binding(get: { hub.contextEngine }, set: { value in Task { await changeContext(value) } })) {
                        ForEach(hub.contextOptions) { Text($0.name).tag($0.name) }
                    }
                    if let current = hub.contextOptions.first(where: { $0.name == hub.contextEngine }) { Text(current.detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Agent plugins") {
                if loading && hub == nil { ProgressView("Loading plugins…") }
                else if let hub, filtered(hub.plugins).isEmpty { Text(search.isEmpty ? "No agent plugins discovered." : "No matching plugins.").foregroundStyle(.secondary) }
                else if let hub { ForEach(filtered(hub.plugins)) { plugin in pluginRow(plugin) } }
            }
            if let hub, !hub.dashboardOnly.isEmpty {
                Section("Dashboard extensions") {
                    Text("These extensions provide web-dashboard UI. Alice does not execute arbitrary plugin JavaScript, but shows what Hermes discovered.").font(.caption).foregroundStyle(.secondary)
                    ForEach(hub.dashboardOnly) { plugin in
                        VStack(alignment: .leading, spacing: 3) { HStack { Text(plugin.label); Spacer(); Text("v\(plugin.version)").font(.caption2).foregroundStyle(.secondary) }; Text(plugin.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3); Text(plugin.path).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                    }
                }
            }
            if let message { Section("Result") { Text(message).font(.footnote).textSelection(.enabled) } }
            if let failure { Section("Last error") { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search plugins")
        .scrollContentBackground(.hidden).background(Palette.background(scheme))
        .task { await load() }.refreshableWithFeedback { await load() }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await rescan() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.disabled(loading).accessibilityLabel("Rescan plugins")
            Button { installing = true } label: { Image(systemName: "plus") }.accessibilityLabel("Install plugin")
        } }
        .sheet(isPresented: $installing) { PluginInstallSheet { identifier, force, enable in try await install(identifier, force: force, enable: enable) }.preferredColorScheme(store.theme.colorScheme) }
        .confirmationDialog(mutationTitle, isPresented: Binding(get: { pendingMutation != nil }, set: { if !$0 { pendingMutation = nil } }), titleVisibility: .visible) {
            if let pendingMutation { Button(pendingMutation.button, role: pendingMutation.destructive ? .destructive : nil) { Task { await perform(pendingMutation) } }; Button("Cancel", role: .cancel) { self.pendingMutation = nil } }
        } message: { Text(mutationMessage) }
    }

    @ViewBuilder private func pluginRow(_ plugin: HermesPlugin) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(plugin.name).font(.subheadline.weight(.medium)); Spacer(); Text(plugin.runtimeStatus.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(plugin.runtimeStatus == "disabled" ? Color.secondary : Color.green) }
            Text(plugin.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 7) { Text(plugin.source); Text("v\(plugin.version)"); if plugin.authRequired { Label("auth", systemImage: "key") } }.font(.caption2).foregroundStyle(.tertiary)
            if plugin.authRequired && !plugin.authCommand.isEmpty { Text(plugin.authCommand).font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Button(plugin.runtimeStatus == "disabled" ? "Enable" : "Disable") { pendingMutation = .toggle(plugin, enable: plugin.runtimeStatus == "disabled") }
                if plugin.canUpdateGit { Button("Update") { pendingMutation = .update(plugin) } }
                if plugin.canRemove { Button("Remove", role: .destructive) { pendingMutation = .remove(plugin) } }
                if plugin.hasDashboardManifest { Button(plugin.userHidden ? "Show in web" : "Hide in web") { pendingMutation = .visibility(plugin, hidden: !plugin.userHidden) } }
                if busyName == plugin.name { ProgressView() }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(.vertical, 3)
    }

    private func filtered(_ plugins: [HermesPlugin]) -> [HermesPlugin] { let q=search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard !q.isEmpty else { return plugins }; return plugins.filter { $0.name.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.source.lowercased().contains(q) } }
    private func load() async { loading=true; defer { loading=false }; do { hub=try await store.pluginHub(); failure=nil } catch { failure=reason(error) } }
    private func rescan() async { loading=true; defer { loading=false }; do { let count=try await store.rescanPlugins(); message="Hermes rescanned \(count) dashboard plugins."; hub=try await store.pluginHub(); failure=nil } catch { failure=reason(error) } }
    private func install(_ identifier: String, force: Bool, enable: Bool) async throws { let warnings=try await store.installAgentPlugin(identifier: identifier, force: force, enable: enable); message=warnings.isEmpty ? "Installed \(identifier)." : warnings.joined(separator: "\n"); hub=try await store.pluginHub() }
    private func changeContext(_ name: String) async { do { try await store.setContextEngine(name); hub=try await store.pluginHub() } catch { failure=reason(error) } }
    private func perform(_ action: PluginMutation) async { pendingMutation=nil; busyName=action.plugin.name; defer { busyName=nil }; do { switch action { case let .toggle(p,e): try await store.setAgentPlugin(p.name, enabled:e); case let .update(p): message=try await store.updateAgentPlugin(p.name) ?? "Updated \(p.name)."; case let .remove(p): try await store.removeAgentPlugin(p.name); case let .visibility(p,h): try await store.setPluginHidden(p.name, hidden:h) }; hub=try await store.pluginHub(); failure=nil } catch { failure=reason(error) } }
    private var mutationTitle: String { pendingMutation?.title ?? "Change plugin?" }
    private var mutationMessage: String { pendingMutation?.message ?? "" }
    private func reason(_ error: Error) -> String { PlainWords.describe(error) }
}

private enum PluginMutation: Identifiable {
    case toggle(HermesPlugin, enable: Bool), update(HermesPlugin), remove(HermesPlugin), visibility(HermesPlugin, hidden: Bool)
    var id: String { "\(plugin.name)|\(title)" }
    var plugin: HermesPlugin { switch self { case let .toggle(p,_), let .update(p), let .remove(p), let .visibility(p,_): p } }
    var title: String { switch self { case let .toggle(_,e): e ? "Enable plugin?" : "Disable plugin?"; case .update: "Update plugin code?"; case .remove: "Remove plugin?"; case .visibility: "Change dashboard visibility?" } }
    var button: String { switch self { case let .toggle(_,e): e ? "Enable" : "Disable"; case .update: "Update"; case .remove: "Remove"; case let .visibility(_,h): h ? "Hide" : "Show" } }
    var destructive: Bool { if case .remove = self { return true }; return false }
    var message: String { switch self { case .toggle: "Plugin activation changes Hermes runtime behavior and usually takes effect for new sessions."; case .update: "Hermes may fetch and replace code for this user plugin."; case .remove: "The plugin will be removed from the Hermes host. Bundled plugins cannot be removed."; case .visibility: "This changes only whether the plugin appears in Hermes' web dashboard." } }
}

private struct PluginInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var identifier=""
    @State private var force=false
    @State private var enable=true
    @State private var confirm=false
    @State private var busy=false
    @State private var failure:String?
    let install: (String,Bool,Bool) async throws -> Void
    var body: some View { NavigationStack { Form {
        Section("Plugin") { TextField("Identifier or repository", text:$identifier).textInputAutocapitalization(.never).autocorrectionDisabled(); Toggle("Enable after install",isOn:$enable); Toggle("Force reinstall",isOn:$force) }
        Section { Text("Installing a plugin can download and execute third-party code on the Mac running Hermes. Review the identifier/source before continuing.").font(.caption).foregroundStyle(.orange) }
        if let failure { Section { Text(failure).foregroundStyle(.red).font(.footnote) } }
    }.navigationTitle("Install Plugin").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}; ToolbarItem(placement:.confirmationAction){if busy{ProgressView()}else{Button("Install"){confirm=true}.disabled(identifier.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}} }.confirmationDialog("Install code on the Hermes host?",isPresented:$confirm,titleVisibility:.visible){Button("Install"){Task{await run()}};Button("Cancel",role:.cancel){}} message:{Text("Hermes will resolve this identifier and may execute its install steps on the Mac.")} }
    private func run() async { busy=true; defer{busy=false}; do{try await install(identifier.trimmingCharacters(in:.whitespacesAndNewlines),force,enable);dismiss()}catch{failure=PlainWords.describe(error, doing: "install the plugin")} }
}
