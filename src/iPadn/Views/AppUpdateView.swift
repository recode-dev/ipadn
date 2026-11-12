import SwiftUI
import UIKit

/// A newer iPadn release: what changed, and its installation package.
struct AppUpdateView: View {
    @EnvironmentObject private var store: ToolStore
    let release: AppRelease
    @State private var progress: Double?
    @State private var downloaded: URL?
    @State private var share: SharedFile?
    @State private var downloading: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPadn \(release.version)").font(.title2.weight(.bold))
                    Text([release.published?.formatted(date: .abbreviated, time: .omitted),
                          release.packageSize > 0 ? release.packageSize.byteLabel : nil,
                          AppText.text("Current: \(AppUpdateService.currentVersion)")].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            let notes = AppUpdateService.blocks(release.notes, version: release.version)
            if !notes.isEmpty {
                Section("What's new") {
                    ReleaseNotesText(blocks: notes).padding(.vertical, 4)
                }
            }
            Section {
                if release.package != nil {
                    if let downloaded {
                        Button { share = SharedFile(url: downloaded) } label: {
                            HStack {
                                Label("Install new version", systemImage: "square.and.arrow.up")
                                Spacer()
                                Text("Downloaded").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("update.share")
                    } else {
                        Button { download() } label: {
                            HStack {
                                Label(progress == nil ? "Download package" : "Downloading…", systemImage: "arrow.down.circle")
                                Spacer()
                                if let progress {
                                    Text("\(Int(progress * 100))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(progress != nil)
                        .accessibilityIdentifier("update.download")
                        if let progress { ProgressView(value: progress) }
                    }
                    if AppUpdateService.installedByTrollStore, let url = AppUpdateService.trollStoreURL(for: release) {
                        Button("Install with TrollStore", systemImage: "square.and.arrow.down") {
                            UIApplication.shared.open(url) { opened in
                                if !opened { store.errorMessage = AppText.text("TrollStore didn't open. Enable its URL scheme in TrollStore's settings, or download the package and install it from the share sheet.") }
                            }
                        }
                    }
                }
                Link(destination: release.page) { Label("View on GitHub", systemImage: "arrow.up.right.square") }
            } footer: {
                Text(downloaded == nil
                     ? "The package isn't signed. After downloading, pick the signing tool you used for iPadn (for example TrollStore or ESign) in the share sheet and install it the same way."
                     : "The package is saved on this device, so leaving this page won't download it again. Tap “Install new version”, then pick the signing tool you used for iPadn in the share sheet.")
            }
        }
        .navigationTitle("iPadn update")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .onAppear { if downloaded == nil { downloaded = AppUpdateService.downloadedPackage(for: release) } }
        .onDisappear { if share == nil { downloading?.cancel() } }
    }

    private func download() {
        guard downloading == nil else { return }
        progress = 0
        downloading = Task {
            defer { downloading = nil }
            do {
                let file = try await AppUpdateService.download(release) { value in
                    // A late report must not bring back a finished download's bar.
                    Task { @MainActor in if progress != nil { progress = value } }
                }
                progress = nil
                downloaded = file
                share = SharedFile(url: file)
            } catch {
                progress = nil
                if !(error is CancellationError) { store.errorMessage = AppText.text("Download failed. Check the connection and try again.") }
            }
        }
    }
}

/// Release notes from Markdown: section headings, bullets and paragraphs,
/// with inline links and emphasis.
private struct ReleaseNotesText: View {
    let blocks: [AppUpdateService.NoteBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text)).font(.subheadline.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                    .font(.subheadline)
                case .paragraph(let text):
                    Text(inline(text)).font(.subheadline)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
