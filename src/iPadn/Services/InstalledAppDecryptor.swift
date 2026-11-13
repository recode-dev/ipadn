import Foundation
import ZIPFoundation

@_silgen_name("objc_msgSend")
private func ipadnMsgSendID(_ receiver: UnsafeRawPointer?, _ op: Selector, _ argument: UnsafeRawPointer?) -> UnsafeRawPointer?

@_silgen_name("objc_msgSend")
private func ipadnMsgSendPlain(_ receiver: UnsafeRawPointer?, _ op: Selector) -> UnsafeRawPointer?

@_silgen_name("objc_msgSend")
private func ipadnMsgSendRecordInit(_ receiver: UnsafeRawPointer?, _ op: Selector, _ bundleID: NSString, _ allowPlaceholder: Bool,
                                    _ error: UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UnsafeRawPointer?

@_silgen_name("objc_retainAutoreleasedReturnValue")
private func ipadnRetainAutoreleased(_ value: UnsafeRawPointer?) -> UnsafeRawPointer?

@_silgen_name("objc_release")
private func ipadnRelease(_ value: UnsafeRawPointer?)

enum InstalledAppDecryptor {

    struct InstalledBundle {
        let bundleID: String
        let path: String
        let executable: String
    }

    static func resolve(bundleID: String) -> InstalledBundle? {
        guard !bundleID.isEmpty else { return nil }
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

    private static func classPointer(_ name: String) -> UnsafeRawPointer? {
        guard let cls: AnyClass = NSClassFromString(name) else { return nil }
        return unsafeBitCast(cls, to: UnsafeRawPointer?.self)
    }

    private static func argumentString(_ value: String) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(value as NSString).toOpaque())
    }

    private static func stringValue(_ pointer: UnsafeRawPointer?) -> String? {
        guard let autoreleased = pointer else { return nil }
        guard let retained = ipadnRetainAutoreleased(autoreleased) else { return nil }
        return Unmanaged<NSString>.fromOpaque(retained).takeRetainedValue() as String
    }

    private static func urlValue(_ pointer: UnsafeRawPointer?) -> String? {
        guard let autoreleased = pointer else { return nil }
        guard let retained = ipadnRetainAutoreleased(autoreleased) else { return nil }
        let url = Unmanaged<NSURL>.fromOpaque(retained).takeRetainedValue()
        return (url.path as String?) ?? (url.absoluteString as String?)
    }

    private static func workspacePointer() -> UnsafeRawPointer? {
        guard let cls = classPointer("LSApplicationWorkspace") else { return nil }
        return ipadnMsgSendPlain(cls, NSSelectorFromString("defaultWorkspace"))
    }

    private static func proxyPointers(from workspace: UnsafeRawPointer?) -> [UnsafeRawPointer?] {
        guard let workspace else { return [] }
        for selector in ["allInstalledApplications", "allApplications"] {
            guard let autoreleased = ipadnMsgSendPlain(workspace, NSSelectorFromString(selector)) else { continue }
            guard let retained = ipadnRetainAutoreleased(autoreleased) else { continue }
            let array = Unmanaged<NSArray>.fromOpaque(retained).takeRetainedValue()
            var proxies: [UnsafeRawPointer?] = []
            for index in 0..<array.count {
                guard let element = array.object(at: index) as? NSObject else { continue }
                proxies.append(Unmanaged.passUnretained(element).toOpaque())
            }
            if !proxies.isEmpty { return proxies }
        }
        return []
    }

    private static func bundle(fromProxy proxy: UnsafeRawPointer?, fallbackID: String) -> InstalledBundle? {
        guard let proxy else { return nil }
        let id = stringValue(ipadnMsgSendID(proxy, NSSelectorFromString("valueForKey:"), argumentString("bundleIdentifier"))) ?? fallbackID
        guard let path = urlValue(ipadnMsgSendID(proxy, NSSelectorFromString("valueForKey:"), argumentString("bundleURL"))), !path.isEmpty else { return nil }
        let executable = stringValue(ipadnMsgSendID(proxy, NSSelectorFromString("valueForKey:"), argumentString("bundleExecutable")))
            ?? executableFromInfoPlist(path: path) ?? ""
        guard !executable.isEmpty else { return nil }
        return InstalledBundle(bundleID: id, path: path, executable: executable)
    }

    private static func resolveViaWorkspace(bundleID: String) -> InstalledBundle? {
        for proxy in proxyPointers(from: workspacePointer()) {
            let id = stringValue(ipadnMsgSendID(proxy, NSSelectorFromString("valueForKey:"), argumentString("bundleIdentifier")))
            guard id == bundleID else { continue }
            if let bundle = bundle(fromProxy: proxy, fallbackID: bundleID) { return bundle }
        }
        return nil
    }

    private static func resolveViaProxy(bundleID: String) -> InstalledBundle? {
        guard let cls = classPointer("LSApplicationProxy") else { return nil }
        let autoreleased = ipadnMsgSendID(cls, NSSelectorFromString("applicationProxyForIdentifier:"), argumentString(bundleID))
        guard let retained = autoreleased.flatMap({ ipadnRetainAutoreleased($0) }) else { return nil }
        let proxy = Unmanaged<AnyObject>.fromOpaque(retained).takeRetainedValue()
        let proxyPointer = Unmanaged.passUnretained(proxy).toOpaque()
        return bundle(fromProxy: proxyPointer, fallbackID: bundleID)
    }

    private static func resolveViaRecord(bundleID: String) -> InstalledBundle? {
        guard let cls = classPointer("LSApplicationRecord") else { return nil }
        guard let allocated = ipadnMsgSendPlain(cls, NSSelectorFromString("alloc")) else { return nil }
        var failure: Unmanaged<NSError>? = nil
        let identifier = bundleID as NSString
        guard let recordPointer = ipadnMsgSendRecordInit(allocated, NSSelectorFromString("initWithBundleIdentifier:allowPlaceholder:error:"),
                                                         identifier, false, &failure) else {
            ipadnRelease(allocated)
            return nil
        }
        let record = Unmanaged<AnyObject>.fromOpaque(recordPointer).takeRetainedValue()
        let recordReference = Unmanaged.passUnretained(record).toOpaque()
        guard let path = urlValue(ipadnMsgSendID(recordReference, NSSelectorFromString("valueForKey:"), argumentString("URL"))), !path.isEmpty else { return nil }
        let executableURL = urlValue(ipadnMsgSendID(recordReference, NSSelectorFromString("valueForKey:"), argumentString("executableURL")))
        var executable = executableURL.map { ($0 as NSString).lastPathComponent } ?? ""
        if executable.isEmpty { executable = executableFromInfoPlist(path: path) ?? "" }
        guard !executable.isEmpty else { return nil }
        return InstalledBundle(bundleID: bundleID, path: path, executable: executable)
    }

    private static func executableFromInfoPlist(path: String) -> String? {
        let plistPath = (path as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
        return executable
    }
}
