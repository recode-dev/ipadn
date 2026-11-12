import SwiftUI

struct InstalledAppsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var apps: [NativeInstaller.InstalledApp] = []
    @State private var listings: [String: StoreApp] = [:]
    @State private var loading = false
    @State private var loaded = false
    @State private var issue: String?
    @State private var term = ""
    @State private var updating = false

    static var isSupported: Bool {
        NativeInstaller.listingIsAvailable
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))
    }

    enum Group: CaseIterable {
        case update, link, store, other
    }

    private var paired: Bool { NativeInstaller.hasPairingFile || LocalResources.isPreview }

    private func listing(_ app: NativeInstaller.InstalledApp) -> StoreApp? { app.storeItemID.flatMap { listings[$0] } }

    func group(of app: NativeInstaller.InstalledApp) -> Group {
        if app.manifestInstall == true { return .link }
        if !app.updatesBlocked, let latest = listing(app), let installed = app.version,
           Self.isUpdate(latest, installed: installed, versionID: app.storeVersionID) { return .update }
        return app.storeItemID != nil ? .store : .other
    }

    static func isUpdate(_ latest: StoreApp, installed: String, versionID: String?) -> Bool {
        if let versionID, let current = latest.externalVersionID, versionID == current { return false }
        if latest.version.hasPrefix(installed + ".") { return false }
        return VersionOrder.isNewer(latest.version, than: installed)
    }

    private var visible: [NativeInstaller.InstalledApp] {
        let query = term.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            query.isEmpty || (app.name ?? "").localizedCaseInsensitiveContains(query)
                || (app.bundleID ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let shown = visible
        let grouped = Dictionary(grouping: shown, by: group(of:))
        List {
            if !paired {
                requirement(title: "Pair for Native Install First",
                            message: "Apps on This Device reads the apps installed on this phone through Native Install. Pair once in Installation settings to use it.",
                            retry: false)
            } else if let issue, apps.isEmpty {
                requirement(title: "Connect LocalDevVPN",
                            message: "Apps on This Device reads installed apps through LocalDevVPN. Open LocalDevVPN and tap Connect; iPadn reads the list when you come back.",
                            retry: true, detail: issue)
            } else if loading && apps.isEmpty {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text("Reading apps on this device…").foregroundStyle(.secondary) }
                }
            } else {
                if !apps.isEmpty {
                    Section {
                        SearchInput(text: $term, placeholder: "Search installed apps", capsule: true)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }
                section(.update, grouped[.update] ?? [])
                section(.link, grouped[.link] ?? [])
                section(.store, grouped[.store] ?? [])
                section(.other, grouped[.other] ?? [])
                if loaded && shown.isEmpty {
                    Section { Text(apps.isEmpty ? "No apps to show" : "No matching apps").foregroundStyle(.secondary) }
                }
                if loaded {
                    Section {} footer: {
                        Text("The list of installed apps is read on this device only. To check for updates, iPadn asks Apple for these apps’ store versions.")
                    }
                }
            }
        }
        .toolPage().navigationTitle("Apps on This Device").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .compatibleOnChange(of: scenePhase) { phase in
            if phase == .active, issue != nil, apps.isEmpty { Task { await load() } }
        }
        .overlay { if updating { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }

    @ViewBuilder private func requirement(title: LocalizedStringKey, message: LocalizedStringKey, retry: Bool, detail: String? = nil) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .regular)).foregroundStyle(.secondary)
                    .padding(.bottom, 2).accessibilityHidden(true)
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if retry {
                    Button { Task { await load() } } label: {
                        if loading { ProgressView() } else { Text("Try Again") }
                    }
                    .buttonStyle(CapsuleButtonStyle()).disabled(loading).padding(.top, 4)
                    .accessibilityIdentifier("installed.retry")
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            NavigationLink { InstallationSettingsView() } label: { Label("Open Installation Settings", systemImage: "arrow.down.app") }
        } footer: {
            if let detail { Text(detail) }
        }
    }

    @ViewBuilder private func section(_ kind: Group, _ rows: [NativeInstaller.InstalledApp]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending },
                        id: \.identity) { app in row(app, kind: kind) }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(kind)) + Text(verbatim: " · \(rows.count)")
                    Spacer()
                    if kind == .update && rows.count > 1 {
                        Button("Update All") { updateAll(rows) }
                            .font(.body.weight(.semibold)).textCase(nil).buttonStyle(.borderless)
                            .disabled(updating)
                            .accessibilityIdentifier("installed.update-all")
                    }
                }
            } footer: {
                switch kind {
                case .link: Text("These were installed from a link, so the App Store shows a cloud and can’t update them. Install once more with Native Install to fix it; data is kept.")
                case .other: Text("Apps installed with other signing tools. The App Store can’t update them.")
                default: EmptyView()
                }
            }
        }
    }

    private func title(_ kind: Group) -> LocalizedStringKey {
        switch kind {
        case .update: return "Updates Available"
        case .link: return "Not Recognized by the App Store"
        case .store: return "From the App Store"
        case .other: return "Other Sources"
        }
    }

    @ViewBuilder private func row(_ app: NativeInstaller.InstalledApp, kind: Group) -> some View {
        let latest = listing(app)
        let installed = app.version ?? ""
        let subtitle = kind == .update
            ? AppText.text("Installed \(installed), store has \(latest?.version ?? "")")
            : app.updatesBlocked ? AppText.text("Installed \(installed) · Updates blocked")
            : (installed.isEmpty ? (app.bundleID ?? "") : AppText.text("Installed \(installed)"))
        let shown = StoreApp(id: app.storeItemID ?? app.bundleID ?? "", name: latest?.name ?? app.name ?? app.bundleID ?? "",
                             bundleID: app.bundleID ?? "", version: installed, iconURL: latest?.iconURL)
        if let latest {
            NavigationLink { AppDetailView(app: latest) } label: { AppRow(app: shown, subtitle: subtitle) }
        } else {
            AppRow(app: shown, subtitle: subtitle)
        }
    }

    private func load() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        #if DEBUG
        if LocalResources.isPreview { apps = Self.previewApps; listings = Self.previewListings; issue = nil; return }
        #endif
        do {
            let found = try await NativeInstaller.installedApps().filter { $0.placeholder != true }
            apps = found
            issue = nil
            let ids = found.compactMap(\.storeItemID)
            if !ids.isEmpty, let result = try? await StoreService.lookup(ids: ids, country: store.watchCountry) {
                listings = result.apps
            }
        } catch is CancellationError {
        } catch { issue = error.localizedDescription }
    }

    private func updateAll(_ rows: [NativeInstaller.InstalledApp]) {
        let targets = rows.compactMap(listing)
        guard !targets.isEmpty else { return }
        updating = true
        UX.feedback()
        Task {
            defer { updating = false }
            let result = await store.startDownloads(targets) { _ in }
            if result.added > 0 { store.infoMessage = AppText.text("Added \(result.added) downloads") }
            if !result.failures.isEmpty { store.errorMessage = result.failures.joined(separator: "\n") }
        }
    }

    #if DEBUG
    static var previewApps: [NativeInstaller.InstalledApp] {
        let apps = PreviewData.updatable
        func make(_ app: StoreApp, version: String, link: Bool = false) -> NativeInstaller.InstalledApp {
            var installed = NativeInstaller.InstalledApp(installed: true)
            installed.bundleID = app.bundleID; installed.name = app.name; installed.version = version
            installed.storeItemID = app.id; installed.hasPurchaseRecord = !link; installed.manifestInstall = link
            return installed
        }
        var other = NativeInstaller.InstalledApp(installed: true)
        other.bundleID = "com.example.tool"; other.name = "LocalDevVPN"; other.version = "1.2"
        return [make(apps[0], version: "26.4.0"), make(apps[1], version: "9.1.98", link: true), make(apps[2], version: "1.7.353"), other]
    }
    static var previewListings: [String: StoreApp] {
        Dictionary(uniqueKeysWithValues: PreviewData.updatable.map { app in
            var latest = app
            if app.id == PreviewData.updatable[0].id { latest.version = "26.5.0" }
            return (app.id, latest)
        })
    }
    #endif
}

extension NativeInstaller.InstalledApp {
    var identity: String { bundleID ?? storeItemID ?? UUID().uuidString }
}
