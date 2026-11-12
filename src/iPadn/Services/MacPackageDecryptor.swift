import Foundation
import Security

enum MacPackageDecryptor {
    enum Stage: Int32 {
        case idle = 0, components, starting, decrypting
        var title: String {
            switch self {
            case .idle: return AppText.text("Preparing")
            case .components: return AppText.text("Downloading required components")
            case .starting: return AppText.text("Preparing")
            case .decrypting: return AppText.text("Processing")
            }
        }
    }

    private typealias DecryptFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<UInt8>, Int32,
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32) -> Int32
    private typealias StatusFunction = @convention(c) (UnsafeMutablePointer<Int64>?) -> Int32
    private typealias CancelFunction = @convention(c) () -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let decryptFunction = symbol("iPadnMacPKGDecrypt", as: DecryptFunction.self)
    private static let statusFunction = symbol("iPadnMacPKGStatus", as: StatusFunction.self)
    private static let cancelFunction = symbol("iPadnMacPKGCancel", as: CancelFunction.self)

    static var isAvailable: Bool { decryptFunction != nil && statusFunction != nil && cancelFunction != nil }

    static func decrypt(hardwareID: String, dpInfo: Data, from source: URL, to destination: URL) throws {
        guard let decryptFunction else {
            throw ToolError.message(AppText.text("This version can't download this Mac package"))
        }
        guard hardwareID.count == 12, hardwareID.allSatisfy(\.isHexDigit), !dpInfo.isEmpty else {
            throw ToolError.message(AppText.text("The download license expired. Get the app again."))
        }
        var message = [CChar](repeating: 0, count: 1024)
        let code = dpInfo.withUnsafeBytes { raw -> Int32 in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            return hardwareID.withCString { hardware in
                source.path.withCString { input in
                    destination.path.withCString { output in
                        decryptFunction(hardware, bytes, Int32(dpInfo.count), input, output, &message, Int32(message.count))
                    }
                }
            }
        }
        if code == 1 { throw CancellationError() }
        guard code == 0 else {
            let text = String(cString: message)
            throw ToolError.message(text.isEmpty ? AppText.text("Couldn't process the Mac package (\(code))") : text)
        }
    }

    static func status() -> (stage: Stage, bytes: Int64)? {
        guard let statusFunction else { return nil }
        var bytes: Int64 = 0
        let stage = Stage(rawValue: statusFunction(&bytes)) ?? .idle
        return (stage, bytes)
    }

    private static let queue = DispatchQueue(label: "iPadn.mac-package", qos: .userInitiated)
    private static let lock = NSLock()
    private static var current: UUID?
    private static var cancelled = Set<UUID>()
    private static var finishCurrent: ((Error?) -> Void)?
    private static var waiting: [UUID: Once] = [:]

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        @discardableResult func finish(_ error: Error?) -> Bool {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            guard let pending else { return false }
            if let error { pending.resume(throwing: error) } else { pending.resume() }
            return true
        }
    }

    static var currentJob: UUID? { lock.lock(); defer { lock.unlock() }; return current }

    static func process(job: UUID, hardwareID: String, dpInfo: Data, from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            lock.lock(); waiting[job] = once; lock.unlock()
            queue.async {
                lock.lock()
                waiting[job] = nil
                let skip = cancelled.remove(job) != nil
                if !skip { current = job; finishCurrent = { once.finish($0) } }
                lock.unlock()
                if skip { once.finish(CancellationError()); return }
                var result: Error?
                do { try decrypt(hardwareID: hardwareID, dpInfo: dpInfo, from: source, to: destination) }
                catch { result = error }
                lock.lock(); current = nil; finishCurrent = nil; cancelled.remove(job); lock.unlock()
                if !once.finish(result) { try? FileManager.default.removeItem(at: destination) }
            }
        }
    }

    static func cancel(job: UUID) {
        lock.lock()
        let running = current == job
        let finish = running ? finishCurrent : nil
        let queued = running ? nil : waiting.removeValue(forKey: job)
        if !running { cancelled.insert(job) }
        lock.unlock()
        finish?(CancellationError())
        queued?.finish(CancellationError())
        if running, let cancelFunction {
            DispatchQueue.global(qos: .userInitiated).async { cancelFunction() }
        }
    }
}

enum MacPackageSecrets {
    struct Entry: Codable, Equatable {
        let hardwareID: String
        let dpInfo: Data
    }

    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.macpkg" : ".macpkg")
    }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func save(_ entry: Entry, for id: UUID) throws {
        delete(id)
        var item = query(id)
        item[kSecValueData as String] = try JSONEncoder().encode(entry)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError.message(AppText.text("Couldn't save the Mac download license (\(status))")) }
    }

    static func load(_ id: UUID) throws -> Entry {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            throw ToolError.message(AppText.text("The download license expired. Delete the task and get the app again."))
        }
        return entry
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
