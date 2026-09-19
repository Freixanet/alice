import SwiftUI

struct SystemExtrasScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var pool:[CredentialPoolProvider]=[]
    @State private var hooks=HermesHooksSnapshot(hooks:[],validEvents:[])
    @State private var curator:HermesCuratorStatus?
    @State private var portal:HermesPortalStatus?
    @State private var computer:HermesComputerUseStatus?
    @State private var terminal: HermesTerminalBackends?
    @State private var profiles:[(id:String,label:String)]=[("default","Alice")]
    @State private var profile="default"
    @State private var loading=false
    @State private var failure:String?
    @State private var addingCredential=false
    @State private var addingHook=false
    @State private var removeCredential:CredentialRemoval?
    @State private var removeHook:HermesHook?
    @State private var activeAction:HermesActionStart?
    @State private var actionStatus:HermesActionStatus?
    @State private var debugConfirm=false
    @State private var debugResult:HermesDebugShare?
    @State private var memoryReset:String?
    @State private var permissionConfirm=false

    var body:some View{List{
        portalSection
        curatorSection
        terminalSection
        Section("Learning") {
            NavigationLink { LearningScreen() } label: {
                Label("Learned skills & memory graph", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Text("Inspect, edit or remove the profile-scoped nodes Hermes has learned over time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        computerSection
        credentialsSection
        hooksSection
        diagnosticsSection
        if let activeAction { Section("Current operation") { actionView(activeAction) } }
        if let debugResult { Section("Debug share") { ForEach(debugResult.urls,id:\.self){url in Text(url).font(.caption.monospaced()).textSelection(.enabled)}; if !debugResult.failures.isEmpty{Text(debugResult.failures.joined(separator:"\n")).font(.caption).foregroundStyle(.orange)}; Text(debugResult.redacted ? "Report redaction enabled. Hermes also uploaded the requested log bundle." : "Redaction was disabled.").font(.caption2).foregroundStyle(.secondary) } }
        if let failure{Section("Last error"){Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled)}}
    }.navigationTitle("Advanced Operations").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(Palette.background(scheme)).task{await loadProfiles();await load()}.task(id:activeAction?.name){await pollAction()}.onChange(of:profile){_,_ in Task{await loadComputer()}}.refreshableWithFeedback{await load()}
    .sheet(isPresented:$addingCredential){CredentialAddSheet{provider,key,label in try await store.addCredentialPool(provider:provider,apiKey:key,label:label);await loadPool()}.preferredColorScheme(store.theme.colorScheme)}
    .sheet(isPresented:$addingHook){HookAddSheet(events:hooks.validEvents){event,command,matcher,timeout,approve in try await store.createHook(event:event,command:command,matcher:matcher,timeout:timeout,approve:approve);await loadHooks()}.preferredColorScheme(store.theme.colorScheme)}
    .confirmationDialog("Remove credential?",isPresented:Binding(get:{removeCredential != nil},set:{if !$0{removeCredential=nil}}),titleVisibility:.visible){Button("Remove credential",role:.destructive){if let r=removeCredential{Task{await deleteCredential(r)}}};Button("Cancel",role:.cancel){removeCredential=nil}} message:{Text("Hermes may also clean or suppress the credential's backing source (for example an environment or OAuth source) so it does not immediately reappear.")}
    .confirmationDialog("Delete shell hook?",isPresented:Binding(get:{removeHook != nil},set:{if !$0{removeHook=nil}}),titleVisibility:.visible){Button("Delete hook",role:.destructive){if let h=removeHook{Task{await deleteHook(h)}}};Button("Cancel",role:.cancel){removeHook=nil}} message:{Text("Hermes will remove the hook from config and revoke its consent entry.")}
    .confirmationDialog("Upload a debug bundle?",isPresented:$debugConfirm,titleVisibility:.visible){Button("Upload redacted debug bundle"){Task{await shareDebug()}};Button("Cancel",role:.cancel){}} message:{Text("Hermes will upload a redacted diagnostic report and the requested logs to its paste service and return shareable URLs. Do not use this if the logs contain information you do not want uploaded.")}
    .confirmationDialog("Reset built-in memory?",isPresented:Binding(get:{memoryReset != nil},set:{if !$0{memoryReset=nil}}),titleVisibility:.visible){if let target=memoryReset{Button(target=="all" ? "Delete USER.md + MEMORY.md":"Delete \(target.uppercased()).md",role:.destructive){Task{await resetMemory(target)}}};Button("Cancel",role:.cancel){memoryReset=nil}} message:{Text("This permanently deletes the selected built-in memory file(s) from Hermes. External memory providers are not reset.")}
    .confirmationDialog("Request Mac permissions?",isPresented:$permissionConfirm,titleVisibility:.visible){Button("Request permissions"){Task{await grantPermissions()}};Button("Cancel",role:.cancel){}} message:{Text("Hermes will launch CuaDriver on the Mac. macOS may display Accessibility or Screen Recording permission dialogs on that Mac.")}
    }

    private var portalSection:some View{Section("Nous Portal"){if let portal{HStack{Label(portal.loggedIn ? "Connected":"Not connected",systemImage:portal.loggedIn ? "checkmark.circle.fill":"circle").foregroundStyle(portal.loggedIn ? .green:.secondary);Spacer();if !portal.provider.isEmpty{Text(portal.provider).font(.caption).foregroundStyle(.secondary)}};ForEach(portal.features){f in LabeledContent(f.label,value:f.state)};if let u=portal.portalURL{Text(u).font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)}}else{ProgressView()}}}
    private var curatorSection:some View{Section("Curator"){if let curator{HStack{VStack(alignment:.leading,spacing:2){Text(curator.enabled ? "Skill curator enabled":"Skill curator disabled");if let h=curator.intervalHours{Text("Review every \(Int(h)) hours").font(.caption).foregroundStyle(.secondary)}};Spacer();Toggle("Paused",isOn:Binding(get:{curator.paused},set:{v in Task{await pauseCurator(v)}})).labelsHidden()};if let last=curator.lastRunAt{LabeledContent("Last run",value:last)};Button("Run curator now"){Task{await runCurator()}}.disabled(!curator.enabled || activeAction != nil)}else{ProgressView()}}}
    private var terminalSection: some View {
        Section("Terminal backend") {
            if let terminal {
                Picker("Execution backend", selection: Binding(
                    get: { terminal.active },
                    set: { value in Task { await changeTerminal(value) } }
                )) {
                    ForEach(terminal.backends) { backend in Text(backend.label).tag(backend.name) }
                }
                if let active = terminal.backends.first(where: { $0.name == terminal.active }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(active.status.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(active.status == "ready" ? Color.green : Color.orange); Spacer(); Text(active.name).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        Text(active.detail).font(.caption).foregroundStyle(.secondary)
                        if !active.statusDetail.isEmpty { Text(active.statusDetail).font(.caption2).foregroundStyle(.orange) }
                    }
                }
                ForEach(terminal.backends.filter { $0.name != terminal.active && $0.status != "ready" }) { backend in
                    DisclosureGroup("\(backend.label) · \(backend.status)") {
                        Text(backend.statusDetail.isEmpty ? backend.detail : backend.statusDetail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { ProgressView() }
        }
    }

    private var computerSection:some View{Section("Computer Use"){Picker("Profile",selection:$profile){ForEach(profiles,id:\.id){Text($0.label).tag($0.id)}};if let computer{HStack{Label(computer.ready ? "Ready":"Not ready",systemImage:computer.ready ? "checkmark.circle.fill":"display.trianglebadge.exclamationmark").foregroundStyle(computer.ready ? Color.green : Color.orange);Spacer();if let v=computer.version{Text(v).font(.caption2).foregroundStyle(.secondary)}};ForEach(computer.checks){c in VStack(alignment:.leading,spacing:2){HStack{Text(c.label);Spacer();Text(c.status.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(c.status=="ok" ? Color.green : Color.orange)};Text(c.message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)}};if computer.canGrant && !computer.ready{Button("Request macOS permissions"){permissionConfirm = true}}}else{ProgressView()}}}
    private var credentialsSection:some View{Section("Credential pools"){Text("Secrets stay redacted. Adding supports manual API keys; interactive OAuth pooling remains a Hermes CLI flow.").font(.caption).foregroundStyle(.secondary);ForEach(pool){provider in DisclosureGroup("\(provider.provider) · \(provider.entries.count)"){ForEach(provider.entries){entry in VStack(alignment:.leading,spacing:4){HStack{Text(entry.label ?? entry.identifier ?? "Credential");Spacer();if let status=entry.lastStatus{Text(status.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(status=="ok" ? Color.green : Color.orange)}};Text([entry.authType,entry.source,entry.tokenPreview].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary);Button("Remove",role:.destructive){removeCredential = .init(provider:provider.provider,entry:entry)}.controlSize(.small)}}}};Button("Add API key"){addingCredential = true}}}
    private var hooksSection:some View{Section("Shell hooks"){Text("Hooks can execute arbitrary host commands on Hermes lifecycle events. Approved hooks run automatically on matching events.").font(.caption).foregroundStyle(.orange);if hooks.hooks.isEmpty{Text("No shell hooks configured.").foregroundStyle(.secondary)}else{ForEach(hooks.hooks){h in VStack(alignment:.leading,spacing:4){HStack{Text(h.event).font(.subheadline.weight(.medium));Spacer();Text(h.allowed ? "APPROVED":"NOT APPROVED").font(.caption2.weight(.bold)).foregroundStyle(h.allowed ? Color.green : Color.orange)};Text(h.command).font(.caption.monospaced()).textSelection(.enabled);if let m=h.matcher{Text("Matcher: \(m)").font(.caption2).foregroundStyle(.secondary)};Button("Delete",role:.destructive){removeHook = h}.controlSize(.small)}}};Button("Add shell hook"){addingHook = true}.disabled(hooks.validEvents.isEmpty)} }
    private var diagnosticsSection:some View{Section("More diagnostics"){Button("Migrate Hermes configuration"){Task{await configMigrate()}};Button("Create shareable debug bundle"){debugConfirm = true};Menu("Reset built-in memory"){Button("MEMORY.md",role:.destructive){memoryReset = "memory"};Button("USER.md",role:.destructive){memoryReset = "user"};Button("Both",role:.destructive){memoryReset = "all"}}} }
    @ViewBuilder private func actionView(_ action:HermesActionStart)->some View{if let status=actionStatus{HStack{Text(status.name);Spacer();Text(status.running ? "RUNNING":(status.exitCode==0 ? "DONE":"FAILED")).font(.caption2.weight(.bold)).foregroundStyle(status.running ? Color.orange : (status.exitCode == 0 ? Color.green : Color.red))};if !status.lines.isEmpty{ScrollView(.horizontal){Text(status.lines.joined(separator:"\n")).font(.caption2.monospaced()).textSelection(.enabled).frame(minWidth:500,alignment:.leading)}};if !status.running{Button("Close"){activeAction=nil;actionStatus=nil}}}else{ProgressView("Starting \(action.name)…")}}

    private func loadProfiles()async{do{profiles=try await store.routineProfiles().map{($0.id,$0.label)}}catch{profiles=[("default","Alice")]}}
    private func load() async {
        loading = true
        defer { loading = false }
        async let p: HermesPortalStatus? = try? store.portalStatus()
        async let c: HermesCuratorStatus? = try? store.curatorStatus()
        async let cp: [CredentialPoolProvider]? = try? store.credentialPool()
        async let h: HermesHooksSnapshot? = try? store.hooks()
        async let cu: HermesComputerUseStatus? = try? store.computerUseStatus(profile: profile)
        async let tb: HermesTerminalBackends? = try? store.terminalBackends(profile: profile)
        let r = await (p, c, cp, h, cu, tb)
        portal = r.0; curator = r.1
        if let value = r.2 { pool = value }
        if let value = r.3 { hooks = value }
        computer = r.4; terminal = r.5
        if [r.0 == nil, r.1 == nil, r.2 == nil, r.3 == nil, r.4 == nil, r.5 == nil].allSatisfy({ $0 }) {
            failure = "Hermes did not return advanced operations state."
        } else { failure = nil }
    }
    private func loadPool()async{do{pool=try await store.credentialPool()}catch{failure=reason(error)}}
    private func loadHooks()async{do{hooks=try await store.hooks()}catch{failure=reason(error)}}
    private func loadComputer() async {
        do {
            async let computerValue = store.computerUseStatus(profile: profile)
            async let terminalValue = store.terminalBackends(profile: profile)
            (computer, terminal) = try await (computerValue, terminalValue)
        } catch { failure = reason(error) }
    }
    private func changeTerminal(_ backend: String) async {
        do {
            try await store.setTerminalBackend(backend, profile: profile)
            terminal = try await store.terminalBackends(profile: profile)
            failure = nil
        } catch { failure = reason(error) }
    }
    private func pauseCurator(_ paused:Bool)async{do{try await store.setCuratorPaused(paused);curator=try await store.curatorStatus()}catch{failure=reason(error)}}
    private func runCurator()async{do{activeAction=try await store.runCurator();actionStatus=nil}catch{failure=reason(error)}}
    private func configMigrate()async{do{activeAction=try await store.runConfigMigration();actionStatus=nil}catch{failure=reason(error)}}
    private func grantPermissions()async{do{activeAction=try await store.grantComputerUsePermissions(profile:profile);actionStatus=nil}catch{failure=reason(error)}}
    private func pollAction()async{guard let name=activeAction?.name else{return};while !Task.isCancelled{do{let s=try await store.hermesActionStatus(name,lines:300);guard activeAction?.name==name else{return};actionStatus=s;if !s.running{if name=="computer-use-grant"{await loadComputer()};if name=="curator-run"{curator=try? await store.curatorStatus()};return}}catch{failure=reason(error)};try? await Task.sleep(for:.milliseconds(1200))}}
    private func deleteCredential(_ r:CredentialRemoval)async{removeCredential=nil;do{try await store.removeCredentialPool(provider:r.provider,index:r.entry.index);await loadPool()}catch{failure=reason(error)}}
    private func deleteHook(_ h:HermesHook)async{removeHook=nil;do{try await store.deleteHook(event:h.event,command:h.command);await loadHooks()}catch{failure=reason(error)}}
    private func shareDebug()async{do{debugResult=try await store.debugShare(lines:500,redact:true);failure=nil}catch{failure=reason(error)}}
    private func resetMemory(_ target:String)async{memoryReset=nil;do{let deleted=try await store.resetBuiltinMemory(target:target);failure=deleted.isEmpty ? "No matching built-in memory files existed." : nil}catch{failure=reason(error)}}
    private func reason(_ error:Error)->String{PlainWords.describe(error)}
}

private struct CredentialRemoval:Identifiable{var id:String{"\(provider)|\(entry.index)"};var provider:String;var entry:CredentialPoolEntry}

private struct CredentialAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ""
    @State private var label = ""
    @State private var key = ""
    @State private var busy = false
    @State private var failure: String?
    let save: (String, String, String?) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Manual API key") {
                    TextField("Provider ID", text: $provider)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Label (optional)", text: $label)
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("Alice never stores this key. Hermes adds it to the provider's credential pool on the host.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Credential")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() }
                    else { Button("Add") { Task { await run() } }.disabled(provider.trimmingCharacters(in: .whitespaces).isEmpty || key.isEmpty) }
                }
            }
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        do {
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try await save(provider.trimmingCharacters(in: .whitespacesAndNewlines), key, cleanLabel.isEmpty ? nil : cleanLabel)
            dismiss()
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "Hermes rejected the credential." }
    }
}

private struct HookAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let events: [String]
    let save: (String, String, String?, Int?, Bool) async throws -> Void
    @State private var event = ""
    @State private var command = ""
    @State private var matcher = ""
    @State private var timeout = ""
    @State private var approve = true
    @State private var confirm = false
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Hook") {
                    Picker("Event", selection: $event) {
                        Text("Choose…").tag("")
                        ForEach(events, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.body.monospaced()).lineLimit(2...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Matcher (optional)", text: $matcher)
                    TextField("Timeout seconds (optional)", text: $timeout).keyboardType(.numberPad)
                    Toggle("Approve immediately", isOn: $approve)
                }
                Section {
                    Text("An approved hook can execute this shell command automatically on the Mac when its event fires. Treat the command as executable code.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Shell Hook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() }
                    else { Button("Add") { confirm = true }.disabled(event.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
            .confirmationDialog("Allow this host command?", isPresented: $confirm, titleVisibility: .visible) {
                Button(approve ? "Add & approve" : "Add without approval") { Task { await run() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text(command) }
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        do {
            try await save(event, command, matcher.isEmpty ? nil : matcher, Int(timeout), approve)
            dismiss()
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "Hermes rejected the hook." }
    }
}
