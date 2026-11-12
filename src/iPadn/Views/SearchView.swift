import SwiftUI

/// App Store-style search: title with the account avatar on one line, a
/// capsule search bar under it, filter chips, recent
/// searches as suggestions, and result rows with a "Get" capsule.
struct SearchView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false
    @State private var getting: StoreApp?
    @State private var viewingFavorite: StoreApp?
    @State private var headerAway = false
    /// The common storefronts, in this order; names follow the interface language.
    private static let regions = ["CN", "US", "HK", "TW", "JP", "GB", "SG", "CA", "AU", "KR", "DE", "FR"]
    var body: some View {
        List {
            Section {
                PageHeader(title: "Search") { AccountMenuButton() }
                    .onScrolledUnderBar { headerAway = $0 }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 12))
                SearchInput(text: $store.searchText, placeholder: "App name, App ID or link", capsule: true,
                            submit: { store.search() }, clear: { store.clearSearch() })
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { regionPicker; platformPicker }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            // Placeholders where the results will appear, so they replace the
            // loading rows instead of pushing everything down.
            if store.searching {
                Section {
                    HStack { ProgressView(); Text("Searching…").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("Cancel") { store.cancelSearch() } }
                    if store.results.isEmpty { AppSkeleton(); AppSkeleton() }
                }
            }
            if let error = store.searchError {
                Section { InlineIssue(message: error) { store.search(store.lastSearchTerm) } }
            }
            if !store.results.isEmpty {
                Section {
                    ForEach(store.results) { app in resultRow(app, note: app.tvOSCandidate == true ? AppText.text("May support Apple TV") : nil) }
                } header: { Text("store.results.count results") }
            }
            if !store.localResults.isEmpty {
                Section {
                    ForEach(store.localResults) { app in resultRow(app, note: nil) }
                } header: { Text("More results") }
            }
            if store.results.isEmpty && store.localResults.isEmpty && store.hasSearched && !store.searching && store.searchError == nil {
                Section {
                    EmptyState(title: "No results", message: "No apps match “store.lastSearchTerm”. Try an App ID, an App Store link, or another region.",
                               symbol: "magnifyingglass", actionTitle: "Clear search", action: { store.clearSearch() })
                }.listRowBackground(Color.clear)
            }
            if !store.hasSearched && !store.searching {
                suggestions
            }
        }
        .animation(UX.motion(reduceMotion), value: store.searchHistory.map(\.id))
        .animation(UX.motion(reduceMotion), value: store.favorites.map(\.id))
        .toolPage()
        .rootTabBar("Search", headerScrolledAway: headerAway)
        .compatibleNavigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .compatibleNavigationDestination(item: $viewingFavorite) { app in AppDetailView(app: app) }
        .actionConfirmation(isPresented: $confirmClear, title: "Clear recent searches?", confirmTitle: "Clear") { withAnimation { store.clearHistory() } }
        .task { await store.loadNameCatalog() }
        .task { await store.checkWatched() }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
    }

    private func resultRow(_ app: StoreApp, note: String?) -> some View {
        NavigationLink { AppDetailView(app: app) } label: {
            AppRow(app: app, subtitle: note.map { [app.displayCategory, $0].filter { !$0.isEmpty }.joined(separator: " · ") }) {
                RowCapsule(title: "Get") { getting = app; UX.feedback() }
                    .accessibilityLabel("Get app.name")
            }
        }
        .contextMenu {
            Button(store.isFavorite(app) ? "Unfollow" : "Follow", systemImage: store.isFavorite(app) ? "bell.slash" : "bell") {
                store.toggleFavorite(app); UX.feedback()
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !store.searchHistory.isEmpty {
            ForEach(Array(store.searchHistory.prefix(8))) { item in
                Section {
                    Button { store.search(item.term) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text(item.term).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(RevealRowButtonStyle())
                    .accessibilityIdentifier("history.\(item.id)")
                    .revealDelete(id: "history." + item.id, style: .compact) { withAnimation { store.removeHistory(item.term) } }
                } header: {
                    if item.id == store.searchHistory.first?.id {
                        HStack {
                            Text("Recent searches").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                            Spacer()
                            Button("Clear") { confirmClear = true }.font(.body).textCase(nil)
                        }
                    }
                }
            }
        }
        if !store.favorites.isEmpty {
            Section {
                ForEach(store.favorites) { app in
                    Button { viewingFavorite = app } label: {
                        HStack {
                            WatchRow(app: app)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }
                        .buttonStyle(RevealRowButtonStyle())
                        .accessibilityIdentifier("favorite." + app.id)
                        .revealDelete(id: "favorite." + app.id, title: "Unfollow") { withAnimation { store.toggleFavorite(app) } }
                }
            } header: {
                HStack {
                    Text("Follow").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                    if store.watchChecking { ProgressView().controlSize(.small) }
                }
            }
        }
        // The charts come after what the user searched and follows.
        DiscoverSection()
    }

    private func chip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(title).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).frame(minHeight: 32)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
    }
    private var regionPicker: some View {
        Menu {
            Picker("Storefront", selection: $store.settings.store.country) {
                ForEach(Self.regions, id: \.self) { code in Text(StoreRegions.name(code)).tag(code) }
            }
        } label: { chip(StoreRegions.name(store.settings.store.country), symbol: "globe") }
        .accessibilityLabel("Storefront")
    }
    private var platformPicker: some View {
        Menu {
            Picker("Platform", selection: $store.settings.store.platform) {
                ForEach(AppPlatform.allCases) { platform in Label(platform.title, systemImage: platform.symbol).tag(platform) }
            }
        } label: { chip(store.settings.store.platform.title, symbol: store.settings.store.platform.symbol) }
        .accessibilityLabel("Platform: store.settings.store.platform.title")
    }
}

/// App Store's top-right account button: avatar with a quick account switcher.
struct AccountMenuButton: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    var body: some View {
        Menu {
            if !apple.accounts.isEmpty {
                Section("Switch account") {
                    ForEach(apple.accounts) { account in
                        Button { apple.select(account.id); UX.feedback() } label: {
                            Label(account.id, systemImage: account.id == apple.activeID ? "checkmark.circle.fill" : "person.crop.circle")
                        }
                    }
                }
            }
            Button("Account & settings", systemImage: "person.crop.circle") { store.tab = 3 }
        } label: {
            AccountAvatar(account: apple.active, size: 32).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Switch or manage accounts")
    }
}

struct AccountAvatar: View {
    let account: AppleAccount?
    var size: CGFloat = 32
    private var initials: String {
        guard let account else { return "" }
        let source = account.name.isEmpty ? account.id : account.name
        return String(source.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
    var body: some View {
        ZStack {
            Circle().fill(account == nil ? AnyShapeStyle(Color(.tertiarySystemFill))
                          : AnyShapeStyle(LinearGradient(colors: [Color(.systemGray2), Color(.systemGray)], startPoint: .top, endPoint: .bottom)))
            if account == nil {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
            } else {
                Text(initials).font(.system(size: size * 0.45, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
