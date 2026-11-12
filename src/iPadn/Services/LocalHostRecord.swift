import Foundation
import CFNetwork
import dnssd

final class LocalHostRecord: @unchecked Sendable {
    static let shared = LocalHostRecord()
    static let host = "ipadn.local"
    private let queue = DispatchQueue(label: "iPadn.local-host-record")
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?

    func publish() -> Bool {
        queue.sync {
            if connection != nil { return true }
            var connection: DNSServiceRef?
            guard DNSServiceCreateConnection(&connection) == DNSServiceErrorType(kDNSServiceErr_NoError), let connection else {
                return false
            }
            var record: DNSRecordRef?
            let address: [UInt8] = [127, 0, 0, 1]
            let status = address.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsShared),
                                         UInt32.max,
                                         Self.host + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                         UInt16(bytes.count), bytes.baseAddress, 60,
                                         { _, _, _, error, _ in
                                             if error != DNSServiceErrorType(kDNSServiceErr_NoError) {
                                                 InstallLog.shared.add("ipadn.local record error \(error)")
                                             }
                                         }, nil)
            }
            guard status == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                InstallLog.shared.add("ipadn.local record not registered (\(status))")
                DNSServiceRefDeallocate(connection)
                return false
            }
            DNSServiceSetDispatchQueue(connection, queue)
            self.connection = connection; self.record = record
            InstallLog.shared.add("ipadn.local record registered")
            return true
        }
    }

    static var proxyOrVPNActive: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        if (settings["HTTPEnable"] as? Int) == 1 || (settings["HTTPSEnable"] as? Int) == 1 || (settings["ProxyAutoConfigEnable"] as? Int) == 1 {
            return true
        }
        let scoped = (settings["__SCOPED__"] as? [String: Any]).map { Array($0.keys) } ?? []
        return scoped.contains { name in ["utun", "tun", "tap", "ppp", "ipsec"].contains { name.hasPrefix($0) } }
    }
}
