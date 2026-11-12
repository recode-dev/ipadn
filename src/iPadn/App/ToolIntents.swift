import AppIntents
import Foundation

struct SearchAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Search apps or a store link"
    static var description = IntentDescription("Open iPadn and search by name, App ID, store link, or App ID with version ID.")
    static var openAppWhenRun = true
    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search \(\.$query)") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try SearchQuery.parse(query)
        AppContainer.shared.tab = 0
        AppContainer.shared.search(query)
        return .result()
    }
}

struct ImportIPAIntent: AppIntent {
    static var title: LocalizedStringResource = "Import IPA package"
    static var description = IntentDescription("Imports a file into iPadn and opens Downloads. Useful for a shortcut in the share sheet.")
    static var openAppWhenRun = true
    @Parameter(title: "IPA file") var file: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Import \(\.$file)") }
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppContainer.shared
        store.tab = 1
        if let url = file.fileURL { try await store.downloads.importFile(url) }
        else {
            let name = PackageService.safeName(file.filename)
            guard ["ipa", "zip"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
                throw ToolError.message(AppText.text("Only IPA and ZIP files are supported"))
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try file.data.write(to: temporary, options: .atomic)
            try await store.downloads.importFile(temporary)
        }
        return .result()
    }
}

struct DownloadIPAURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Download IPA link"
    static var description = IntentDescription("Adds an HTTPS package link to the background download queue.")
    static var openAppWhenRun = true
    @Parameter(title: "HTTPS download link") var url: URL
    static var parameterSummary: some ParameterSummary { Summary("Download \(\.$url)") }
    @MainActor func perform() async throws -> some IntentResult {
        try AppContainer.shared.downloads.enqueueURL(url)
        AppContainer.shared.tab = 1
        return .result()
    }
}

/// Looks up an App ID or App Store link in the current storefront.
@MainActor
private func storeApp(_ input: String) async throws -> (app: StoreApp, versionID: String?) {
    guard case .appID(let id, let versionID) = try SearchQuery.parse(input) else {
        throw ToolError.message(AppText.text("Enter an App ID or App Store link"))
    }
    let store = AppContainer.shared
    let country = store.settings.store.country
    guard let app = try await StoreService.lookup(ids: [id], country: country).apps[id] else {
        throw ToolError.message(AppText.text("This app is not in the \(StoreRegions.name(country.uppercased())) store"))
    }
    return (app, versionID)
}

struct DownloadAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Download App"
    static var description = IntentDescription("Downloads the app for an App ID or App Store link (optionally with a version ID) with the current account, and opens Downloads.")
    static var openAppWhenRun = true
    @Parameter(title: "App ID or Store Link") var app: String
    static var parameterSummary: some ParameterSummary { Summary("Download \(\.$app)") }
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppContainer.shared
        guard store.apple.active != nil else { throw ToolError.message(AppText.text("Sign in to your Apple Account on the Account page first")) }
        let found = try await storeApp(app)
        await store.downloads.loaded()
        try await store.startDownload(app: found.app, versionID: found.versionID)
        return .result()
    }
}

struct CheckUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Downloaded Apps for Updates"
    static var description = IntentDescription("Compares downloaded apps with the store’s latest versions and returns the ones with a newer version.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let store = AppContainer.shared
        await store.downloads.loaded()
        await store.checkForUpdates(force: true)
        let lines = store.updatableJobs.compactMap { job -> String? in
            guard let key = job.updateKey, let latest = store.availableUpdates[key] else { return nil }
            return "\(job.app.name) \(job.app.version) → \(latest.version)"
        }
        let text = lines.isEmpty ? AppText.text("All downloaded apps are up to date.") : lines.joined(separator: "\n")
        return .result(value: lines, dialog: "\(text)")
    }
}

struct DownloadAllUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Download All Updates"
    static var description = IntentDescription("Checks downloaded apps for updates and queues every newer version.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppContainer.shared
        await store.downloads.loaded()
        await store.checkForUpdates(force: true)
        let jobs = store.updatableJobs
        guard !jobs.isEmpty else { return .result(dialog: "\(AppText.text("All downloaded apps are up to date."))") }
        store.tab = 1
        try await store.downloadAllUpdates(of: jobs)
        return .result(dialog: "\(AppText.text("Added \(jobs.count) downloads"))")
    }
}

struct DownloadStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Download Progress"
    static var description = IntentDescription("Returns the downloads in progress or waiting, with their progress.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let lines = manager.jobs.compactMap { job -> String? in
            let state = manager.progress(for: job.id).bytes
            let written = state?.written ?? job.downloaded, expected = max(state?.expected ?? 0, job.expected)
            let percent = (expected > 0 ? Double(written) / Double(expected) : 0).formatted(.percent.precision(.fractionLength(0)))
            switch job.status {
            case .running, .pausing: return AppText.text("\(job.app.name): downloading \(percent)%")
            case .queued: return AppText.text("\(job.app.name): waiting")
            case .paused: return AppText.text("\(job.app.name): paused \(percent)%")
            case .processing: return AppText.text("\(job.app.name): preparing")
            default: return nil
            }
        }
        let text = lines.isEmpty ? AppText.text("No downloads in progress.") : lines.joined(separator: "\n")
        return .result(value: lines, dialog: "\(text)")
    }
}

struct PauseAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause All Downloads"
    static var description = IntentDescription("Pauses downloads in progress or waiting; progress is kept.")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let count = manager.jobs.filter { $0.status == .running || $0.status == .queued }.count
        manager.pauseAll()
        return .result(dialog: "\(AppText.text("Paused \(count) downloads"))")
    }
}

struct ResumeAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume All Downloads"
    static var description = IntentDescription("Resumes every paused download.")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let count = manager.jobs.filter { $0.status == .paused }.count
        manager.resumeAll()
        return .result(dialog: "\(AppText.text("Resumed \(count) downloads"))")
    }
}

struct FollowAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Follow app"
    static var description = IntentDescription("Follows the app for an App ID or App Store link and tells you about new versions, price drops and free offers.")
    @Parameter(title: "App ID or Store Link") var app: String
    static var parameterSummary: some ParameterSummary { Summary("Watch \(\.$app)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppContainer.shared
        let found = try await storeApp(app).app
        if store.isFavorite(found) { return .result(dialog: "\(AppText.text("Already following \(found.name)"))") }
        store.toggleFavorite(found)
        return .result(dialog: "\(AppText.text("Following \(found.name)"))")
    }
}

struct ToolShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchAppIntent(), phrases: ["Search apps in \(.applicationName)"],
                    shortTitle: "Search apps", systemImageName: "magnifyingglass")
        AppShortcut(intent: ImportIPAIntent(), phrases: ["Import a package with \(.applicationName)"],
                    shortTitle: "Import IPA", systemImageName: "doc.badge.plus")
        AppShortcut(intent: CheckUpdatesIntent(), phrases: ["Check updates with \(.applicationName)"],
                    shortTitle: "Check for updates", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: DownloadStatusIntent(), phrases: ["Download progress in \(.applicationName)"],
                    shortTitle: "Download progress", systemImageName: "arrow.down.circle")
    }
}
