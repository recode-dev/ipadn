import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sizes: [UUID: Int64] = [:]
    @State private var available: Int64?
    @State private var measuring = true
    @State private var confirmingCleanup = false
    @State private var pendingDelete: DownloadJob?
    @State private var deleting = false

    private var completed: [DownloadJob] { manager.jobs.filter { $0.status == .completed && manager.fileURL($0) != nil } }
    private var olderVersions: [DownloadJob] {
        var newest: [String: DownloadJob] = [:]
        for job in completed {
            let key = job.updateKey ?? "\(job.platformLabel)|\(job.app.id)|\(job.app.bundleID)"
            if let current = newest[key], !VersionOrder.isNewer(job.app.version, than: current.app.version),
               !(job.app.version == current.app.version && job.createdAt > current.createdAt) { continue }
            newest[key] = job
        }
        let kept = Set(newest.values.map(\.id))
        return completed.filter { !kept.contains($0.id) }
    }
    private func total(_ jobs: [DownloadJob]) -> Int64 { jobs.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    var body: some View {
        let completed = completed
        let older = olderVersions
        List {
            Section {
                LabeledContent("Packages", value: measuring ? AppText.text("Calculating…") : AppText.text("\(completed.count) items · \(total(completed).byteLabel)"))
                if let available { LabeledContent("Free space", value: available.byteLabel) }
            } footer: {
                Text("Packages are kept in iPadn. You can also find them in the Files app under On My iPhone › iPadn › Packages.")
            }
            if !older.isEmpty {
                Section {
                    Button(role: .destructive) { confirmingCleanup = true } label: {
                        LabeledContent("Delete old versions", value: AppText.text("\(older.count) items · \(total(older).byteLabel)"))
                    }
                    .accessibilityIdentifier("storage.remove-older")
                } footer: {
                    Text("When a newer download of an app exists, delete the older packages and keep the newest one per app.")
                }
            }
            if !completed.isEmpty {
                Section("By size") {
                    ForEach(completed.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }) { job in
                        HStack(spacing: 12) {
                            AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.app.name.isEmpty ? job.app.bundleID : job.app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text([job.platformLabel, job.app.version.isEmpty ? "" : "v\(job.app.version)"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(sizes[job.id].map(\.byteLabel) ?? "…").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .revealDelete(id: "storage." + job.id.uuidString, enabled: !deleting) { pendingDelete = job }
                    }
                }
            } else if !measuring {
                Section { Text("No packages downloaded yet.").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .animation(UX.motion(reduceMotion), value: completed.map(\.id))
        .disabled(deleting)
        .overlay { if deleting { ProgressView("Deleting…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .toolPage().navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
        .task(id: completed.map(\.id)) { await measure(completed) }
        .refreshable { await measure(self.completed) }
        .actionConfirmation(isPresented: $confirmingCleanup, title: "Delete \(older.count) old versions?",
                            message: "Frees \(total(older).byteLabel). The newest download of each app is kept.", confirmTitle: "Delete old versions") {
            remove(older)
        }
        .actionConfirmation(isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            title: "Delete this package?", message: "The download task and its file are both deleted.", confirmTitle: "Delete") {
            if let job = pendingDelete { remove([job]) }
            pendingDelete = nil
        }
    }

    private func measure(_ jobs: [DownloadJob]) async {
        let files = jobs.compactMap { job in manager.fileURL(job).map { (job.id, $0) } }
        let result = await Task.detached(priority: .utility) { () -> ([UUID: Int64], Int64?) in
            var sizes: [UUID: Int64] = [:]
            for (id, url) in files {
                sizes[id] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            return (sizes, free)
        }.value
        guard !Task.isCancelled else { return }
        sizes = result.0; available = result.1; measuring = false
    }

    private func remove(_ jobs: [DownloadJob]) {
        let freed = total(jobs)
        guard !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await manager.removeBatch(Set(jobs.map(\.id)))
                store.infoMessage = AppText.text("Freed \(freed.byteLabel)")
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
