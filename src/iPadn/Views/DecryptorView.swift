import SwiftUI

struct DecryptorView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.scenePhase) private var scenePhase
    @State private var apps: [NativeInstaller.InstalledApp] = []
    @State private var listings: [String: StoreApp] = [:]
    @State private var loading = false
    @State private var loaded = false
    @State private var issue: String?
    @State private var term = ""
    @State private var credential: Data?
    @State private var busy: Set<String> = []
    @State private var rowStatus: [String: String] = [:]
    @State private var encryptedFlag: [String: Bool] = [:]
    @State private var pendingInstall: PendingInstall?
    @State private var installPhase: NativeInstaller.Phase?

    struct PendingInstall: Identifiable {
        let url: URL
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    private var paired: Bool { NativeInstaller.hasPairingFile || LocalResources.isPreview }

    var body: some View {
        List {
            if !paired {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 40, weight: .regular)).foregroundStyle(.secondary)
                        Text("Pair for Native Install First").font(.headline)
                        Text("The decryptor reads the apps installed on this device and reinstalls the DRM-free version through the native installation. Complete the one-time pairing to use it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    NavigationLink { InstallationSettingsView() } label: { Label("Open Installation Settings", systemImage: "arrow.down.app") }
                }
            } else if let issue, apps.isEmpty {
                Section { InlineIssue(message: issue) }
            } else if loading && apps.isEmpty {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text("Reading apps on this device…").foregroundStyle(.secondary) }
                }
            } else {
                appsSection
            }
        }
        .toolPage().navigationTitle(Text("Decryptor")).navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .compatibleOnChange(of: scenePhase) { phase in
            if phase == .active, issue != nil, apps.isEmpty { Task { await load() } }
        }
        .actionConfirmation(isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }),
                            title: "Install the DRM-free version?",
                            message: "The decrypted package is saved. Install it over the current app through the native installation? The App Store can still update it afterwards.",
                            confirmTitle: "Install now") { installPending() }
        .overlay {
            if installPhase != nil {
                ProgressView(phaseText).padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }


    @ViewBuilder private var appsSection: some View {
        if !apps.isEmpty {
            Section {
                SearchInput(text: $term, placeholder: "Search installed apps", capsule: true)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
        let shown = visible
        Section {
            ForEach(shown.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending },
                    id: \.identity) { app in
                row(app)
            }
            if loaded && shown.isEmpty {
                Text(apps.isEmpty ? "No apps to show" : "No matching apps").foregroundStyle(.secondary)
            }
        } header: {
            Text("Installed apps") + Text(verbatim: " · \(shown.count)")
        } footer: {
            Text("Tap Decrypt and iPadn fetches the app’s encrypted package with the current download account (reusing the local copy when present), decrypts it right on the phone and saves the DRM-free package. Only for apps you are licensed to use.")
        }
    }

    private var visible: [NativeInstaller.InstalledApp] {
        let query = term.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            query.isEmpty || (app.name ?? "").localizedCaseInsensitiveContains(query)
                || (app.bundleID ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder private func row(_ app: NativeInstaller.InstalledApp) -> some View {
        let bundleID = app.bundleID ?? app.storeItemID ?? UUID().uuidString
        let listing = app.storeItemID.flatMap { listings[$0] }
        let shown = StoreApp(id: app.storeItemID ?? bundleID, name: listing?.name ?? app.name ?? app.bundleID ?? "",
                             bundleID: app.bundleID ?? "", version: app.version ?? "",
                             iconURL: listing?.iconURL)
        let busyHere = busy.contains(bundleID)
        AppRow(app: shown,
               subtitle: rowStatus[bundleID] ?? ((app.version ?? "").isEmpty ? (app.bundleID ?? "") : AppText.text("Installed \(app.version ?? "")")),
               badge: badge(for: bundleID)) {
            Button {
                UX.feedback()
                Task { await decrypt(app, bundleID: bundleID) }
            } label: {
                if busyHere { ProgressView().controlSize(.small) } else {
                    Text("Decrypt").font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(busyHere)
            .accessibilityIdentifier("decryptor.decrypt." + bundleID)
        }
    }

    private func badge(for bundleID: String) -> (text: LocalizedStringKey, tint: Color)? {
        if let encrypted = encryptedFlag[bundleID] {
            return encrypted ? (LocalizedStringKey("cryptid=1"), .orange) : (LocalizedStringKey("DRM-free"), .green)
        }
        return nil
    }


    private func load() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        credential = FairPlayCredentialStore.load()
        if credential == nil {
            credential = await FairPlayCredentialStore.fetchFromEndpoint()
        }
        #if DEBUG
        if LocalResources.isPreview {
            apps = InstalledAppsView.previewApps
            listings = InstalledAppsView.previewListings
            issue = nil
            return
        }
        #endif
        do {
            let found = try await NativeInstaller.installedApps().filter { $0.placeholder != true }
            apps = found
            issue = nil
            let ids = found.compactMap(\.storeItemID)
            if !ids.isEmpty, let result = try? await StoreService.lookup(ids: ids, country: store.watchCountry) {
                listings = result.apps
            }
            await probeEncryption()
        } catch is CancellationError {
        } catch { issue = error.localizedDescription }
    }

    private func probeEncryption() async {
        let completed = store.downloads.jobs.filter { $0.status == .completed && $0.rawFormat == nil }
        var flags: [String: Bool] = [:]
        for job in completed.prefix(40) {
            let bundleID = job.app.bundleID
            guard !bundleID.isEmpty, flags[bundleID] == nil,
                  let filename = job.localFilename, let url = LocalResources.packageURL(filename) else { continue }
            let state = try? FairPlayDecryptor.ipaEncryptionState(at: url)
            flags[bundleID] = state?.encrypted ?? false
        }
        encryptedFlag = flags
    }



    private func decrypt(_ app: NativeInstaller.InstalledApp, bundleID: String) async {
        guard !busy.contains(bundleID) else { return }
        busy.insert(bundleID)
        defer { busy.remove(bundleID) }
        do {
            guard apple.active != nil else { throw ToolError.message(AppText.text("Sign in with an Apple account first to fetch the app’s encrypted package")) }
            let url = try await resolvePackage(app, bundleID: bundleID)
            rowStatus[bundleID] = AppText.text("Checking package encryption…")
            let state = try FairPlayDecryptor.ipaEncryptionState(at: url)
            let encrypted = state.encrypted
            encryptedFlag[bundleID] = encrypted
            if !encrypted {
                try await finishClearPackage(url, app: app, bundleID: bundleID)
                return
            }
            rowStatus[bundleID] = AppText.text("Preparing the FairPlay license…")
            guard let credential = await acquireCredential() else {
                rowStatus[bundleID] = AppText.text("FairPlay key unavailable for this account")
                throw ToolError.message(AppText.text("This app is FairPlay-encrypted and the account’s license key isn’t available on the device yet. The decryptor fetches it automatically; tap Decrypt again in a moment."))
            }
            rowStatus[bundleID] = AppText.text("Decrypting…")
            let listing = app.storeItemID.flatMap { listings[$0] }
            let name = listing?.name ?? app.name ?? app.bundleID ?? "App"
            let version = listing?.version ?? app.version ?? ""
            var outputName = "\(PackageService.safeName(name))-\(PackageService.safeName(version.isEmpty ? "1.0" : version))-DRM-free.ipa"
            if LocalResources.packageURL(outputName) != nil {
                outputName = "\(PackageService.safeName(name))-\(UUID().uuidString.prefix(6))-DRM-free.ipa"
            }
            let destination = LocalResources.packages.appendingPathComponent(outputName)
            try? FileManager.default.createDirectory(at: LocalResources.packages, withIntermediateDirectories: true)
            let result = try FairPlayDecryptor.decryptIPA(at: url, credential: credential, destination: destination)
            let pages = result.binaries.reduce(0) { $0 + $1.pages }
            encryptedFlag[bundleID] = false
            rowStatus[bundleID] = nil
            UX.feedback()
            store.infoMessage = AppText.text("Decrypted (\(pages) pages): \(outputName)")
            pendingInstall = PendingInstall(url: destination, bundleID: app.bundleID ?? "", name: name)
        } catch is CancellationError {
            rowStatus[bundleID] = nil
        } catch {
            rowStatus[bundleID] = nil
            store.errorMessage = error.localizedDescription
        }
    }

    private func acquireCredential() async -> Data? {
        if let existing = FairPlayCredentialStore.load() { return existing }
        let fetched = await FairPlayCredentialStore.fetchFromEndpoint()
        if let fetched { credential = fetched }
        return fetched
    }

    private func finishClearPackage(_ url: URL, app: NativeInstaller.InstalledApp, bundleID: String) async throws {
        let listing = app.storeItemID.flatMap { listings[$0] }
        let name = listing?.name ?? app.name ?? app.bundleID ?? "App"
        let version = listing?.version ?? app.version ?? ""
        var outputName = "\(PackageService.safeName(name))-\(PackageService.safeName(version.isEmpty ? "1.0" : version))-DRM-free.ipa"
        if LocalResources.packageURL(outputName) != nil {
            outputName = "\(PackageService.safeName(name))-\(UUID().uuidString.prefix(6))-DRM-free.ipa"
        }
        let destination = LocalResources.packages.appendingPathComponent(outputName)
        try? FileManager.default.createDirectory(at: LocalResources.packages, withIntermediateDirectories: true)
        let result = try FairPlayDecryptor.clearIPA(at: url, destination: destination)
        rowStatus[bundleID] = nil
        UX.feedback()
        store.infoMessage = AppText.text(result.stripped ? "DRM-free package saved (no FairPlay layers): \(outputName)" : "DRM-free package saved: \(outputName)")
        pendingInstall = PendingInstall(url: destination, bundleID: app.bundleID ?? "", name: name)
    }

    private func resolvePackage(_ app: NativeInstaller.InstalledApp, bundleID: String) async throws -> URL {
        if let job = store.downloads.jobs.first(where: { $0.status == .completed && $0.rawFormat == nil && $0.app.bundleID == bundleID }),
           let filename = job.localFilename, let url = LocalResources.packageURL(filename) {
            return url
        }
        guard let storeItemID = app.storeItemID, UInt64(storeItemID).map({ $0 > 0 }) == true else {
            throw ToolError.message(AppText.text("This app has no store record, so the encrypted package cannot be fetched"))
        }
        rowStatus[bundleID] = AppText.text("Downloading the encrypted package…")
        var target = listings[storeItemID] ?? StoreApp(id: storeItemID, name: app.name ?? storeItemID,
                                                       bundleID: bundleID, version: app.version ?? "")
        if target.bundleID.isEmpty { target.bundleID = bundleID }
        let result = await store.startDownloads([target]) { _ in }
        if result.added == 0 {
            throw ToolError.message(result.failures.joined(separator: "\n"))
        }
        let deadline = Date().addingTimeInterval(60 * 60)
        while Date() < deadline, !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let job = store.downloads.jobs.first(where: { $0.app.bundleID == bundleID }) else { continue }
            switch job.status {
            case .completed:
                guard let filename = job.localFilename, let url = LocalResources.packageURL(filename) else {
                    throw ToolError.message(AppText.text("The downloaded package is unusable, please try again"))
                }
                return url
            case .failed:
                throw ToolError.message(job.error ?? AppText.text("Download failed"))
            case .paused, .pausing:
                continue
            default:
                rowStatus[bundleID] = AppText.text("Downloading the encrypted package… \(Int(job.progress * 100))")
            }
        }
        throw ToolError.message(AppText.text("Download timed out, retry later from the downloads page"))
    }

    private func installPending() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        Task {
            installPhase = .connecting
            defer { installPhase = nil }
            do {
                let outcome = try await NativeInstaller.install(package: pending.url, bundleID: pending.bundleID) { phase in
                    Task { @MainActor in installPhase = phase }
                }
                UX.feedback()
                store.infoMessage = outcome.upgraded ? AppText.text("The DRM-free version replaced the installed app") : AppText.text("The DRM-free version is installed")
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private var phaseText: String {
        switch installPhase {
        case .connecting: return AppText.text("Connecting…")
        case .uploading(let fraction): return AppText.text("Transferring… \(Int(fraction * 100))")
        case .installing(let fraction): return AppText.text("Installing… \(Int(fraction * 100))")
        case nil: return ""
        }
    }
}
