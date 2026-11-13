import Foundation
import ZIPFoundation

@_silgen_name("ipadn_ls_class")
private func ipadnLsClass(_ className: UnsafePointer<CChar>) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_send_plain")
private func ipadnLsSendPlain(_ receiver: UnsafeRawPointer?, _ selectorName: UnsafePointer<CChar>) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_send_plain_retained")
private func ipadnLsSendPlainRetained(_ receiver: UnsafeRawPointer?, _ selectorName: UnsafePointer<CChar>) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_send_id_retained")
private func ipadnLsSendIDRetained(_ receiver: UnsafeRawPointer?, _ selectorName: UnsafePointer<CChar>, _ argument: UnsafeRawPointer?) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_send_record_init")
private func ipadnLsSendRecordInit(_ receiver: UnsafeRawPointer?, _ selectorName: UnsafePointer<CChar>, _ argument: UnsafeRawPointer?, _ placeholder: Int32, _ error: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_is_array")
private func ipadnLsIsArray(_ value: UnsafeRawPointer?) -> Int32

@_silgen_name("ipadn_ls_retain")
private func ipadnLsRetain(_ value: UnsafeRawPointer?) -> UnsafeRawPointer?

@_silgen_name("ipadn_ls_release")
private func ipadnLsRelease(_ value: UnsafeRawPointer?)

enum InstalledAppDecryptor {

    struct InstalledBundle {
        let bundleID: String
        let path: String
        let executable: String
    }

    static func resolve(bundleID: String) -> InstalledBundle? {
        guard !bundleID.isEmpty else { return nil }
        if let bundle = resolveViaFilesystem(bundleID: bundleID) { return bundle }
        if let bundle = resolveViaWorkspace(bundleID: bundleID) { return bundle }
        if let bundle = resolveViaProxy(bundleID: bundleID) { return bundle }
        return resolveViaRecord(bundleID: bundleID)
    }

    static func decryptInstalled(at bundle: InstalledBundle, destination: URL) throws -> FairPlayDecryptor.IpaResult {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.message(AppText.text("The output file already exists"))
        }
        let root = bundle.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.message(AppText.text("The installed app bundle could not be located on this device"))
        }
        let appDirName = (root as NSString).lastPathComponent
        let staging = LocalResources.support.appendingPathComponent("installed-decrypted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let outAppDir = staging.appendingPathComponent("Payload", isDirectory: true).appendingPathComponent(appDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: outAppDir, withIntermediateDirectories: true)

        var reports: [FairPlayDecryptor.BinaryReport] = []
        var keptEncrypted: [String] = []
        var firstMremapError: FairPlayKernelDecryptor.KernelError?
        var lastError: Error?
        var wroteAny = false

        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let element = enumerator?.nextObject() as? URL {
            let relative = element.path.replacingOccurrences(of: root + "/", with: "")
            guard !relative.isEmpty else { continue }
            let parts = relative.split(separator: "/").map(String.init)
            if parts.last == "SC_Info" {
                enumerator?.skipDescendants()
                continue
            }
            if parts.contains("SC_Info") { continue }
            let link = (try? element.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if link { continue }
            let directory = (try? element.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if directory { continue }
            let outPath = outAppDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: outPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let magic = fileMagic(at: element.path)
            if FairPlayDecryptor.isMachOMagic(magic) {
                do {
                    let pages = try FairPlayKernelDecryptor.decryptBinaryFile(at: element, destination: outPath)
                    reports.append(FairPlayDecryptor.BinaryReport(path: "Payload/\(appDirName)/\(relative)", pages: pages))
                    wroteAny = true
                } catch FairPlayDecryptor.DecryptError.notEncrypted {
                    try FileManager.default.copyItem(at: element, to: outPath)
                    wroteAny = true
                } catch FairPlayDecryptor.DecryptError.notMachO {
                    try FileManager.default.copyItem(at: element, to: outPath)
                    wroteAny = true
                } catch let error as FairPlayKernelDecryptor.KernelError {
                    if case .mremap = error, firstMremapError == nil { firstMremapError = error }
                    keptEncrypted.append(relative)
                    lastError = error
                } catch {
                    keptEncrypted.append(relative)
                    lastError = error
                }
            } else {
                try FileManager.default.copyItem(at: element, to: outPath)
                wroteAny = true
            }
        }

        guard wroteAny, !reports.isEmpty else {
            if let firstMremapError { throw firstMremapError }
            if let lastError { throw lastError }
            throw FairPlayDecryptor.DecryptError.notEncrypted
        }

        try? FileManager.default.removeItem(at: destination)
        let output = try Archive(url: destination, accessMode: .create)
        let stagedFiles = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
        while let element = stagedFiles?.nextObject() as? URL {
            let values = try? element.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let relative = element.path.replacingOccurrences(of: staging.path + "/", with: "")
            guard !relative.isEmpty else { continue }
            try output.addEntry(with: relative, relativeTo: staging, compressionMethod: .deflate)
        }
        return FairPlayDecryptor.IpaResult(destination: destination, binaries: reports, stripped: true,
                                           encryptedSkipped: keptEncrypted)
    }

    private static func fileMagic(at path: String) -> [UInt8] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4)) ?? Data()
        return Array(data)
    }

    private static func resolveViaFilesystem(bundleID: String) -> InstalledBundle? {
        var scanned = Set<String>()
        for root in filesystemRoots() {
            guard scanned.insert(root.path).inserted else { continue }
            for directory in appBundleDirectories(root: root) {
                if let bundle = installedBundle(at: directory, bundleID: bundleID) { return bundle }
            }
        }
        return nil
    }

    private static func filesystemRoots() -> [URL] {
        var roots: [URL] = []
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        if parent.lastPathComponent == "Applications" { roots.append(parent) }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documents.appendingPathComponent("Applications", isDirectory: true))
        }
        roots.append(URL(fileURLWithPath: "/private/var/containers/Bundle/Application"))
        return roots
    }

    private static func appBundleDirectories(root: URL) -> [URL] {
        var result: [URL] = []
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: [.skipsHiddenFiles]) else { return result }
        for child in children {
            let directory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard directory else { continue }
            if child.pathExtension.lowercased() == "app" {
                result.append(child)
                continue
            }
            if let nested = try? FileManager.default.contentsOfDirectory(at: child,
                                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                                        options: [.skipsHiddenFiles]) {
                for item in nested where item.pathExtension.lowercased() == "app" {
                    result.append(item)
                }
            }
        }
        return result
    }

    private static func installedBundle(at directory: URL, bundleID: String) -> InstalledBundle? {
        let plist = infoPlistDictionary(at: directory)
        let identifier = plist?["CFBundleIdentifier"] as? String
        if let identifier, identifier != bundleID { return nil }
        if identifier == nil, directory.lastPathComponent != bundleID + ".app" { return nil }
        let executable = (plist?["CFBundleExecutable"] as? String)
            ?? (directory.lastPathComponent as NSString).deletingPathExtension
        guard !executable.isEmpty else { return nil }
        return InstalledBundle(bundleID: identifier ?? bundleID, path: directory.path, executable: executable)
    }

    private static func infoPlistDictionary(at directory: URL) -> [String: Any]? {
        let plistURL = directory.appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return plist as? [String: Any]
    }

    private static func argumentString(_ value: String) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(value as NSString).toOpaque())
    }

    private static func stringValue(_ pointer: UnsafeRawPointer?) -> String? {
        guard let pointer else { return nil }
        return Unmanaged<NSString>.fromOpaque(pointer).takeRetainedValue() as String
    }

    private static func urlValue(_ pointer: UnsafeRawPointer?) -> String? {
        guard let pointer else { return nil }
        let url = Unmanaged<NSURL>.fromOpaque(pointer).takeRetainedValue()
        return (url.path as String?) ?? (url.absoluteString as String?)
    }

    private static func workspaceInstance() -> UnsafeRawPointer? {
        guard let cls = ipadnLsClass("LSApplicationWorkspace") else { return nil }
        return ipadnLsSendPlainRetained(cls, "defaultWorkspace")
    }

    private static func installedProxies(workspace: UnsafeRawPointer?) -> [UnsafeRawPointer?] {
        var proxies: [UnsafeRawPointer?] = []
        guard let workspace else { return proxies }
        for selector in ["allInstalledApplications", "allApplications"] {
            guard let arrayPointer = ipadnLsSendPlainRetained(workspace, selector) else { continue }
            guard ipadnLsIsArray(arrayPointer) != 0 else {
                ipadnLsRelease(arrayPointer)
                continue
            }
            let array = Unmanaged<NSArray>.fromOpaque(arrayPointer).takeRetainedValue()
            for index in 0..<array.count {
                guard let element = array.object(at: index) as? NSObject else { continue }
                let pointer = Unmanaged.passUnretained(element).toOpaque()
                if ipadnLsRetain(pointer) != nil { proxies.append(pointer) }
            }
            if !proxies.isEmpty { return proxies }
        }
        return proxies
    }

    private static func bundle(fromProxy proxy: UnsafeRawPointer?, fallbackID: String) -> InstalledBundle? {
        guard let proxy else { return nil }
        let id = stringValue(ipadnLsSendIDRetained(proxy, "valueForKey:", argumentString("bundleIdentifier"))) ?? fallbackID
        guard let path = urlValue(ipadnLsSendIDRetained(proxy, "valueForKey:", argumentString("bundleURL"))), !path.isEmpty else { return nil }
        let executable = stringValue(ipadnLsSendIDRetained(proxy, "valueForKey:", argumentString("bundleExecutable")))
            ?? executableFromInfoPlist(path: path) ?? ""
        guard !executable.isEmpty else { return nil }
        return InstalledBundle(bundleID: id, path: path, executable: executable)
    }

    private static func resolveViaWorkspace(bundleID: String) -> InstalledBundle? {
        let workspace = workspaceInstance()
        defer { ipadnLsRelease(workspace) }
        for proxy in installedProxies(workspace: workspace) {
            defer { ipadnLsRelease(proxy) }
            let id = stringValue(ipadnLsSendIDRetained(proxy, "valueForKey:", argumentString("bundleIdentifier")))
            guard id == bundleID else { continue }
            if let bundle = bundle(fromProxy: proxy, fallbackID: bundleID) { return bundle }
        }
        return nil
    }

    private static func resolveViaProxy(bundleID: String) -> InstalledBundle? {
        guard let cls = ipadnLsClass("LSApplicationProxy") else { return nil }
        guard let retained = ipadnLsSendIDRetained(cls, "applicationProxyForIdentifier:", argumentString(bundleID)) else { return nil }
        let proxy = Unmanaged<AnyObject>.fromOpaque(retained).takeRetainedValue()
        let proxyPointer = Unmanaged.passUnretained(proxy).toOpaque()
        return bundle(fromProxy: proxyPointer, fallbackID: bundleID)
    }

    private static func resolveViaRecord(bundleID: String) -> InstalledBundle? {
        guard let cls = ipadnLsClass("LSApplicationRecord") else { return nil }
        guard let allocated = ipadnLsSendPlain(cls, "alloc") else { return nil }
        var failure: UnsafeMutableRawPointer? = nil
        let identifier = argumentString(bundleID)
        guard let recordPointer = ipadnLsSendRecordInit(allocated, "initWithBundleIdentifier:allowPlaceholder:error:",
                                                        identifier, 0, &failure) else {
            ipadnLsRelease(allocated)
            return nil
        }
        let record = Unmanaged<AnyObject>.fromOpaque(recordPointer).takeRetainedValue()
        let recordReference = Unmanaged.passUnretained(record).toOpaque()
        guard let path = urlValue(ipadnLsSendIDRetained(recordReference, "valueForKey:", argumentString("URL"))), !path.isEmpty else { return nil }
        let executableURL = urlValue(ipadnLsSendIDRetained(recordReference, "valueForKey:", argumentString("executableURL")))
        var executable = executableURL.map { ($0 as NSString).lastPathComponent } ?? ""
        if executable.isEmpty { executable = executableFromInfoPlist(path: path) ?? "" }
        guard !executable.isEmpty else { return nil }
        return InstalledBundle(bundleID: bundleID, path: path, executable: executable)
    }

    private static func executableFromInfoPlist(path: String) -> String? {
        guard let plist = infoPlistDictionary(at: URL(fileURLWithPath: path)),
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
        return executable
    }
}
