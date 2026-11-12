import Foundation
import Security

/// The 16-byte per-account FairPlay credential that unlocks SINF records for
/// every app that account owns. Obtained once (for example from the repo's
/// `fp-credential` workflow, which signs the Apple ID into the macOS App
/// Store on a runner and saves `~/Library/FairPlay/credential.bin`), stored in
/// the keychain, reused for every decryption afterwards.
enum FairPlayCredentialStore {

    static let hexLength = 32

    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.fairplay" : ".fairplay")
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "fairplay-credential-v1"]
    }

    /// The stored 16-byte credential, or nil when none was imported yet.
    static func load() -> Data? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 16 else { return nil }
        return data
    }

    static func save(_ credential: Data) throws {
        guard credential.count == 16 else {
            throw ToolError.message(AppText.text("凭据必须是 16 字节（32 位十六进制）"))
        }
        let attributes: [String: Any] = [
            kSecValueData as String: credential,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ToolError.message(AppText.text("无法保存凭据（\(added)）")) }
        } else if status != errSecSuccess {
            throw ToolError.message(AppText.text("无法更新凭据（\(status)）"))
        }
    }

    static func remove() {
        SecItemDelete(query() as CFDictionary)
    }

    /// Parses user input into a credential: 32 hex characters, base64, or a
    /// 16-byte file (credential.bin). Whitespace is ignored.
    static func parse(_ raw: String) -> Data? {
        var text = raw
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
        text = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        if text.count == hexLength, text.allSatisfy({ $0.isHexDigit }),
           let data = Data(hexString: text) { return data }
        if let data = Data(base64Encoded: text), data.count == 16 { return data }
        if text.count == 16, let data = text.data(using: .nonLossyASCII), data.count == 16 { return data }
        return nil
    }

    /// Reads a credential from a file (credential.bin style).
    static func parseFile(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.count == 16 { return data }
        if let text = String(data: data, encoding: .utf8) { return parse(text) }
        return nil
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
