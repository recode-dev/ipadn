import SwiftUI

struct PurchasedView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @EnvironmentObject private var manager: DownloadManager
    @State private var term = ""
    /// `term` after typing pauses: large purchase lists filter once, not per key.
    @State private var query = ""
    @State private var months = 0
    @State private var showLogin = false
    @State private var getting: StoreApp?
    @State private var headerAway = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var batchProgress: (done: Int, total: Int)?
    /// Only purchases no longer on sale in the account's storefront.
    @State private var delistedOnly = false
    @State private var share: SharedFile?
    private var filtered: [OwnedApp] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        let term = query.trimmingCharacters(in: .whitespaces)
        if term.isEmpty && months == 0 && !delistedOnly { return store.owned }
        return store.owned.filter {
            (!delistedOnly || store.ownedListed[$0.id] == false) &&
            (months == 0 || ($0.purchaseDate ?? .distantPast) >= cutoff) &&
            (term.isEmpty || $0.id.contains(term) || $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term))
        }
    }
    /// Download state per App ID: a newer store version first, then downloaded.
    private var downloadBadges: [String: (text: LocalizedStringKey, tint: Color)] {
        var badges: [String: (text: LocalizedStringKey, tint: Color)] = [:]
        // Purchases are iPhone and iPad apps; a Mac or Apple TV download under
        // a shared App ID is a different package.
        for job in manager.jobs where job.status == .completed && [AppPlatform.iOS, .iPadOS].contains(job.updatePlatform) {
            if let key = job.updateKey, let latest = store.availableUpdates[key] {
                badges[job.app.id] = ("Version latest.version is available", UX.tint)
            } else if badges[job.app.id] == nil {
                badges[job.app.id] = (job.app.version.isEmpty ? "Downloaded" : "Downloaded job.app.version", .green)
            }
        }
        return badges
    }
    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        UX.feedback()
    }
    private func storeApp(_ app: OwnedApp) -> StoreApp {
        var listing = app.storeApp
        if store.ownedListed[app.id] == false { listing.delisted = true }
        return listing
    }
    private func findDelisted() {
        Task {
            guard let count = await store.checkOwnedListings() else {
                if !store.checkingListings { store.errorMessage = AppText.text("Can't check store status right now. Try again later.") }
                return
            }
            if count == 0 { store.infoMessage = AppText.text("All purchased apps are still on sale"); return }
            withAnimation { delistedOnly = true; term = ""; query = ""; months = 0 }
        }
    }
    private func export() {
        do { share = SharedFile(url: try store.exportOwned()) }
        catch { store.errorMessage = AppText.text("Export failed: error.localizedDescription") }
    }
    /// Adds the selected apps one after another; the list order is kept.
    private func downloadSelected() {
        download(store.owned.filter { selection.contains($0.id) }.map(\.storeApp))
    }
    private func download(_ apps: [StoreApp]) {
        guard !apps.isEmpty, batchProgress == nil else { return }
        batchProgress = (0, apps.count)
        Task {
            let result = await SAPSigner.$userInitiated.withValue(true) {
                await store.startDownloads(apps) { done in batchProgress = (done, apps.count) }
            }
            batchProgress = nil
            if result.added > 0 {
                selection.removeAll(); selecting = false
                store.infoMessage = AppText.text("Added result.added downloads")
            }
            if !result.failures.isEmpty { store.errorMessage = result.failures.joined(separator: "\n") }
        }
    }
    var body: some View {
        List {
            Section {
                PageHeader(title: "Purchased") {
                    Menu {
                        Button("Find removed apps", systemImage: "archivebox") { findDelisted() }
                            .disabled(store.owned.isEmpty || store.checkingListings)
                        Button("Export as spreadsheet", systemImage: "tablecells") { export() }
                            .disabled(store.owned.isEmpty)
                    } label: {
                        ZStack {
                            if store.checkingListings { ProgressView().controlSize(.small) }
                            else { Image(systemName: "ellipsis").font(.body.weight(.semibold)) }
                        }
                        .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .disabled(apple.active == nil || selecting)
                    .accessibilityLabel("More actions")
                    .accessibilityIdentifier("purchased.more")
                }
                .onScrolledUnderBar { headerAway = $0 }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let account = apple.active {
                Section {
                    SearchInput(text: $term, placeholder: "Search purchases or App ID", capsule: true)
                    Picker("Purchase date", selection: $months) {
                        Text("All").tag(0); Text("1 month").tag(1); Text("6 months").tag(6); Text("1 year").tag(12)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text("Account: account.id")
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if let error = store.ownedError { Section { InlineIssue(message: error) { Task { await store.refreshOwned() } } } }
                if delistedOnly {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Removed but still downloadable").font(.subheadline.weight(.semibold))
                                Text("These apps are no longer on sale. Your account can still download them; back them up soon.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Show all") { withAnimation { delistedOnly = false } }
                                .font(.subheadline).buttonStyle(.borderless)
                        }
                        let backups = filtered
                        if !backups.isEmpty {
                            Button {
                                download(backups.map(\.storeApp))
                            } label: {
                                Label(batchProgress.map { AppText.text("Adding $0.done of $0.total") }
                                        ?? AppText.text("Back up all (backups.count)"),
                                      systemImage: "square.and.arrow.down.on.square")
                                    .fontWeight(.semibold)
                            }
                            .disabled(batchProgress != nil)
                            .accessibilityIdentifier("purchased.backup-all")
                        }
                    }
                }
                let visible = filtered
                if (store.ownedLoading || store.cacheLoading) && store.owned.isEmpty {
                    Section {
                        HStack { ProgressView(); Text("Syncing purchases…").font(.subheadline).foregroundStyle(.secondary) }
                        AppSkeleton(); AppSkeleton(); AppSkeleton()
                    }
                }
                let badges = downloadBadges
                if !visible.isEmpty {
                    Section {
                        ForEach(visible) { app in
                            let subtitle = app.purchaseDate.map {
                                AppText.text("Acquired \($0.formatted(.dateTime.year().month(.defaultDigits).day()))")
                            }
                            if selecting {
                                Button { toggle(app.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(app.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(selection.contains(app.id) ? Color.accentColor : Color.secondary)
                                            .compatibleSymbolReplacement()
                                        AppRow(app: storeApp(app), subtitle: subtitle, badge: badges[app.id])
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(selection.contains(app.id) ? AppText.text("Deselect app.name") : AppText.text("Select app.name"))
                            } else {
                                NavigationLink { AppDetailView(app: storeApp(app)) } label: {
                                    AppRow(app: storeApp(app), subtitle: subtitle, badge: badges[app.id]) {
                                        // The App Store's re-download glyph leaves room for the
                                        // purchase date in longer languages.
                                        Image(systemName: "icloud.and.arrow.down")
                                            .font(.title3.weight(.medium)).foregroundStyle(UX.tint)
                                            .frame(width: 34, height: 44).contentShape(Rectangle())
                                            .highPriorityGesture(TapGesture().onEnded { getting = app.storeApp; UX.feedback() })
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityAddTraits(.isButton)
                                            .accessibilityLabel("Download app.name")
                                            .accessibilityAction { getting = app.storeApp; UX.feedback() }
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("visible.count items")
                            Spacer()
                            Button(selecting ? "Done" : "Select") {
                                withAnimation(.compatibleSnappy) { selecting.toggle(); selection.removeAll() }
                            }
                            .font(.body.weight(.semibold))
                            .textCase(nil)
                            .buttonStyle(.borderless)
                            .disabled(batchProgress != nil)
                            .accessibilityIdentifier("purchased.select")
                        }
                    }
                } else if !store.ownedLoading && !store.cacheLoading && store.ownedError == nil {
                    Section {
                        if delistedOnly && term.isEmpty && months == 0 {
                            EmptyState(title: "No removed apps", message: "Every app you've acquired is still on sale.", symbol: "checkmark.seal", actionTitle: "Show all", action: { delistedOnly = false })
                        } else if term.isEmpty && months == 0 {
                            EmptyState(title: "No purchases yet", message: "After syncing, find and download the apps you've acquired here.", symbol: "clock.arrow.circlepath", actionTitle: "Sync now", action: { Task { await store.refreshOwned() } })
                        } else {
                            EmptyState(title: "No matching apps", message: "Try another keyword, or adjust the time range.", symbol: "line.3.horizontal.decrease.circle", actionTitle: "Clear filters", action: { term = ""; query = ""; months = 0 })
                        }
                    }
                }
            } else {
                Section { EmptyState(title: "Not signed in", message: "Sign in to see the apps you've acquired.", symbol: "person.crop.circle.badge.checkmark", actionTitle: "Sign in", action: { showLogin = true }) }
            }
        }
        .navigationDestination(isPresented: $showLogin) { LoginView() }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .compatibleNavigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
        .toolPage()
        .rootTabBar("Purchased", headerScrolledAway: headerAway)
        .task(id: "\(apple.activeID ?? "")|\(store.ownedRevision)") { await store.loadOwnedArtwork() }
        .refreshable { if apple.active != nil { await store.refreshOwned() } }
        .task(id: term) {
            // Clearing is instant; typing waits for a short pause.
            if !term.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            query = term
        }
        .task { await store.checkForUpdates() }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 12) {
                    let visible = filtered
                    let allSelected = !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
                    Button(allSelected ? "Deselect all" : "Select all") {
                        if allSelected { selection.subtract(visible.map(\.id)) } else { selection.formUnion(visible.map(\.id)) }
                    }
                    .disabled(visible.isEmpty || batchProgress != nil)
                    Spacer()
                    if let batchProgress {
                        ProgressView()
                        Text("Adding batchProgress.done of batchProgress.total").font(.subheadline.monospacedDigit())
                    } else {
                        Button { downloadSelected() } label: {
                            Text(selection.isEmpty ? "Download selected" : "Download selected (selection.count)").fontWeight(.semibold)
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("purchased.download-selected")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .compatibleOnChange(of: apple.activeID) { _ in selecting = false; selection.removeAll(); delistedOnly = false }
    }
}
