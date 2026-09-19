import SwiftUI

struct PairingAdminScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var profiles: [(id: String, label: String)] = [("default", "Alice")]
    @State private var profile = "default"
    @State private var snapshot: PairingSnapshot?
    @State private var loading = false
    @State private var failure: String?
    @State private var code = ""
    @State private var codePlatform = "telegram"
    @State private var revoke: PairingUser?
    @State private var clearing = false

    var body: some View {
        List {
            Section("Profile") {
                Picker("Bot", selection: $profile) {
                    ForEach(profiles, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
            Section("Pending") {
                if loading && snapshot == nil { ProgressView("Loading pairing requests…") }
                else if let snapshot, snapshot.pending.isEmpty { Text("No pending pairing requests.").foregroundStyle(.secondary) }
                else if let snapshot {
                    ForEach(snapshot.pending) { user in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(user.userName ?? user.userID, systemImage: "person.crop.circle.badge.questionmark")
                                Spacer()
                                Text(user.platform).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            if let age = user.ageMinutes { Text("Requested \(Int(age)) min ago").font(.caption).foregroundStyle(.secondary) }
                            Button("Approve") { Task { await approve(user) } }.buttonStyle(.borderedProminent).controlSize(.small)
                        }.padding(.vertical, 3)
                    }
                }
            }
            Section("Approve a code") {
                Picker("Platform", selection: $codePlatform) {
                    ForEach(["telegram", "discord", "slack", "whatsapp", "matrix", "signal", "sms", "email"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("Pairing code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Approve code") { Task { await approveCode() } }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Approved") {
                if let snapshot, snapshot.approved.isEmpty { Text("No approved users.").foregroundStyle(.secondary) }
                else if let snapshot {
                    ForEach(snapshot.approved) { user in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.userName ?? user.userID)
                                Text("\(user.platform) · \(user.userID)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button(role: .destructive) { revoke = user } label: { Image(systemName: "person.crop.circle.badge.minus") }
                        }
                    }
                }
            }
            if let snapshot, !snapshot.pending.isEmpty {
                Section {
                    Button("Clear all pending requests", role: .destructive) { clearing = true }
                } footer: {
                    Text("This only removes pending requests for the selected profile. Approved users are unchanged.")
                }
            }
            if let failure { Section("Last error") { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .navigationTitle("Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await loadProfiles(); await load() }
        .onChange(of: profile) { _, _ in snapshot = nil; Task { await load() } }
        .refreshableWithFeedback { await load() }
        .confirmationDialog("Revoke this user?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { if let revoke { Task { await revokeUser(revoke) } } }
            Button("Cancel", role: .cancel) { revoke = nil }
        } message: { Text("Hermes will stop accepting messages from this identity until it is paired again.") }
        .confirmationDialog("Clear all pending requests?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear pending", role: .destructive) { Task { await clearPending() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadProfiles() async {
        do { profiles = try await store.routineProfiles().map { ($0.id, $0.label) } }
        catch { profiles = [("default", "Alice")] }
        if !profiles.contains(where: { $0.id == profile }) { profile = profiles.first?.id ?? "default" }
    }
    private func load() async { loading = true; defer { loading = false }; do { snapshot = try await store.pairing(profile: profile); failure = nil } catch { failure = reason(error) } }
    private func approve(_ user: PairingUser) async { do { try await store.approvePairing(platform: user.platform, requestID: user.requestID, profile: profile); await load() } catch { failure = reason(error) } }
    private func approveCode() async { let c = code.trimmingCharacters(in: .whitespacesAndNewlines); do { try await store.approvePairing(platform: codePlatform, code: c, profile: profile); code = ""; await load() } catch { failure = reason(error) } }
    private func revokeUser(_ user: PairingUser) async { revoke = nil; do { try await store.revokePairing(platform: user.platform, userID: user.userID, profile: profile); await load() } catch { failure = reason(error) } }
    private func clearPending() async { do { _ = try await store.clearPendingPairing(profile: profile); await load() } catch { failure = reason(error) } }
    private func reason(_ error: Error) -> String { PlainWords.describe(error) }
}
