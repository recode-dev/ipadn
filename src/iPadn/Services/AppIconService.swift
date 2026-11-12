import UIKit
import Combine

@MainActor
final class AppIconService: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case dimensional, flat
        var id: String { rawValue }
        var title: String { self == .dimensional ? AppText.text("Dimensional icon") : AppText.text("Flat icon") }
        var preview: String { self == .dimensional ? "BrandMark" : "FlatBrandMark" }
    }
    enum Theme: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String { self == .automatic ? AppText.text("Follow system") : self == .light ? AppText.text("Light") : AppText.text("Dark") }
    }
    struct Selection: Equatable {
        var style: Choice
        var theme: Theme
        var alternateName: String? {
            switch (style, theme) {
            case (.dimensional, .dark): return nil
            case (.dimensional, .automatic): return "AppIconAuto"
            case (.flat, .automatic): return "AppIconFlat"
            case (_, .light): return style == .flat ? "AppIconFlatLight" : "AppIconLight"
            case (.flat, .dark): return "AppIconFlatDark"
            }
        }
    }

    static let primary = Selection(style: .dimensional, theme: .dark)
    @Published private(set) var current = AppIconService.primary
    var selected: Choice { current.style }
    var theme: Theme { current.theme }
    @Published private(set) var changing = false
    @Published private(set) var awaitingSystem: Selection?
    @Published private(set) var statusHint: String?

    private var reconciliation: Task<Void, Never>?
    private static var confirmedThisLaunch: Selection?

    private var simulatesChanges: Bool {
        #if DEBUG
        return LocalResources.isPreview && !ProcessInfo.processInfo.arguments.contains("--system-icon-test")
        #else
        return false
        #endif
    }
    var supported: Bool { simulatesChanges || UIApplication.shared.supportsAlternateIcons }

    static func systemSelection(for alternateIconName: String?) -> Selection {
        if alternateIconName == "AppIconDark" { return primary }
        for style in Choice.allCases {
            for theme in Theme.allCases where Selection(style: style, theme: theme).alternateName == alternateIconName {
                return Selection(style: style, theme: theme)
            }
        }
        return primary
    }
    static func systemChoice(for alternateIconName: String?) -> Choice { systemSelection(for: alternateIconName).style }

    private static let rememberedKey = "appIconRememberedAlternate"
    static var rememberedAlternate: String? {
        get { UserDefaults.standard.string(forKey: rememberedKey) }
        set { UserDefaults.standard.set(newValue, forKey: rememberedKey) }
    }
    static func effectiveSelection(reported: String?, remembered: String?,
                                   isBundled: ((String) -> Bool)? = nil) -> Selection {
        if reported == nil, let remembered, isBundled?(remembered) ?? bundledAlternateIsAvailable(remembered) {
            return systemSelection(for: remembered)
        }
        return systemSelection(for: reported)
    }
    private static var observedSelection: Selection {
        effectiveSelection(reported: UIApplication.shared.alternateIconName, remembered: rememberedAlternate)
    }

    static func bundledAlternateIsAvailable(_ name: String = "AppIconFlat", in bundle: Bundle = .main) -> Bool {
        guard let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any],
              let entry = alternates[name] as? [String: Any],
              let names = entry["CFBundleIconFiles"] as? [String], !names.isEmpty
        else { return false }
        return bundle.url(forResource: name + "60x60@2x", withExtension: "png") != nil ||
            bundle.url(forResource: name + "60x60@3x", withExtension: "png") != nil
    }

    static func isTransientIconError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == 35
    }

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        let observed = Self.observedSelection
        current = Self.confirmedThisLaunch ?? observed
        let reported = Self.systemSelection(for: UIApplication.shared.alternateIconName)
        if awaitingSystem == reported {
            confirm(reported)
        }
    }

    private func confirm(_ choice: Selection) {
        Self.confirmedThisLaunch = choice
        Self.rememberedAlternate = choice.alternateName
        current = choice
        awaitingSystem = nil
        statusHint = nil
        reconciliation?.cancel()
        reconciliation = nil
    }

    func select(_ style: Choice) async throws {
        refresh()
        try await apply(Selection(style: style, theme: current.theme))
    }
    func select(theme: Theme) async throws {
        refresh()
        try await apply(Selection(style: current.style, theme: theme), reapplyPrimary: true)
    }

    private func apply(_ choice: Selection, reapplyPrimary: Bool = false) async throws {
        guard !changing else { throw ToolError.message(AppText.text("Waiting for the system to change the icon")) }
        guard choice != current || (reapplyPrimary && choice.alternateName == nil) else { return }
        guard supported else { throw ToolError.message(AppText.text("This device doesn't support changing the icon")) }
        guard simulatesChanges || UIApplication.shared.applicationState == .active else {
            throw ToolError.message(AppText.text("Return to the app before changing the icon"))
        }
        changing = true
        defer { changing = false }
        if simulatesChanges { current = choice; return }
        guard choice.alternateName.map({ Self.bundledAlternateIsAvailable($0) }) ?? true else {
            throw ToolError.message(AppText.text("This build of iPadn is missing icon assets, so the icon can't be changed"))
        }
        reconciliation?.cancel()
        reconciliation = nil
        awaitingSystem = nil
        statusHint = nil

        if choice.alternateName == nil, UIApplication.shared.alternateIconName == nil,
           let restated = [Self.rememberedAlternate, "AppIconLight"].compactMap({ $0 }).first(where: { Self.bundledAlternateIsAvailable($0) }),
           Self.rememberedAlternate != nil || (reapplyPrimary && choice == current) {
            _ = await request(Self.systemSelection(for: restated))
            try? await Task.sleep(for: .milliseconds(800))
        }

        var lastError: Error?
        let delays = [800, 1600, 2400, 3200, 4000, 5000, 6000, 8000, 10000, 10000, 10000]
        for attempt in 0...delays.count {
            let result = await request(choice)
            if result == nil || Self.systemSelection(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
            lastError = result
            guard let error = result, Self.isTransientIconError(error), attempt < delays.count else { break }
            try await Task.sleep(for: .milliseconds(delays[attempt]))
            if Self.systemSelection(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
        }
        if lastError is IconRequestTimeout || lastError.map(Self.isTransientIconError) == true {
            awaitingSystem = choice
            statusHint = AppText.text("Changing the icon…")
            beginReconciliation()
            return
        }
        throw ToolError.message(AppText.text("Couldn't change the icon. Try again later."))
    }

    private struct IconRequestTimeout: Error {}

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Error?, Never>?
        init(_ continuation: CheckedContinuation<Error?, Never>) { self.continuation = continuation }
        func resume(_ error: Error?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: error)
        }
    }

    private func request(_ choice: Selection) async -> Error? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let once = ResumeOnce(continuation)
            UIApplication.shared.setAlternateIconName(choice.alternateName) { error in once.resume(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { once.resume(IconRequestTimeout()) }
        }
    }

    private func beginReconciliation() {
        reconciliation?.cancel()
        reconciliation = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let self, self.awaitingSystem != nil else { return }
                self.refresh()
            }
            guard let self, self.awaitingSystem != nil else { return }
            self.awaitingSystem = nil
            Self.confirmedThisLaunch = nil
            self.statusHint = AppText.text("The system didn't confirm the change. Check the Home Screen.")
            self.refresh()
        }
    }
}
