import SwiftUI
import UniformTypeIdentifiers

/// One-click FairPlay removal: lists the apps installed on this device and
/// strips cryptid=1 from their store packages, fully on-device. Needs the
/// account's 16-byte FairPlay credential once (imported in the first card);
/// afterwards every decryption is a single tap — the package is downloaded
/// with the signed-in account if it is not on the device yet, decrypted with
/// the SINF/SUPF license the store ships, and can be reinstalled DRM-free
/// through the native installation connection.
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
    @State private var hexInput = ""
    @State private var importing = false
    @State private var savingCredential = false
    @State private var busy: Set<String> = []
    @State private var rowStatus: [String: String] = [:]
    @State private var encryptedFlag: [String: Bool] = [:]
    @State private var pendingInstall: PendingInstall?
    @State private var installPhase: NativeInstaller.Phase?
    @State private var confirmRemoveCredential = false

    struct PendingInstall: Identifiable {
        let url: URL
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    static var isSupported: Bool {
        InstalledAppsView.isSupported
    }

    private var paired: Bool { NativeInstaller.hasPairingFile || LocalResources.isPreview }

    var body: some View {
        List {
            credentialSection
            if !paired {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 40, weight: .regular)).foregroundStyle(.secondary)
                        Text("需要先完成原生安装配对").font(.headline)
                        Text("解密器读取本机已装的应用，并借助原生安装重装无 DRM 的版本。完成一次配对后即可使用。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    NavigationLink { InstallationSettingsView() } label: { Label("前往安装设置", systemImage: "arrow.down.app") }
                }
            } else if let issue, apps.isEmpty {
                Section { InlineIssue(message: issue) }
            } else if loading && apps.isEmpty {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text("正在读取本机应用…").foregroundStyle(.secondary) }
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let parsed = FairPlayCredentialStore.parseFile(at: url) {
                save(parsed)
            } else {
                store.errorMessage = AppText.text("无法识别凭据文件：需要 credential.bin 或 32 位十六进制")
            }
        }
        .actionConfirmation(isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }),
                            title: "安装无 DRM 版本？",
                            message: "解密后的安装包已保存。现在通过原生安装覆盖安装这个版本吗？App Store 之后仍可正常更新。",
                            confirmTitle: "立即安装") { installPending() }
        .actionConfirmation(isPresented: $confirmRemoveCredential,
                            title: "移除凭据？",
                            message: "移除后解密需要重新导入凭据。",
                            confirmTitle: "移除") {
            FairPlayCredentialStore.remove()
            credential = nil
        }
    }

    // MARK: - Credential card

    @ViewBuilder private var credentialSection: some View {
        Section {
            if let credential {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FairPlay 凭据已就绪").font(.body.weight(.medium))
                        Text(verbatim: credential.map { byte in String(format: "%02X", byte) }.joined().prefix(8) + "…")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { confirmRemoveCredential = true } label: { Text("移除") }
                        .buttonStyle(.borderless)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.orange).font(.title3)
                        Text("还没有 FairPlay 凭据").font(.body.weight(.medium))
                    }
                    Text("凭据由 Apple ID 一次性生成：运行 fp-credential 工作流（登录你的 Apple ID）下载 credential.bin，或粘贴 32 位十六进制到这里。之后解密任何应用都只需一次点按。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField(AppText.text("粘贴 32 位十六进制凭据"), text: $hexInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button { if let parsed = FairPlayCredentialStore.parse(hexInput) { save(parsed) } else {
                            store.errorMessage = AppText.text("凭据无效：需要 16 字节（32 位十六进制）")
                        } } label: { Text("保存") }
                            .buttonStyle(CapsuleButtonStyle()).disabled(hexInput.trimmingCharacters(in: .whitespaces).isEmpty || savingCredential)
                        Button { importing = true } label: { Label("导入文件", systemImage: "doc") }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
            }
        } header: { Text("FairPlay 凭据") } footer: {
            Text("凭据保存在钥匙串，只在本机使用。它对应导入时所用 Apple ID 账号。")
        }
    }

    // MARK: - Apps

    @ViewBuilder private var appsSection: some View {
        if !apps.isEmpty {
            Section {
                SearchInput(text: $term, placeholder: "搜索已装应用", capsule: true)
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
                Text(apps.isEmpty ? "没有可显示的应用" : "没有匹配的应用").foregroundStyle(.secondary)
            }
        } header: {
            Text("已装应用") + Text(verbatim: " · \(shown.count)")
        } footer: {
            Text("点按「解密」后 iPadn 会用当前下载账号取得该应用的加密安装包（本地已有则直接使用），在手机上完成解密并保存无 DRM 的安装包。仅用于解密你拥有许可的应用。")
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
               subtitle: rowStatus[bundleID] ?? ((app.version ?? "").isEmpty ? (app.bundleID ?? "") : AppText.text("已装 \(app.version ?? "")")),
               badge: badge(for: bundleID)) {
            Button {
                UX.feedback()
                Task { await decrypt(app, bundleID: bundleID) }
            } label: {
                if busyHere { ProgressView().controlSize(.small) } else {
                    Text("解密").font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(busyHere || credential == nil)
            .accessibilityIdentifier("decryptor.decrypt." + bundleID)
        }
    }

    private func badge(for bundleID: String) -> (text: LocalizedStringKey, tint: Color)? {
        if let encrypted = encryptedFlag[bundleID] {
            return encrypted ? (LocalizedStringKey("cryptid=1"), .orange) : (LocalizedStringKey("无 DRM"), .green)
        }
        return nil
    }

    // MARK: - Data loading

    private func load() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        credential = FairPlayCredentialStore.load()
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

    /// Marks which installed apps already have a downloaded, still-encrypted
    /// store package on the device.
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

    // MARK: - Decrypt pipeline

    private func save(_ parsed: Data) {
        savingCredential = true
        defer { savingCredential = false }
        do {
            try FairPlayCredentialStore.save(parsed)
            credential = parsed
            hexInput = ""
            UX.feedback()
            store.infoMessage = AppText.text("已保存 FairPlay 凭据")
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func decrypt(_ app: NativeInstaller.InstalledApp, bundleID: String) async {
        guard let credential else {
            store.errorMessage = AppText.text("请先导入 FairPlay 凭据")
            return
        }
        guard !busy.contains(bundleID) else { return }
        busy.insert(bundleID)
        defer { busy.remove(bundleID) }
        do {
            guard apple.active != nil else { throw ToolError.message(AppText.text("需要先登录 Apple 账号才能取得应用的加密安装包")) }
            let url = try await resolvePackage(app, bundleID: bundleID)
            rowStatus[bundleID] = AppText.text("正在解密…")
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
            store.infoMessage = AppText.text("解密完成（\(pages) 页）：\(outputName)")
            pendingInstall = PendingInstall(url: destination, bundleID: app.bundleID ?? "", name: name)
        } catch is CancellationError {
            rowStatus[bundleID] = nil
        } catch {
            rowStatus[bundleID] = nil
            store.errorMessage = error.localizedDescription
        }
    }

    /// The encrypted store package for an installed app: the already
    /// downloaded one, else a fresh authorized download for the same version.
    private func resolvePackage(_ app: NativeInstaller.InstalledApp, bundleID: String) async throws -> URL {
        if let job = store.downloads.jobs.first(where: { $0.status == .completed && $0.rawFormat == nil && $0.app.bundleID == bundleID }),
           let filename = job.localFilename, let url = LocalResources.packageURL(filename) {
            return url
        }
        guard let storeItemID = app.storeItemID, UInt64(storeItemID).map({ $0 > 0 }) == true else {
            throw ToolError.message(AppText.text("此应用没有商店记录，无法取得加密安装包"))
        }
        rowStatus[bundleID] = AppText.text("正在下载加密安装包…")
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
                    throw ToolError.message(AppText.text("下载的安装包不可用，请重试"))
                }
                return url
            case .failed:
                throw ToolError.message(job.error ?? AppText.text("下载失败"))
            case .paused, .pausing:
                continue
            default:
                rowStatus[bundleID] = AppText.text("正在下载加密安装包… \(Int(job.progress * 100))")
            }
        }
        throw ToolError.message(AppText.text("下载超时，请稍后在下载页重试"))
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
                store.infoMessage = outcome.upgraded ? AppText.text("无 DRM 版本已覆盖安装") : AppText.text("无 DRM 版本已安装")
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
