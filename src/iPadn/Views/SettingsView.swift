import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    /// Settings are grouped into pages, like the system's Settings app, so
    /// the first screen stays short.
    enum Page {
        case root, downloads, follow, appearance, lock, sources, maintenance
        var title: LocalizedStringKey {
            switch self {
            case .root: return "Settings"
            case .downloads: return "Download"
            case .follow: return "Follow"
            case .appearance: return "Appearance & icon"
            case .lock: return "App Lock"
            case .sources: return "Version sources"
            case .maintenance: return "Backup & maintenance"
            }
        }
    }
    var page = Page.root
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var icons = AppIconService()
    @State private var iconIssue: String?
    @State private var addingSource = false
    @State private var editingSourceID: UUID?
    /// Results of the last "check all sources", by source.
    @State private var sourceChecks: [UUID: SourceCheckState] = [:]
    @State private var share: SharedFile?
    @State private var resetSettings = false
    @State private var importingBackup = false
    @State private var pendingBackup: Data?
    @State private var clearCache = false
    /// The appearance the home screen icon has: fixed by the icon theme, or the
    /// system's (not iPadn's own appearance setting) when following the system.
    private var iconScheme: ColorScheme {
        switch icons.theme {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
    private func pageLink(_ page: Page, _ symbol: String, _ identifier: String) -> some View {
        NavigationLink { SettingsView(page: page) } label: { Label(page.title, systemImage: symbol) }
            .accessibilityIdentifier(identifier)
    }
    var body: some View {
        Form {
            if page == .root {
            Section {
                pageLink(.downloads, "arrow.down.circle", "settings.page.downloads")
                pageLink(.follow, "bell", "settings.page.follow")
                pageLink(.appearance, "paintbrush", "settings.page.appearance")
                pageLink(.lock, "lock", "settings.page.lock")
                pageLink(.sources, "clock.arrow.circlepath", "settings.page.sources")
                NavigationLink { InstallationSettingsView() } label: { Label("Installation settings", systemImage: "arrow.down.app") }
                    .accessibilityIdentifier("settings.installation")
                pageLink(.maintenance, "wrench.and.screwdriver", "settings.page.maintenance")
            }
            }
            if page == .downloads {
            Section {
                Stepper("Simultaneous downloads: \(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...6)
                Stepper("Queue limit: \(store.settings.maxQueuedDownloads)", value: $store.settings.maxQueuedDownloads, in: 1...100)
                Toggle("Notify when downloads finish", isOn: $store.settings.notifications)
                Toggle("New version alerts", isOn: $store.settings.updateNotifications)
                    .compatibleOnChange(of: store.settings.updateNotifications) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("Download over Wi‑Fi Only", isOn: $store.settings.wifiOnlyDownloads)
                    .accessibilityIdentifier("settings.wifi-only")
                Toggle("Install When Downloaded", isOn: $store.settings.autoInstall)
                    .accessibilityIdentifier("settings.auto-install")
                Toggle("Show Downloads in Live Activity", isOn: $store.settings.downloadLiveActivity)
                    .accessibilityIdentifier("settings.download-activity")
                Toggle("Compatible download mode", isOn: $store.settings.compatibleDownloadMode)
                if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                    Button(AppText.text("Try Background Downloads Again")) { store.downloads.retryBackgroundDownloads(); store.infoMessage = AppText.text("The next download will try background downloading again") }
                }
            } header: {
                Text("Download")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("With “New version alerts” off, the Download page no longer marks newer versions and no notifications are sent.")
                    Text("With “Download over Wi‑Fi Only”, downloads wait in the queue while only cellular data is available and continue on Wi‑Fi. “Install When Downloaded” opens the installer and starts installing while iPadn is open.")
                    Text("Shows download progress on the Lock Screen and in the Dynamic Island. While iPadn is in the background, progress is estimated from the measured speed and corrected when you return.")
                    if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                        Text("With the current signature, the system's background download service can't save files, so downloads now run inside the app. Keep iPadn in the foreground while downloading. After re-signing, tap “Try Background Downloads Again”.")
                    } else {
                        Text("If an enterprise re-sign or a specific environment reports “couldn't create file”, turn on compatible download mode: downloads then run in the foreground, so keep iPadn open while they finish.")
                    }
                }
            }
            }
            if page == .follow {
            Section {
                Toggle("Notify about followed apps", isOn: $store.settings.watchNotifications)
                    .compatibleOnChange(of: store.settings.watchNotifications) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("Target price alerts", isOn: $store.settings.targetPrices)
                    .accessibilityIdentifier("settings.target-prices")
            } header: { Text("Follow") } footer: {
                Text("Notifies you when a followed app has a new version, a price drop, becomes free, or is removed. The system decides when background checks run; iPadn also checks when you open it.")
            }
            }
            if page == .lock {
            Section {
                Toggle(isOn: Binding(get: { store.settings.appLock }, set: { on in
                    Task {
                        guard await AppLock.shared.authenticate(reason: AppText.text(on ? "Turn on App Lock" : "Turn off App Lock")) else { return }
                        withAnimation { store.settings.appLock = on }
                    }
                })) {
                    switch AppLock.method {
                    case .faceID: Text("Lock with Face ID")
                    case .touchID: Text("Lock with Touch ID")
                    default: Text("Lock with Passcode")
                    }
                }
                .disabled(AppLock.method == .unavailable && !store.settings.appLock)
                .accessibilityIdentifier("settings.app-lock")
                if store.settings.appLock {
                    Picker("Require", selection: $store.settings.appLockDelay) {
                        Text("Immediately").tag(0)
                        Text("After 1 Minute").tag(60)
                        Text("After 5 Minutes").tag(300)
                        Text("After 15 Minutes").tag(900)
                    }
                }
            } footer: {
                if AppLock.method == .unavailable && !store.settings.appLock {
                    Text("This device has no passcode, so App Lock can’t be used.")
                } else {
                    Text("iPadn asks who you are when it opens or when you come back after a while, and hides its content in the app switcher. Downloads keep running in the background.")
                }
            }
            }
            if page == .appearance {
            Section("Search & appearance") {
                Picker("Number of results", selection: $store.settings.searchLimit) {
                    ForEach([10, 30, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Appearance", selection: $store.settings.appearance) {
                    Text("Follow system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            Section {
                ForEach(AppIconService.Choice.allCases) { choice in
                    Button {
                        Task {
                            do { try await icons.select(choice) }
                            catch { iconIssue = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            // The preview shows the chosen theme (or the current one when following the system).
                            Image(choice.preview).resizable().scaledToFit().frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                                .environment(\.colorScheme, iconScheme)
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if icons.changing && choice != icons.selected { ProgressView() }
                            else if icons.awaitingSystem?.style == choice {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                    .accessibilityLabel("Waiting for the system")
                            }
                            else if icons.selected == choice { Image(systemName: "checkmark").foregroundStyle(.primary) }
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(icons.changing || !icons.supported)
                        .accessibilityIdentifier("settings.icon." + choice.rawValue)
                        .accessibilityAddTraits(icons.selected == choice ? .isSelected : [])
                        .accessibilityRemoveTraits(icons.selected == choice ? [] : .isSelected)
                        .accessibilityValue(icons.selected == choice ? "Selected" : "Not selected")
                }
                Picker("Icon theme", selection: Binding(get: { icons.theme }, set: { theme in
                    Task {
                        do { try await icons.select(theme: theme) }
                        catch { iconIssue = error.localizedDescription }
                    }
                })) {
                    ForEach(AppIconService.Theme.allCases) { Text($0.title).tag($0) }
                }
                .disabled(icons.changing || !icons.supported)
                .accessibilityIdentifier("settings.icon.theme")
            } header: { Text("App icon") } footer: {
                if let status = icons.statusHint {
                    Text(status)
                        .accessibilityIdentifier("settings.icon.status")
                } else if !icons.supported {
                    Text("This device doesn't support changing the icon.")
                } else {
                    Text("Uses the dark icon by default. “Follow system” tracks the Home Screen's light, dark and tinted appearance (iOS 18 or later); you can also keep the light icon.")
                }
            }
            }
            if page == .sources {
            ForEach($store.settings.versionSources) { $source in
                Section {
                    Button { editingSourceID = source.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(source.urlTemplate).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if let check = sourceChecks[source.id] { SourceCheckLabel(state: check) }
                            }
                            Spacer()
                            Text(source.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.source." + source.name)
                    .revealDelete(id: "source." + source.id.uuidString, title: "Remove") {
                        let id = source.id
                        withAnimation { store.settings.versionSources.removeAll { $0.id == id } }
                    }
                } header: { if source.id == store.settings.versionSources.first?.id { Text("Version sources") } }
            }
            Section {
                Button { checkSources() } label: {
                    HStack {
                        Label("Check All Sources", systemImage: "checkmark.circle")
                        Spacer()
                        if sourceChecks.values.contains(.checking) { ProgressView() }
                    }
                }
                .disabled(sourceChecks.values.contains(.checking) || store.settings.versionSources.isEmpty)
                .accessibilityIdentifier("settings.sources.check")
                Button("Add version source", systemImage: "plus") { addingSource = true }
            } footer: {
                Text("Used to look up an app's earlier versions. The check asks each source for WeChat's version history and shows whether it works, how many versions it returned and how long it took.")
            }
            }
            if page == .downloads {
            Section {
                Toggle("Speed up repeat downloads", isOn: $store.settings.useSignerCache)
                Button("Clear cache") { store.signer.clearCache(); store.infoMessage = AppText.text("Cache cleared") }
            } header: { Text("Performance") } footer: {
                Text("The cache lasts only for this run.")
            }
            }
            if page == .root {
            Section {
                Toggle("Pro mode", isOn: $store.settings.proMode.animation())
                    .accessibilityIdentifier("settings.pro-mode")
                if store.settings.proMode {
                    NavigationLink { CredentialsView() } label: { Label("Account & device identifier", systemImage: "key") }
                        .accessibilityIdentifier("settings.credentials")
                }
            } footer: {
                Text(store.settings.proMode ? "Browse package contents in download task details, and view account tokens and the device identifier."
                     : "Turns on browsing package contents, viewing account tokens and changing the device identifier.")
            }
            }
            if page == .maintenance {
            Section {
                Button("Export settings and followed apps") {
                    do { share = SharedFile(url: try store.exportBackup()) } catch { store.errorMessage = error.localizedDescription }
                }
                .accessibilityIdentifier("settings.export-backup")
                Button("Import settings and followed apps") { importingBackup = true }
                    .accessibilityIdentifier("settings.import-backup")
            } header: { Text("Backup") } footer: {
                Text("Includes settings, version sources, followed apps with their price records and recent searches. Accounts and downloaded packages are not included. Export before changing signing method or device, then import to restore.")
            }
            Section("Maintenance") {
                NavigationLink { StorageView() } label: { Label("Storage", systemImage: "internaldrive") }
                    .accessibilityIdentifier("settings.storage")
                Button("Clear version cache") { clearCache = true }
                Button("Export diagnostics") {
                    do { share = SharedFile(url: try store.exportDiagnostics()) } catch { store.errorMessage = error.localizedDescription }
                }
                Button("Copy diagnostics") { store.copyDiagnostics(); UX.feedback() }
                    .accessibilityIdentifier("settings.copy-diagnostics")
                Button("Restore default settings", role: .destructive) { resetSettings = true }
            }
            }
            if page == .root {
            Section {
                // One compact row: the icon as chosen in 应用图标 (in the appearance
                // it currently shows), with the name, version and description beside it.
                HStack(alignment: .center, spacing: 14) {
                    Image(icons.selected.preview).resizable().scaledToFit().frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 52 * UX.iconCorner, style: .continuous))
                        .environment(\.colorScheme, iconScheme)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "iPadn").font(.headline)
                            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Search, download and manage packages for apps you're licensed to use, on iPhone, iPad, Apple TV and Mac.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                if let update = store.appUpdate {
                    NavigationLink { AppUpdateView(release: update) } label: {
                        Label("iPadn \(update.version) is available", systemImage: "arrow.down.app.fill")
                            .foregroundStyle(.tint).fontWeight(.semibold)
                    }
                    .accessibilityIdentifier("settings.app-update")
                }
                Button {
                    Task {
                        let reached = await store.checkAppUpdate(force: true)
                        if !reached { store.errorMessage = AppText.text("Can't check for updates right now. Try again later.") }
                        else if store.appUpdate == nil { store.infoMessage = AppText.text("You're up to date") }
                    }
                } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        if store.appUpdateChecking { ProgressView() }
                    }
                }
                .disabled(store.appUpdateChecking)
                Toggle("Check for updates automatically", isOn: $store.settings.appUpdateCheck)
                    .compatibleOnChange(of: store.settings.appUpdateCheck) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Link("Project & updates", destination: URL(string: "https://github.com/mengangs/ipadn")!)
            }
            Section {
                NavigationLink { SupportView() } label: { SupportRow() }
                    .accessibilityIdentifier("settings.support")
            }
            }
        }
        .toolPage().navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
        .compatibleOnChange(of: scenePhase) { phase in if phase == .active { icons.refresh() } }
        .alert("Icon not changed", isPresented: Binding(get: { iconIssue != nil }, set: { if !$0 { iconIssue = nil } })) {
            Button("OK", role: .cancel) { iconIssue = nil }
        } message: { Text(iconIssue ?? "") }
        .sheet(isPresented: $addingSource) { AddVersionSourceView() }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try AppBackup.decode(data)
                pendingBackup = data
            } catch { store.errorMessage = error.localizedDescription }
        }
        .actionConfirmation(isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } }),
                            title: "Import this backup?", message: "Current settings are replaced by the backup’s, and followed apps are merged. Accounts and downloaded packages aren’t affected.",
                            confirmTitle: "Import", destructive: false) {
            guard let data = pendingBackup else { return }
            Task { do { try await store.importBackup(data) } catch { store.errorMessage = error.localizedDescription } }
        }
        .compatibleNavigationDestination(item: $editingSourceID) { id in
            if let index = store.settings.versionSources.firstIndex(where: { $0.id == id }) {
                VersionSourceEditor(source: $store.settings.versionSources[index])
            }
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .actionConfirmation(isPresented: $resetSettings, title: "Restore default settings?", message: "Accounts, downloaded packages and purchase records aren't affected.", confirmTitle: "Restore default settings") { store.settings = ToolSettings() }
        .actionConfirmation(isPresented: $clearCache, title: "Clear the version cache?", confirmTitle: "Clear cache") {
            Task { do { try await store.versions.clearCache(); store.infoMessage = AppText.text("Cache cleared") } catch { store.errorMessage = error.localizedDescription } }
        }
    }
}

extension SettingsView {
    /// Checks every source at once, enabled or not, and shows each result
    /// under its row as it arrives.
    private func checkSources() {
        let sources = store.settings.versionSources
        UX.feedback()
        for source in sources { sourceChecks[source.id] = .checking }
        for source in sources {
            Task {
                let result: SourceCheckState
                do {
                    let check = try await VersionService.check(source)
                    result = .available(versions: check.versions, seconds: check.seconds)
                } catch { result = .unavailable(error.localizedDescription) }
                sourceChecks[source.id] = result
            }
        }
    }
}

enum SourceCheckState: Equatable {
    case checking
    case available(versions: Int, seconds: Double)
    case unavailable(String)
}

/// One line under a version source: whether it answered, and how.
struct SourceCheckLabel: View {
    let state: SourceCheckState
    var body: some View {
        Group {
            switch state {
            case .checking:
                Label("Checking…", systemImage: "clock").foregroundStyle(.secondary)
            case .available(let versions, let seconds):
                Label("Available · \(versions) versions · \(String(format: "%.1f", seconds)) s", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(let reason):
                Label("Unavailable: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(2)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("settings.sourceCheckResult")
    }
}

struct VersionSourceEditor: View {
    @Binding var source: VersionSource
    var body: some View {
        Form {
            Section("Source settings") {
                Toggle("Enable", isOn: $source.enabled)
                TextField("Source name", text: $source.name)
                TextField("API address, with {id} or {appId} for the App ID", text: $source.urlTemplate)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("List field name (optional)", text: $source.containerKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Show in reverse order", isOn: $source.reverse)
            }
            Section("Endpoint format") {
                Text("[{\"external_identifier\":\"123\",\"bundle_version\":\"1.0\"}]")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("If the response is {\"data\":[…]}, set the list container key to data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct AddVersionSourceView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = VersionSource(name: AppText.text("New source"), urlTemplate: "https://", containerKey: "data", reverse: false)
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VersionSourceEditor(source: $source)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  source.url(for: "123") != nil else { error = AppText.text("Enter a name and an https API address containing {id} or {appId}"); return }
                            store.settings.versionSources.append(source); dismiss()
                        }
                    }
                }
                .alert("Can't add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
