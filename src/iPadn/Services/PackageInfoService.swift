import Foundation
import ZIPFoundation

/// What a package declares about itself, read from its Info.plist files only.
/// Nothing in the package is run or decrypted.
struct PackageInfo: Equatable {
    struct Permission: Equatable, Identifiable {
        var key: String
        /// The developer's reason, in the package's own language.
        var reason: String
        var id: String { key }
    }
    struct Extension: Equatable, Identifiable {
        var name: String
        var point: String
        var id: String { point + "|" + name }
    }
    var name = ""
    var bundleID = ""
    var version = ""
    var build = ""
    var minimumOS = ""
    var devices = ""
    var languages: [String] = []
    var permissions: [Permission] = []
    var extensions: [Extension] = []
    var urlSchemes: [String] = []
    var backgroundModes: [String] = []
    var hasWatchApp = false
    var hasAppClip = false
    var frameworks = 0
    var frameworkNames: [String] = []
    /// The package file's size on disk.
    var packageSize: Int64 = 0
}

enum PackageInfoService {
    static func read(_ url: URL) throws -> PackageInfo {
        let archive = try Archive(url: url, accessMode: .read)
        guard let main = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message(AppText.text("This isn't a valid IPA package")) }
        let prefix = String(main.path.dropLast("Info.plist".count))
        let plist = try readPlist(main, archive: archive)
        var paths: [String] = []
        for entry in archive where entry.path.hasPrefix(prefix) { paths.append(String(entry.path.dropFirst(prefix.count))) }

        var info = describe(plist)
        info.devices = PackageService.describePlatforms(families: Set(plist["UIDeviceFamily"] as? [Int] ?? []),
                                                        platforms: Set(plist["CFBundleSupportedPlatforms"] as? [String] ?? []))
        info.languages = languages(in: paths)
        info.hasWatchApp = paths.contains { $0.hasPrefix("Watch/") }
        info.hasAppClip = paths.contains { $0.hasPrefix("AppClips/") }
        info.frameworkNames = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count >= 2 && parts[0] == "Frameworks" ? String(parts[1]) : nil
        }).sorted()
        info.frameworks = info.frameworkNames.count
        info.packageSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        // Extensions: PlugIns/*.appex and Extensions/*.appex, each with its own Info.plist.
        for path in paths where isExtensionInfo(path) {
            guard let entry = archive[prefix + path], let extensionPlist = try? readPlist(entry, archive: archive) else { continue }
            let point = plistString((extensionPlist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
                                    ?? (extensionPlist["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"])
            let name = plistString(extensionPlist["CFBundleDisplayName"] ?? extensionPlist["CFBundleName"])
            info.extensions.append(.init(name: name.isEmpty ? String(path.split(separator: "/")[1].dropLast(".appex".count)) : name, point: point))
        }
        info.extensions.sort { ($0.point, $0.name) < ($1.point, $1.name) }
        return info
    }

    /// The parts of a main Info.plist the page shows. Internal for tests.
    static func describe(_ plist: [String: Any]) -> PackageInfo {
        var info = PackageInfo()
        info.name = plistString(plist["CFBundleDisplayName"] ?? plist["CFBundleName"])
        info.bundleID = plistString(plist["CFBundleIdentifier"])
        info.version = plistString(plist["CFBundleShortVersionString"])
        info.build = plistString(plist["CFBundleVersion"])
        info.minimumOS = plistString(plist["MinimumOSVersion"])
        info.permissions = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
            .map { PackageInfo.Permission(key: $0, reason: plistString(plist[$0])) }
        info.urlSchemes = ((plist["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .filter { !$0.isEmpty }
        info.urlSchemes = Array(NSOrderedSet(array: info.urlSchemes)) as? [String] ?? info.urlSchemes
        info.backgroundModes = (plist["UIBackgroundModes"] as? [String] ?? []).sorted()
        return info
    }

    static func isExtensionInfo(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 3 && (parts[0] == "PlugIns" || parts[0] == "Extensions")
            && parts[1].hasSuffix(".appex") && parts[2] == "Info.plist"
    }

    /// Localizations the app ships, as language codes; Base is not a language.
    static func languages(in paths: [String]) -> [String] {
        Set(paths.compactMap { path -> String? in
            guard let first = path.split(separator: "/").first, first.hasSuffix(".lproj") else { return nil }
            let code = String(first.dropLast(".lproj".count))
            return code == "Base" || code.isEmpty ? nil : code
        }).sorted()
    }

    private static func readPlist(_ entry: Entry, archive: Archive) throws -> [String: Any] {
        let limit = 2 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { throw ToolError.message(AppText.text("The package is damaged")) }
        var data = Data()
        _ = try archive.extract(entry, consumer: {
            guard data.count + $0.count <= limit else { throw ToolError.message(AppText.text("The package is damaged")) }
            data.append($0)
        })
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.message(AppText.text("The package is damaged"))
        }
        return result
    }

    /// Permissions under their readable names, one row per name: several keys
    /// mean the same thing (old and new Bluetooth or location keys).
    static func groupedPermissions(_ permissions: [PackageInfo.Permission]) -> [(name: String, reasons: [String])] {
        var groups: [(name: String, reasons: [String])] = []
        for permission in permissions {
            let name = permissionName(permission.key) ?? permission.key
            let reason = permission.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = groups.firstIndex(where: { $0.name == name }) {
                if !reason.isEmpty && !groups[index].reasons.contains(reason) { groups[index].reasons.append(reason) }
            } else {
                groups.append((name, reason.isEmpty ? [] : [reason]))
            }
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A readable name for a privacy permission key; nil for keys without one.
    static func permissionName(_ key: String) -> String? {
        let names: [String: String] = [
            "NSCameraUsageDescription": "Camera",
            "NSMicrophoneUsageDescription": "Microphone",
            "NSPhotoLibraryUsageDescription": "Photos",
            "NSPhotoLibraryAddUsageDescription": "Add to Photos",
            "NSLocationWhenInUseUsageDescription": "Location While Using",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "Location Always",
            "NSLocationAlwaysUsageDescription": "Location Always",
            "NSLocationUsageDescription": "Location",
            "NSContactsUsageDescription": "Contacts",
            "NSCalendarsUsageDescription": "Calendars",
            "NSCalendarsFullAccessUsageDescription": "Calendars",
            "NSCalendarsWriteOnlyAccessUsageDescription": "Add Calendar Events",
            "NSRemindersUsageDescription": "Reminders",
            "NSRemindersFullAccessUsageDescription": "Reminders",
            "NSBluetoothAlwaysUsageDescription": "Bluetooth",
            "NSBluetoothPeripheralUsageDescription": "Bluetooth",
            "NSLocalNetworkUsageDescription": "Local Network",
            "NSMotionUsageDescription": "Motion & Fitness",
            "NSHealthShareUsageDescription": "Read Health Data",
            "NSHealthUpdateUsageDescription": "Write Health Data",
            "NSSpeechRecognitionUsageDescription": "Speech Recognition",
            "NSAppleMusicUsageDescription": "Media & Apple Music",
            "NSFaceIDUsageDescription": "Face ID",
            "NSUserTrackingUsageDescription": "Tracking",
            "NSHomeKitUsageDescription": "Home",
            "NSSiriUsageDescription": "Siri",
            "NSNearbyInteractionUsageDescription": "Nearby Interactions",
            "NSFocusStatusUsageDescription": "Focus Status",
        ]
        return names[key].map { AppText.text(String.LocalizationValue($0)) }
    }

    /// A readable name for a background mode; nil for unknown modes.
    static func backgroundModeName(_ mode: String) -> String? {
        let names: [String: String] = [
            "audio": "Audio playback", "location": "Location updates", "voip": "Internet calls", "fetch": "Background refresh",
            "remote-notification": "Remote notifications", "processing": "Background tasks", "bluetooth-central": "Bluetooth",
            "bluetooth-peripheral": "Bluetooth", "external-accessory": "External accessories", "nearby-interaction": "Nearby Interactions",
            "push-to-talk": "Push to talk",
        ]
        return names[mode].map { AppText.text(String.LocalizationValue($0)) }
    }

    /// A readable name for an extension point; nil for unknown points.
    static func extensionKind(_ point: String) -> String? {
        let kinds: [String: String] = [
            "com.apple.widgetkit-extension": "Widget",
            "com.apple.share-services": "Share",
            "com.apple.ui-services": "Action",
            "com.apple.usernotifications.service": "Notification service",
            "com.apple.usernotifications.content-extension": "Notification content",
            "com.apple.keyboard-service": "Keyboard",
            "com.apple.intents-service": "Siri & Shortcuts",
            "com.apple.intents-ui-service": "Siri & Shortcuts",
            "com.apple.appintents-extension": "Siri & Shortcuts",
            "com.apple.photo-editing": "Photo editing",
            "com.apple.fileprovider-nonui": "File provider",
            "com.apple.fileprovider-actionsui": "File provider",
            "com.apple.networkextension.packet-tunnel": "VPN",
            "com.apple.Safari.web-extension": "Safari extension",
            "com.apple.Safari.content-blocker": "Safari content blocker",
            "com.apple.callkit.call-directory": "Call identification",
            "com.apple.broadcast-services-upload": "Screen broadcast",
            "com.apple.broadcast-services-setupui": "Screen broadcast",
            "com.apple.message-payload-provider": "iMessage",
            "com.apple.background-asset-downloader-extension": "Background assets",
            "com.apple.spotlight.import": "Spotlight",
        ]
        return kinds[point].map { AppText.text(String.LocalizationValue($0)) }
    }
}
