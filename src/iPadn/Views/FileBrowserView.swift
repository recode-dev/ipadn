import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var store: ToolStore
    @State private var area: Area?
    @State private var trail: [String] = []
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var sweeping = false
    @State private var issue: String?
    @State private var preview: Preview?
    @State private var share: SharedFile?
    @State private var renameTarget: Entry?
    @State private var renameText = ""
    @State private var folderSheet = false
    @State private var folderText = ""
    @State private var deleteTarget: Entry?
    @State private var generation = 0

    struct Area: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        let dynamic: Bool
        let path: String?

        static let all: [Area] = [
            Area(id: "documents", title: "This App", symbol: "internaldrive", dynamic: true, path: nil),
            Area(id: "bundles", title: "App Bundles", symbol: "shippingbox", dynamic: false, path: "/private/var/containers/Bundle/Application"),
            Area(id: "data", title: "App Data", symbol: "app.gear", dynamic: false, path: "/private/var/mobile/Containers/Data/Application"),
            Area(id: "groups", title: "App Groups", symbol: "person.2.square.stack", dynamic: false, path: "/private/var/mobile/Containers/Shared/AppGroup"),
            Area(id: "systemGroups", title: "System Groups", symbol: "square.stack.3d.up", dynamic: false, path: "/private/var/containers/Shared/SystemGroup"),
            Area(id: "systemData", title: "System Data", symbol: "dial.min.fill", dynamic: false, path: "/private/var/containers/Data/System"),
            Area(id: "daemons", title: "Internal Daemons", symbol: "gearshape.2", dynamic: false, path: "/private/var/mobile/Containers/Data/InternalDaemon"),
            Area(id: "plugins", title: "PlugIn Kit", symbol: "puzzlepiece.extension", dynamic: false, path: "/private/var/mobile/Containers/Data/PluginKitPlugin"),
        ]

        var containerParent: Bool { path != nil }
    }

    struct Entry: Identifiable {
        let name: String
        let path: String
        let directory: Bool
        let symbolic: Bool
        let size: UInt64
        let modified: Int64
        let label: String?
        var id: String { path }
    }

    struct Preview: Identifiable {
        let path: String
        let name: String
        let data: Data
        let text: String?
        var id: String { path }
    }

    private var currentPath: String {
        guard let area else { return "" }
        if area.dynamic {
            var path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
                ?? NSTemporaryDirectory()
            for part in trail { path = (path as NSString).appendingPathComponent(part) }
            return path
        }
        var path = area.path ?? "/"
        for part in trail { path = (path as NSString).appendingPathComponent(part) }
        return path
    }

    private var escapeNote: String {
        if let group = WorseQueryAccess.appGroup() as String? {
            return AppText.text("Sandbox escape active · \(group)")
        }
        return AppText.text("No App Group entitlement, so the sandbox escape is off. Only areas this app can already reach will open.")
    }

    var body: some View {
        List {
            if area == nil {
                areasSection
            } else {
                entriesSection
            }
        }
        .toolPage().navigationTitle(Text("File Browser")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if area != nil {
                    Button {
                        if trail.isEmpty {
                            area = nil
                            entries = []
                        } else {
                            trail.removeLast()
                            reload()
                        }
                    } label: { Image(systemName: "chevron.up") }
                    Button {
                        folderSheet = true
                    } label: { Image(systemName: "folder.badge.plus") }
                }
                Button {
                    reload()
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading || sweeping)
            }
        }
        .refreshable { reload() }
        .task { reload() }
        .sheet(item: $preview) { item in PreviewSheet(preview: item) }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { applyRename() }
        }
        .alert("New Folder", isPresented: $folderSheet) {
            TextField("Name", text: $folderText)
            Button("Cancel", role: .cancel) { folderText = "" }
            Button("Create") { applyCreateFolder() }
        }
        .confirmationDialog("Delete this item?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { applyDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(verbatim: deleteTarget?.path ?? "")
        }
    }

    private var areasSection: some View {
        Section {
            ForEach(Area.all) { candidate in
                Button {
                    area = candidate
                    trail = []
                    issue = nil
                    reload()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: candidate.symbol)
                            .foregroundStyle(UX.tint)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).foregroundStyle(.primary)
                            Text(candidate.path ?? AppText.text("This app's shared documents"))
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Areas")
        } footer: {
            Text(escapeNote)
        }
    }

    @ViewBuilder private var entriesSection: some View {
        Section {
            if loading || sweeping {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(sweeping ? "Sweeping volume inodes…" : "Reading directory…")
                        .foregroundStyle(.secondary)
                }
            } else if let issue {
                InlineIssue(message: issue)
            } else if entries.isEmpty {
                Text("Nothing reachable here").foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        } header: {
            Text(verbatim: (currentPath as NSString).lastPathComponent)
        }
    }

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.directory ? "folder.fill" : (entry.symbolic ? "link" : "doc"))
                .foregroundStyle(entry.directory ? UX.tint : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(2)
                if let subtitle = subtitle(for: entry), !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.directory {
                trail.append(entry.name)
                issue = nil
                reload()
            } else {
                openPreview(entry)
            }
        }
        .contextMenu {
            if !entry.directory {
                Button { openPreview(entry) } label: { Label("Preview", systemImage: "eye") }
                Button { saveToDocuments(entry) } label: { Label("Save to This App", systemImage: "square.and.arrow.down") }
                Button { shareEntry(entry) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button {
                renameTarget = entry
                renameText = entry.name
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) {
                deleteTarget = entry
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func subtitle(for entry: Entry) -> String? {
        if entry.directory, let label = entry.label { return label }
        var parts: [String] = []
        if entry.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) }
        if entry.modified > 0 {
            parts.append(Date(timeIntervalSince1970: TimeInterval(entry.modified)).formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        generation += 1
        let token = generation
        issue = nil
        guard area != nil else { return }
        loading = true
        let target = currentPath
        let atContainerParent = trail.isEmpty && (area?.containerParent ?? false)
        Task.detached(priority: .userInitiated) {
            var names = WorseQueryAccess.list(target)
            var swept = false
            if names.isEmpty, atContainerParent {
                await MainActor.run {
                    if token == generation { sweeping = true; loading = false }
                }
                names = WorseQueryAccess.enumerate(target)
                swept = true
                await MainActor.run {
                    if token == generation { sweeping = false }
                }
            }
            let capped = Array(names.prefix(4000))
            var rows: [Entry] = []
            for name in capped {
                let path = (target as NSString).appendingPathComponent(name)
                var directory = ObjCBool(false)
                var symbolic = ObjCBool(false)
                var size: UInt64 = 0
                var modified: Int64 = 0
                let known = WorseQueryAccess.statPath(path, isDirectory: &directory, size: &size, modified: &modified, symbolic: &symbolic)
                let isDirectory = known && directory.boolValue
                var label: String?
                if isDirectory, atContainerParent {
                    label = WorseQueryAccess.containerLabel(path)
                }
                rows.append(Entry(name: name, path: path, directory: isDirectory, symbolic: symbolic.boolValue,
                                  size: size, modified: modified, label: label))
            }
            let sorted = rows.sorted { lhs, rhs in
                if lhs.directory != rhs.directory { return lhs.directory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            await MainActor.run {
                guard token == generation else { return }
                entries = sorted
                if sorted.isEmpty {
                    issue = AppText.text(swept ? "No container folders found under this area." : "Nothing readable here. The sandbox escape could not reach this path.")
                }
                loading = false
            }
        }
    }

    private func openPreview(_ entry: Entry) {
        Task.detached(priority: .userInitiated) {
            let data = WorseQueryAccess.read(entry.path, limit: 262144) ?? Data()
            let sample = data.prefix(4096)
            let printable = sample.filter { $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }.count
            let readable = data.isEmpty || Double(printable) / Double(max(1, sample.count)) > 0.9
            let text = readable ? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) : nil
            let item = Preview(path: entry.path, name: entry.name, data: data, text: text)
            await MainActor.run { preview = item }
        }
    }

    private func saveToDocuments(_ entry: Entry) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var destination = documents.appendingPathComponent(entry.name)
        var index = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(index) \(entry.name)")
            index += 1
        }
        if WorseQueryAccess.copyFile(entry.path, to: destination.path) {
            store.infoMessage = AppText.text("Saved to This App: \(destination.lastPathComponent)")
        } else {
            store.errorMessage = AppText.text("Could not save \(entry.name)")
        }
    }

    private func shareEntry(_ entry: Entry) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ipadn-share-\(UUID().uuidString)-\(entry.name)")
        guard WorseQueryAccess.copyFile(entry.path, to: scratch.path) else {
            store.errorMessage = AppText.text("Could not read \(entry.name) for sharing")
            return
        }
        share = SharedFile(url: scratch)
    }

    private func applyRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let clean = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "/", !clean.contains("/") else { return }
        let destination = ((target.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(clean)
        if WorseQueryAccess.rename(target.path, to: destination) {
            reload()
        } else {
            store.errorMessage = AppText.text("Rename failed (errno \(errno))")
        }
    }

    private func applyCreateFolder() {
        folderSheet = false
        let clean = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
        folderText = ""
        guard !clean.isEmpty, !clean.contains("/") else { return }
        let destination = (currentPath as NSString).appendingPathComponent(clean)
        if WorseQueryAccess.createDirectory(destination) {
            reload()
        } else {
            store.errorMessage = AppText.text("Could not create the folder (errno \(errno))")
        }
    }

    private func applyDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        if WorseQueryAccess.remove(target.path) {
            reload()
        } else {
            store.errorMessage = AppText.text("Delete failed (errno \(errno))")
        }
    }
}

struct PreviewSheet: View {
    let preview: FileBrowserView.Preview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(preview.text ?? FileBrowserView.hexDump(preview.data))
                    .font(.system(preview.text == nil ? .caption2 : .footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .navigationTitle(preview.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension FileBrowserView {
    static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(2048))
        var lines: [String] = []
        var index = 0
        while index < bytes.count {
            let row = Array(bytes[index..<min(index + 16, bytes.count)])
            var hex = row.map { String(format: "%02x", $0) }
            if hex.count > 8 { hex.insert(" ", at: 8) }
            let ascii = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %@  %@", index, hex.joined(separator: " "), ascii))
            index += 16
        }
        if data.count > 2048 { lines.append("… \(data.count) bytes total, showing 2048") }
        return lines.joined(separator: "\n")
    }
}
