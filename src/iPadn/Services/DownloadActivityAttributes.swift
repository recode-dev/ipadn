import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Int
        var name: String
        var count: Int
        var written: Int64
        var expected: Int64
        var updated: Date
        var estimatedEnd: Date?
    }
}
