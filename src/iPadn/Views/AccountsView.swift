import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleting: AppleAccount?
    @State private var signingOut = false
    @State private var headerAway = false
    var body: some View {
        List {
            Section {
                PageHeader(title: "Account")
                    .onScrolledUnderBar { headerAway = $0 }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let error = apple.accountStorageError { Section { InlineIssue(message: error) } }
            Section {
                if let account = apple.active {
                    HStack(spacing: 14) {
                        AccountAvatar(account: account, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name.isEmpty ? account.id : account.name).font(.title3.weight(.semibold)).lineLimit(1)
                            Text(account.id).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if let country = StoreService.country(forStorefront: account.storeFront) {
                                Text("Storefront: \(country)").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }.padding(.vertical, 6)
                } else {
                    NavigationLink { LoginView() } label: {
                        HStack(spacing: 14) {
                            AccountAvatar(account: nil, size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sign in to your Apple Account").font(.title3.weight(.semibold))
                                Text("Sync purchases and download apps you're licensed to use").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            if !apple.accounts.isEmpty {
                Section {
                    ForEach(apple.accounts) { account in
                        Button {
                            guard apple.activeID != account.id else { return }
                            apple.select(account.id); UX.feedback()
                        } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(account: account, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name.isEmpty ? account.id : account.name).foregroundStyle(.primary).lineLimit(1)
                                    if !account.name.isEmpty { Text(account.id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 8)
                                if account.id == apple.activeID {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                                        .accessibilityLabel("Current account")
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(RevealRowButtonStyle())
                        .accessibilityHint(account.id == apple.activeID ? AppText.text("Current download account") : AppText.text("Switch to this account"))
                        .accessibilityIdentifier("account." + account.id)
                        .disabled(store.accountRemoving != nil)
                        .revealDelete(id: "account." + account.id, enabled: store.accountRemoving == nil,
                                      grouping: account.id == apple.accounts.first?.id ? .first : .middle,
                                      separatorInset: 68, title: "Remove") { deleting = account }
                    }
                    NavigationLink { LoginView() } label: { Label("Add account", systemImage: "plus") }
                } header: { Text("Account") } footer: { Text("Tap to switch the download account; swipe to remove.") }
            }
            Section {
                Button { store.tab = 2 } label: { Label("Purchased", systemImage: "bag") }
                Button { store.tab = 1 } label: { Label("Downloads & installation", systemImage: "arrow.down.circle") }
                if InstalledAppsView.isSupported {
                    NavigationLink { InstalledAppsView() } label: { Label("Apps on This Device", systemImage: "iphone") }
                    NavigationLink { WiFiTransferView() } label: { Label("Wi‑Fi Transfer", systemImage: "laptopcomputer.and.arrow.down") }
                        .accessibilityIdentifier("account.wifi-transfer")
                        .accessibilityIdentifier("accounts.installed-apps")
                }
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("accounts.settings")
            }
            if apple.active != nil {
                Section { Button("Sign out", role: .destructive) { signingOut = true }.frame(maxWidth: .infinity) }
            }
            if DecryptorView.isSupported {
                Section {
                    NavigationLink { DecryptorView() } label: { Label("Decryptor", systemImage: "checkmark.shield") }
                        .accessibilityIdentifier("accounts.decryptor")
                } footer: {
                    Text("One-tap FairPlay removal (cryptid=1) for installed apps — builds a DRM-free package right on the phone.")
                }
            }
        }
        .animation(UX.motion(reduceMotion), value: apple.accounts.map(\.id))
        .overlay { if store.accountRemoving != nil { ProgressView("Removing the account…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .toolPage().rootTabBar("Account", headerScrolledAway: headerAway)
        .actionConfirmation(isPresented: $signingOut, title: "Sign out of this account?", message: "The account is kept; you can switch back at any time.", confirmTitle: "Sign out") { apple.select(nil) }
        .actionConfirmation(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), title: "Remove account?", message: removalMessage, confirmTitle: "Remove account") {
            guard let id = deleting?.id else { return }
            Task {
                do { try await store.deleteAccount(id); store.infoMessage = AppText.text("Account removed") } catch { store.errorMessage = error.localizedDescription }
            }
            deleting = nil
        }
    }

    private var removalMessage: LocalizedStringKey {
        let id = deleting?.id ?? ""
        return deleting?.id == apple.activeID
            ? "\(id)\nThis is the active download account; removing it signs you out.\nDownloaded packages are kept."
            : "\(id)\nDownloaded packages are kept."
    }
}

struct VerificationStep: View {
    let account: String
    @Binding var code: String
    let busy: Bool
    let issue: String?
    var submitTitle = AppText.text("Verify")
    var sent = true
    var resend: (() -> Void)? = nil
    let submit: () -> Void
    var changeAccount: (() -> Void)? = nil
    @State private var showingHelp = false
    @State private var resendAvailableAt = Date().addingTimeInterval(30)
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.tint)
                .padding(.top, 12).accessibilityHidden(true)
            Text("Two-factor authentication").font(.title.weight(.bold))
            Text(sent ? "Apple sent a sign-in request to the trusted devices of “\(account)”. Tap Allow on the device to see a 6-digit code, then enter it to continue."
                 : "Asking Apple to send a code to the trusted devices of “\(account)”…")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VerificationCodeField(code: $code, disabled: busy) { _ in submit() }
                .padding(.vertical, 6)
            if busy {
                HStack(spacing: 8) { ProgressView(); Text("Verifying…").font(.subheadline).foregroundStyle(.secondary) }
            } else if let issue {
                Text(issue).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: submit) { Text(submitTitle).frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || code.count != 6)
                .accessibilityIdentifier("apple.verification.submit")
            if let resend {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "Resend Code (\(wait) s)" : "Resend Code") {
                        resendAvailableAt = Date().addingTimeInterval(30)
                        resend()
                    }
                    .font(.subheadline).disabled(busy || !sent || wait > 0)
                    .accessibilityIdentifier("apple.verification.resend")
                }
            }
            Button("Didn't get a code?") { showingHelp = true }.font(.subheadline)
            if let changeAccount {
                Button("Change account or password", action: changeAccount).font(.subheadline).disabled(busy)
            }
        }
        .alert("Get a verification code", isPresented: $showingHelp) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The code goes to the iPhone, iPad or Mac signed into this Apple account - not by SMS.\n1. On that device, tap Allow when the Apple Account sign-in request appears.\n2. If nothing appears, get a code on that device under Settings › [Your Name] › Sign-In & Security › Get Verification Code; it works here too.\n3. Still nothing? Tap Resend. When requests come too often Apple may pause them for a while.\n\nFree downloads can also ask for verification because Apple accounts require a password for free apps. On a device signed into the account open Settings › Media & Purchases › Password Settings and turn off Require Password for free downloads (not shown when buying with Face ID).")
        }
    }
}

struct LoginView: View {
    let initialAccountID: String?
    let onSignedIn: (() -> Void)?
    init(initialAccountID: String? = nil, onSignedIn: (() -> Void)? = nil) {
        self.initialAccountID = initialAccountID
        self.onSignedIn = onSignedIn
        _email = State(initialValue: initialAccountID ?? "")
    }
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var verifying = false
    @State private var failure: String?
    @State private var loginTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case email, password }
    private var canSubmit: Bool {
        !busy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && (!verifying || code.count == 6)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if verifying {
                    VerificationStep(account: email.trimmingCharacters(in: .whitespacesAndNewlines), code: $code,
                                     busy: busy, issue: failure, submitTitle: AppText.text("Verify and sign in"), resend: resendCode, submit: submit,
                                     changeAccount: { verifying = false; code = ""; failure = nil; focus = .password })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    credentials.transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.compatibleSnappy, value: verifying)
            .frame(maxWidth: 460).padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            if busy { ToolbarItem(placement: .compatibleTopBarTrailing) { Button("Cancel") { loginTask?.cancel() } } }
        }
        .onDisappear { loginTask?.cancel() }
    }

    private var credentials: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(initialAccountID == nil ? "Sign in to your Apple Account" : "Sign in again").font(.title.weight(.bold))
                Text(initialAccountID == nil ? "Syncs purchases and downloads apps you're licensed to use."
                     : "The current sign-in expired. Enter the password this account uses now.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.top, 12)
            VStack(spacing: 0) {
                TextField("Email or phone number", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .email).submitLabel(.next).onSubmit { focus = .password }
                    .padding(.horizontal, 16).frame(minHeight: 50)
                Divider().padding(.leading, 16)
                SecureField("Password", text: $password).textContentType(.password)
                    .focused($focus, equals: .password).submitLabel(.go)
                    .onSubmit { if canSubmit { submit() } }
                    .padding(.horizontal, 16).frame(minHeight: 50)
            }
            .disabled(busy)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(UX.onAccent) }
                    Text(busy ? "Signing in…" : "Resume")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(!canSubmit)
            Label("Your account details are stored only on this device.", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .onAppear { if email.isEmpty { focus = .email } else if password.isEmpty { focus = .password } }
    }

    private func resendCode() {
        guard !busy else { return }
        busy = true; failure = nil; code = ""
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                try await apple.login(email: email, password: password, code: "", useCache: store.settings.useSignerCache)
                password = ""; UX.success(); onSignedIn?(); dismiss()
            } catch AppleLoginError.verificationRequired {
                failure = nil
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil; busy = true; failure = nil
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                try await apple.login(email: email, password: password, code: verifying ? code : "", useCache: store.settings.useSignerCache)
                password = ""; code = ""; UX.success(); onSignedIn?(); dismiss()
            } catch AppleLoginError.verificationRequired {
                verifying = true; code = ""
            } catch is CancellationError {
                failure = AppText.text("Sign-in cancelled. You can try again.")
            } catch {
                failure = error.localizedDescription
                code = ""
            }
        }
    }
}

struct ExistingAccountVerificationView: View {
    @MainActor private static var lastSilentSignIn: Date?
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    let onVerified: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VerificationStep(account: accountID, code: $code, busy: busy, issue: issue,
                                 submitTitle: AppText.text("Verify and continue"), sent: sent, resend: requestCode, submit: verify)
                    .frame(maxWidth: 460).padding(24).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
            .task { requestCode() }
        }
    }

    private func requestCode() {
        guard !busy else { return }
        busy = true; issue = nil; sent = false
        Task {
            defer { busy = false }
            do {
                if try await apple.requestVerificationCode(expectedID: accountID, useCache: store.settings.useSignerCache) {
                    sent = true
                } else if let last = Self.lastSilentSignIn, Date().timeIntervalSince(last) < 60 {
                    Self.lastSilentSignIn = nil
                    sent = true
                    issue = AppText.text("Apple still requires verification for this account. On a device signed in to it, open Settings › [your name] › Sign-In & Security › Get Verification Code and enter the code shown.")
                } else {
                    Self.lastSilentSignIn = Date()
                    UX.success(); onVerified(); dismiss()
                }
            } catch is CancellationError {
                issue = AppText.text("The request was cancelled. You can tap “Resend Code”."); sent = true
            } catch {
                issue = error.localizedDescription; sent = true
            }
        }
    }

    private func verify() {
        guard !busy, code.count == 6 else { return }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                try await apple.verifyCurrentAccount(code: code, expectedID: accountID, useCache: store.settings.useSignerCache)
                code = ""; UX.success()
                onVerified()
                dismiss()
            } catch is CancellationError {
                issue = AppText.text("Verification cancelled. Try again.")
            } catch {
                issue = error.localizedDescription
                code = ""
            }
        }
    }
}
