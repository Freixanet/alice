import SwiftUI

struct SavedEndpointsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let profile: String
    @State private var snapshot: SavedCustomEndpointsSnapshot?
    @State private var editing: SavedCustomEndpoint?
    @State private var adding=false
    @State private var deleting: SavedCustomEndpoint?
    @State private var busy:String?
    @State private var failure:String?

    var body: some View {
        List {
            Section("Persistent OpenAI-compatible endpoints") {
                if snapshot == nil && failure == nil { ProgressView("Loading endpoints…") }
                else if let snapshot, snapshot.endpoints.isEmpty { Text("No saved custom endpoints for this profile.").foregroundStyle(.secondary) }
                else if let snapshot { ForEach(snapshot.endpoints) { endpoint in
                    VStack(alignment:.leading,spacing:6) {
                        HStack { Text(endpoint.name).font(.subheadline.weight(.medium)); Spacer(); if endpoint.isCurrent { Text("ACTIVE").font(.caption2.weight(.bold)).foregroundStyle(.green) } }
                        Text(endpoint.baseURL).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(endpoint.model).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing:7) { if endpoint.hasAPIKey { Label(endpoint.APIKeyPreview.isEmpty ? "key set" : endpoint.APIKeyPreview,systemImage:"key.fill") }; Text(endpoint.discoverModels ? "model discovery" : "fixed model") }.font(.caption2).foregroundStyle(.tertiary)
                        HStack(spacing:8) {
                            if !endpoint.isCurrent { Button("Use") { Task { await activate(endpoint) } } }
                            Button("Edit") { editing=endpoint }
                            Button("Delete",role:.destructive) { deleting=endpoint }
                            if busy == endpoint.id { ProgressView() }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(.vertical,3)
                } }
            }
            if let snapshot { Section("Current model route") { LabeledContent("Provider",value:snapshot.currentProvider.isEmpty ? "None" : snapshot.currentProvider); LabeledContent("Model",value:snapshot.currentModel.isEmpty ? "None" : snapshot.currentModel); if !snapshot.currentBaseURL.isEmpty { Text(snapshot.currentBaseURL).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) } } }
            if let failure { Section("Last error") { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .navigationTitle("Saved Endpoints").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(Palette.background(scheme))
        .task { await load() }.refreshableWithFeedback { await load() }
        .toolbar { ToolbarItem(placement:.primaryAction) { Button { adding=true } label:{Image(systemName:"plus")}.accessibilityLabel("Add custom endpoint") } }
        .sheet(isPresented:$adding){ EndpointEditor(profile:profile, endpoint:nil){await load()}.environment(store).preferredColorScheme(store.theme.colorScheme) }
        .sheet(item:$editing){ endpoint in EndpointEditor(profile:profile, endpoint:endpoint){await load()}.environment(store).preferredColorScheme(store.theme.colorScheme) }
        .confirmationDialog("Delete saved endpoint?",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}}),titleVisibility:.visible){Button("Delete",role:.destructive){if let deleting{Task{await remove(deleting)}}};Button("Cancel",role:.cancel){deleting=nil}} message:{Text("The provider entry and its dedicated stored credential will be removed. If it is the active model route, Hermes also detaches that route.")}
    }
    private func load() async { do { snapshot=try await store.savedCustomEndpoints(profile:profile); failure=nil } catch { failure=reason(error) } }
    private func activate(_ endpoint:SavedCustomEndpoint) async { busy=endpoint.id;defer{busy=nil};do{try await store.activateCustomEndpoint(endpoint.id,profile:profile);await load()}catch{failure=reason(error)} }
    private func remove(_ endpoint:SavedCustomEndpoint) async { deleting=nil;busy=endpoint.id;defer{busy=nil};do{try await store.deleteCustomEndpoint(endpoint.id,profile:profile);await load()}catch{failure=reason(error)} }
    private func reason(_ error:Error)->String{(error as? LocalizedError)?.errorDescription ?? "Hermes did not answer."}
}

private struct EndpointEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let profile:String
    let endpoint:SavedCustomEndpoint?
    let saved:() async -> Void
    @State private var name=""
    @State private var baseURL=""
    @State private var model=""
    @State private var apiKey=""
    @State private var contextLength=""
    @State private var discover=true
    @State private var makeDefault=false
    @State private var validation:CustomEndpointValidation?
    @State private var busy=false
    @State private var failure:String?
    var body:some View{NavigationStack{Form{
        Section("Endpoint") { TextField("Name",text:$name); TextField("https://host.example/v1",text:$baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL); TextField("Model ID",text:$model).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField(endpoint?.hasAPIKey == true ? "New API key (leave blank to keep existing)" : "API key (optional)",text:$apiKey).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Context length (optional)",text:$contextLength).keyboardType(.numberPad); Toggle("Discover models from /models",isOn:$discover); Toggle("Make this the profile default",isOn:$makeDefault) }
        Section("Connection test") { Button("Validate /models") { Task{await validate()} }.disabled(!basicValid||busy); if let validation { Label(validation.ok ? "Endpoint accepted" : (validation.reachable ? "Endpoint rejected configuration" : "Endpoint unreachable"),systemImage:validation.ok ? "checkmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(validation.ok ? Color.green : Color.orange); if !validation.message.isEmpty{Text(validation.message).font(.caption).foregroundStyle(.secondary)}; if !validation.models.isEmpty{Text("Models: \(validation.models.prefix(8).joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)} } }
        Section { Text("API keys are write-only. Alice sends a new value directly to Hermes and never saves it in local preferences. Leaving the field blank while editing preserves the existing key.").font(.caption).foregroundStyle(.secondary) }
        if let failure{Section{Text(failure).font(.footnote).foregroundStyle(.red)}}
    }.navigationTitle(endpoint == nil ? "Add Endpoint":"Edit Endpoint").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(Palette.background(scheme)).toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){if busy{ProgressView()}else{Button("Save"){Task{await save()}}.disabled(!basicValid)}}}.task{guard name.isEmpty else{return};if let endpoint{name=endpoint.name;baseURL=endpoint.baseURL;model=endpoint.model;contextLength=endpoint.contextLength.map(String.init) ?? "";discover=endpoint.discoverModels}}}}
    private var basicValid:Bool{guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let u=URL(string:baseURL),["http","https"].contains(u.scheme?.lowercased() ?? ""),u.host != nil else{return false};return true}
    private var context:Int?{Int(contextLength.trimmingCharacters(in:.whitespacesAndNewlines))}
    private func validate()async{busy=true;defer{busy=false};do{validation=try await store.validateCustomEndpoint(name:name,baseURL:baseURL,model:model,apiKey:apiKey.isEmpty ? nil:apiKey,contextLength:context,discoverModels:discover);failure=nil}catch{failure=reason(error)}}
    private func save()async{busy=true;defer{busy=false};do{_ = try await store.saveCustomEndpoint(id:endpoint?.id ?? "",name:name,baseURL:baseURL,model:model,apiKey:apiKey.isEmpty ? nil:apiKey,contextLength:context,discoverModels:discover,makeDefault:makeDefault,profile:profile);await saved();dismiss()}catch{failure=reason(error)}}
    private func reason(_ error:Error)->String{(error as? LocalizedError)?.errorDescription ?? "Hermes rejected this endpoint."}
}
