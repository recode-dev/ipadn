import SwiftUI

struct PackageInstallationView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let job: DownloadJob
    /// Opened because the download just finished: start installing right away.
    var startsAutomatically = false
    @State private var busy = false
    /// The link is open and the system is loading the install details: the
    /// button keeps showing progress until its prompt actually appears.
    @State private var openingSystem = false
    @State private var message: String?
    @State private var issue: String?
    @State private var sharedFile: SharedFile?
    /// The system took the install link; show how far it has got.
    @State private var started = false
    @State private var attempted = false
    /// Which request the delayed connection check belongs to.
    @State private var attempt = 0
    private let proxied = LocalHostRecord.proxyOrVPNActive
    /// How far a native installation has got; nil when none is running.
    @State private var nativePhase: NativeInstaller.Phase?
    /// Native installation only: keep the App Store from offering updates.
    @State private var blockUpdates = false
    private var native: Bool { store.settings.usesNativeInstallation }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 96)
                        VStack(spacing: 4) {
                            Text(job.app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                            Text([job.app.version.isEmpty ? "" : AppText.text("Version \(job.app.version)"), job.app.size > 0 ? job.app.size.byteLabel : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            requestInstallation()
                        } label: {
                            HStack(spacing: 8) {
                                if busy || openingSystem { ProgressView().tint(UX.onAccent) }
                                Text(nativePhase != nil ? "Installing…" : busy ? "Preparing…" : openingSystem ? "Opening the installer…" : "Install")
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity)
                            .animation(.easeOut(duration: 0.15), value: busy || openingSystem)
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || openingSystem)
                        .accessibilityIdentifier("installation.request")
                        if !native, attempted || InstallLog.insideLiveContainer {
                            Button { requestInstallation(viaBrowser: true) } label: {
                                Label("Install in Safari", systemImage: "safari").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless).disabled(busy || openingSystem)
                            .accessibilityIdentifier("installation.browser")
                        }
                        Button {
                            if let file = manager.fileURL(job) { sharedFile = SharedFile(url: file) }
                            else { issue = AppText.text("The package file is missing. Download it again.") }
                        } label: { Label("Export package", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if let nativePhase {
                    Section { NativeProgressRow(phase: nativePhase) }
                } else if started {
                    Section {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            InstallProgressRow(progress: InstallLog.shared.currentProgress, note: message)
                        }
                    }
                } else if let message {
                    Section { Label(message, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.primary) }
                }
                if native {
                    Section {
                        Toggle("Block App Store Updates", isOn: $blockUpdates)
                            .disabled(nativePhase != nil)
                            .accessibilityIdentifier("installation.block-updates")
                    } footer: {
                        Text("The App Store then treats this app as up to date and won’t offer or install updates. To get updates again, turn this off and install once more.")
                    }
                }
                Section {
                    NavigationLink { InstallationSettingsView() } label: {
                        LabeledContent("Install method", value: store.settings.installationMethodTitle)
                    }.accessibilityIdentifier("installation.settings")
                    .disabled(nativePhase != nil)
                } footer: {
                    if native {
                        Text("Tap Connect in LocalDevVPN before installing, and keep iPadn open until it finishes.\nAfter installing, the App Store recognises and updates the app; an existing store version is replaced in place and data is kept.")
                    } else {
                        Text(installationHint)
                    }
                }
            }.toolPage().navigationTitle("Install").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(nativePhase != nil) } }
                .interactiveDismissDisabled(nativePhase != nil)
                .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
                .compatibleOnChange(of: scenePhase) { phase in if phase != .active { openingSystem = false } }
                .task {
                    guard startsAutomatically, !attempted else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    requestInstallation()
                }
                .alert("Installation didn't start", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("OK", role: .cancel) { issue = nil }
                } message: { Text(issue ?? "") }
        }
    }
    /// What this install method needs to succeed.
    private var installationHint: String {
        var text = store.settings.automaticInstallation ? AppText.text("Don't leave iPadn until the installation finishes.")
            : store.settings.localInstallation ? AppText.text("Create a certificate in Install method first, then install the profile and enable trust.")
            : AppText.text("Requires proxy rules you've already set up.")
        if InstallLog.insideLiveContainer && store.settings.automaticInstallation {
            text += "\n" + AppText.text("In LiveContainer, long-press iPadn and turn on “Fix File Picker” in its settings so one-tap install can show the system install prompt; if it still doesn’t, use “Local Certificate”.")
        }
        text += proxied ? proxyHint : ""
        text += "\n" + AppText.text("Apps installed this way aren't recognized or updated by the App Store, and can't replace an App Store copy already on the device. For either, use Native Install or export to a computer.")
        return text
    }
    /// Shown while a proxy or VPN is on: the address this method needs to reach directly.
    private var proxyHint: String {
        let host = store.settings.automaticInstallation ? "api.palera.in"
            : store.settings.localInstallation ? "ipadn.localtest.me" : nil
        guard let host else { return "" }
        return "\n" + AppText.text("Proxy detected: if installation fails, add a DIRECT rule for \(host).")
    }
    /// Hands the package to the system installer and waits for it to finish.
    private func requestNativeInstallation() {
        guard !busy else { return }
        UX.feedback()
        busy = true; message = nil; started = false; nativePhase = .connecting
        Task { @MainActor in
            defer { busy = false; nativePhase = nil }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message("The package file is missing. Download it again.") }
                let outcome = try await NativeInstaller.install(package: file, bundleID: job.app.bundleID, blockUpdates: blockUpdates) { phase in
                    Task { @MainActor in if nativePhase != nil { nativePhase = phase } }
                }
                UX.feedback()
                message = outcome.after?.recognisedByAppStore == false
                    ? AppText.text("Installed, but the system didn't keep this package's purchase record, so the App Store may not recognize it.")
                    : outcome.upgraded ? AppText.text("Replaced the installed app and kept its data.") : AppText.text("Installed.")
                if blockUpdates, outcome.after?.updatesBlocked == true {
                    message = (message ?? "") + "\n" + AppText.text("App Store updates are blocked for this app.")
                }
            } catch is CancellationError {
                message = nil
            } catch { issue = error.localizedDescription }
        }
    }
    private func requestInstallation(viaBrowser: Bool = false) {
        if native, !viaBrowser { requestNativeInstallation(); return }
        guard !busy, !openingSystem else { return }
        UX.feedback()
        busy = true; message = nil; started = false; attempted = true
        attempt += 1
        let current = attempt
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message(AppText.text("The package file is missing. Download it again.")) }
                let url: URL
                if store.settings.automaticInstallation {
                    url = try await store.installation.automaticInstallURL(job: job, file: file)
                } else if store.settings.localInstallation {
                    url = try await store.installation.localInstallURL(job: job, file: file, host: store.settings.localInstallHost,
                        icon: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL)
                } else {
                    url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                }
                let local = !store.settings.automaticInstallation && store.settings.localInstallation
                let served = InstallLog.shared.manifestCount
                InstallLog.shared.beginInstallation()
                let target = try viaBrowser ? store.installation.browserPage(installURL: url, app: job.app) : url
                openURL(target) { accepted in
                    InstallLog.shared.add((viaBrowser ? "install page handed to Safari: " : "install link handed to the system: ")
                                          + (accepted ? "accepted" : "refused"))
                    if accepted {
                        started = true
                        // Until the prompt (or Safari) takes over the screen.
                        openingSystem = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(12))
                            if attempt == current { openingSystem = false }
                        }
                        message = viaBrowser ? AppText.text("Confirm the installation in Safari, then return to iPadn and wait.") : AppText.text("Confirm the installation in the system prompt. Don't leave iPadn until it finishes.")
                    }
                    else { issue = AppText.text("Couldn't start the installation. Check the install method, or export the package."); store.installation.stopHosting() }
                    guard accepted, local else { return }
                    // The system fetches the install details from iPadn right away;
                    // if it never did, it could not connect.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if attempt == current, InstallLog.shared.manifestCount == served, !viaBrowser {
                            message = nil; started = false
                            issue = proxied
                                ? AppText.text("The system couldn't reach iPadn's local installation service. With a proxy or VPN on, add a DIRECT rule for ipadn.localtest.me or turn it off temporarily; you can also use one-tap install.")
                                : AppText.text("The system couldn't reach iPadn's local installation service. Check that iPadn's local installation CA is trusted under Settings › General › About › Certificate Trust Settings; you can also use one-tap install.")
                        }
                    }
                }
            } catch { issue = error.localizedDescription }
        }
    }
}

/// The step a native installation is at.
private struct NativeProgressRow: View {
    let phase: NativeInstaller.Phase
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .connecting:
                Label("Connecting to this device's installation service…", systemImage: "point.3.connected.trianglepath.dotted")
                ProgressView().tint(UX.tint)
            case .uploading(let fraction):
                Label("Uploading package \(Int(fraction * 100))%", systemImage: "arrow.down.app")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
            case .installing(let fraction):
                Label("System installing \(Int(fraction * 100))%", systemImage: "gearshape.2")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.native-progress")
    }
}

/// What the system is doing with the installation right now.
private struct InstallProgressRow: View {
    let progress: InstallLog.Progress
    let note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if progress.finished {
                Label("The package finished transferring. Check the Home Screen for install progress.", systemImage: "checkmark.circle.fill")
            } else if progress.started {
                Label("Uploading package \(Int(progress.fraction * 100))%", systemImage: "arrow.down.app")
                ProgressView(value: progress.fraction).tint(UX.tint)
                    .animation(.linear(duration: 0.4), value: progress.fraction)
            } else {
                Label(note ?? AppText.text("Confirm the installation in the system prompt."), systemImage: "hand.tap")
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.progress")
    }
}
