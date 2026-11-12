import ActivityKit
import Foundation

struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: Int
        var code: String?
        var message: String?
    }
    var hostName: String
}
