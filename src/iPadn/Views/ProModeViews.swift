import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// 专业模式: the device identifier Apple sees and each account's sign-in
/// token. Only reachable when 专业模式 is on.
struct CredentialsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var editing = false
    @State private var draft = ""
    @State private var revealed = Set<String>()
    var body: some View {
        Form {
            Section {
                LabeledContent("Device identifier") {
                    Text(apple.guid).font(.body.monospaced()).textSelection(.enabled)
                }
                Button("Copy device identifier", systemImage: "doc.on.doc") { copy(apple.guid, secret: false) }
                Button("Change device identifier", systemImage: "pencil") { draft = apple.guid; editing = true }
                    .accessibilityIdentifier("pro.edit-device")
            } header: { Text("This device") } footer: {
                Text("Apple identifies the device that downloads with this identifier. After changing it, signed-in accounts may need to sign in again, and Apple limits how many devices one account can use at a time.")
            }
            if apple.accounts.isEmpty {
                Section { Text("You're not signed in to an Apple Account.").foregroundStyle(.secondary) }
            }
            ForEach(apple.accounts) { account in
                Section {
                    if !account.dsid.isEmpty {
                        LabeledContent("DSID") { Text(account.dsid).font(.body.monospaced()).textSelection(.enabled) }
                    }
                    if !account.storeFront.isEmpty { LabeledContent("Storefront code", value: account.storeFront) }
                    LabeledContent("Token") {
                        Text(revealed.contains(account.id) ? account.passwordToken : String(repeating: "•", count: 12))
                            .font(.footnote.monospaced()).lineLimit(revealed.contains(account.id) ? nil : 1)
                            .textSelection(.enabled)
                    }
                    Button(revealed.contains(account.id) ? "Hide token" : "Show token",
                           systemImage: revealed.contains(account.id) ? "eye.slash" : "eye") {
                        if revealed.contains(account.id) { revealed.remove(account.id) } else { revealed.insert(account.id) }
                    }
                    Button("Copy token", systemImage: "doc.on.doc") { copy(account.passwordToken, secret: true) }
                        .disabled(account.passwordToken.isEmpty)
                } header: { Text(account.id).textCase(nil) }
            }
            if !apple.accounts.isEmpty {
                Section {} footer: {
                    Text("The token can access your Apple Account directly. Never share it. A copied token is cleared from the clipboard after two minutes.")
                }
            }
        }
        .toolPage().navigationTitle("Account & device identifier").navigationBarTitleDisplayMode(.inline)
        .alert("Change device identifier", isPresented: $editing) {
            TextField("12 hex characters", text: $draft)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Random") { save(AppleService.randomGUID()) }
            Button("Save") { save(draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("After changing it, signed-in accounts may need to sign in again.")
        }
    }
    private func save(_ value: String) {
        do { try apple.setGUID(value); store.infoMessage = AppText.text("Device identifier changed") }
        catch { store.errorMessage = error.localizedDescription }
    }
    private func copy(_ value: String, secret: Bool) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if secret { options[.expirationDate] = Date().addingTimeInterval(120) }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: value]], options: options)
        store.infoMessage = AppText.text("Copied")
    }
}

/// One file or folder inside a package.
struct PackageItem: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isFolder: Bool
    var size: UInt64
    var compressedSize: UInt64
    var modified: Date?
    var id: String { path }
}

enum PackageContents {
    /// Everything in the archive, as paths without a trailing slash.
    static func items(_ file: URL) throws -> [PackageItem] {
        let archive = try Archive(url: file, accessMode: .read)
        var items: [PackageItem] = []
        var folders = Set<String>()
        for entry in archive {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard !path.isEmpty, PackageService.isSafeArchivePath(path) else { continue }
            // Folders are often implied by their files rather than stored.
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent).inserted { parent = (parent as NSString).deletingLastPathComponent }
            if entry.type == .directory { folders.insert(path); continue }
            items.append(PackageItem(path: path, name: (path as NSString).lastPathComponent, isFolder: false,
                                     size: entry.uncompressedSize, compressedSize: entry.compressedSize,
                                     modified: entry.fileAttributes[.modificationDate] as? Date))
        }
        items += folders.map { PackageItem(path: $0, name: ($0 as NSString).lastPathComponent, isFolder: true, size: 0, compressedSize: 0) }
        return items
    }
    /// The direct children of `folder` ("" for the top level), folders first.
    static func children(of folder: String, in items: [PackageItem]) -> [PackageItem] {
        items.filter { ($0.path as NSString).deletingLastPathComponent == folder }
            .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Copies one file out of the package into a temporary folder.
    static func extract(_ path: String, from file: URL) throws -> URL {
        let archive = try Archive(url: file, accessMode: .read)
        guard PackageService.isSafeArchivePath(path), let entry = archive[path], entry.type == .file else {
            throw ToolError.message(AppText.text("That file wasn't found"))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PackageContents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(PackageService.safeName((path as NSString).lastPathComponent))
        let checksum = try archive.extract(entry, to: destination)
        guard checksum == entry.checksum else {
            try? FileManager.default.removeItem(at: folder)
            throw ToolError.message(AppText.text("The package is damaged. Download it again."))
        }
        return destination
    }
}

/// Browse what's inside a downloaded package and take single files out.
struct PackageContentsView: View {
    let file: URL
    var folder = ""
    /// Shared by every level, so the archive is read once.
    var preloaded: [PackageItem]?
    @State private var items: [PackageItem]?
    @State private var failure: String?
    @State private var query = ""
    private var title: String { folder.isEmpty ? AppText.text("Package contents") : (folder as NSString).lastPathComponent }
    var body: some View {
        let all = items ?? preloaded
        List {
            if let failure {
                Section { InlineIssue(message: failure) }
            } else if let all {
                let shown = query.isEmpty ? PackageContents.children(of: folder, in: all)
                    : all.filter { !$0.isFolder && $0.path.hasPrefix(folder) && $0.name.localizedCaseInsensitiveContains(query) }
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                Section {
                    ForEach(shown) { item in
                        if item.isFolder {
                            NavigationLink { PackageContentsView(file: file, folder: item.path, preloaded: all) } label: {
                                Label(item.name, systemImage: "folder").lineLimit(1)
                            }
                        } else {
                            NavigationLink { PackageFileView(file: file, item: item) } label: {
                                HStack {
                                    Label(item.name, systemImage: Self.symbol(item.name)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Int64(clamping: item.size).byteLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(query.isEmpty ? "shown.count items" : "Found shown.count files")
                }
            } else {
                Section { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
            }
        }
        .toolPage().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search file names")
        .task {
            guard items == nil, preloaded == nil else { return }
            let url = file
            do { items = try await Task.detached(priority: .userInitiated) { try PackageContents.items(url) }.value }
            catch { failure = AppText.text("Couldn't read the package contents.") }
        }
    }
    static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "pdf": return "photo"
        case "plist", "json", "xml", "strings", "txt", "md": return "doc.text"
        case "car": return "paintpalette"
        case "dylib", "framework", "": return "gearshape"
        default: return "doc"
        }
    }
}

/// One file: its details, a preview for text and images, and a way to take
/// it out of the package.
private struct PackageFileView: View {
    let file: URL
    let item: PackageItem
    @State private var extracted: URL?
    @State private var text: String?
    @State private var image: UIImage?
    @State private var busy = false
    @State private var failure: String?
    @State private var sharing: SharedFile?
    private var kind: String { (item.name as NSString).pathExtension.lowercased() }
    private var previewsText: Bool { ["plist", "json", "xml", "strings", "txt", "md", "entitlements"].contains(kind) && item.size <= 1024 * 1024 }
    private var previewsImage: Bool { ["png", "jpg", "jpeg", "gif", "heic"].contains(kind) && item.size <= 20 * 1024 * 1024 }
    var body: some View {
        Form {
            Section {
                LabeledContent("Path") { Text(item.path).font(.footnote.monospaced()).textSelection(.enabled) }
                LabeledContent("Size", value: Int64(clamping: item.size).byteLabel)
                LabeledContent("Compressed", value: Int64(clamping: item.compressedSize).byteLabel)
                if let modified = item.modified { LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let image {
                Section("Preview") { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity) }
            } else if let text {
                Section("Preview") { Text(text).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let failure { Section { InlineIssue(message: failure) } }
            Section {
                Button {
                    Task { if let url = await extract() { sharing = SharedFile(url: url) } }
                } label: {
                    HStack { Label("Extract and share", systemImage: "square.and.arrow.up"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy)
                .accessibilityIdentifier("pro.extract")
            } footer: { Text("The file is copied to a temporary location; the package isn't modified.") }
        }
        .toolPage().navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .task {
            guard previewsText || previewsImage, let url = await extract() else { return }
            let wantsImage = previewsImage
            // Read and prepared off the main thread; long text is cut short so
            // the page stays responsive.
            let preview = await Task.detached(priority: .userInitiated) { () -> (UIImage?, String?) in
                guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
                if wantsImage {
                    guard let full = UIImage(data: data) else { return (nil, nil) }
                    let scale = min(1, 1200 / max(full.size.width, full.size.height, 1))
                    let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
                    return (await full.byPreparingThumbnail(ofSize: size) ?? full, nil)
                }
                return (nil, Self.readable(data).map(Self.shortened))
            }.value
            image = preview.0; text = preview.1
        }
    }
    private func extract() async -> URL? {
        if let extracted { return extracted }
        busy = true; defer { busy = false }
        let (source, path) = (file, item.path)
        do {
            let url = try await Task.detached(priority: .userInitiated) { try PackageContents.extract(path, from: source) }.value
            extracted = url
            return url
        } catch { failure = error.localizedDescription; return nil }
    }
    nonisolated static func shortened(_ text: String) -> String {
        let limit = 20_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + AppText.text("\n\n… (first \(limit) characters shown; extract the file for the full content)")
    }
    /// Text as is; property lists (often binary) as XML.
    nonisolated static func readable(_ data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            return String(data: xml, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
}
