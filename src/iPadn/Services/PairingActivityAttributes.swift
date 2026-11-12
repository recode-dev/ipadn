import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: Int
        var code: String?
        var message: String?
    }
    var hostName: String
}
