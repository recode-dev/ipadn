import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: DownloadFilter = .all
    @State private var term = ""
    @State private var importing = false
    @State private var showingActions = false
    @State private var nextAction: AdditionAction?
    @State private var pickedFiles: [URL] = []
    private enum AdditionAction { case file, link }
    @State private var addLink = false
    @State private var link = ""
    @State private var share: SharedFile?
    @State private var pendingDelete: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var installing: DownloadJob?
    @AppStorage("liveContainerTipDismissed") private var liveContainerTipDismissed = false
    @State private var inspecting: DownloadJob?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var editRowsShown = false
    @State private var cardsShown = true
    @State private var switchingMode = false
    @State private var actionBusy = false
    private var filteredJobs: [DownloadJob] {
        manager.jobs.filter { filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    private var updateTargets: [UUID: StoreApp] {
        guard store.settings.updateNotifications else { return [:] }
        var targets: [UUID: StoreApp] = [:]
        var seen = Set<String>()
        for job in manager.jobs where job.status == .completed {
            guard let key = job.updateKey, seen.insert(key).inserted, let latest = store.availableUpdates[key] else { continue }
            targets[job.id] = latest
        }
        return targets
    }
    var body: some View {
        let visible = filteredJobs
        let updates = updateTargets
        ZStack {
            downloadList(edit: false, visible: visible, updates: updates)
                .environment(\.editMode, .constant(.inactive))
                .opacity(editMode.isEditing ? 0 : 1)
                .allowsHitTesting(!editMode.isEditing)
                .accessibilityHidden(editMode.isEditing)
            downloadList(edit: true, visible: visible, updates: updates)
                .environment(\.editMode, $editMode)
                .opacity(editMode.isEditing ? 1 : 0)
                .allowsHitTesting(editMode.isEditing)
                .accessibilityHidden(!editMode.isEditing)
        }
        .task(id: manager.jobs.filter { $0.status == .completed }.map { $0.id.uuidString }.joined()) {
            await manager.loadPackageIcons()
            if store.settings.updateNotifications { await store.checkForUpdates() }
        }
        .refreshable { await store.checkForUpdates(force: true) }
        .animation(UX.motion(reduceMotion), value: manager.jobs.map(\.id))
        .toolPage().navigationTitle("Download").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .compatibleTopBarLeading) {
                Button(editMode.isEditing ? "Done" : "Edit") { toggleEditMode() }
                .disabled(manager.jobs.isEmpty || switchingMode)
                .accessibilityIdentifier("downloads.edit")
                if !manager.jobs.isEmpty {
                    Menu {
                        ForEach(DownloadFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Label(item.title, systemImage: item.symbol)
                            }
                            .accessibilityIdentifier("download.filter." + item.id)
                            .accessibilityAddTraits(filter == item ? .isSelected : [])
                        }
                    } label: {
                        Image(systemName: filter.symbol)
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(AppText.text("Filter downloads, currently \(filter.title)")).accessibilityIdentifier("download.filter.menu")
                }
            }
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Button { showingActions = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(actionBusy).accessibilityLabel("Add download").accessibilityIdentifier("downloads.add")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack(spacing: 16) {
                    let ids = Set(filteredJobs.map(\.id))
                    let all = !ids.isEmpty && ids.isSubset(of: selection)
                    Button(all ? "Deselect all" : "Select all") {
                        if all { selection.subtract(ids) } else { selection.formUnion(ids) }
                        UX.feedback()
                    }
                    .disabled(ids.isEmpty)
                    .accessibilityIdentifier("downloads.select-all")
                    Text("\(selection.count) selected").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete selected", systemImage: "trash", role: .destructive) { askDelete(selection) }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("downloads.delete-selected")
                }.padding(18).background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .compatibleOnChange(of: editMode) { mode in
            if !mode.isEditing { selection.removeAll() }
            if !mode.isEditing && !cardsShown { DispatchQueue.main.async { cardsShown = true } }
            if !mode.isEditing { editRowsShown = false }
            if mode.isEditing { DispatchQueue.main.async { editRowsShown = true } }
        }
        .compatibleOnChange(of: filter) { _ in selection.removeAll() }
        .compatibleOnChange(of: term) { _ in selection.removeAll() }
        .sheet(isPresented: $showingActions, onDismiss: {
            let action = nextAction; nextAction = nil
            switch action {
            case .file: importing = true
            case .link: addLink = true
            case nil: break
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add download").font(.title3.weight(.semibold)).padding(.bottom, 6)
                Button { nextAction = .file; showingActions = false } label: {
                    Label("Import IPA", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("downloads.import")
                Button { nextAction = .link; showingActions = false } label: {
                    Label("Download from a link", systemImage: "link").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
                if manager.jobs.contains(where: { [.running, .queued, .paused].contains($0.status) }) {
                    Divider()
                    Button("Pause all", systemImage: "pause.circle") { manager.pauseAll(); showingActions = false; store.infoMessage = AppText.text("Downloads paused") }
                        .disabled(!manager.jobs.contains { [.running, .queued].contains($0.status) }).frame(minHeight: 44)
                    Button("Resume all", systemImage: "play.circle") { manager.resumeAll(); showingActions = false }
                        .disabled(!manager.jobs.contains { $0.status == .paused }).frame(minHeight: 44)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .presentationDetents([.height(manager.jobs.contains { [.running, .queued, .paused].contains($0.status) } ? 360 : 240), .large])
                .presentationDragIndicator(.visible).compatiblePresentationCornerRadius(28)
        }
        .sheet(isPresented: $importing, onDismiss: importPickedFiles) {
            PackageDocumentPicker { result in
                switch result {
                case .success(let urls): pickedFiles = urls
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
                importing = false
            }.ignoresSafeArea()
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $inspecting) { item in
            NavigationStack {
                if let job = manager.jobs.first(where: { $0.id == item.id }) {
                    Form {
                        Section { AppRow(app: packageDisplayApp(job)); TaskStatusPill(status: job.status) }
                        Section("Task details") {
                            LabeledContent("Added", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                            TaskSizeRows(job: job, progress: manager.progress(for: job.id))
                            if let account = job.account { LabeledContent("Apple Account", value: account) }
                        }
                        if let error = job.error { Section("Why it stopped") { Text(error).font(.subheadline) } }
                        if job.status == .completed {
                            if let file = manager.fileURL(job) {
                                if job.rawFormat == nil {
                                    Section {
                                        PackagePlatformRow(file: file)
                                        NavigationLink { PackageInfoView(file: file, job: job) } label: {
                                            Label("Package Info", systemImage: "info.circle")
                                        }
                                        .accessibilityIdentifier("download.package-info")
                                        if store.settings.proMode {
                                            NavigationLink { PackageContentsView(file: file) } label: {
                                                Label("Browse package contents", systemImage: "folder")
                                            }
                                            .accessibilityIdentifier("download.package-contents")
                                        }
                                    }
                                }
                                Section { ShareLink(item: file) { Label("Export file", systemImage: "square.and.arrow.up") } }
                            }
                        }
                    }.toolPage().navigationTitle("Task details").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { inspecting = nil } } }
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert("Download from a link", isPresented: $addLink) {
            TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Add to downloads") {
                do {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ToolError.message(AppText.text("Invalid link")) }
                    try manager.enqueueURL(url); link = ""; filter = .all; term = ""; store.infoMessage = AppText.text("Download started")
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Enter a download link for an IPA package.") }
        .actionConfirmation(isPresented: $confirmingDelete, title: "Delete \(pendingDelete.count) tasks?", message: "Downloaded packages are deleted too.", confirmTitle: "Delete tasks and files") {
            let ids = pendingDelete
            pendingDelete.removeAll()
            perform {
                let count = try await manager.removeBatch(ids)
                selection.subtract(ids)
                if manager.jobs.isEmpty { editMode = .inactive }
                store.infoMessage = AppText.text("Deleted \(count) tasks and their files")
            }
        }
        .sheet(item: $installing) { job in
            PackageInstallationView(job: job).sheetNotice().environmentObject(store).environmentObject(manager)
        }
        .overlay { if actionBusy { HStack { ProgressView(); Text("Processing…").font(.subheadline) }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false) } }
    }
    private func headerSummary(visible: [DownloadJob], updates: [UUID: StoreApp]) -> String {
        var text = filter == .all ? AppText.text("\(visible.count) items") : AppText.text("\(filter.title) · \(visible.count)")
        if !updates.isEmpty { text += AppText.text(" · \(updates.count) updates") }
        return text
    }
    private func taskContent(_ job: DownloadJob, update: StoreApp?, editing: Bool = false) -> some View {
        DownloadTaskRow(snapshot: job, progress: manager.progress(for: job.id), update: update, kept: store.keepsVersion(job), editing: editing, inspecting: { inspecting = job }, primary: { primary(job) }, exporting: {
            if let file = manager.fileURL(job) { share = SharedFile(url: file) }
        }, updating: { downloadUpdate(job) })
    }
    private func downloadUpdate(_ job: DownloadJob) {
        UX.feedback()
        perform { try await store.downloadUpdate(of: job); filter = .all; term = "" }
    }
    private func downloadAllUpdates() {
        let jobs = manager.jobs.filter { updateTargets[$0.id] != nil }
        UX.feedback()
        perform { try await store.downloadAllUpdates(of: jobs); filter = .all; term = "" }
    }
    @ViewBuilder private func downloadList(edit: Bool, visible: [DownloadJob], updates: [UUID: StoreApp]) -> some View {
            List {
                if !manager.jobs.isEmpty {
                    Section {
                        SearchInput(text: $term, placeholder: "Search name, version or Bundle ID", capsule: true)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if let error = manager.storageError { Section { InlineIssue(message: error) } }
                if InstallLog.insideLiveContainer && !liveContainerTipDismissed {
                    Section {
                        LiveContainerTip { withAnimation { liveContainerTipDismissed = true } }
                    }
                }
            if manager.waitingForWiFi, manager.jobs.contains(where: { [.queued, .pausing].contains($0.status) }) {
                Section { WiFiWaitRow() }
            }
                if let warning = manager.discoveryWarning { Section { InlineIssue(message: warning) } }
                if let warning = manager.saveWarning { Section { InlineIssue(message: warning) } }
                if visible.isEmpty {
                    Section {
                        EmptyState(title: manager.jobs.isEmpty ? "No downloads yet" : "No matching downloads", message: manager.jobs.isEmpty ? "Get apps from Search, or tap + in the top-right corner to import a package." : "Try other filters.", symbol: manager.jobs.isEmpty ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: manager.jobs.isEmpty ? "Search apps" : "Show all", action: {
                            if manager.jobs.isEmpty { store.tab = 0 } else { term = ""; filter = .all }
                        })
                    }
                } else if edit {
                    Section {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                            editRow(job)
                                .modifier(DrawerRow(shown: editRowsShown || reduceMotion, index: index, travel: 18))
                        }
                        .onMove(perform: filter == .all && term.isEmpty ? { manager.move(from: $0, to: $1) } : nil)
                    } header: {
                        Text(headerSummary(visible: visible, updates: updates))
                    } footer: {
                        if filter == .all && term.isEmpty && visible.count > 1 {
                            Text("Drag the handles to change the order. Waiting tasks download in this order.")
                                .opacity(editRowsShown || reduceMotion ? 1 : 0)
                                .animation(.easeOut(duration: 0.18).delay(0.08), value: editRowsShown)
                        }
                    }
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                        Section {
                            HStack(spacing: 12) {
                                if edit {
                                    Image(systemName: selection.contains(job.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundStyle(selection.contains(job.id) ? Color.accentColor : Color.secondary)
                                        .frame(width: 32)
                                        .transition(.move(edge: .leading).combined(with: .opacity))
                                }
                                taskContent(job, update: updates[job.id], editing: edit)
                                    .allowsHitTesting(!edit)
                            }
                            .overlay {
                                if edit {
                                    Button { toggleSelection(job.id) } label: { Color.clear.contentShape(Rectangle()) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(selection.contains(job.id) ? AppText.text("Deselect \(job.app.name)") : AppText.text("Select \(job.app.name)"))
                                        .accessibilityIdentifier("download.select." + job.id.uuidString)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("download.task." + job.app.id + "." + job.status.rawValue)
                            .revealDelete(id: "download." + job.id.uuidString,
                                          enabled: !edit && !actionBusy && job.status != .processing && job.status != .pausing) { askDelete([job.id]) }
                            .contextMenu {
                                if !edit {
                                    if let latest = updates[job.id] {
                                        Button("Download new version \(latest.version)", systemImage: "arrow.down.circle") { downloadUpdate(job) }
                                    }
                                    if job.status == .completed && job.updateKey != nil {
                                        if store.keepsVersion(job) {
                                            Button("Resume update reminders", systemImage: "bell") { store.keepVersion(false, of: job); UX.feedback() }
                                        } else {
                                            Button("Keep this version", systemImage: "pin") {
                                                store.keepVersion(true, of: job); UX.feedback()
                                                store.infoMessage = AppText.text("This version is kept; update reminders are off")
                                            }
                                        }
                                    }
                                    Button("Task details", systemImage: "info.circle") { inspecting = job }
                                    if let file = manager.fileURL(job) {
                                        Button("Export file", systemImage: "square.and.arrow.up") { share = SharedFile(url: file) }
                                        if job.rawFormat == nil {
                                            Button("Install", systemImage: "square.and.arrow.down") { installing = job }
                                        }
                                        Button("Copy local link", systemImage: "link") {
                                            perform {
                                                let url = try await store.installation.localURL(file: file)
                                                UIPasteboard.general.string = url.absoluteString
                                                store.infoMessage = AppText.text("Link copied")
                                            }
                                        }
                                    }
                                    if job.status != .processing && job.status != .pausing {
                                        Button("Delete task and file", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                                    }
                                }
                            }
                            .modifier(DrawerRow(shown: cardsShown || reduceMotion, index: index, travel: 28))
                        } header: {
                            if job.id == visible.first?.id {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(headerSummary(visible: visible, updates: updates))
                                    Spacer()
                                    if updates.count > 1, !edit {
                                        Button("Update All") { downloadAllUpdates() }
                                            .font(.body.weight(.semibold)).textCase(nil).buttonStyle(.borderless)
                                            .disabled(actionBusy)
                                            .accessibilityIdentifier("downloads.update-all")
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }

    private func toggleEditMode() {
        guard !switchingMode else { return }
        let entering = !editMode.isEditing
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { editMode = entering ? .active : .inactive }
            return
        }
        switchingMode = true
        if entering { cardsShown = false } else { editRowsShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if entering { editRowsShown = false } else { cardsShown = false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { editMode = entering ? .active : .inactive }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { switchingMode = false }
        }
    }

    private func editRow(_ job: DownloadJob) -> some View {
        let app = job.displayApp(packageIcon: manager.packageIconURL(job))
        let selected = selection.contains(job.id)
        let details = [app.version.isEmpty ? "" : "v" + app.version, job.status.title].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { toggleSelection(job.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .compatibleSymbolReplacement()
                AppIcon(url: app.iconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name.isEmpty ? app.bundleID : app.name).font(.body).lineLimit(1)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? AppText.text("Deselect \(app.name)") : AppText.text("Select \(app.name)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("download.select." + job.id.uuidString)
    }
    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func importPickedFiles() {
        let files = pickedFiles; pickedFiles.removeAll()
        guard !files.isEmpty else { return }
        perform {
            var imported = 0
            var failures: [String] = []
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            for url in files {
                do { try await manager.importFile(url); imported += 1 }
                catch { failures.append(AppText.text("\(url.lastPathComponent): \(error.localizedDescription)")) }
                if url.resolvingSymlinksInPath().path.hasPrefix(temporary) { try? FileManager.default.removeItem(at: url) }
            }
            if imported > 0 { filter = .all; term = ""; store.infoMessage = AppText.text("Imported \(imported) packages") }
            if !failures.isEmpty { store.errorMessage = failures.joined(separator: "\n") }
        }
    }
    private func packageDisplayApp(_ job: DownloadJob) -> StoreApp {
        var app = job.app
        app.iconURL = job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL
        return app
    }
    private func primary(_ job: DownloadJob) {
        UX.feedback()
        switch job.status {
        case .running, .queued: manager.pause(job.id)
        case .paused: manager.resume(job.id)
        case .failed:
            if job.asset != nil { perform { try await store.refreshDownload(job) } } else { manager.resume(job.id) }
        case .completed:
            if job.rawFormat != nil, let file = manager.fileURL(job) {
                share = SharedFile(url: file)
            } else { installing = job }
        default: break
        }
    }
    private func askDelete(_ ids: Set<UUID>) {
        pendingDelete = Set(manager.jobs.filter { ids.contains($0.id) && $0.status != .processing && $0.status != .pausing }.map(\.id))
        if pendingDelete.isEmpty { store.infoMessage = AppText.text("Wait for the task to finish processing before deleting") }
        else { confirmingDelete = true }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !actionBusy else { return }; actionBusy = true
        Task {
            defer { actionBusy = false }
            do { try await SAPSigner.$userInitiated.withValue(true) { try await operation() } }
            catch is CancellationError { }
            catch AppleLoginError.verificationRequired { store.requestVerification { perform(operation) } }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

struct DownloadTaskRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let snapshot: DownloadJob
    @ObservedObject var progress: DownloadProgressState
    private var job: DownloadJob { progress.applying(to: snapshot) }
    var update: StoreApp? = nil
    var kept = false
    var editing = false
    var inspecting: () -> Void
    var primary: () -> Void
    var exporting: () -> Void
    var updating: () -> Void = {}
    private var displayedApp: StoreApp {
        job.displayApp(packageIcon: manager.packageIconURL(job))
    }
    private var platformSymbol: String {
        switch job.platformLabel {
        case "tvOS": return "appletv"
        case "iPad": return "ipad"
        case "Mac": return "macbook"
        case "iOS": return "iphone"
        default: return "shippingbox"
        }
    }
    private var platformIcon: some View {
        Image(systemName: platformSymbol)
            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            .frame(minWidth: 16)
            .accessibilityLabel(job.platformLabel)
            .accessibilityIdentifier("download.platform." + job.platformLabel)
    }
    private var appHeading: some View {
        let displayedApp = self.displayedApp
        return HStack(alignment: .center, spacing: 14) {
            AppIcon(url: displayedApp.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedApp.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    platformIcon
                    MarqueeText(text: [displayedApp.version.isEmpty ? "" : "v\(displayedApp.version)",
                                       displayedApp.size > 0 ? displayedApp.size.byteLabel : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("download.size." + job.app.id)
                }
                statusLine
                    .id(controlKey)
                    .transition(.statusSwap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
    private var controlKey: String {
        "\(job.status.rawValue)-\(manager.cancelling.contains(job.id))"
    }
    @ViewBuilder private var statusLine: some View {
        switch job.status {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let metric = manager.metrics(for: job.id)
                let now = ProcessInfo.processInfo.systemUptime
                let speed = metric?.rate(at: now) ?? 0
                Text([progressText, speed > 0 ? "\(Int64(min(speed, Double(Int64.max / 2))).byteLabel)/s" : "",
                      etaText(metric?.remaining(expected: job.expected, at: now))]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        case .paused, .pausing:
            Text([job.status.title, progressText].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        case .processing:
            Text(manager.cancelling.contains(job.id) ? AppText.text("Cancelling…") : manager.processingDetail[job.id] ?? job.status.title)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        default:
            TaskStatusPill(status: job.status)
        }
    }
    private var progressText: String {
        job.expected > 0 ? "\(job.downloaded.byteLabel) / \(job.expected.byteLabel)" : job.downloaded > 0 ? job.downloaded.byteLabel : ""
    }
    private func etaText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return seconds < 60 ? AppText.text("\(max(1, Int(seconds))) s left")
            : seconds < 3600 ? AppText.text("\(Int(ceil(seconds / 60))) min left")
            : AppText.text("\(Int(ceil(min(seconds / 3600, 999)))) h left")
    }
    @ViewBuilder private var trailingControl: some View {
        switch job.status {
        case .running:
            Button(action: primary) { ProgressRing(progress: job.expected > 0 ? job.progress : nil, symbol: "pause.fill") }
                .buttonStyle(RevealRowButtonStyle())
                .accessibilityLabel("Pause").accessibilityValue("\(Int(job.progress * 100))%")
        case .queued:
            Button(action: primary) { ProgressRing(progress: nil) }
                .buttonStyle(RevealRowButtonStyle()).accessibilityLabel("Waiting to download; tap to pause")
        case .processing where manager.cancelling.contains(job.id):
            ProgressView().frame(width: 44, height: 44)
                .accessibilityLabel("Cancelling")
        case .processing where job.protectedMacPackage == true:
            RowCapsule(title: "Cancel") { manager.cancelProcessing(job.id) }
                .accessibilityLabel("Cancel processing")
        case .pausing, .processing:
            ProgressView().frame(width: 44, height: 44)
        case .paused:
            RowCapsule(title: "Resume", action: primary)
        case .failed:
            RowCapsule(title: "Retry", action: primary)
        case .completed:
            HStack(spacing: 8) {
                if job.rawFormat == nil {
                    Button("Install", action: primary)
                        .buttonStyle(CapsuleButtonStyle(filled: true))
                        .accessibilityIdentifier("download.install." + job.app.id)
                }
                if !editing {
                    Button(action: exporting) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RevealRowButtonStyle())
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("download.export." + job.app.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: inspecting) { appHeading }.buttonStyle(RevealRowButtonStyle())
                trailingControl
                    .id(controlKey)
                    .transition(.statusSwap)
            }
            if job.status == .running || job.status == .paused, job.expected > 0 {
                ProgressView(value: job.progress).tint(job.status == .paused ? .secondary : UX.tint)
                    .animation(.linear(duration: 0.25), value: job.progress)
                    .accessibilityLabel("Download progress").accessibilityValue("\(Int(job.progress * 100))%")
            }
            if job.status == .completed && kept {
                Label("This version is kept; no update reminders", systemImage: "pin.fill")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("download.kept." + job.app.id)
            } else if job.status == .completed, let update {
                Button(action: updating) {
                    Label("Version \(update.version) is available. Tap to download.", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(UX.tint).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(RevealRowButtonStyle())
                .transition(.opacity)
                .accessibilityLabel("Download new version \(update.version)")
                .accessibilityIdentifier("download.update." + job.app.id)
            }
            if let error = job.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .animation(.compatibleSnappy, value: controlKey)
        .animation(.easeOut(duration: 0.2), value: update?.version)
    }
}

private struct PackagePlatformRow: View {
    let file: URL
    @State private var summary: String?
    var body: some View {
        LabeledContent("Supported devices", value: summary ?? "…")
            .accessibilityIdentifier("download.package-platform")
            .task(id: file) {
                let url = file
                summary = await Task.detached(priority: .utility) {
                    (try? PackageService.platformSummary(url)) ?? AppText.text("Unknown")
                }.value
            }
    }
}

private struct TaskSizeRows: View {
    let job: DownloadJob
    @ObservedObject var progress: DownloadProgressState
    var body: some View {
        let current = progress.applying(to: job)
        let total = current.expected > 0 ? current.expected : current.app.size
        if current.status == .completed {
            if total > 0 { LabeledContent("Size", value: total.byteLabel) }
        } else {
            LabeledContent("Downloaded", value: total > 0 && current.downloaded > 0
                           ? "\(current.downloaded.byteLabel)（\(Int((Double(current.downloaded) / Double(total) * 100).rounded(.down)))%）"
                           : current.downloaded.byteLabel)
                .accessibilityIdentifier("download.detail.downloaded")
            if total > 0 { LabeledContent("Size", value: total.byteLabel) }
        }
    }
}



private struct DrawerRow: ViewModifier {
    let shown: Bool
    let index: Int
    let travel: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -travel)
            .scaleEffect(x: 1, y: shown ? 1 : 0.9, anchor: .top)
            .animation(shown ? .spring(response: 0.32, dampingFraction: 0.84).delay(0.01 + Double(min(index, 10)) * 0.02)
                             : .easeIn(duration: 0.12), value: shown)
    }
}
