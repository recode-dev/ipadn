import SwiftUI

struct PackageInfoView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    let file: URL
    var job: DownloadJob? = nil
    @State private var info: PackageInfo?
    @State private var issue: String?

    var body: some View {
        Form {
            if let info {
                Section("Overview") {
                    row("Bundle ID", info.bundleID, monospaced: true)
                    row("Version", info.version)
                    row("Build", info.build)
                    row("Requires", info.minimumOS.isEmpty ? "" : "iOS " + info.minimumOS)
                    row("Supported devices", info.devices)
                    if !info.languages.isEmpty {
                        NavigationLink {
                            List(info.languages, id: \.self) { code in
                                LabeledContent(Locale.current.localizedString(forIdentifier: code) ?? code, value: code)
                            }
                            .toolPage().navigationTitle("Languages").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent("Languages", value: "\(info.languages.count)")
                        }
                    }
                }
                let permissions = PackageInfoService.groupedPermissions(info.permissions)
                Section {
                    if permissions.isEmpty {
                        Text("This package declares no permissions that need your approval.").foregroundStyle(.secondary)
                    }
                    ForEach(permissions, id: \.name) { permission in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: permission.name)
                            ForEach(permission.reasons, id: \.self) { reason in
                                Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Permissions") + Text(verbatim: permissions.isEmpty ? "" : " · \(permissions.count)")
                } footer: {
                    if !info.permissions.isEmpty { Text("The reasons are written by the developer; the system shows them when the app asks.") }
                }
                if !info.extensions.isEmpty {
                    Section {
                        ForEach(info.extensions) { item in
                            LabeledContent(item.name, value: PackageInfoService.extensionKind(item.point) ?? item.point)
                        }
                    } header: {
                        Text("Extensions") + Text(verbatim: " · \(info.extensions.count)")
                    }
                }
                Section("Other") {
                    LabeledContent("Apple Watch App", value: info.hasWatchApp ? AppText.text("Included") : AppText.text("Not included"))
                    LabeledContent("App Clip", value: info.hasAppClip ? AppText.text("Included") : AppText.text("Not included"))
                    LabeledContent("Frameworks", value: "\(info.frameworks)")
                    if !info.backgroundModes.isEmpty {
                        LabeledContent("Runs in Background", value: info.backgroundModes
                            .map { PackageInfoService.backgroundModeName($0) ?? $0 }
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            .joined(separator: AppText.text(", ")))
                    }
                    if !info.urlSchemes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("URL Scheme")
                            Text(verbatim: info.urlSchemes.joined(separator: "\n"))
                                .font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let job, store.settings.proMode, !otherVersions(of: job).isEmpty {
                    Section {
                        ForEach(otherVersions(of: job)) { other in
                            NavigationLink { compare(job, other) } label: {
                                LabeledContent(AppText.text("Compare with \(other.app.version.isEmpty ? "–" : other.app.version)"),
                                               value: other.createdAt.formatted(date: .abbreviated, time: .omitted))
                            }
                            .accessibilityIdentifier("package-info.compare." + other.id.uuidString)
                        }
                    } header: { Text("Compare Versions") } footer: {
                        Text("Shows what changed between two downloaded packages: version, permissions, extensions, frameworks and more.")
                    }
                }
            } else if let issue {
                Section { InlineIssue(message: issue) }
            } else {
                Section { HStack(spacing: 10) { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
            }
        }
        .toolPage().navigationTitle("Package Info").navigationBarTitleDisplayMode(.inline)
        .task(id: file) {
            let url = file
            do { info = try await Task.detached(priority: .userInitiated) { try PackageInfoService.read(url) }.value }
            catch { issue = error.localizedDescription }
        }
    }

    private func otherVersions(of job: DownloadJob) -> [DownloadJob] {
        manager.jobs.filter {
            $0.id != job.id && $0.status == .completed && $0.rawFormat == nil
                && !$0.app.bundleID.isEmpty && $0.app.bundleID == job.app.bundleID && manager.fileURL($0) != nil
        }
    }

    @ViewBuilder private func compare(_ job: DownloadJob, _ other: DownloadJob) -> some View {
        if let otherFile = manager.fileURL(other) {
            let mine = (version: job.app.version, file: file), theirs = (version: other.app.version, file: otherFile)
            if VersionOrder.isNewer(job.app.version, than: other.app.version) {
                PackageCompareView(older: theirs, newer: mine)
            } else {
                PackageCompareView(older: mine, newer: theirs)
            }
        }
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(verbatim: value).font(monospaced ? .footnote.monospaced() : .body)
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
