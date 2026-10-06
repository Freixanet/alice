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
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var identifier = ""
    @State private var secret = ""
    @State private var working = false
    @State private var failed = false
    @State private var answered = false
    /// The site's authenticator key, given once so codes are never asked again.
    @State private var authenticatorKey = ""
    @State private var usingKey = false
    @State private var keyProblem: String?
    /// A login Hermes asks for is either an account he has or one to create:
    /// the vault asks the same way for both, so he says which.
    @State private var newAccount = false
    @FocusState private var focus: Field?

    private enum Field { case identifier, secret }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if textSize.isAccessibilitySize {
                        Text(title).font(.headline)
                    } else {
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
                }
                .listRowBackground(Color.clear)

                if needsIdentifier {
                    Section {
                        accountChoice
                    }
                }

                Section {
                    fields
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if textSize.isAccessibilitySize { Text(subtitle) }
                        Text(footer)
                    }
                }

                if let keyProblem {
                    Text(keyProblem)
                        .font(.footnote)
                        .foregroundStyle(Palette.danger(scheme))
                }
                if failed {
                    Text("Could not deliver the secure answer. Check the connection and try again.")
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
            // Let the person see the account choice before the keyboard takes
            // space away from it. Codes and single secrets can focus directly.
            .onAppear { if !needsIdentifier { focus = .secret } }
            .onDisappear {
                // Swiped away: "not now", so Hermes is not left waiting on it.
                guard !answered else { return }
                Task { _ = await store.answerSecureRequest(request, value: "") }
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    @ViewBuilder
    private var accountChoice: some View {
        if textSize.isAccessibilitySize {
            Button { newAccount = false } label: {
                Label("I have an account", systemImage: newAccount ? "circle" : "checkmark.circle.fill")
            }
            .accessibilityAddTraits(newAccount ? [] : .isSelected)
            Button { newAccount = true } label: {
                Label("Create one", systemImage: newAccount ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityAddTraits(newAccount ? .isSelected : [])
        } else {
            Picker("Account", selection: $newAccount) {
                Text("I have an account").tag(false)
                Text("Create one").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch request.kind {
        case .saveLogin:
            TextField(newAccount ? LocalizedStringKey("Email for the new account") : LocalizedStringKey("Email or username"), text: $identifier)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .identifier)
                .submitLabel(.next)
                .onSubmit { focus = .secret }
            if let problem = identifierProblem, !problem.isEmpty, focus != .identifier {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
            SecureField(newAccount ? LocalizedStringKey("New password") : LocalizedStringKey("Password"), text: $secret)
                // A new account gets iOS' own strong-password suggestion.
                .textContentType(newAccount ? .newPassword : .password)
                .focused($focus, equals: .secret)
                .submitLabel(.go)
                .onSubmit { if ready { Task { await send(answer) } } }
        case let .code(site, _):
            if usingKey {
                SecureField("Setup key or otpauth:// link", text: $authenticatorKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .secret)
            } else {
                TextField("Code", text: $secret)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.asciiCapableNumberPad)
                    .font(.title2.monospacedDigit())
                    .focused($focus, equals: .secret)
            }
            if site != nil && request.errandID == nil {
                Button(usingKey ? String(localized: "Type a code instead") : String(localized: "Never ask me for codes here")) {
                    withMotion { usingKey.toggle() }
                    focus = .secret
                }
                .font(.subheadline)
            }
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
            usingKey
                ? String(localized: "Paste the key the site gives when you set up an authenticator app (\"setup key\" or \"can't scan the code?\"). It is kept encrypted with this login in Hermes on your Mac, and Alice makes the codes herself from now on.")
                : String(localized: "Goes straight into the page. It never appears in the chat.")
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
        if usingKey { return !authenticatorKey.trimmingCharacters(in: .whitespaces).isEmpty }
        return !secret.isEmpty && (!needsIdentifier || identifierProblem == nil)
    }

    /// Why the email or username cannot be used, or nil. A new account needs a
    /// real email; anything typed with an `@` must be one too. A plain name is
    /// a username.
    private var identifierProblem: String? {
        let typed = identifier.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return "" }
        let isEmail = typed.wholeMatch(of: /[^@\s]+@[^@\s]+\.[A-Za-z]{2,}/) != nil
        if (newAccount || typed.contains("@")) && !isEmail { return "That is not a valid email." }
        return nil
    }

    private var answer: String {
        switch request.kind {
        case .saveLogin:
            SecureRequest.loginAnswer(identifier: identifier.trimmingCharacters(in: .whitespaces), password: secret)
        case .code:
            usingKey ? authenticatorKey : secret.filter { !$0.isWhitespace }
        case .unlock, .secret:
            secret
        }
    }

    private func send(_ value: String) async {
        // A key instead of a code: saved with the login on the Mac, which
        // answers with this moment's code — the sign-in goes on at once.
        if usingKey, !value.isEmpty, case let .code(site?, _) = request.kind {
            working = true
            do {
                let code = try await store.saveAuthenticatorKey(
                    site: site, key: authenticatorKey.trimmingCharacters(in: .whitespacesAndNewlines))
                authenticatorKey = ""
                working = false
                usingKey = false
                await send(code)
            } catch {
                Haptic.error.play()
                working = false
                keyProblem = PlainWords.describe(error, doing: "save the key")
            }
            return
        }
        guard !answered else { return }
        answered = true
        failed = false
        working = true
        let delivered = await store.answerSecureRequest(request, value: value, accountAction: newAccount ? "create" : "login")
        // Nothing typed stays in memory longer than it must.
        secret = ""
        identifier = ""
        working = false
        if !delivered {
            answered = false
            if !value.isEmpty { failed = true }
        }
        // Declining (an empty answer) is not an outcome worth a touch.
        if !value.isEmpty { (delivered ? Haptic.success : Haptic.error).play() }
        // The vault answer is the same for both; only this says it is a new
        // account. No secret in it: the site, and what to do.
        if delivered, !value.isEmpty, newAccount, request.errandID == nil, case .saveLogin = request.kind {
            store.sendAppNote("The person has no account on \(host): create it with the email and password they just gave. Ask only for what the form needs and they have not given.")
        }
    }
}
