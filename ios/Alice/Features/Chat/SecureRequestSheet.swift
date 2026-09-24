import SwiftUI

/// Hermes asking for something only the person can type, as a native secure
/// sheet: the login for the site an agent is signing into (saved in Hermes'
/// vault, bound to that exact site, filled without the agent ever seeing the
/// password), the code a site just sent, a password manager's master password,
/// or a key. iOS offers its own saved passwords and fills texted codes; what is
/// typed goes straight to Hermes and is never kept here or shown in the chat.
struct SecureRequestSheet: View {
    let request: SecureRequest

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var identifier = ""
    @State private var secret = ""
    @State private var working = false
    @State private var failed = false
    @State private var answered = false
    /// A login Hermes asks for is either an account he has or one to create:
    /// the vault asks the same way for both, so he says which.
    @State private var newAccount = false
    @FocusState private var focus: Field?

    private enum Field { case identifier, secret }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(store.accent.primary(scheme))
                            .frame(width: 44, height: 44)
                            .background(store.accent.primary(scheme).opacity(0.12), in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.headline)
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)

                Section {
                    fields
                } footer: {
                    Text(footer)
                }

                if failed {
                    Text("Hermes is no longer waiting for this. Ask Alice to try again.")
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                }
            }
            .aliceFormPaper(scheme)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { Task { await send("") } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(confirmTitle) { Task { await send(answer) } }
                            .disabled(!ready)
                    }
                }
            }
            .onAppear { focus = needsIdentifier ? .identifier : .secret }
            .onDisappear {
                // Swiped away: "not now", so Hermes is not left waiting on it.
                guard !answered else { return }
                Task { _ = await store.answerSecureRequest(request, value: "") }
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var fields: some View {
        switch request.kind {
        case .saveLogin:
            Picker("Account", selection: $newAccount) {
                Text("I have an account").tag(false)
                Text("Create one").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            TextField(newAccount ? LocalizedStringKey("Email for the new account") : LocalizedStringKey("Email or username"), text: $identifier)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .identifier)
                .submitLabel(.next)
                .onSubmit { focus = .secret }
            SecureField(newAccount ? LocalizedStringKey("New password") : LocalizedStringKey("Password"), text: $secret)
                // A new account gets iOS' own strong-password suggestion.
                .textContentType(newAccount ? .newPassword : .password)
                .focused($focus, equals: .secret)
                .submitLabel(.go)
                .onSubmit { if ready { Task { await send(answer) } } }
        case .code:
            TextField("Code", text: $secret)
                .textContentType(.oneTimeCode)
                .keyboardType(.asciiCapableNumberPad)
                .font(.title2.monospacedDigit())
                .focused($focus, equals: .secret)
        case .unlock, .secret:
            SecureField(prompt, text: $secret)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .secret)
                .submitLabel(.done)
                .onSubmit { if ready { Task { await send(answer) } } }
        }
    }

    // MARK: Words

    private var host: String {
        if case let .saveLogin(origin, _) = request.kind {
            return URL(string: origin)?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? origin
        }
        return ""
    }

    private var symbol: String {
        switch request.kind {
        case .saveLogin: "person.badge.key.fill"
        case .code: "number.circle.fill"
        case .unlock: "lock.open.fill"
        case .secret: "key.fill"
        }
    }

    private var title: String {
        switch request.kind {
        case .saveLogin: newAccount ? String(localized: "Create an account on \(host)") : String(localized: "Sign in to \(host)")
        case let .code(site, _): site.map { String(localized: "Code from \($0)") } ?? String(localized: "Verification code")
        case let .unlock(manager): String(localized: "Unlock \(manager)")
        case let .secret(name, _): name
        }
    }

    private var subtitle: String {
        switch request.kind {
        case .saveLogin: newAccount
            ? String(localized: "Choose the email and password. Alice fills in the rest of the form and asks you for what is missing.")
            : String(localized: "Alice needs your account to continue. No account? Choose “Create one”.")
        case let .code(_, hint): hint ?? String(localized: "Type the code the site just sent you.")
        case .unlock: String(localized: "For Alice to use the logins it keeps.")
        case let .secret(_, prompt): prompt.isEmpty ? String(localized: "A key Alice needs.") : prompt
        }
    }

    private var prompt: String {
        if case let .unlock(manager) = request.kind { return String(localized: "\(manager) master password") }
        return String(localized: "Key")
    }

    private var footer: String {
        switch request.kind {
        case .saveLogin:
            String(localized: "Saved encrypted in Hermes on your Mac, for \(host) only. Alice fills it in without ever seeing it, and it never appears in the chat.")
        case .code:
            String(localized: "Goes straight into the page. It never appears in the chat.")
        case .unlock:
            String(localized: "Used once to unlock it on your Mac, and not kept.")
        case .secret:
            String(localized: "Saved in Hermes on your Mac. It never appears in the chat.")
        }
    }

    private var confirmTitle: String {
        switch request.kind {
        case .saveLogin: newAccount ? String(localized: "Create Account") : String(localized: "Sign In")
        case .code: String(localized: "Send")
        case .unlock: String(localized: "Unlock")
        case .secret: String(localized: "Save")
        }
    }

    // MARK: Answer

    private var needsIdentifier: Bool {
        if case .saveLogin = request.kind { return true }
        return false
    }

    private var ready: Bool {
        !secret.isEmpty && (!needsIdentifier || !identifier.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var answer: String {
        switch request.kind {
        case .saveLogin:
            SecureRequest.loginAnswer(identifier: identifier.trimmingCharacters(in: .whitespaces), password: secret)
        case .code:
            secret.filter { !$0.isWhitespace }
        case .unlock, .secret:
            secret
        }
    }

    private func send(_ value: String) async {
        guard !answered else { return }
        answered = true
        working = true
        let delivered = await store.answerSecureRequest(request, value: value)
        // Nothing typed stays in memory longer than it must.
        secret = ""
        identifier = ""
        working = false
        if !delivered && !value.isEmpty { failed = true }
        // The vault answer is the same for both; only this says it is a new
        // account. No secret in it: the site, and what to do.
        if delivered, !value.isEmpty, newAccount, case .saveLogin = request.kind {
            store.sendAppNote("The person has no account on \(host): create it with the email and password they just gave. Ask only for what the form needs and they have not given.")
        }
    }
}
