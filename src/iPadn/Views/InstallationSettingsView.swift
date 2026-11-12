import SwiftUI
import UniformTypeIdentifiers

struct InstallationSettingsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.openURL) private var openURL
    @State private var importing = false
    @State private var hasLocalProfile = false
    @State private var replacingCertificate = false
    @State private var certificateData: Data?
    @State private var password = ""
    @State private var certificateName = Self.notImported
    private static let notImported = "Not imported"
    @State private var issue: String?
    @State private var busy = false
    @State private var working: Action?
    private enum Action { case create, profile, check, connection }
    private enum ImportKind { case certificate, pairingFile }
    @State private var importKind = ImportKind.certificate
    @State private var hasPairingFile = NativeInstaller.hasPairingFile
    @State private var removingPairingFile = false
    @StateObject private var pairing = OnDevicePairing()
    @State private var showingPairingGuide = false
    @Environment(\.scenePhase) private var scenePhase
    private enum Method: Hashable { case native, automatic, localCertificate, proxy }
    private var method: Binding<Method> {
        Binding(get: {
            store.settings.usesNativeInstallation ? .native
                : store.settings.automaticInstallation ? .automatic
                : store.settings.localInstallation ? .localCertificate : .proxy
        }, set: { value in
            store.settings.nativeInstallation = value == .native
            guard value != .native else { return }
            store.settings.automaticInstallation = value == .automatic
            if value != .automatic { store.settings.localInstallation = value == .localCertificate }
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("Install method", selection: method) {
                    Text("One-tap").tag(Method.automatic)
                    if NativeInstaller.isAvailable { Text("Native").tag(Method.native) }
                    Text("Certificate").tag(Method.localCertificate)
                    Text("Proxy").tag(Method.proxy)
                }.pickerStyle(.segmented).accessibilityIdentifier("installation.method")
            }
            if store.settings.usesNativeInstallation {
                Section {
                    Label("The App Store recognizes and updates installed apps", systemImage: "checkmark.seal")
                    Label("Can replace apps installed from the App Store and keep their data", systemImage: "arrow.triangle.2.circlepath")
                    LabeledContent("Pairing File", value: hasPairingFile ? AppText.text("Imported") : AppText.text("Not imported"))
                    if OnDevicePairing.isSupported {
                        Button { pairing.start(); showingPairingGuide = true } label: {
                            actionLabel(hasPairingFile ? "Pair Again" : "Pair on This Device", systemImage: "iphone.radiowaves.left.and.right", running: pairing.phase.isActive)
                        }
                        .disabled(pairing.phase.isActive).accessibilityIdentifier("installation.pair-on-device")
                    }
                    Button("Import Pairing File", systemImage: "square.and.arrow.down") { importPairingFile() }
                        .accessibilityIdentifier("installation.pairing-file")
                    Button { checkConnection() } label: { actionLabel("Check Connection", systemImage: "point.3.connected.trianglepath.dotted", action: .connection) }
                        .disabled(busy || !hasPairingFile).accessibilityIdentifier("installation.native-check")
                    if hasPairingFile {
                        Button("Remove Pairing File", systemImage: "trash", role: .destructive) { removingPairingFile = true }
                    }
                } header: { Text("Native Install") } footer: {
                    if OnDevicePairing.isSupported {
                        Text("Installs through the system installation service, the same way a computer does.\n1. Tap Pair on this device, then open Settings › Privacy & Security › Developer Mode, tap Pair with iPadn and enter the code iPadn shows. If Developer Mode is hidden, enable it on that page first and restart the device.\n2. Before installing, open LocalDevVPN and tap Connect, or use a proxy tool with loopback routing already set up.\nChanging the passcode or restoring the system requires pairing again. The package never leaves this device.")
                    } else {
                        Text("Installs through the system installation service, the same way a computer does. You need two things:\n1. LocalDevVPN from the App Store; open it and tap Connect once. It cannot run alongside another proxy or VPN.\n2. On a computer, generate a Remote Pairing (RPPairing) file for this device with idevice_pair, put it in Files › On My iPhone › iPadn and tap Import Pairing File - or pick it from another location. iOS updates or restores may require a new file.\nThe package never leaves this device.")
                    }
                }
                if pairing.phase != .idle, !showingPairingGuide {
                    Section { PairingStatusRow(phase: pairing.phase) { pairing.cancel() } }
                }
            } else if store.settings.automaticInstallation {
                Section {
                    Label("No profile or certificate needed", systemImage: "checkmark.seal")
                    Label("The package never leaves this device", systemImage: "iphone")
                } header: { Text("One-tap install (recommended)") } footer: {
                    Text("Installation needs a network connection. Don't leave iPadn until it finishes. If you use a proxy, add a DIRECT rule for api.palera.in.")
                }
            } else if store.settings.localInstallation {
                Section {
                    TextField("Server address", text: $store.settings.localInstallHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("Certificate", value: certificateName == Self.notImported ? AppText.text("Not imported") : certificateName)
                    Button {
                        if certificateName == Self.notImported { createLocalCertificate() }
                        else { replacingCertificate = true }
                    } label: { actionLabel("Create certificate", systemImage: "lock.shield", action: .create) }
                    .disabled(busy).accessibilityIdentifier("installation.create-certificate")
                    if hasLocalProfile {
                        Button { installProfile() } label: {
                            actionLabel("Install profile", systemImage: "doc.badge.gearshape", action: .profile)
                        }
                        .disabled(busy).accessibilityIdentifier("installation.local-profile")
                    }
                    Button("Import certificate", systemImage: "square.and.arrow.down") { importKind = .certificate; importing = true }
                        .accessibilityIdentifier("installation.certificate")
                    Button { checkCertificate() } label: { actionLabel("Check certificate", systemImage: "checkmark.shield", action: .check) }
                        .disabled(busy)
                } header: { Text("Local certificate") } footer: {
                    Text("The first time, create a certificate and install its profile, then enable trust under Settings › General › About › Certificate Trust Settings. If you use a proxy, add a DIRECT rule for ipadn.localtest.me.")
                }
            } else {
                Section {
                    TextField("Manifest service address", text: $store.settings.plistServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Proxy service") } footer: {
                    Text("For people who already have proxy rules in Surge, Loon and similar tools.")
                }
            }
            Section {
                Link("Installation help", destination: URL(string: "https://github.com/mengangs/ipadn#安装下载的应用")!)
            }
        }.toolPage().navigationTitle("Installation settings").navigationBarTitleDisplayMode(.inline)
            .task {
                refreshCertificate()
                if store.settings.usesNativeInstallation, !hasPairingFile, (try? NativeInstaller.importPairingFileFromDocuments()) == true {
                    hasPairingFile = NativeInstaller.hasPairingFile
                    store.infoMessage = AppText.text("Pairing file imported from the iPadn folder. Connect in LocalDevVPN, then tap “Check Connection”.")
                }
            }
            .compatibleOnChange(of: scenePhase) { phase in if phase != .active, working == .profile { working = nil } }
            .sheet(isPresented: $showingPairingGuide) {
                PairingGuideView(pairing: pairing)
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled(pairing.phase.isActive)
            }
            .compatibleOnChange(of: pairing.phase) { phase in
                if phase == .finished {
                    hasPairingFile = NativeInstaller.hasPairingFile
                    store.infoMessage = AppText.text("Paired. Connect in LocalDevVPN before installing; tap “Check Connection” to confirm.")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .pairingFile ? [.propertyList, .xml, .data, .item] : [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if importKind == .pairingFile {
                        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 else { throw ToolError.message(AppText.text("This isn't a valid pairing file.")) }
                        try NativeInstaller.importPairingFile(try Data(contentsOf: url))
                        hasPairingFile = NativeInstaller.hasPairingFile
                        store.infoMessage = AppText.text("Pairing file imported. Connect in LocalDevVPN, then tap “Check Connection”.")
                        return
                    }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw ToolError.message(AppText.text("Choose a .p12 or .pfx certificate file")) }
                    certificateData = try Data(contentsOf: url); password = ""
                } catch { issue = error.localizedDescription }
            }
            .sheet(isPresented: Binding(get: { certificateData != nil }, set: { if !$0 { certificateData = nil; password = "" } })) {
                NavigationStack {
                    Form {
                        Section { SecureField("Certificate password (optional)", text: $password) } footer: {
                            Text("The certificate is stored only on this device.")
                        }
                        if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
                    }.navigationTitle("Import certificate").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { certificateData = nil; password = ""; issue = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("Import") { saveCertificate() } }
                        }
                }.presentationDetents([.medium, .large])
            }
            .actionConfirmation(isPresented: $removingPairingFile, title: "Remove pairing file?", message: "You'll need to import it again to use Native Install.", confirmTitle: "Remove", destructive: true) {
                do { try NativeInstaller.removePairingFile(); hasPairingFile = NativeInstaller.hasPairingFile; store.infoMessage = AppText.text("Pairing file removed.") }
                catch { issue = error.localizedDescription }
            }
            .actionConfirmation(isPresented: $replacingCertificate, title: "Recreate the certificate?", message: "You'll need to install and trust the new profile.", confirmTitle: "Recreate", destructive: false) { createLocalCertificate() }
            .alert("Installation settings", isPresented: Binding(get: { issue != nil && certificateData == nil }, set: { if !$0 { issue = nil } })) {
                Button("OK", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
    }
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, action: Action) -> some View {
        actionLabel(title, systemImage: systemImage, running: working == action)
    }
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, running: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if running { ProgressView().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: running)
    }
    private func refreshCertificate() {
        do {
            certificateName = try InstallationCertificate.load()?.name ?? Self.notImported
            hasLocalProfile = try InstallationCertificate.localProfile() != nil
        }
        catch { issue = error.localizedDescription }
    }
    private func createLocalCertificate() {
        guard !busy else { return }; busy = true; working = .create
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                let material = try await Task.detached(priority: .userInitiated) { try LocalInstallationIdentityFactory.create() }.value
                try InstallationCertificate.save(data: material.pkcs12, password: material.password,
                    localRoot: material.rootCertificate, localIdentifier: material.identifier)
                store.installation.stopHosting(); store.settings.localInstallation = true; store.settings.localInstallHost = ManifestBuilder.defaultLocalHost
                refreshCertificate()
                store.infoMessage = AppText.text("Certificate created. Install the profile.")
            } catch { issue = error.localizedDescription }
        }
    }
    private func installProfile() {
        guard !busy else { return }; busy = true; working = .profile
        UX.feedback()
        Task {
            defer { busy = false; Task { try? await Task.sleep(for: .seconds(8)); if working == .profile { working = nil } } }
            do {
                guard let profile = try InstallationCertificate.localProfile() else { throw ToolError.message(AppText.text("Create a certificate first")) }
                let url = try await store.installation.profileURL(data: profile)
                openURL(url) { accepted in
                    if accepted { store.infoMessage = AppText.text("Install the profile in Settings, then enable trust under General › About › Certificate Trust Settings.") }
                    else { issue = AppText.text("Couldn't open the profile. Try again later."); working = nil }
                }
            } catch { issue = error.localizedDescription; working = nil }
        }
    }
    private func saveCertificate() {
        guard let data = certificateData else { return }
        do {
            try InstallationCertificate.save(data: data, password: password)
            store.installation.stopHosting()
            certificateData = nil; password = ""; issue = nil
            refreshCertificate(); store.infoMessage = AppText.text("Certificate imported.")
        } catch { issue = error.localizedDescription }
    }
    private func importPairingFile() {
        do {
            if try NativeInstaller.importPairingFileFromDocuments() {
                hasPairingFile = NativeInstaller.hasPairingFile
                store.infoMessage = AppText.text("Pairing file imported from the iPadn folder. Connect in LocalDevVPN, then tap “Check Connection”.")
                return
            }
        } catch {
            issue = error.localizedDescription
            return
        }
        importKind = .pairingFile
        importing = true
    }
    private func checkConnection() {
        guard !busy else { return }; busy = true; working = .connection
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                _ = try await NativeInstaller.lookup(bundleID: Bundle.main.bundleIdentifier ?? "app.local.iPadn")
                store.infoMessage = AppText.text("Connected. Native Install is ready.")
            } catch { issue = error.localizedDescription }
        }
    }
    private func checkCertificate() {
        busy = true; working = .check
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                let host = try ManifestBuilder.localHost(store.settings.localInstallHost)
                guard let certificate = try InstallationCertificate.load() else { throw ToolError.message(AppText.text("Create or import a certificate first")) }
                try await certificate.validateAsync(host: host)
                store.infoMessage = AppText.text("The certificate is valid.")
            } catch { issue = error.localizedDescription }
        }
    }
}

extension OnDevicePairing.Phase {
    var isActive: Bool {
        switch self {
        case .waiting, .connected, .code: return true
        default: return false
        }
    }
}

private struct PairingStatusRow: View {
    let phase: OnDevicePairing.Phase
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .waiting:
                Label("Open Settings › Privacy & Security › Developer Mode and tap “Pair with iPadn”.", systemImage: "gear")
            case .connected:
                Label("Device connected. Starting to pair…", systemImage: "iphone.radiowaves.left.and.right")
            case .code(let code):
                Text("Enter the code in Settings").font(.subheadline).foregroundStyle(.secondary)
                Text(code).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit().tracking(6)
                    .textSelection(.enabled).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("installation.pairing-code")
            case .finished:
                Label("Paired", systemImage: "checkmark.circle.fill")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            case .idle:
                EmptyView()
            }
            if phase.isActive {
                Button("Cancel Pairing", role: .cancel, action: cancel).frame(maxWidth: .infinity)
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.pairing-status")
    }
}

private struct PairingGuideView: View {
    @ObservedObject var pairing: OnDevicePairing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var step: Int {
        switch pairing.phase {
        case .waiting: return 1
        case .connected: return 2
        case .code: return 3
        case .finished: return 4
        default: return 0
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    guideRow(1, "Open Settings", "Privacy & Security › Developer Mode › Pair with iPadn")
                    guideRow(2, "Wait for the device to connect", "It connects once you select iPadn")
                    guideRow(3, "Enter the code", "The code appears here, in the Dynamic Island and in a notification")
                } footer: {
                    Text("If Developer Mode isn't there, turn it on in that page and restart when asked. iPadn keeps running in the background while pairing and stops when done.")
                }
                if pairing.phase != .idle {
                    Section { PairingStatusRow(phase: pairing.phase) { pairing.cancel() } }
                }
            }
            .navigationTitle("Pair on This Device").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if pairing.phase.isActive {
                        Button("Open Settings") { openSettings() }.accessibilityIdentifier("installation.pairing-open-settings")
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
    private func guideRow(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        let done = step > number && step != 0
        let current = step == number
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done || current ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(current ? .white : .secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(current ? .semibold : .regular))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    private func openSettings() {
        let candidates = ["App-prefs:Privacy&path=DEVELOPER_MODE", "App-prefs:Privacy", UIApplication.openSettingsURLString]
        func attempt(_ index: Int) {
            guard index < candidates.count, let url = URL(string: candidates[index]) else { return }
            openURL(url) { accepted in if !accepted { attempt(index + 1) } }
        }
        attempt(0)
    }
}
