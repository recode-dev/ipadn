import Foundation
import Combine
import UIKit
import UserNotifications

struct SearchHistoryItem: Codable, Identifiable {
    var id: String { term }
    var term: String
    var count: Int
    var lastUsed: Date
}

struct AppBackup: Codable {
    static let currentFormat = 1
    var format = AppBackup.currentFormat
    var app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    var created = Date()
    var settings: ToolSettings
    var favorites: [StoreApp]
    var watch: [String: WatchRecord]
    var keptVersions: [String: String]
    var searchHistory: [SearchHistoryItem]

    static func decode(_ data: Data) throws -> AppBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(AppBackup.self, from: data), backup.format >= 1 else {
            throw ToolError.message(AppText.text("This isn’t a valid iPadn backup file."))
        }
        guard backup.format <= currentFormat else {
            throw ToolError.message(AppText.text("This backup comes from a newer version of iPadn. Update iPadn first."))
        }
        return backup
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    static func merged(_ imported: [StoreApp], with existing: [StoreApp]) -> [StoreApp] {
        let ids = Set(imported.map(\.id))
        var seen = Set<String>()
        return (imported + existing.filter { !ids.contains($0.id) }).filter { seen.insert($0.id).inserted }
    }
}

struct UndoNotice: Identifiable {
    let id = UUID()
    let message: String
    let restore: () -> Void
}

@MainActor
final class ToolStore: ObservableObject {
    let signer = SAPSigner()
    let versions = VersionService()
    let metadataStore = VersionMetadataStore()
    let downloads: DownloadManager
    let installation = InstallationService()
    lazy var apple = AppleService(signer: signer)
    @Published var settings: ToolSettings {
        didSet {
            do { LocalResources.defaults.set(try JSONEncoder().encode(settings), forKey: LocalResources.settings) }
            catch { errorMessage = AppText.text("Couldn't save settings: \(error.localizedDescription)") }
            downloads.configure(settings)
            if oldValue.store != settings.store, hasSearched { search() }
        }
    }
    @Published var tab = 0
    @Published var searchText = ""
    @Published private(set) var searchError: String?
    @Published private(set) var lastSearchTerm = ""
    @Published private(set) var favorites: [StoreApp] = []
    private var favoritesStorageError: String?
    private var ownedStorageError: String?
    @Published private(set) var ownedRevision = UUID()
    @Published private(set) var ownedError: String?
    @Published private(set) var results: [StoreApp] = []
    @Published private(set) var localResults: [StoreApp] = []
    private var appCatalog: [String: [StoreApp]] = [:]
    private var nameCatalog: [AppNameEntry] = []
    @Published private(set) var cacheLoading = true
    @Published var undoNotice: UndoNotice?
    private var cacheLoadTask: Task<Void, Never>?
    private let cacheWrites = DispatchQueue(label: "iPadn.catalog-writes", qos: .utility)
    private var resultsContext: StoreContext?
    private var favoriteTask: Task<Void, Never>?
    @Published private(set) var accountRemoving: String?

    private func saveCache<T: Encodable>(_ value: T, filename: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cacheWrites.async {
                do { try LocalResources.save(value, filename: filename); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private var catalogRequested = false
    private var ownedAutoAttempted = Set<String>()
    @Published private(set) var searching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var searchHistory: [SearchHistoryItem] = []
    @Published private(set) var owned: [OwnedApp] = []
    @Published private(set) var ownedLoading = false
    @Published var errorMessage: String?
    @Published private(set) var availableUpdates: [String: StoreApp] = [:]
    private var updatesChecked: (date: Date, keys: Set<String>)?
    @Published private(set) var keptVersions: [String: String] =
        LocalResources.defaults.dictionary(forKey: "storage_keptVersions") as? [String: String] ?? [:]
    @Published private(set) var watch: [String: WatchRecord] = [:]
    @Published private(set) var watchChecking = false
    private var watchChecked: (date: Date, keys: Set<String>)?
    private var watchRecheck = false
    private var officialVersionCache: [String: (date: Date, versions: [AppVersion])] = [:]
    @Published var infoMessage: String?
    struct VerificationRequest: Identifiable {
        let id = UUID()
        let accountID: String
        let retry: (@MainActor () -> Void)?
    }
    @Published var verificationRequest: VerificationRequest?
    func requestVerification(retry: (@MainActor () -> Void)? = nil) {
        guard let id = apple.activeID else { errorMessage = "Sign in to your Apple Account on the Account page first"; return }
        verificationRequest = VerificationRequest(accountID: id, retry: retry)
    }
    #if DEBUG
    private var visualPreview = false
    #endif
    private var searchTask: Task<Void, Never>?
    private var localSearchTask: Task<Void, Never>?
    private var localSearchID = UUID()
    private var searchID = UUID()
    private var ownedByAccount: [String: [OwnedApp]] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var lastAccountID: String?
    private var ownedArtworkAttempted = Set<String>()

    init(downloadManager: DownloadManager? = nil) {
        downloads = downloadManager ?? DownloadManager()
        if let data = LocalResources.defaults.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        if let data = LocalResources.defaults.data(forKey: LocalResources.searchHistory) {
            searchHistory = (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
        }
        if ["https://api.scripting.fun/ipa-plist", "https://xiaobai.app/install"].contains(settings.plistServer) { settings.plistServer = "" }
        downloads.configure(settings)
        apple.$activeID.sink { [weak self] id in
            guard let self = self else { return }
            self.ownedRevision = UUID()
            self.ownedError = nil
            self.owned = id.flatMap { self.ownedByAccount[$0] } ?? []
            self.ownedListed = [:]
            self.updateLocalResults()
        }.store(in: &subscriptions)
        lastAccountID = apple.activeID
        apple.$activeID.dropFirst().removeDuplicates().sink { [weak self] id in
            Task { @MainActor in self?.accountChanged(to: id) }
        }.store(in: &subscriptions)
        cacheLoadTask = Task { await loadCachedState() }
    }

    private func loadCachedState() async {
        struct Snapshot {
            var favorites: [StoreApp] = []
            var watch: [String: WatchRecord] = [:]
            var owned: [String: [OwnedApp]] = [:]
            var catalog: [String: [StoreApp]] = [:]
            var names: [AppNameEntry] = []
            var favoritesError: String?
            var ownedError: String?
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            var snapshot = Snapshot()
            do { snapshot.favorites = try LocalResources.loadChecked([StoreApp].self, filename: "favorites.json") ?? [] }
            catch { snapshot.favoritesError = AppText.text("Couldn't read the followed list; the original file was kept.") }
            do { snapshot.owned = try LocalResources.loadChecked([String: [OwnedApp]].self, filename: LocalResources.ownedFilename) ?? [:] }
            catch { snapshot.ownedError = AppText.text("Couldn't read the purchase cache; the original file was kept so other accounts' records aren't overwritten.") }
            snapshot.watch = LocalResources.load([String: WatchRecord].self, filename: "watch.json") ?? [:]
            snapshot.catalog = LocalResources.load([String: [StoreApp]].self, filename: "app-catalog.json") ?? [:]
            snapshot.names = (LocalResources.load([AppNameEntry].self, filename: AppNameCatalog.cacheFile) ?? []) + AppNameCatalog.bundled()
            return snapshot
        }.value
        #if DEBUG
        if visualPreview {
            nameCatalog = snapshot.names; cacheLoading = false
            updateLocalResults(); return
        }
        #endif
        favorites = snapshot.favorites; watch = snapshot.watch; ownedByAccount = snapshot.owned
        appCatalog = snapshot.catalog; nameCatalog = snapshot.names
        favoritesStorageError = snapshot.favoritesError; ownedStorageError = snapshot.ownedError
        if let issue = snapshot.favoritesError ?? snapshot.ownedError { errorMessage = issue }
        owned = apple.activeID.flatMap { ownedByAccount[$0] } ?? []
        cacheLoading = false
        updateLocalResults()
    }

    func search(_ text: String? = nil) {
        if let text = text { searchText = text }
        let input = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        if cacheLoading {
            searching = true
            searchTask = Task {
                await cacheLoadTask?.value
                guard !Task.isCancelled else { return }
                search(input)
            }
            return
        }
        let id = UUID(); searchID = id
        let context = settings.store
        let limit = settings.searchLimit
        if input != lastSearchTerm || resultsContext != context { results = [] }
        resultsContext = context
        localResults = []
        updateLocalResults(for: input)
        searching = true; hasSearched = true; searchError = nil; lastSearchTerm = input
        searchTask = Task {
            defer { if self.searchID == id { self.searching = false } }
            do {
                let query = try SearchQuery.parse(input)
                let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
                var apps = try await StoreService.search(query, store: context, limit: limit, accountCountry: accountCountry)
                if case .appID(let appID, _) = query, apps.isEmpty {
                    var fallback = knownApp(appID) ?? StoreApp(id: appID, name: "App \(appID)", price: "")
                    fallback.delisted = true
                    apps = [fallback]
                }
                if case .appID(_, let versionID) = query, let versionID {
                    apps = apps.map {
                        var result = $0
                        result.externalVersionID = versionID
                        return result
                    }
                }
                try Task.checkCancellation()
                guard searchID == id else { return }
                results = apps
                let remoteIDs = Set(apps.map(\.id))
                localResults.removeAll { remoteIDs.contains($0.id) }
                let key = context.platform.rawValue
                let listed = apps.filter { $0.delisted != true }.map { app -> StoreApp in var app = app; app.description = ""; return app }
                appCatalog[key] = Array(AppSearchIndex.unique(listed + (appCatalog[key] ?? [])).prefix(1000))
                let snapshot = appCatalog
                cacheWrites.async { try? LocalResources.save(snapshot, filename: "app-catalog.json") }
                remember(input)
                searching = false
                await fillMissingArtwork(searchID: id, store: context, accountCountry: accountCountry)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, searchID == id {
                    searchError = AppErrorMessage.forSearch(error)
                }
            }
        }
    }
    private func knownApp(_ id: String) -> StoreApp? {
        let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app)
            + appCatalog.values.flatMap { $0 } + nameCatalog.map(\.app)
        guard var app = known.first(where: { $0.id == id }) else { return nil }
        if app.iconURL == nil { app.iconURL = localArtwork(id) ?? known.first { $0.id == id && $0.iconURL != nil }?.iconURL }
        return app
    }

    func localArtwork(_ id: String) -> URL? {
        for job in downloads.jobs where job.app.id == id {
            if let icon = job.displayApp(packageIcon: downloads.packageIconURL(job)).iconURL { return icon }
        }
        return nil
    }

    private func fillMissingArtwork(searchID id: UUID, store context: StoreContext, accountCountry: String?) async {
        func local(_ apps: [StoreApp]) -> [StoreApp] {
            apps.map { app in
                var app = app
                if app.iconURL == nil { app.iconURL = localArtwork(app.id) }
                return app
            }
        }
        results = local(results)
        localResults = local(localResults)
        let missing = Array(Set((results + localResults)
            .filter { $0.iconURL == nil && !$0.id.isEmpty && $0.id.allSatisfy({ $0.isASCII && $0.isNumber }) }
            .map(\.id))).prefix(50)
        guard !missing.isEmpty,
              let icons = try? await StoreService.artwork(Array(missing), store: context, accountCountry: accountCountry),
              !icons.isEmpty, searchID == id else { return }
        func filled(_ apps: [StoreApp]) -> [StoreApp] {
            apps.map { app in
                var app = app
                if app.iconURL == nil { app.iconURL = icons[app.id] }
                return app
            }
        }
        results = filled(results)
        localResults = filled(localResults)
    }

    private func updateLocalResults(for input: String? = nil) {
        localSearchTask?.cancel()
        let request = UUID(); localSearchID = request
        guard case .keyword(let term)? = try? SearchQuery.parse(input ?? lastSearchTerm) else { return }
        let context = settings.store, queryID = searchID, directory = nameCatalog
        let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app) + (appCatalog[settings.store.platform.rawValue] ?? [])
        localSearchTask = Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                let saved = AppSearchIndex.search(term, apps: known)
                let named = AppNameCatalog.search(term, platform: context.platform, entries: directory)
                return AppSearchIndex.unique(saved + named)
            }.value
            guard !Task.isCancelled, localSearchID == request, searchID == queryID, settings.store == context else { return }
            let remoteIDs = Set(results.map(\.id))
            localResults = candidates.filter { !remoteIDs.contains($0.id) }
        }
    }

    func loadNameCatalog() async {
        await cacheLoadTask?.value
        guard !catalogRequested else { return }
        catalogRequested = true
        #if DEBUG
        if visualPreview { return }
        #endif
        do {
            let entries = try await AppNameCatalog.updated()
            try Task.checkCancellation()
            nameCatalog = entries + AppNameCatalog.bundled()
            cacheWrites.async { try? LocalResources.save(entries, filename: AppNameCatalog.cacheFile) }
            updateLocalResults()
        } catch { }
    }

    private func accountChanged(to id: String?) {
        guard id != lastAccountID else { return }
        let previous = lastAccountID
        lastAccountID = id
        guard let id, let account = apple.accounts.first(where: { $0.id == id }) else {
            if let previous, apple.accounts.contains(where: { $0.id == previous }) { infoMessage = AppText.text("Signed out") }
            return
        }
        infoMessage = AppText.text("Switched to \(account.name.isEmpty ? account.id : account.name)")
        if let country = StoreService.country(forStorefront: account.storeFront), settings.store.country != country {
            settings.store.country = country
        } else if hasSearched {
            search()
        }
        #if DEBUG
        if visualPreview { return }
        #endif
        Task { await refreshOwned() }
    }

    func ensureOwnedLoaded() async {
        await cacheLoadTask?.value
        #if DEBUG
        if visualPreview { return }
        #endif
        guard let id = apple.activeID, ownedByAccount[id] == nil, !ownedLoading,
              ownedAutoAttempted.insert(id).inserted else { return }
        await refreshOwned()
    }

    func cancelSearch() { searchTask?.cancel(); localSearchTask?.cancel(); searchID = UUID(); searching = false; hasSearched = !results.isEmpty || !localResults.isEmpty; searchError = nil }
    func clearSearch() { cancelSearch(); searchText = ""; results = []; localResults = []; hasSearched = false; lastSearchTerm = "" }
    func isFavorite(_ app: StoreApp) -> Bool { favorites.contains { $0.id == app.id } }
    func toggleFavorite(_ app: StoreApp) {
        let previous = favoriteTask
        favoriteTask = Task {
            await previous?.value
            await changeFavorite(app)
        }
    }
    private func changeFavorite(_ app: StoreApp) async {
        guard !cacheLoading else { infoMessage = AppText.text("Loading local records. Try again shortly."); return }
        guard favoritesStorageError == nil else { errorMessage = favoritesStorageError; return }
        var next = favorites
        let following = !next.contains(where: { $0.id == app.id })
        let previousIndex = next.firstIndex { $0.id == app.id } ?? 0
        if following { next.insert(app, at: 0) } else { next.removeAll { $0.id == app.id } }
        do { try await saveCache(next, filename: "favorites.json"); favorites = next; updateLocalResults() }
        catch { errorMessage = AppText.text("Couldn't save followed apps: \(error.localizedDescription)"); return }
        if following {
            Task { await checkWatched(force: true) }
            if settings.watchNotifications {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            let previousRecords = watch.filter { $0.value.id == app.id }
            watch = watch.filter { $0.value.id != app.id }
            persistWatch()
            undoNotice = UndoNotice(message: AppText.text("Unfollowed \(app.name)")) { [weak self] in
                guard let self, !self.isFavorite(app) else { return }
                let previous = self.favoriteTask
                self.favoriteTask = Task {
                    await previous?.value
                    guard !self.isFavorite(app) else { return }
                    var restored = self.favorites
                    restored.insert(app, at: min(previousIndex, restored.count))
                    do {
                        try await self.saveCache(restored, filename: "favorites.json")
                        self.favorites = restored
                        self.watch.merge(previousRecords) { current, _ in current }
                        self.persistWatch(); self.updateLocalResults()
                    }
                    catch { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    var watchCountry: String {
        (apple.active.flatMap { StoreService.country(forStorefront: $0.storeFront) } ?? settings.store.country).uppercased()
    }
    func watchRecord(_ id: String) -> WatchRecord? { watch[WatchRecord.key(id: id, country: watchCountry)] }

    typealias WatchEvent = (app: StoreApp, change: WatchChange, currency: String, country: String)

    @discardableResult
    func checkWatched(force: Bool = false) async -> [WatchEvent] {
        await cacheLoadTask?.value
        #if DEBUG
        if visualPreview { return [] }
        #endif
        let apps = favorites
        let ids = Set(apps.map(\.id))
        let primary = watchCountry
        var countries = [primary]
        for country in settings.priceRegions.map({ $0.uppercased() }) where !countries.contains(country) { countries.append(country) }
        let keys = ids.union(countries.map { "@" + $0 })
        guard !apps.isEmpty else { return [] }
        if watchChecking {
            if force { watchRecheck = true }
            return []
        }
        if !force, let checked = watchChecked, checked.keys == keys, Date().timeIntervalSince(checked.date) < 3 * 3600 { return [] }
        watchChecking = true
        defer { watchChecking = false }
        var listings: [String: [String: StoreApp]] = [:]
        await withTaskGroup(of: (String, [String: StoreApp]?).self) { group in
            for country in countries {
                group.addTask { (country, try? await StoreService.lookup(ids: Array(ids), country: country).apps) }
            }
            for await (country, found) in group { if let found { listings[country] = found } }
        }
        guard var found = listings[primary] else { return [] }
        let missing = apps.map(\.id).filter { id in
            guard found[id] == nil, let record = watch[WatchRecord.key(id: id, country: primary)] else { return false }
            return record.listed && !record.delisted
        }
        var unsure = Set<String>()
        if !missing.isEmpty {
            if let again = try? await StoreService.lookup(ids: missing, country: primary).apps {
                found.merge(again) { first, _ in first }
            } else {
                unsure = Set(missing)
            }
        }
        listings[primary] = found
        guard !Task.isCancelled, primary == watchCountry else { return [] }
        var records = watch
        var events: [WatchEvent] = []
        var refreshed = favorites
        for app in apps where refreshed.contains(where: { $0.id == app.id }) {
            for (country, found) in listings where !(country == primary && unsure.contains(app.id)) {
                let key = WatchRecord.key(id: app.id, country: country)
                let listing = found[app.id]
                let result = WatchService.update(records[key], id: app.id, country: country, listing: listing)
                records[key] = result.record
                let changes = country == primary ? result.changes : result.changes.filter {
                    if case .priceDrop = $0 { return true }; if case .free = $0 { return true }; return false
                }
                events += changes.filter { WatchService.notifies($0, target: settings.targetPrices ? result.record.target : nil) }
                    .map { (app: listing ?? app, change: $0, currency: result.record.currency, country: country) }
            }
            if let listing = found[app.id], let index = refreshed.firstIndex(where: { $0.id == app.id }) {
                var updated = refreshed[index]
                if !listing.version.isEmpty { updated.version = listing.version }
                updated.price = listing.price; updated.priceValue = listing.priceValue; updated.currency = listing.currency
                if updated.iconURL == nil { updated.iconURL = listing.iconURL }
                refreshed[index] = updated
            }
        }
        let followed = Set(favorites.map(\.id))
        watch = records.filter { followed.contains($0.value.id) }
        watchChecked = (Date(), keys)
        persistWatch()
        if refreshed != favorites {
            let metadata = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let previous = favoriteTask
            favoriteTask = Task {
                await previous?.value
                let next = self.favorites.map { metadata[$0.id] ?? $0 }
                do { try await self.saveCache(next, filename: "favorites.json"); self.favorites = next }
                catch { self.errorMessage = AppText.text("Couldn't save followed apps: \(error.localizedDescription)") }
            }
        }
        if watchRecheck {
            watchRecheck = false
            Task { await self.checkWatched(force: true) }
        }
        return events
    }

    func setWatchTarget(_ target: Double?, id: String, country: String) {
        let key = WatchRecord.key(id: id, country: country)
        guard watch[key] != nil else { return }
        watch[key]?.target = target.flatMap { $0 > 0 ? $0 : nil }
        persistWatch()
    }

    private func persistWatch() {
        let snapshot = watch
        cacheWrites.async { try? LocalResources.save(snapshot, filename: "watch.json") }
    }

    func notifyWatchChanges(_ events: [WatchEvent]) {
        let primary = watchCountry
        let lines = events.compactMap { event in
            WatchService.message(event.change, currency: event.currency).map { message in
                event.country == primary
                    ? AppText.text("\(event.app.name): \(message)")
                    : AppText.text("\(event.app.name) (\(StoreRegions.name(event.country))): \(message)")
            }
        }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = lines.count == 1 ? AppText.text("Followed apps changed") : AppText.text("\(lines.count) followed apps changed")
        let shown = lines.prefix(4).joined(separator: "\n")
        content.body = lines.count > 4 ? shown + "\n" + AppText.text("and more") : shown
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-" + UUID().uuidString, content: content, trigger: nil))
    }

    private func remember(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = searchHistory.firstIndex(where: { $0.term == term }) {
            var item = searchHistory.remove(at: index); item.count += 1; item.lastUsed = Date(); searchHistory.insert(item, at: 0)
        } else { searchHistory.insert(SearchHistoryItem(term: term, count: 1, lastUsed: Date()), at: 0) }
        searchHistory = Array(searchHistory.prefix(50)); persistHistory()
    }
    func removeHistory(_ term: String) {
        guard let index = searchHistory.firstIndex(where: { $0.term == term }) else { return }
        let item = searchHistory.remove(at: index); persistHistory()
        undoNotice = UndoNotice(message: AppText.text("Search entry deleted")) { [weak self] in
            guard let self, !self.searchHistory.contains(where: { $0.term == term }) else { return }
            self.searchHistory.insert(item, at: min(index, self.searchHistory.count))
            self.searchHistory = Array(self.searchHistory.prefix(50)); self.persistHistory()
        }
    }
    func clearHistory() {
        let previous = searchHistory
        searchHistory.removeAll(); persistHistory()
        undoNotice = UndoNotice(message: AppText.text("Recent searches cleared")) { [weak self] in
            guard let self else { return }
            let current = Set(self.searchHistory.map(\.term))
            self.searchHistory = Array((self.searchHistory + previous.filter { !current.contains($0.term) }).prefix(50))
            self.persistHistory()
        }
    }
    func undoLastAction() {
        let notice = undoNotice; undoNotice = nil
        notice?.restore()
    }
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) { LocalResources.defaults.set(data, forKey: LocalResources.searchHistory) }
    }

    func loadVersions(for app: StoreApp, force: Bool = false, official: Bool = false) async throws -> [AppVersion] {
        #if DEBUG
        if visualPreview { return [AppVersion(id: "123456789", version: "3.2.1", source: "Version notes"), AppVersion(id: "123456788", version: "3.1.0", source: "Version notes")] }
        #endif
        let context = settings.store
        if official, let account = apple.activeID {
            let key = "\(account)|\(context.platform.rawValue)|\(context.country)|\(app.id)"
            if !force, let hit = officialVersionCache[key], Date().timeIntervalSince(hit.date) < 30 * 60 { return hit.versions }
            let list = try await appleVersions(for: app, context: context, force: force)
            officialVersionCache[key] = (Date(), list)
            return list
        }
        if context.platform == .macOS {
            guard let id = try await MacStoreOfferService.latestVersionID(appID: app.id, bundleID: app.bundleID, country: context.country)
            else { return [] }
            return [AppVersion(id: id, version: app.version.isEmpty ? AppVersion.unknown : app.version, source: "App Store")]
        }
        if context.platform == .tvOS {
            guard let listing = try await StoreService.platformApp(app.id, store: context),
                  let id = listing.externalVersionID, !id.isEmpty else { return [] }
            return [AppVersion(id: id, version: listing.version.isEmpty ? AppVersion.unknown : listing.version, source: "Apple TV")]
        }
        return try await versions.thirdParty(app.id, sources: settings.versionSources, force: force)
    }

    private func appleVersions(for app: StoreApp, context: StoreContext, force: Bool) async throws -> [AppVersion] {
        var seen = Set<String>()
        if context.platform == .macOS {
            let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache, allowLicenseAcquisition: false)
            let ids = offer.externalVersionIDs.isEmpty ? [offer.versionID] : Array(offer.externalVersionIDs.reversed())
            return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
                AppVersion(id: id, version: id == offer.versionID && !offer.displayVersion.isEmpty ? offer.displayVersion : AppVersion.unknown, source: "Apple")
            }
        }
        let asset = try await apple.asset(appID: app.id, versionID: nil, store: context,
                                          useCache: settings.useSignerCache, allowLicenseAcquisition: false)
        let third = context.platform == .iOS ? (try? await versions.thirdParty(app.id, sources: settings.versionSources, force: force)) ?? [] : []
        let names = Dictionary(third.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let ids = asset.externalVersionIDs.isEmpty ? [asset.app.externalVersionID ?? ""] : Array(asset.externalVersionIDs.reversed())
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
            AppVersion(id: id, version: id == asset.app.externalVersionID ? asset.app.version : names[id] ?? AppVersion.unknown, source: "Apple")
        }
    }

    func cachedVersionMetadata(app: StoreApp, versionIDs: [String]) async -> [String: VersionMetadata] {
        let platform = settings.store.platform
        let keys = Dictionary(versionIDs.map { (VersionMetadataStore.key(platform: platform, appID: app.id, versionID: $0), $0) },
                              uniquingKeysWith: { first, _ in first })
        let found = await metadataStore.cached(Array(keys.keys))
        return Dictionary(found.compactMap { key, value in keys[key].map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    func versionMetadata(app: StoreApp, versionID: String) async throws -> VersionMetadata {
        #if DEBUG
        if visualPreview { return VersionMetadata(version: "3.2.1", released: Date(timeIntervalSince1970: 1_714_694_400)) }
        #endif
        let platform = settings.store.platform
        let useCache = settings.useSignerCache
        let key = VersionMetadataStore.key(platform: platform, appID: app.id, versionID: versionID)
        return try await metadataStore.load(key) { @MainActor [apple] in
            if platform == .macOS {
                let offer = try await apple.macPackageOffer(app, versionID: versionID, useCache: useCache,
                                                            allowLicenseAcquisition: false)
                guard !offer.displayVersion.isEmpty else { throw RemoteZip.Failure.notFound }
                return VersionMetadata(version: offer.displayVersion, released: nil)
            }
            let url = try await apple.versionTicket(appID: app.id, versionID: versionID, useCache: useCache)
            return try await RemoteZip.versionMetadata(HTTPRangeReader(url: url))
        }
    }

    func startDownload(app: StoreApp, versionID: String?) async throws {
        var asset = try await SAPSigner.$userInitiated.withValue(true) {
            try await apple.asset(appID: app.id, versionID: versionID, store: settings.store, useCache: settings.useSignerCache)
        }
        if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
        try downloads.enqueue(asset)
        if let icon = asset.app.iconURL {
            func patched(_ apps: [StoreApp]) -> [StoreApp] {
                apps.map { var item = $0; if item.id == app.id && item.iconURL == nil { item.iconURL = icon }; return item }
            }
            results = patched(results)
            localResults = patched(localResults)
        }
        tab = 1
    }

    func checkForUpdates(force: Bool = false) async {
        #if DEBUG
        if visualPreview { return }
        #endif
        let jobs = downloads.jobs.filter { $0.status != .failed && $0.updateKey != nil && !$0.storeVersion.isEmpty }
        let keys = Set(jobs.filter { $0.status == .completed }.compactMap(\.updateKey))
        if !force, let checked = updatesChecked, checked.keys == keys,
           Date().timeIntervalSince(checked.date) < 6 * 3600 { return }
        guard !keys.isEmpty else { availableUpdates = [:]; return }
        let country = apple.active.flatMap { StoreService.country(forStorefront: $0.storeFront) } ?? settings.store.country
        var newest: [String: String] = [:]
        for job in jobs {
            guard let key = job.updateKey else { continue }
            if let known = newest[key], !VersionOrder.isNewer(job.storeVersion, than: known) { continue }
            newest[key] = job.storeVersion
        }
        var listings: [String: StoreApp] = [:]
        let byPlatform = Dictionary(grouping: keys, by: { $0.split(separator: "|").first.map(String.init) ?? "" })
        func ids(_ platform: AppPlatform) -> [String] {
            (byPlatform[platform.rawValue] ?? []).compactMap { $0.split(separator: "|").last.map(String.init) }
        }
        let lookupIDs = Set(ids(.iOS) + ids(.iPadOS) + ids(.macOS))
        if let found = try? await StoreService.lookup(ids: Array(lookupIDs), country: country) {
            for platform in [AppPlatform.iOS, .iPadOS, .macOS] {
                for id in ids(platform) {
                    guard let app = found.apps[id] else { continue }
                    if platform == .macOS && !found.nativeMac.contains(id) { continue }
                    listings["\(platform.rawValue)|\(id)"] = app
                }
            }
        }
        for id in ids(.tvOS).prefix(30) {
            if let app = try? await StoreService.platformApp(id, store: StoreContext(country: country, platform: .tvOS)) {
                listings["\(AppPlatform.tvOS.rawValue)|\(id)"] = app
            }
        }
        guard !Task.isCancelled else { return }
        let outgrown = keptVersions.filter { key, kept in newest[key].map { VersionOrder.isNewer($0, than: kept) } ?? false }
        if !outgrown.isEmpty {
            for key in outgrown.keys { keptVersions[key] = nil }
            LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
        }
        var updates: [String: StoreApp] = [:]
        for (key, app) in listings where keptVersions[key] == nil {
            if let current = newest[key], VersionOrder.isNewer(app.version, than: current) { updates[key] = app }
        }
        availableUpdates = updates
        updatesChecked = (Date(), keys)
    }

    @Published private(set) var appUpdate: AppRelease?
    @Published private(set) var appUpdateChecking = false
    private(set) var appUpdateDiagnostic = "No update check attempted in this session."

    @discardableResult
    func checkAppUpdate(force: Bool = false) async -> Bool {
        #if DEBUG
        if visualPreview { return false }
        #endif
        let key = "storage_appUpdateChecked"
        if !force, let last = LocalResources.defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 12 * 3600 {
            if appUpdate == nil, let data = LocalResources.defaults.data(forKey: "storage_appUpdate") {
                appUpdate = AppUpdateService.newer(try? JSONDecoder().decode(AppRelease.self, from: data))
            }
            return true
        }
        guard !appUpdateChecking else { return false }
        appUpdateChecking = true
        defer { appUpdateChecking = false }
        guard let latest = await AppUpdateService.latest(report: { self.appUpdateDiagnostic = $0 }) else { return false }
        LocalResources.defaults.set(Date(), forKey: key)
        LocalResources.defaults.set(try? JSONEncoder().encode(latest), forKey: "storage_appUpdate")
        appUpdate = AppUpdateService.newer(latest)
        if appUpdate == nil { AppUpdateService.removeDownloads() }
        return true
    }

    func notifyAppUpdate() {
        guard let release = appUpdate else { return }
        let key = "storage_appUpdateNotified"
        guard LocalResources.defaults.string(forKey: key) != release.version else { return }
        LocalResources.defaults.set(release.version, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = AppText.text("iPadn \(release.version) is available")
        content.body = AppText.text("Open iPadn, then check Settings for what's new and download the update.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "app-update-" + release.version, content: content, trigger: nil))
    }

    @Published private(set) var ownedListed: [String: Bool] = [:]
    @Published private(set) var checkingListings = false

    func checkOwnedListings() async -> Int? {
        guard !owned.isEmpty, !checkingListings else { return nil }
        let accountID = apple.activeID
        let country = watchCountry
        let ids = owned.map(\.id)
        checkingListings = true
        defer { checkingListings = false }
        guard var found = try? await StoreService.lookup(ids: ids, country: country).apps else { return nil }
        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            guard let again = try? await StoreService.lookup(ids: missing, country: country).apps else { return nil }
            found.merge(again) { first, _ in first }
        }
        guard apple.activeID == accountID else { return nil }
        ownedListed = Dictionary(uniqueKeysWithValues: ids.map { ($0, found[$0] != nil) })
        return ownedListed.values.filter { !$0 }.count
    }

    func exportOwned() throws -> URL {
        let downloaded = Set(downloads.jobs.filter { $0.status == .completed }.map(\.app.id))
        let text = PurchaseExport.csv(owned, listed: ownedListed, downloaded: downloaded)
        let stamp = Date().formatted(.iso8601.year().month().day())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(AppText.text("iPadn-Purchased-\(stamp)") + ".csv")
        try Data(("\u{FEFF}" + text).utf8).write(to: file, options: .atomic)
        return file
    }

    func keepsVersion(_ job: DownloadJob) -> Bool { job.updateKey.map { keptVersions[$0] == job.storeVersion } ?? false }
    func keepVersion(_ keep: Bool, of job: DownloadJob) {
        guard let key = job.updateKey else { return }
        if keep {
            keptVersions[key] = job.storeVersion
            availableUpdates[key] = nil
        } else {
            keptVersions[key] = nil
            Task { await checkForUpdates(force: true) }
        }
        LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
    }

    func notifyNewUpdates() {
        let key = "storage_notifiedUpdates"
        var notified = LocalResources.defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let fresh = availableUpdates.filter { notified[$0.key] != $0.value.version }
        guard !fresh.isEmpty else { return }
        for (id, app) in fresh { notified[id] = app.version }
        LocalResources.defaults.set(notified, forKey: key)
        let names = fresh.values.sorted { $0.name < $1.name }.prefix(3).map { "\($0.name) \($0.version)" }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? AppText.text("\(fresh.values.first!.name) has an update") : AppText.text("\(fresh.count) apps have updates")
        let list = names.joined(separator: AppText.text(", ")) + (fresh.count > 3 ? AppText.text(" and more") : "")
        content.body = AppText.text("\(list). Open iPadn to download the new version.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-" + UUID().uuidString, content: content, trigger: nil))
    }

    func downloadUpdate(of job: DownloadJob) async throws {
        guard try await enqueueUpdate(of: job) else { return }
        infoMessage = AppText.text("Downloading the new version")
    }

    var updatableJobs: [DownloadJob] {
        var seen = Set<String>()
        return downloads.jobs.filter { job in
            guard job.status == .completed, let key = job.updateKey, availableUpdates[key] != nil else { return false }
            return seen.insert(key).inserted
        }
    }

    private func updateInProgress(_ key: String) -> Bool {
        downloads.jobs.contains { $0.updateKey == key && [.queued, .running, .pausing, .paused, .processing].contains($0.status) }
    }

    func downloadAllUpdates(of jobs: [DownloadJob]) async throws {
        #if DEBUG
        if visualPreview { infoMessage = AppText.text("Added \(jobs.count) downloads"); return }
        #endif
        var added = 0
        var failures: [String] = []
        defer {
            if added > 0 { infoMessage = AppText.text("Added \(added) downloads") }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
        for job in jobs {
            guard let key = job.updateKey, !updateInProgress(key) else { continue }
            do {
                if try await enqueueUpdate(of: job) { added += 1 }
            } catch let error where error is AppleLoginError || error is AppleAuthError || error is CancellationError {
                throw error
            } catch {
                failures.append(AppText.text("\(job.app.name.isEmpty ? job.app.id : job.app.name): \(error.localizedDescription)"))
                if error is DownloadQueueLimitError { break }
            }
        }
    }

    private func enqueueUpdate(of job: DownloadJob) async throws -> Bool {
        guard let key = job.updateKey, let platform = job.updatePlatform, let latest = availableUpdates[key] else { return false }
        guard apple.active != nil else { throw ToolError.message(AppText.text("Sign in to your Apple Account on the Account page first")) }
        var app = latest
        if app.iconURL == nil { app.iconURL = job.app.iconURL }
        if platform == .macOS {
            let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache)
            try downloads.enqueueOfficialMacPackage(offer, for: app)
        } else {
            var asset = try await apple.asset(appID: job.app.id, versionID: nil,
                store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
            if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
            try downloads.enqueue(asset)
        }
        return true
    }

    func startDownloads(_ apps: [StoreApp], progress: @escaping (Int) -> Void) async -> (added: Int, failures: [String]) {
        var added = 0
        var failures: [String] = []
        for (index, app) in apps.enumerated() {
            if Task.isCancelled { break }
            do {
                if settings.store.platform == .macOS {
                    let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache)
                    try downloads.enqueueOfficialMacPackage(offer, for: app)
                } else {
                    var asset = try await apple.asset(appID: app.id, versionID: nil, store: settings.store,
                                                      useCache: settings.useSignerCache)
                    if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
                    try downloads.enqueue(asset)
                }
                added += 1
            } catch AppleLoginError.verificationRequired {
                let remaining = Array(apps[index...])
                requestVerification { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        let result = await self.startDownloads(remaining) { _ in }
                        if result.added > 0 { self.infoMessage = AppText.text("Added \(result.added) downloads") }
                        if !result.failures.isEmpty { self.errorMessage = result.failures.joined(separator: "\n") }
                    }
                }
                break
            } catch let error where error is AppleAuthError || error is AppleLoginError {
                failures.append(AppText.text("Your Apple Account sign-in has expired. Sign in again in Accounts and try again."))
                break
            } catch {
                let message = error.localizedDescription
                failures.append(AppText.text("\(app.name.isEmpty ? app.id : app.name): \(message)"))
                if error is DownloadQueueLimitError { break }
            }
            progress(index + 1)
        }
        return (added, failures)
    }

    func refreshDownload(_ job: DownloadJob) async throws {
        guard job.status == .failed, job.asset != nil else { throw ToolError.message(AppText.text("This task can't be retried")) }
        guard apple.activeID == job.account else { throw ToolError.message(AppText.text("Switch back to the original download account first: \(job.account ?? "")")) }
        let platform: AppPlatform
        switch job.asset?.platform.lowercased() {
        case "appletvos", "tvos", "atv9": platform = .tvOS
        case "ipad": platform = .iPadOS
        default: platform = .iOS
        }
        let asset = try await apple.asset(appID: job.app.id, versionID: job.asset?.app.externalVersionID,
            store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
        try downloads.refreshFailed(job.id, asset: asset)
        tab = 1
    }

    func refreshOwned() async {
        await cacheLoadTask?.value
        guard accountRemoving == nil else { return }
        guard !ownedLoading, let id = apple.activeID else {
            if apple.activeID == nil { errorMessage = AppText.text("Sign in on the Account page first") }
            return
        }
        ownedLoading = true
        defer {
            ownedLoading = false
            if apple.activeID != id, apple.activeID != nil { Task { await self.refreshOwned() } }
        }
        do {
            let apps = try await apple.ownedApps(useCache: settings.useSignerCache)
            guard apple.activeID == id, accountRemoving == nil else { return }
            ownedError = nil
            let cached = Dictionary(owned.map { ($0.id, $0.iconURL) }, uniquingKeysWith: { first, _ in first })
            owned = apps.map { app in
                var item = app
                if item.iconURL == nil { item.iconURL = cached[item.id] ?? nil }
                return item
            }
            guard ownedStorageError == nil else { ownedError = ownedStorageError; return }
            var next = ownedByAccount; next[id] = owned
            try await saveCache(next, filename: LocalResources.ownedFilename)
            guard accountRemoving == nil else { return }
            ownedByAccount = next
            updateLocalResults()
            ownedRevision = UUID()
        } catch is CancellationError { }
        catch { if apple.activeID == id { ownedError = error.localizedDescription } }
    }
    func loadOwnedArtwork() async {
        #if DEBUG
        if visualPreview { return }
        #endif
        guard let account = apple.activeID, ownedStorageError == nil, accountRemoving == nil else { return }
        let context = settings.store
        var artworkContext = context
        artworkContext.platform = .iOS
        let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
        let revision = ownedRevision
        let ids = owned.filter { $0.iconURL == nil && !ownedArtworkAttempted.contains($0.id) }.map(\.id)
        for offset in stride(from: 0, to: ids.count, by: 20) {
            do {
                try Task.checkCancellation()
                let batch = Array(ids[offset..<min(offset + 20, ids.count)])
                let urls = try await StoreService.artwork(batch, store: artworkContext, accountCountry: accountCountry)
                try Task.checkCancellation()
                guard apple.activeID == account, settings.store == context, ownedRevision == revision, accountRemoving == nil else { return }
                ownedArtworkAttempted.formUnion(batch)
                if !urls.isEmpty {
                    var updated = owned
                    for index in updated.indices { if let url = urls[updated[index].id] { updated[index].iconURL = url } }
                    owned = updated
                    ownedByAccount[account] = owned
                    try await saveCache(ownedByAccount, filename: LocalResources.ownedFilename)
                }
                if offset + 20 < ids.count { try await Task.sleep(nanoseconds: 3_100_000_000) }
            } catch { return }
        }
    }

    func deleteAccount(_ id: String) async throws {
        guard !cacheLoading else { throw ToolError.message(AppText.text("Loading local records. Try again shortly.")) }
        guard accountRemoving == nil else { throw ToolError.message(AppText.text("An account is being removed. Try again shortly.")) }
        guard ownedStorageError == nil else { throw ToolError.message(ownedStorageError!) }
        accountRemoving = id
        defer { accountRemoving = nil }
        var next = ownedByAccount; next.removeValue(forKey: id)
        try await saveCache(next, filename: LocalResources.ownedFilename)
        do { try apple.remove(id) }
        catch {
            try await saveCache(ownedByAccount, filename: LocalResources.ownedFilename)
            throw error
        }
        ownedByAccount = next
    }

    func handleURL(_ url: URL) {
        if url.isFileURL {
            tab = 1
            Task { do { try await downloads.importFile(url) } catch { errorMessage = error.localizedDescription } }
        } else if url.scheme == "ipadn" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            if url.host == "open", let value = items.first(where: { $0.name == "tab" })?.value, let target = Int(value), (0...3).contains(target) {
                tab = target
                if items.contains(where: { $0.name == "check" && $0.value == "updates" }) {
                    Task { await checkForUpdates(force: true) }
                }
            } else if let id = items.first(where: { $0.name == "id" })?.value { tab = 0; search(id) }
            else if let address = items.first(where: { $0.name == "url" })?.value,
                    let download = URL(string: address) {
                do { try downloads.enqueueURL(download); tab = 1 } catch { errorMessage = error.localizedDescription }
            }
        } else if url.host == "apps.apple.com" { tab = 0; search(url.absoluteString) }
    }

    func exportBackup() throws -> URL {
        let backup = AppBackup(settings: settings, favorites: favorites, watch: watch,
                               keptVersions: keptVersions, searchHistory: searchHistory)
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Backup-\(day).json")
        try backup.encoded().write(to: url, options: .atomic)
        return url
    }
    func importBackup(_ data: Data) async throws {
        let backup = try AppBackup.decode(data)
        let next = AppBackup.merged(backup.favorites, with: favorites)
        let previous = favoriteTask
        await previous?.value
        try await saveCache(next, filename: "favorites.json")
        favorites = next
        let followed = Set(next.map(\.id))
        watch = watch.merging(backup.watch) { _, imported in imported }.filter { followed.contains($0.value.id) }
        persistWatch()
        keptVersions = keptVersions.merging(backup.keptVersions) { _, imported in imported }
        LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
        let terms = Set(backup.searchHistory.map(\.term))
        searchHistory = Array((backup.searchHistory + searchHistory.filter { !terms.contains($0.term) }).prefix(50))
        persistHistory()
        settings = backup.settings
        updateLocalResults()
        infoMessage = AppText.text("Backup imported")
        Task { await checkWatched(force: true) }
    }

    func exportDiagnostics() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Diagnostics.txt")
        try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticsText()
        infoMessage = AppText.text("Copied to clipboard")
    }
    func diagnosticsText() -> String {
        [
            "iPadn " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""), "Platform: \(settings.store.platform.title)", "Region: \(settings.store.country)",
            "Jobs: \(downloads.jobs.count)", "Concurrent limit: \(settings.maxConcurrentDownloads)",
            "Version sources: \(settings.versionSources.filter(\.enabled).count)",
            "Task states: " + downloads.jobs.map { "\($0.id.uuidString.prefix(8)): \($0.status.rawValue)" }.joined(separator: ", "),
            "Installation: " + (settings.nativeInstallation ? "native" : settings.automaticInstallation ? "one-tap" : settings.localInstallation ? "local certificate" : "proxy"),
            "Native installer: " + (NativeInstaller.isAvailable ? "linked" : "not linked") + ", pairing file: " + (NativeInstaller.hasPairingFile ? "yes" : "no"),
            "Runs inside LiveContainer: " + (InstallLog.insideLiveContainer ? "yes" : "no"),
            "Proxy or VPN on: " + (LocalHostRecord.proxyOrVPNActive ? "yes" : "no"),
            "iOS " + UIDevice.current.systemVersion,
            "Last login (metadata only):", apple.loginDiagnostic,
            "Last update check (metadata only):", appUpdateDiagnostic,
            "Recent request failures (metadata only):", RequestFailureLog.text,
            "Installation server log:", InstallLog.shared.text.isEmpty ? "(empty)" : InstallLog.shared.text,
            "Contains no credentials, cookies, Apple account names or download URLs."
        ].joined(separator: "\n")
    }
}


#if DEBUG
extension ToolStore {
    func prepareAccountPreview() {
        apple.prepareAccountPreview()
        owned = PreviewData.apps.enumerated().map { index, app in
            OwnedApp(id: app.id, bundleID: app.bundleID, name: app.name, version: app.version,
                     purchaseDate: Date().addingTimeInterval(-Double(index + 1) * 9 * 86400), iconURL: app.iconURL)
        }
    }
    func prepareArchivePreview() {
        searchText = "Forward"; lastSearchTerm = searchText; hasSearched = true
        updateLocalResults()
    }
    func prepareVisualPreview() {
        visualPreview = true
        cacheLoading = false
        results = []; hasSearched = false; searchText = ""
        favorites = [PreviewData.favorite]
        if ProcessInfo.processInfo.arguments.contains("--updates") {
            for app in PreviewData.updatable {
                var latest = app; latest.version = "99.0"
                availableUpdates["\(AppPlatform.iOS.rawValue)|\(app.id)"] = latest
            }
        }
        let day: TimeInterval = 86400
        var record = WatchRecord(id: PreviewData.favorite.id, country: watchCountry, version: "3.2", price: 18, currency: "CNY",
                                 history: [PricePoint(date: Date().addingTimeInterval(-30 * day), price: 30),
                                           PricePoint(date: Date().addingTimeInterval(-3 * day), price: 18)],
                                 started: Date().addingTimeInterval(-30 * day), checked: Date())
        record.change = .priceDrop(from: 30, to: 18); record.changed = Date().addingTimeInterval(-3 * day)
        watch = [record.key: record]
        searchHistory = ["Notion", "Spotify"].map { SearchHistoryItem(term: $0, count: 1, lastUsed: Date()) }
    }
}
#endif
