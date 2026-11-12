import SwiftUI
import UIKit

/// Lets a computer on the same Wi-Fi download finished packages in a browser.
/// The server runs only while this page is open and iPadn is in front.
struct WiFiTransferView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: WiFiTransferServer?
    @State private var address: URL?
    @State private var accesses: [WiFiTransferServer.Access] = []
    @State private var issue: String?
    @State private var stoppedReason: String?
    @State private var lastActivity = Date()
    @State private var starting = false
    private static let idleLimit: TimeInterval = 600

    private var items: [WiFiTransferServer.Item] {
        manager.jobs.compactMap { job in
            guard job.status == .completed, let file = manager.fileURL(job) else { return nil }
            return .init(id: job.id.uuidString, name: job.app.name.isEmpty ? file.deletingPathExtension().lastPathComponent : job.app.name,
                         version: job.app.version, filename: Self.publicName(file.lastPathComponent, id: job.id), file: file,
                         size: ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? job.app.size)
        }
    }

    /// Stored packages start with the task's ID; the computer gets the readable rest.
    static func publicName(_ stored: String, id: UUID) -> String {
        let prefix = id.uuidString + "-"
        return stored.hasPrefix(prefix) ? String(stored.dropFirst(prefix.count)) : stored
    }

    var body: some View {
        Form {
            Section {
                if let address {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Sharing", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: address.absoluteString)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transfer.address")
                        HStack(spacing: 12) {
                            Button("Copy Address", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = address.absoluteString; UX.feedback()
                            }
                            ShareLink(item: address) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    Button("Stop Sharing", role: .destructive) { stop(nil) }
                } else if starting {
                    HStack(spacing: 10) { ProgressView(); Text("Starting…").foregroundStyle(.secondary) }
                } else {
                    if let issue { InlineIssue(message: issue) }
                    else if let stoppedReason { Text(stoppedReason).foregroundStyle(.secondary) }
                    Button("Start Sharing", systemImage: "wifi") { Task { await start() } }
                        .accessibilityIdentifier("transfer.start")
                }
            } footer: {
                Text("Open this address in a browser on a computer on the same Wi‑Fi to download the finished packages (\(items.count)).")
            }
            if !accesses.isEmpty {
                Section("Downloads by Other Devices") {
                    ForEach(accesses.reversed()) { access in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: access.filename).lineLimit(1)
                            Text(verbatim: "\(access.client) · \(access.date.formatted(date: .omitted, time: .standard))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Label("Runs only while this page is open and iPadn is in front; leaving the page, going to the background or 10 idle minutes stop it.", systemImage: "clock")
                Label("The address contains a random key that changes every time; repeated wrong requests stop the transfer.", systemImage: "key")
                Label("Only finished packages can be downloaded; nothing can be uploaded or changed. Only devices on the local network are answered.", systemImage: "lock")
                Label("The transfer isn’t encrypted; use it only on networks you trust.", systemImage: "exclamationmark.shield")
            } header: { Text("Security") }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .toolPage().navigationTitle("Wi‑Fi Transfer").navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { stop(nil) }
        .compatibleOnChange(of: scenePhase) { phase in
            if phase == .background, server != nil { stop(AppText.text("iPadn went to the background, so sharing stopped.")) }
        }
        .compatibleOnChange(of: items.map(\.id)) { _ in server?.update(items: items) }
        .task(id: address) {
            // Stops after ten minutes without a download.
            while address != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if address != nil, Date().timeIntervalSince(lastActivity) > Self.idleLimit {
                    stop(AppText.text("Idle for more than 10 minutes, so sharing stopped."))
                }
            }
        }
    }

    private func start() async {
        guard server == nil, !starting else { return }
        issue = nil; stoppedReason = nil
        guard let host = WiFiTransferServer.wifiAddress() else {
            issue = AppText.text("Connect to Wi‑Fi first; the computer needs to be on the same network.")
            return
        }
        starting = true
        defer { starting = false }
        let next = WiFiTransferServer()
        next.onAccess = { access in
            accesses.append(access); lastActivity = Date()
            if accesses.count > 50 { accesses.removeFirst(accesses.count - 50) }
        }
        next.onStop = { reason in
            if server === next { server = nil; address = nil; stoppedReason = reason }
        }
        do {
            let port = try await next.start(items: items)
            server = next
            address = next.url(host: host, port: port)
            lastActivity = Date()
        } catch {
            next.stop()
            issue = error.localizedDescription
        }
    }

    private func stop(_ reason: String?) {
        guard let current = server else { return }
        server = nil; address = nil; stoppedReason = reason
        current.onStop = nil
        current.stop()
    }
}
