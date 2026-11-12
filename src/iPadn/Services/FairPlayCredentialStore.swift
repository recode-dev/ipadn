import Foundation
import Security

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
            throw ToolError.message(AppText.text("The credential must be 16 bytes (32 hex characters)"))
        }
        let attributes: [String: Any] = [
            kSecValueData as String: credential,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ToolError.message(AppText.text("Could not save the credential (\(added))")) }
        } else if status != errSecSuccess {
            throw ToolError.message(AppText.text("Could not update the credential (\(status))"))
        }
    }

    static func remove() {
        SecItemDelete(query() as CFDictionary)
    }

    static var credentialEndpoint = URL(string: "https://raw.githubusercontent.com/recode-dev/ipadn/main/credential.bin")

    static func fetchFromEndpoint() async -> Data? {
        if let cached = load() { return cached }
        guard let endpoint = credentialEndpoint else { return nil }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        guard let data = try? await URLSession.shared.data(for: request).0 else { return nil }
        let parsed = data.count == 16 ? data : parse(String(data: data, encoding: .utf8) ?? "")
        guard let parsed else { return nil }
        try? save(parsed)
        return parsed
    }

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
