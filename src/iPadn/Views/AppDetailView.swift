import SwiftUI
import UIKit

struct AppDetailView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    let app: StoreApp
    var autoStart = false
    @State private var autoStarted = false
    @State private var versions: [AppVersion] = []
    @State private var versionsLoading = false
    @State private var downloadLoading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var manualID = ""
    @State private var versionSearch = ""
    @State private var versionError: String?
    @AppStorage("storage_officialVersions") private var official = true
    @State private var versionNote: String?
    @State private var metadata: [String: VersionMetadata] = [:]
    @State private var metadataLoading = Set<String>()
    @State private var metadataFailures = 0
    @State private var metadataStopped = false
    @State private var showAllVersions = false
    @State private var releaseNotes: [String: ReleaseNote] = [:]
    @State private var expandedNotes = Set<String>()
    @State private var translatedNotes: [String: String] = [:]
    @State private var translatedDescription: String?
    @State private var versionsStale = false
    @State private var showsMacSpinner = false
    @State private var versionsLoadID = UUID()
    @State private var showLogin = false
    @State private var reauthenticationID: String?
    @State private var retryAfterLoginVersion: String?
    @State private var showVerification = false
    @State private var pendingDownloadVersion: String?
    @State private var retryVersionsAfterVerification = false
    @State private var verifiedForRetry = false
    @State private var showDescription = false
    @State private var reloadID = 0
    @State private var loadedVersionsKey: String?
    @State private var loadedReloadID = 0
    private var versionsKey: String {
        "\(usesApple)-\(reloadID)-\(store.settings.store.country)-\(store.settings.store.platform.rawValue)-\(apple.activeID ?? "")"
    }
    @State private var macWebsite: URL?
    @State private var macInstallers: [MacInstallerService.Installer] = []
    @State private var macLoading = false
    @State private var macOfficialLoading = false
    @State private var macOfficialTask: Task<Void, Never>?
    @State private var enteringMacDownloadURL = false
    @State private var macDownloadURL = ""
    @State private var headerAway = false
    @State private var extras: StoreService.ListingExtras?
    @State private var extrasLoaded = LocalResources.isPreview
    @State private var viewing: StoreService.Screenshot?
    @Namespace private var screenshotZoom
    @State private var developerApps: [StoreApp] = []
    private var iconURL: URL? { app.iconURL ?? store.localArtwork(app.id) }
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)")! }
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter {
            displayVersion($0).localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch)
        }
    }
    private func displayVersion(_ version: AppVersion) -> String { metadata[version.id]?.version ?? version.version }
    private var usesApple: Bool { official && apple.active != nil }
    private var readsMetadata: Bool { usesApple && versionNote == nil && !metadataStopped }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                CardSection {
                    header.onScrolledUnderBar { headerAway = $0 }
                        .cardRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    infoStrip.cardRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                }
                if let shots = extrasLoaded ? extras?.screenshots : [], !extrasLoaded || !shots.isEmpty {
                    CardSection(plain: true) {
                        ScreenshotStrip(screenshots: shots, platform: store.settings.store.platform,
                                        zoom: screenshotZoom) { viewing = $0 }
                    } header: { sectionTitle("Preview") }
                }
                versionSection
                if store.settings.store.platform == .macOS { macSection }
                if !app.description.isEmpty {
                    CardSection {
                        Text(translatedDescription ?? app.description).font(.subheadline)
                            .lineLimit(showDescription ? nil : 4).textSelection(.enabled)
                        let translates = TranslateButton.offered(for: app.description, translation: translatedDescription)
                        if !showDescription || translates {
                            HStack {
                                if !showDescription {
                                    Button("More") { withAnimation { showDescription = true } }
                                }
                                Spacer()
                                if translates {
                                    TranslateButton(text: app.description, translation: $translatedDescription)
                                        .accessibilityIdentifier("detail.description.translate")
                                }
                            }
                            .font(.subheadline).buttonStyle(.borderless)
                        }
                    } header: { sectionTitle("Description") }
                }
                if !app.isDelisted { ReviewsCard(app: app) }
                if !app.isDelisted {
                    CardSection {
                        if store.isFavorite(app) { PriceHistorySection(app: app) }
                        else {
                            Text("Following records price changes and notifies you about price drops or free promotions.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        NavigationLink { RegionPriceView(app: app) } label: {
                            HStack {
                                Label("Price comparison by region", systemImage: "globe")
                                Spacer()
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detail.regionPrices")
                    } header: { sectionTitle("Price") }
                }
                CardSection {
                    if app.isDelisted { LabeledContent("Store status", value: AppText.text("Removed")) }
                    if !app.displayCategory.isEmpty { LabeledContent("Category", value: app.displayCategory) }
                    if app.size > 0 { LabeledContent("Size", value: app.size.byteLabel) }
                    if !app.minimumOS.isEmpty {
                        LabeledContent("Compatibility", value: AppText.text("\(store.settings.store.platform.title) \(app.minimumOS) or later"))
                    }
                    LabeledContent("Price", value: app.priceLabel)
                    LabeledContent("Storefront", value: store.settings.store.country)
                    if !app.bundleID.isEmpty {
                        LabeledContent("Bundle ID") {
                            Text(app.bundleID).font(.footnote.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                    if let developer = extras?.developer, !developer.isEmpty { LabeledContent("Developer", value: developer) }
                    if store.settings.store.platform != .macOS {
                        Link(destination: storeURL) { Label("View in the App Store", systemImage: "arrow.up.right.square") }
                    }
                } header: { sectionTitle("Information") }
                if !developerApps.isEmpty {
                    CardSection {
                        DeveloperAppsStrip(apps: developerApps)
                            .cardRowInsets(EdgeInsets())
                    } header: { sectionTitle(extras?.developer.isEmpty == false ? "More by \(extras!.developer)" : "More apps by this developer") }
                }
            }
            .padding(.top, 8).padding(.bottom, 24)
        }
        .toolPage()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                AppIcon(url: iconURL, size: 30)
                    .opacity(headerAway ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: headerAway)
                    .accessibilityHidden(true)
            }
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Button {
                    let following = !store.isFavorite(app)
                    store.toggleFavorite(app); UX.feedback()
                    if following { store.infoMessage = AppText.text("Following. You'll be notified about new versions, price drops or removal.") }
                } label: {
                    Image(systemName: store.isFavorite(app) ? "bell.fill" : "bell")
                        .compatibleSymbolReplacement()
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(store.isFavorite(app) ? AppText.text("Unfollow") : AppText.text("Follow app"))
            }
        }
        .alert("Download Mac package", isPresented: $enteringMacDownloadURL) {
            TextField("https://example.com/App.dmg", text: $macDownloadURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add to downloads") {
                let value = macDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: value), MacInstallerService.directPackage(url) else {
                    store.errorMessage = AppText.text("Enter a valid HTTPS download link. The file must be a DMG, PKG or ZIP.")
                    return
                }
                enqueueMacInstaller(MacInstallerService.Installer(url: url))
                macDownloadURL = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a download link for a DMG, PKG or ZIP package.")
        }
        .navigationDestination(isPresented: $showLogin) {
            LoginView(initialAccountID: reauthenticationID, onSignedIn: {
                reauthenticationID = nil
                guard let pending = retryAfterLoginVersion else { return }
                retryAfterLoginVersion = nil
                Task { @MainActor in
                    await Task.yield()
                    download(versionID: pending.isEmpty ? nil : pending)
                }
            })
        }
        .sheet(isPresented: $showVerification, onDismiss: {
            guard verifiedForRetry else {
                pendingDownloadVersion = nil
                retryVersionsAfterVerification = false
                return
            }
            verifiedForRetry = false
            if retryVersionsAfterVerification {
                retryVersionsAfterVerification = false
                reloadID += 1
            } else {
                let pending = pendingDownloadVersion
                pendingDownloadVersion = nil
                if let pending { download(versionID: pending.isEmpty ? nil : pending) }
            }
        }) {
            if let accountID = apple.activeID {
                ExistingAccountVerificationView(accountID: accountID, onVerified: {
                    verifiedForRetry = true
                })
                .environmentObject(store)
                .environmentObject(apple)
            }
        }
        .onDisappear { downloadTask?.cancel(); macOfficialTask?.cancel() }
        .task {
            if apple.active != nil, store.settings.useSignerCache { store.signer.prewarm() }
            guard autoStart, !autoStarted else { return }
            autoStarted = true
            if apple.active == nil { showLogin = true }
            else if store.settings.store.platform.supportsIPA { download(versionID: app.externalVersionID) }
            else { downloadAppleMacPKG() }
        }
        .task(id: versionsKey) {
            guard versionsKey != loadedVersionsKey else { return }
            let forced = reloadID != loadedReloadID
            if !forced { versionsStale = !versions.isEmpty }
            let loaded = await fetchVersions(force: forced)
            if loaded { loadedVersionsKey = versionsKey; loadedReloadID = reloadID }
            else if versionsStale, !Task.isCancelled { versions = [] }
            if !Task.isCancelled { versionsStale = false }
        }
        .task(id: "\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            await loadMacInstallers()
        }
        .task(id: "notes-\(app.id)-\(store.settings.store.country)") {
            guard !LocalResources.isPreview, !app.isDelisted else { return }
            var countries = [store.settings.store.country.uppercased()]
            if !countries.contains(store.watchCountry) { countries.append(store.watchCountry) }
            let notes = await ReleaseNotesService.notes(appID: app.id, countries: countries)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { releaseNotes = notes }
        }
        .task(id: "extras-\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            guard !LocalResources.isPreview else { return }
            let found = try? await StoreService.listingExtras(id: app.id, country: store.settings.store.country,
                                                            platform: store.settings.store.platform)
            guard !Task.isCancelled else { return }
            extras = found; extrasLoaded = true
            guard let developerID = found?.developerID else { developerApps = []; return }
            let apps = (try? await StoreService.developerApps(developerID, excluding: app.id, country: store.settings.store.country,
                                                             platform: store.settings.store.platform)) ?? []
            guard !Task.isCancelled else { return }
            developerApps = apps
        }
        .fullScreenCover(item: $viewing) { shot in
            ScreenshotViewer(screenshots: extras?.screenshots ?? [shot], selection: shot)
                .zoomTransition(shot.id, in: screenshotZoom)
        }
    }
    static let collapsedVersions = 5
    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(url: iconURL, size: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? app.bundleID : app.name).font(.title3.weight(.bold))
                    .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                if app.isDelisted {
                    TagBadge(text: "Removed", tint: .orange)
                } else if !app.displayCategory.isEmpty {
                    Text(app.displayCategory).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.version.isEmpty ? "Version not loaded" : "v\(app.version)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .layoutPriority(1)
                        .accessibilityIdentifier("app.version")
                    Spacer(minLength: 4)
                    Button { copy(app.id) } label: {
                        HStack(spacing: 4) {
                            Text("ID \(app.id)").monospacedDigit().lineLimit(1)
                            Image(systemName: "doc.on.doc")
                        }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("App ID \(app.id), tap to copy")
                    .accessibilityIdentifier("app.copy-id")
                }
                Spacer(minLength: 10)
                HStack(spacing: 12) {
                    primaryButton
                    Spacer(minLength: 0)
                    ShareLink(item: storeURL) { Image(systemName: "square.and.arrow.up").font(.title3) }
                        .buttonStyle(.borderless).accessibilityLabel("Share store link")
                }
                if let account = apple.active, store.settings.store.platform.supportsIPA || store.settings.store.platform == .macOS {
                    Text("Use \(account.id)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let busy = downloadLoading || macOfficialLoading
        if busy {
            HStack(spacing: 10) {
                Button {
                    downloadTask?.cancel(); macOfficialTask?.cancel()
                } label: { ProgressRing(progress: nil) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel preparing")
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if apple.active == nil {
            RowCapsule(title: "Sign in", filled: true) { showLogin = true }
        } else if store.settings.store.platform.supportsIPA {
            RowCapsule(title: app.isFree ? "Get" : "Download", filled: true) {
                download(versionID: app.externalVersionID)
            }
            .accessibilityIdentifier("detail.get")
        } else {
            RowCapsule(title: "Get PKG", filled: true) { downloadAppleMacPKG() }
                .accessibilityIdentifier("mac.official-pkg")
        }
    }

    private var infoStrip: some View {
        let items = Array(stripItems.prefix(4))
        return HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                items[index]
                if index < items.count - 1 { Divider().frame(height: 40) }
            }
        }
        .padding(.horizontal, 8)
    }

    private var stripItems: [InfoStripItem] {
        let platform = store.settings.store.platform
        var items: [InfoStripItem] = []
        if app.rating > 0 {
            items.append(InfoStripItem(caption: "Rating", value: String(format: "%.1f", app.rating),
                                       detail: String(repeating: "★", count: max(0, min(5, Int(app.rating.rounded()))))))
        }
        if app.size > 0 {
            let parts = app.size.byteLabel.components(separatedBy: " ")
            items.append(InfoStripItem(caption: "Size", value: parts.first ?? app.size.byteLabel, detail: parts.count > 1 ? parts.last : nil))
        }
        if !app.minimumOS.isEmpty {
            items.append(InfoStripItem(caption: "Compatibility", value: app.minimumOS + "+", detail: platform.title))
        } else {
            items.append(InfoStripItem(caption: "Platform", value: platform.title, symbol: platform.symbol))
        }
        if app.isDelisted {
            items.append(InfoStripItem(caption: "Status", value: AppText.text("Removed"), symbol: "archivebox"))
        } else if !app.displayCategory.isEmpty {
            items.append(InfoStripItem(caption: "Category", value: app.displayCategory, symbol: "square.grid.2x2"))
        }
        items.append(InfoStripItem(caption: "Region", value: store.settings.store.country, detail: AppText.text("Store")))
        return items
    }

    @ViewBuilder private var versionSection: some View {
        CardSection {
            Toggle("Get the full version list from Apple", isOn: $official).font(.subheadline)
                .disabled(apple.active == nil)
            if let versionError { InlineIssue(message: versionError) { reloadID += 1 } }
            if let versionNote {
                Label(versionNote, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if versions.count > 6 {
                SearchInput(text: $versionSearch, placeholder: "Filter by version or version ID")
            }
            let matches = filtered
            let limit = showAllVersions || !versionSearch.isEmpty ? matches.count : Self.collapsedVersions
            if versions.isEmpty && versionsLoading {
                ForEach(0..<3, id: \.self) { _ in VersionRowSkeleton() }
            }
            ForEach(matches.prefix(limit)) { version in
                versionRow(version)
                    .opacity(versionsStale ? 0.4 : 1)
                    .disabled(versionsStale)
                    .task(id: "\(version.id)-\(readsMetadata)-\(versionsStale)") {
                        if !versionsStale { await loadMetadata(version) }
                    }
            }
            if !versions.isEmpty && matches.isEmpty { Text("No matching versions.").font(.subheadline).foregroundStyle(.secondary) }
            if versionSearch.isEmpty && matches.count > Self.collapsedVersions {
                Button {
                    withAnimation(.compatibleSnappy) { showAllVersions.toggle() }
                } label: {
                    HStack {
                        Text(showAllVersions ? "Show less" : "Show all \(matches.count) versions")
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(showAllVersions ? 180 : 0))
                    }
                    .font(.subheadline.weight(.medium))
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("detail.versions.toggle")
            }
            if versions.isEmpty && !versionsLoading && versionError == nil {
                Text("No older versions").font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("Enter a version ID") {
                HStack {
                    TextField("Internal version ID", text: $manualID).keyboardType(.numberPad)
                    RowCapsule(title: "Download", enabled: !manualID.isEmpty && !downloadLoading) { download(versionID: manualID) }
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Version history")
                Spacer()
                RefreshButton(busy: versionsLoading) { reloadID += 1 }
                    .accessibilityIdentifier("detail.versions.refresh")
            }
        }
    }

    private func versionRow(_ version: AppVersion) -> some View {
        let name = displayVersion(version)
        let known = name != AppVersion.unknown
        let reading = !known && metadataLoading.contains(version.id)
        let note = known ? releaseNotes[name] : nil
        let date = (metadata[version.id]?.released ?? note?.date)?.formatted(.dateTime.year().month().day())
        let expanded = expandedNotes.contains(version.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(known ? "Version \(name)" : reading ? "Version 0.0.0" : "Unknown version")
                        .font(.body.weight(.medium))
                        .redacted(reason: reading ? .placeholder : [])
                    Text([date, AppText.text("Version ID \(version.id)")].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .animation(.easeOut(duration: 0.2), value: name)
                Spacer(minLength: 8)
                RowCapsule(title: "Download", enabled: !downloadLoading && !macOfficialLoading) { download(versionID: version.id) }
                    .accessibilityLabel(known ? AppText.text("Download version \(name)") : AppText.text("Download version ID \(version.id)"))
            }
            if let note, !note.text.isEmpty {
                Button {
                    withAnimation(.compatibleSnappy) {
                        if expanded { expandedNotes.remove(version.id) } else { expandedNotes.insert(version.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Hide release notes" : "Release notes")
                        Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.caption.weight(.medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("detail.version.notes." + version.id)
                if expanded {
                    Text(translatedNotes[version.id] ?? note.text).font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    if TranslateButton.offered(for: note.text, translation: translatedNotes[version.id]) {
                        TranslateButton(text: note.text, translation: Binding(
                            get: { translatedNotes[version.id] }, set: { translatedNotes[version.id] = $0 }))
                            .font(.caption.weight(.medium)).buttonStyle(.borderless)
                            .accessibilityIdentifier("detail.version.translate." + version.id)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu { Button("Copy version ID", systemImage: "doc.on.doc") { copy(version.id) } }
    }

    private func loadMetadata(_ version: AppVersion) async {
        guard readsMetadata, metadata[version.id] == nil, !metadataLoading.contains(version.id) else { return }
        metadataLoading.insert(version.id)
        defer { metadataLoading.remove(version.id) }
        do {
            metadata[version.id] = try await store.versionMetadata(app: app, versionID: version.id)
            metadataFailures = 0
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            if error is AppleAuthError || error is AppleLoginError { metadataStopped = true; return }
            metadataFailures += 1
            if metadataFailures >= 3 { metadataStopped = true }
        }
    }

    @ViewBuilder private var macSection: some View {
        CardSection {
            Text(MacPackageDecryptor.isAvailable
                 ? "After downloading, export it to install on a Mac."
                 : "Only unencrypted Mac packages can be downloaded.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(macInstallers) { installer in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installer.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text("From the developer's website · \(installer.format.uppercased())").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RowCapsule(title: "Download") { enqueueMacInstaller(installer) }
                        .accessibilityIdentifier("mac.download." + installer.format)
                }
            }
            Button("Download from a link", systemImage: "link") { enteringMacDownloadURL = true }
                .accessibilityIdentifier("mac.manual-download")
            if let website = macWebsite {
                Link(destination: website) { Label("Developer website", systemImage: "safari") }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Mac package")
                Spacer()
                if showsMacSpinner { ProgressView().controlSize(.small).transition(.opacity) }
            }
            .revealAfterDelay(macLoading, into: $showsMacSpinner)
        }
    }

    private func copy(_ text: String) { UIPasteboard.general.string = text; store.infoMessage = AppText.text("Copied to clipboard"); UX.feedback() }
    @discardableResult
    private func fetchVersions(force: Bool) async -> Bool {
        let loadID = UUID(); versionsLoadID = loadID
        versionsLoading = true
        defer { if versionsLoadID == loadID { versionsLoading = false } }
        do {
            var result: [AppVersion]
            do {
                result = try await store.loadVersions(for: app, force: force, official: usesApple)
                versionNote = nil
            } catch is AppleLicenseError {
                result = try await store.loadVersions(for: app, force: force, official: false)
                versionNote = AppText.text("This account hasn't acquired the app, so the public version details are shown. Get it to see the full list.")
            } catch {
                if usesApple, let publicVersions = try? await store.loadVersions(for: app, force: force, official: false), !publicVersions.isEmpty {
                    result = publicVersions
                    versionNote = AppText.text("Apple's version service didn't respond, so the public version list is shown. Tap refresh to try again.")
                } else {
                    throw error
                }
            }
            try Task.checkCancellation(); versions = result; versionError = nil
            if versionsStale { showAllVersions = false }
            if force { metadataStopped = false; metadataFailures = 0 }
            let cached = await store.cachedVersionMetadata(app: app, versionIDs: result.map(\.id))
            metadata.merge(cached) { current, _ in current }
            return true
        } catch is CancellationError { }
        catch AppleAuthError.reauthenticationRequired {
            if !Task.isCancelled {
                reauthenticationID = apple.activeID
                retryVersionsAfterVerification = false
                showLogin = true
            }
        }
        catch AppleLoginError.verificationRequired {
            if !Task.isCancelled {
                retryVersionsAfterVerification = true
                showVerification = true
            }
        }
        catch {
            if !Task.isCancelled {
                let message = error.localizedDescription
                if error is VersionListUnavailableError || error is AppleLicenseError {
                    versionError = message
                } else if let tool = error as? ToolError, case .message(let text) = tool {
                    versionError = text
                } else {
                    versionError = AppErrorMessage.forSearch(error)
                }
            }
        }
        return false
    }
    private func downloadAppleMacPKG(versionID: String? = nil) {
        guard !macOfficialLoading else { return }
        guard apple.active != nil else {
            showLogin = true
            return
        }
        macOfficialLoading = true
        macOfficialTask = Task {
            defer { macOfficialLoading = false; macOfficialTask = nil }
            do {
                let offer = try await SAPSigner.$userInitiated.withValue(true) {
                    try await apple.macPackageOffer(app, versionID: versionID, useCache: store.settings.useSignerCache)
                }
                try Task.checkCancellation()
                try store.downloads.enqueueOfficialMacPackage(offer, for: app)
                store.infoMessage = AppText.text("Download started")
                store.tab = 1
                reloadIfLicenseWasMissing()
            } catch AppleAuthError.reauthenticationRequired {
                reauthenticationID = apple.activeID
                showLogin = true
            } catch AppleLoginError.verificationRequired {
                store.requestVerification { downloadAppleMacPKG(versionID: versionID) }
            } catch is CancellationError { }
            catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadIfLicenseWasMissing() {
        if versionNote != nil || versionError == AppleLicenseError.notOwned.errorDescription { reloadID += 1 }
    }

    private func enqueueMacInstaller(_ installer: MacInstallerService.Installer) {
        do {
            try store.downloads.enqueueMacInstaller(installer.url, for: app)
            store.tab = 1
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func loadMacInstallers() async {
        guard store.settings.store.platform == .macOS else { return }
        macLoading = true
        macInstallers = []
        defer { macLoading = false }
        var website = app.developerURL
        if website == nil, app.id.allSatisfy({ $0.isNumber }) {
            let query = SearchQuery.appID(app.id, versionID: nil)
            if let matches = try? await StoreService.search(query, store: store.settings.store, limit: 1) {
                website = matches.first(where: { $0.id == app.id })?.developerURL
            }
        }
        guard !Task.isCancelled else { return }
        macWebsite = website
        if let website, let installers = try? await MacInstallerService.find(on: website),
           !Task.isCancelled {
            macInstallers = installers
        }
    }

    private func download(versionID: String?) {
        guard !downloadLoading else { return }
        if let versionID, !versionID.isEmpty, !versionID.allSatisfy({ $0.isASCII && $0.isNumber }) { store.errorMessage = AppText.text("The version ID can only contain digits"); return }
        guard store.settings.store.platform.supportsIPA else {
            downloadAppleMacPKG(versionID: versionID?.isEmpty == true ? nil : versionID)
            return
        }
        guard apple.active != nil else { showLogin = true; return }
        downloadLoading = true
        downloadTask = Task {
            defer { downloadLoading = false; downloadTask = nil }
            do {
                try await store.startDownload(app: app, versionID: versionID?.isEmpty == true ? nil : versionID)
                reloadIfLicenseWasMissing()
            }
            catch AppleLoginError.verificationRequired {
                pendingDownloadVersion = versionID ?? ""
                retryVersionsAfterVerification = false
                showVerification = true
            }
            catch AppleAuthError.reauthenticationRequired {
                reauthenticationID = apple.activeID
                retryAfterLoginVersion = versionID ?? ""
                showLogin = true
            }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

private struct ScreenshotStrip: View {
    let screenshots: [StoreService.Screenshot]
    let platform: AppPlatform
    let zoom: Namespace.ID
    var open: (StoreService.Screenshot) -> Void
    @State private var images: [URL: UIImage] = [:]
    @State private var failed = Set<URL>()
    @State private var legacyWidth: CGFloat = 1
    private var ready: Bool { !screenshots.isEmpty && screenshots.allSatisfy { images[$0.url] != nil || failed.contains($0.url) } }
    private func aspect(_ shot: StoreService.Screenshot) -> Double {
        guard ready, let image = images[shot.url], image.size.height > 0 else { return shot.aspect }
        return image.size.width / image.size.height
    }
    var body: some View {
        let margin = CardSection<EmptyView, EmptyView>.pageMargin
        let placeholders = screenshots.isEmpty
        let placeholderAspect = platform == .iOS ? 0.462 : platform == .iPadOS ? 1.33 : 1.6
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if placeholders {
                        ForEach(0..<3, id: \.self) { _ in
                            screenshotWidth(of: ScreenshotTile(image: nil, failed: false, cornerRadius: placeholderAspect < 1 ? 22 : 14)
                                .aspectRatio(placeholderAspect, contentMode: .fit), aspect: placeholderAspect, margin: margin)
                        }
                    }
                    ForEach(screenshots) { shot in
                        let ratio = aspect(shot)
                        let portrait = ratio < 1
                        Button { open(shot) } label: {
                            screenshotWidth(of: ScreenshotTile(image: ready ? images[shot.url] : nil, failed: failed.contains(shot.url),
                                           cornerRadius: portrait ? 22 : 14)
                                .aspectRatio(ratio, contentMode: .fit), aspect: ratio, margin: margin)
                        }
                        .buttonStyle(.plain)
                        .zoomSource(shot.id, in: zoom)
                        .accessibilityLabel("Screenshots")
                    }
                }
                .compatibleScrollTargetLayout()
                .legacyHorizontalPadding(margin)
            }
            .compatibleHorizontalScrollMargins(margin)
            .compatibleViewAlignedScrolling()
            .scrollDisabled(placeholders)
            HStack(spacing: 8) {
                DeviceGlyph(platform: platform)
                Text(platform == .iOS ? "iPhone" : platform == .tvOS ? "Apple TV" : platform.title)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, margin)
        }
        .measureLegacyWidth($legacyWidth)
        .task(id: screenshots.map(\.url)) { await load() }
        .accessibilityIdentifier("detail.screenshots")
    }

    @ViewBuilder private func screenshotWidth(of content: some View, aspect: Double, margin: CGFloat) -> some View {
        if #available(iOS 17, *) {
            content.containerRelativeFrame(.horizontal) { length, _ in
                Self.tileWidth(length - margin * 2, aspect: aspect)
            }
        } else {
            content.frame(width: Self.tileWidth(legacyWidth - margin * 2, aspect: aspect))
        }
    }

    nonisolated static func tileWidth(_ width: CGFloat, aspect: Double) -> CGFloat {
        let width = max(1, width) * (aspect < 1 ? 0.64 : 0.92)
        return min(width, CGFloat(560 * aspect))
    }

    private func load() async {
        await withTaskGroup(of: (URL, UIImage?).self) { group in
            for shot in screenshots where images[shot.url] == nil {
                group.addTask { (shot.url, await ScreenshotCache.image(shot.url)) }
            }
            var loaded = images, missing = failed
            for await (url, image) in group {
                if let image { loaded[url] = image } else { missing.insert(url) }
            }
            guard !Task.isCancelled else { return }
            images = loaded; failed = missing
        }
    }
}

private struct VersionRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 110, height: 15)
                RoundedRectangle(cornerRadius: 4).fill(Color(.quaternarySystemFill)).frame(width: 170, height: 11)
            }
            Spacer(minLength: 8)
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 74, height: 30)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}

private struct DeviceGlyph: View {
    let platform: AppPlatform
    var body: some View {
        switch platform {
        case .iOS:
            RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(lineWidth: 1.2).frame(width: 10, height: 17)
        case .iPadOS:
            RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(lineWidth: 1.2).frame(width: 14, height: 18)
        default:
            Image(systemName: platform.symbol)
        }
    }
}

struct CardSection<Content: View, Header: View>: View {
    static var pageMargin: CGFloat { 16 }
    static var cornerRadius: CGFloat {
        if #available(iOS 26, *) { return 26 }
        return 10
    }
    var plain = false
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    init(plain: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.plain = plain; self.content = content(); self.header = header()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, Self.pageMargin + 20)
            if plain { content } else {
                _VariadicView.Tree(CardRows()) { content }
                    .labeledContentStyle(CardLabeledContentStyle())
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                    .padding(.horizontal, Self.pageMargin)
            }
        }
    }
}
extension CardSection where Header == EmptyView {
    init(plain: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(plain: plain, content: content) { EmptyView() }
    }
}

private struct CardRowInsetsKey: _ViewTraitKey {
    static var defaultValue: EdgeInsets? { nil }
}
extension View {
    func cardRowInsets(_ insets: EdgeInsets) -> some View { _trait(CardRowInsetsKey.self, insets) }
}

private struct CardRows: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(child[CardRowInsetsKey.self] ?? EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                if child.id != last { Divider().padding(.leading, 20) }
            }
        }
    }
}

private struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label.foregroundStyle(.primary)
            Spacer(minLength: 12)
            configuration.content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private enum ScreenshotCache {
    private actor Requests {
        var pending: [URL: Task<UIImage?, Never>] = [:]
        func image(_ url: URL) async -> UIImage? {
            if let image = cached(url) { return image }
            if let task = pending[url] { return await task.value }
            let task = Task.detached(priority: .utility) { () -> UIImage? in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
                return await image.byPreparingForDisplay() ?? image
            }
            pending[url] = task
            let image = await task.value
            if let image { cache.setObject(image, forKey: url as NSURL, cost: IconCache.cost(of: image)) }
            pending.removeValue(forKey: url)
            return image
        }
    }
    private static let requests = Requests()
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>(); cache.totalCostLimit = 96 * 1024 * 1024; return cache
    }()
    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    static func image(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        return await requests.image(url)
    }
}

private struct ScreenshotTile: View {
    let image: UIImage?
    let failed: Bool
    var cornerRadius: CGFloat
    var body: some View {
        Rectangle().fill(Color(.tertiarySystemFill))
            .overlay { if failed { Image(systemName: "photo").foregroundStyle(.tertiary) } }
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

private struct ScreenshotViewer: View {
    let screenshots: [StoreService.Screenshot]
    let selection: StoreService.Screenshot
    @State private var current: StoreService.Screenshot.ID?
    @State private var images: [URL: UIImage] = [:]
    @Environment(\.dismiss) private var dismiss
    init(screenshots: [StoreService.Screenshot], selection: StoreService.Screenshot) {
        self.screenshots = screenshots; self.selection = selection
        _current = State(initialValue: selection.id)
    }
    private func aspect(_ shot: StoreService.Screenshot) -> Double {
        guard let image = images[shot.url] ?? ScreenshotCache.cached(shot.url), image.size.height > 0 else { return shot.aspect }
        return image.size.width / image.size.height
    }
    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height - 96)
            let widest = proxy.size.width - 64
            let widths = screenshots.map { min(widest, height * aspect($0)) }
            let margin = max(24, (proxy.size.width - (widths.max() ?? widest)) / 2)
            if #available(iOS 17, *) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(zip(screenshots, widths)), id: \.0.id) { shot, width in
                                let ratio = aspect(shot)
                                ScreenshotTile(image: images[shot.url] ?? ScreenshotCache.cached(shot.url), failed: false,
                                               cornerRadius: ratio < 1 ? 28 : 18)
                                    .frame(width: width, height: width / ratio)
                                    .frame(maxHeight: .infinity)
                                    .id(shot.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, margin, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $current)
                    .padding(.top, 72).padding(.bottom, 24)
                    .onAppear { reader.scrollTo(selection.id, anchor: .center) }
                }
            } else {
                TabView(selection: $current) {
                    ForEach(screenshots) { shot in
                        let ratio = aspect(shot)
                        let width = max(1, min(widest, height * ratio))
                        ScreenshotTile(image: images[shot.url] ?? ScreenshotCache.cached(shot.url), failed: false,
                                       cornerRadius: ratio < 1 ? 28 : 18)
                            .frame(width: width, height: width / ratio)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tag(Optional(shot.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .padding(.top, 72).padding(.bottom, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3.weight(.medium)).foregroundStyle(.primary)
                    .frame(width: 48, height: 48).background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            .padding(.trailing, 16).padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task(id: screenshots.map(\.url)) {
            for shot in screenshots where images[shot.url] == nil {
                if let image = await ScreenshotCache.image(shot.url) { images[shot.url] = image }
            }
        }
    }
}

extension View {
    @ViewBuilder func zoomSource(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    @ViewBuilder func zoomTransition(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}

private struct DeveloperAppsStrip: View {
    let apps: [StoreApp]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(apps) { app in
                    NavigationLink { AppDetailView(app: app) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AppIcon(url: app.iconURL, size: 76)
                            Text(app.name).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            if !app.displayCategory.isEmpty {
                                Text(app.displayCategory).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 84, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .compatibleScrollTargetLayout()
            .legacyHorizontalPadding(20)
            .padding(.vertical, 16)
        }
        .compatibleHorizontalScrollMargins(20)
        .compatibleViewAlignedScrolling()
        .clipShape(RoundedRectangle(cornerRadius: CardSection<EmptyView, EmptyView>.cornerRadius, style: .continuous))
        .accessibilityIdentifier("detail.developer-apps")
    }
}

private extension View {
    @ViewBuilder func measureLegacyWidth(_ width: Binding<CGFloat>) -> some View {
        if #available(iOS 17, *) { self }
        else { onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 } }
    }
}
